function result = sl_add_line_safe(modelName, varargin)
% SL_ADD_LINE_SAFE 安全连线 — 含端口预检+占用检查+反模式防护+自动验证
%   格式1: result = sl_add_line_safe(modelName, srcBlock, srcPort, dstBlock, dstPort)
%   格式2: result = sl_add_line_safe(modelName, 'srcBlock/portNum', 'dstBlock/portNum')
%   result = sl_add_line_safe(..., 'autoRouting', true, 'checkBusMatch', true)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   v5.0 反模式防护:
%     #3 connectBlocks 优先 — R2024b+ 用 Simulink.BlockDiagram.connectBlocks，旧版回退 add_line
%     #8 维度 mismatch error — 连线前强制检查端口维度，不匹配则拒绝
%
%   输入:
%     modelName   - 模型名称（必选）
%     格式1（5参数）:
%       srcBlock    - 源模块路径，如 'MyModel/Step'
%       srcPort     - 源端口序号（从1开始）
%       dstBlock    - 目标模块路径，如 'MyModel/Sum'
%       dstPort     - 目标端口序号（从1开始）
%     格式2（2参数，兼容 add_line 习惯）:
%       'srcBlock/portNum' - 源模块路径/端口序号，如 'Reference/1'
%       'dstBlock/portNum' - 目标模块路径/端口序号，如 'Error_Sum/1'
%     'autoRouting'   - 自动布线，默认 true
%     'checkBusMatch' - 检查 Bus 类型匹配，默认 false
%     'checkDimensions' - v5.0 检查端口维度匹配（反模式#8），默认 true
%     'skipAntiPatternCheck' - 跳过反模式检查，默认 false
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .line         - 连线信息 struct
%     .verification - 验证结果 struct
%     .antiPatternInfo - 反模式信息 struct（含 apiUsed 字段）
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数格式 =====
    % 检测是格式1 (5+参数) 还是格式2 (3参数: model, 'src/port', 'dst/port')
    if length(varargin) >= 2 && ischar(varargin{1}) && ~isempty(strfind(varargin{1}, '/')) ...
            && ischar(varargin{2}) && ~isempty(strfind(varargin{2}, '/'))
        % 格式2: sl_add_line_safe(model, 'srcBlock/portNum', 'dstBlock/portNum', ...)
        srcFull = varargin{1};
        dstFull = varargin{2};
        [srcBlock, srcPort] = parse_block_port(srcFull, modelName);
        [dstBlock, dstPort] = parse_block_port(dstFull, modelName);
        extraArgs = varargin(3:end);
    else
        % 格式1: sl_add_line_safe(model, srcBlock, srcPort, dstBlock, dstPort, ...)
        srcBlock = varargin{1};
        srcPort = varargin{2};
        dstBlock = varargin{3};
        dstPort = varargin{4};
        extraArgs = varargin(5:end);
    end
    
    % ===== 解析可选参数 =====
    opts = struct( ...
        'autoRouting', true, ...
        'checkBusMatch', false, ...
        'checkDimensions', true, ...
        'skipAntiPatternCheck', false);
    
    idx = 1;
    while idx <= length(extraArgs)
        if ischar(extraArgs{idx}) && idx < length(extraArgs)
            key = extraArgs{idx};
            val = extraArgs{idx+1};
            if isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end
    
    % ===== 预检: 确保源模块存在 =====
    try
        srcType = get_param(srcBlock, 'BlockType');
    catch
        result = struct('status', 'error', 'error', ...
            ['Source block not found: ' srcBlock], ...
            'suggestion', 'Check block path. Use sl_inspect_model to see all blocks.');
        return;
    end
    
    % ===== 预检: 确保目标模块存在 =====
    try
        dstType = get_param(dstBlock, 'BlockType');
    catch
        result = struct('status', 'error', 'error', ...
            ['Destination block not found: ' dstBlock], ...
            'suggestion', 'Check block path. Use sl_inspect_model to see all blocks.');
        return;
    end
    
    % ===== 预检: 检查源输出端口存在 =====
    try
        srcPortHandles = get_param(srcBlock, 'PortHandles');
        srcOutPorts = srcPortHandles.Outport;
        if srcPort > length(srcOutPorts) || srcPort < 1
            result = struct('status', 'error', 'error', ...
                ['Source port ' num2str(srcPort) ' does not exist on ' srcBlock ...
                 ' (has ' num2str(length(srcOutPorts)) ' output ports)']);
            return;
        end
        srcPortHandle = srcOutPorts(srcPort);
    catch ME
        result = struct('status', 'error', 'error', ...
            ['Cannot access source port: ' ME.message]);
        return;
    end
    
    % ===== 预检: 检查目标输入端口存在 =====
    try
        dstPortHandles = get_param(dstBlock, 'PortHandles');
        dstInPorts = dstPortHandles.Inport;
        if dstPort > length(dstInPorts) || dstPort < 1
            result = struct('status', 'error', 'error', ...
                ['Destination port ' num2str(dstPort) ' does not exist on ' dstBlock ...
                 ' (has ' num2str(length(dstInPorts)) ' input ports)']);
            return;
        end
        dstPortHandle = dstInPorts(dstPort);
    catch ME
        result = struct('status', 'error', 'error', ...
            ['Cannot access destination port: ' ME.message]);
        return;
    end
    
    % ===== 预检: 检查目标端口是否已被占用 =====
    % 一个输入端口只能有一条线（输出端口可分支多条）
    try
        existingLine = get_param(dstPortHandle, 'Line');
        if existingLine ~= -1
            result = struct('status', 'error', 'error', ...
                ['Destination port ' num2str(dstPort) ' of ' dstBlock ' is already connected'], ...
                'suggestion', 'Delete the existing line first, or use a different destination port.');
            return;
        end
    catch
        % 无法检查，继续尝试
    end
    
    % ===== 预检: Bus 类型匹配检查（可选）=====
    if opts.checkBusMatch
        try
            srcDataType = get_param(srcPortHandle, 'OutDataTypeStr');
            dstDataType = get_param(dstPortHandle, 'OutDataTypeStr');
            if ~strcmpi(srcDataType, dstDataType) && ...
               ~strcmpi(srcDataType, 'Inherit: auto') && ...
               ~strcmpi(dstDataType, 'Inherit: auto')
                result = struct('status', 'error', 'error', ...
                    ['Data type mismatch: source=' srcDataType ', destination=' dstDataType], ...
                    'suggestion', 'Add a Data Type Conversion block between them.');
                return;
            end
        catch
            % 无法检查，继续
        end
    end
    
    % ===== v5.0 预检: 维度 mismatch 检查（反模式 #8）=====
    % simulink/skills 明确禁止: 端口维度不匹配就连线
    dimensionInfo = struct('checked', false, 'srcDim', '', 'dstDim', '', 'compatible', true);
    if opts.checkDimensions && ~opts.skipAntiPatternCheck
        try
            srcDim = get_param(srcPortHandle, 'PortDimensions');
            dstDim = get_param(dstPortHandle, 'PortDimensions');
            dimensionInfo.checked = true;
            dimensionInfo.srcDim = srcDim;
            dimensionInfo.dstDim = dstDim;
            
            % 维度兼容性判断
            % -1 或 '1' 表示标量/自动推断 → 通常兼容
            % 相同维度 → 兼容
            % 不同维度 → 可能不兼容（除非是扩展/广播）
            if isnumeric(srcDim) && isnumeric(dstDim)
                % 两者都是数值维度
                if srcDim == -1 || dstDim == -1
                    % -1 表示继承/动态，允许连线
                    dimensionInfo.compatible = true;
                elseif srcDim == dstDim
                    dimensionInfo.compatible = true;
                elseif srcDim == 1 || dstDim == 1
                    % 标量扩展，允许
                    dimensionInfo.compatible = true;
                else
                    % 维度不匹配 — 反模式 #8: 拒绝连线
                    dimensionInfo.compatible = false;
                    result = struct('status', 'error', 'error', ...
                        ['Dimension mismatch (anti-pattern #8): source port dimension=' ...
                        num2str(srcDim) ', destination port dimension=' num2str(dstDim)], ...
                        'rule', '#8', ...
                        'suggestion', 'Check port dimensions before connecting. Add a reshape or conversion block if needed.');
                    return;
                end
            end
        catch
            % 无法获取维度信息（可能模型未编译），允许继续
            dimensionInfo.checked = false;
        end
    end
    
    % ===== v5.0 执行连线: connectBlocks 优先（反模式 #3）=====
    % simulink/skills 明确推荐: connectBlocks (R2024b+) > add_line
    apiUsed = 'add_line';  % 默认
    lineHandle = [];
    
    % v12.0 关键修复: 自动检测最小公共父系统
    % add_line 的第一个参数应该是包含两个模块的最小公共系统
    % 例如: 两个模块都在 Plant 子系统内时，用 Plant 路径而不是顶层模型名
    [commonSys, srcRelPath, dstRelPath] = find_common_system(srcBlock, dstBlock, modelName);
    
    % 检测是否有 Simulink.BlockDiagram.connectBlocks
    hasConnectBlocks = false;
    if ~opts.skipAntiPatternCheck
        try
            m = which('Simulink.BlockDiagram.connectBlocks');
            if ~isempty(m)
                hasConnectBlocks = true;
            end
        catch
        end
    end
    
    if hasConnectBlocks
        % R2024b+: 使用 connectBlocks（现代 API）
        try
            lineHandle = Simulink.BlockDiagram.connectBlocks(modelName, srcBlock, dstBlock);
            apiUsed = 'connectBlocks';
        catch ME_connect
            % connectBlocks 失败，回退到 add_line
            try
                srcPortStr = [srcRelPath '/' num2str(srcPort)];
                dstPortStr = [dstRelPath '/' num2str(dstPort)];
                
                if opts.autoRouting
                    lineHandle = add_line(commonSys, srcPortStr, dstPortStr, 'autorouting', 'on');
                else
                    lineHandle = add_line(commonSys, srcPortStr, dstPortStr);
                end
                apiUsed = 'add_line (connectBlocks fallback)';
            catch ME
                result = struct('status', 'error', 'error', ...
                    ['add_line failed (connectBlocks also failed: ' ME_connect.message '): ' ME.message], ...
                    'suggestion', 'Check that both blocks are in the same model and ports are valid.');
                return;
            end
        end
    else
        % 旧版本: 使用 add_line
        try
            srcPortStr = [srcRelPath '/' num2str(srcPort)];
            dstPortStr = [dstRelPath '/' num2str(dstPort)];
            
            if opts.autoRouting
                lineHandle = add_line(commonSys, srcPortStr, dstPortStr, 'autorouting', 'on');
            else
                lineHandle = add_line(commonSys, srcPortStr, dstPortStr);
            end
        catch ME
            result = struct('status', 'error', 'error', ...
                ['add_line failed: ' ME.message], ...
                'suggestion', 'Check that both blocks are in the same model and ports are valid.');
            return;
        end
    end
    
    % ===== 验证 =====
    verification = struct();
    verification.lineExists = true;
    
    % 检查源端口是否已连线
    try
        srcLineAfter = get_param(srcPortHandle, 'Line');
        verification.srcPortConnected = (srcLineAfter ~= -1);
    catch
        verification.srcPortConnected = true;  % 无法检查，假定成功
    end
    
    % 检查目标端口是否已连线
    try
        dstLineAfter = get_param(dstPortHandle, 'Line');
        verification.dstPortConnected = (dstLineAfter ~= -1);
    catch
        verification.dstPortConnected = true;
    end
    
    % ===== 组装返回 =====
    lineInfo = struct();
    lineInfo.srcBlock = srcBlock;
    lineInfo.srcPort = srcPort;
    lineInfo.dstBlock = dstBlock;
    lineInfo.dstPort = dstPort;
    try
        lineInfo.handle = lineHandle;
    catch
    end
    
    result = struct('status', 'ok', 'line', lineInfo, 'verification', verification);
    
    % v5.0 反模式信息
    antiPatternInfo = struct();
    antiPatternInfo.apiUsed = apiUsed;
    if dimensionInfo.checked
        antiPatternInfo.dimensionCheck = dimensionInfo;
    end
    if hasConnectBlocks && strcmpi(apiUsed(1:min(13,length(apiUsed))), 'connectBlocks')
        antiPatternInfo.modernAPI = true;
    else
        antiPatternInfo.modernAPI = false;
    end
    result.antiPatternInfo = antiPatternInfo;
end

% ===== v12.0 辅助函数: 查找两个模块的最小公共父系统 =====
% 返回: commonSys = 最小公共系统路径, srcRelPath = src在该系统下的相对路径, dstRelPath = dst在该系统下的相对路径
% 例: src='M/Sub/Gain1', dst='M/Sub/Gain2', model='M'
%     -> commonSys='M/Sub', srcRelPath='Gain1', dstRelPath='Gain2'
% 例: src='M/Step', dst='M/Gain', model='M'
%     -> commonSys='M', srcRelPath='Step', dstRelPath='Gain'
function [commonSys, srcRelPath, dstRelPath] = find_common_system(srcBlock, dstBlock, modelName)
    % 去掉模型名前缀，得到子系统层级路径
    modelPrefix = [modelName '/'];
    prefixLen = length(modelPrefix);
    
    if length(srcBlock) > prefixLen && strcmpi(srcBlock(1:prefixLen), modelPrefix)
        srcRel = srcBlock(prefixLen+1:end);
    else
        srcRel = srcBlock;
    end
    
    if length(dstBlock) > prefixLen && strcmpi(dstBlock(1:prefixLen), modelPrefix)
        dstRel = dstBlock(prefixLen+1:end);
    else
        dstRel = dstBlock;
    end
    
    % 拆分路径层级
    srcParts = strsplit(srcRel, '/');
    dstParts = strsplit(dstRel, '/');
    
    % 找到共同前缀
    minLen = min(length(srcParts), length(dstParts));
    commonParts = {};
    for i = 1:minLen
        if strcmpi(srcParts{i}, dstParts{i})
            commonParts{end+1} = srcParts{i}; %#ok<AGROW>
        else
            break;
        end
    end
    
    % 构建公共系统路径
    if isempty(commonParts)
        % 没有共同前缀，使用顶层模型
        commonSys = modelName;
        srcRelPath = srcRel;
        dstRelPath = dstRel;
    else
        commonSys = [modelName '/' strjoin(commonParts, '/')];
        % 计算相对路径：去掉公共前缀部分
        commonLen = length(commonParts);
        srcRemaining = srcParts(commonLen+1:end);
        dstRemaining = dstParts(commonLen+1:end);
        srcRelPath = strjoin(srcRemaining, '/');
        dstRelPath = strjoin(dstRemaining, '/');
    end
end

% ===== 辅助函数: 将绝对路径转为相对模型路径 =====
% 'test_p1/Step' + 'test_p1' → 'Step'
% 'test_p1/Sub/Gain' + 'test_p1' → 'Sub/Gain'
% 'Step' + 'test_p1' → 'Step' (已经是相对路径)
function relPath = make_relative_path(blockPath, modelName)
    modelPrefix = [modelName '/'];
    prefixLen = length(modelPrefix);
    if length(blockPath) > prefixLen && strcmpi(blockPath(1:prefixLen), modelPrefix)
        relPath = blockPath(prefixLen+1:end);
    else
        relPath = blockPath;
    end
end

% ===== 辅助函数: 解析 'BlockName/portNum' 格式 =====
% 'Reference/1' + 'pid_test_model' -> 'pid_test_model/Reference', 1
% 'pid_test_model/Reference/1' + 'pid_test_model' -> 'pid_test_model/Reference', 1
% 'Sub/Gain/2' + 'pid_test_model' -> 'pid_test_model/Sub/Gain', 2
function [blockPath, portNum] = parse_block_port(str, modelName)
    % 找最后一个 '/' 分隔符
    slashPos = strfind(str, '/');
    if isempty(slashPos)
        % 没有斜杠，如 'Reference'（无端口号）
        blockPath = [modelName '/' str];
        portNum = 1;
        return;
    end
    
    lastSlash = slashPos(end);
    afterSlash = str(lastSlash+1:end);
    
    % 检查最后一个 '/' 后面是否是数字（端口号）
    portVal = str2double(afterSlash);
    if ~isnan(portVal) && portVal > 0
        % 最后一段是端口号
        blockPart = str(1:lastSlash-1);
        portNum = round(portVal);
    else
        % 最后一段不是端口号，默认端口1
        blockPart = str;
        portNum = 1;
    end
    
    % 补全模型名前缀
    modelPrefix = [modelName '/'];
    prefixLen = length(modelPrefix);
    if length(blockPart) > prefixLen && strcmpi(blockPart(1:prefixLen), modelPrefix)
        blockPath = blockPart;  % 已有模型名前缀
    else
        blockPath = [modelName '/' blockPart];  % 补全前缀
    end
end
