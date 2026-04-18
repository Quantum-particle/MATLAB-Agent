function result = sl_subsystem_create(modelName, subsystemName, mode, varargin)
% SL_SUBSYSTEM_CREATE 创建子系统 — group/empty 两种模式 + createSubsystem 优先
%   result = sl_subsystem_create('MyModel', 'Controller', 'group', 'blocksToGroup', {'MyModel/Gain1','MyModel/Sum1'})
%   result = sl_subsystem_create('MyModel', 'Controller', 'empty', 'inputPorts', 2, 'outputPorts', 1)
%
%   版本策略: R2017a+ 使用 Simulink.BlockDiagram.createSubsystem (group模式)
%             R2016a 回退手动实现
%
%   输入:
%     modelName      - 模型名称（必选）
%     subsystemName  - 子系统名称（必选），如 'Controller'
%     mode           - 'group' 或 'empty'（必选）
%     'blocksToGroup' - cell{char}，mode='group' 时必填
%     'position'     - [left,top,right,bottom]，mode='empty' 时使用，默认 [200,100,400,250]
%     'inputPorts'   - double，空子系统输入端口数，默认 1
%     'outputPorts'  - double，空子系统输出端口数，默认 1
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .subsystem    - struct(.path, .mode, .inputPorts, .outputPorts, .internalBlocks)
%     .verification - struct(.subsystemExists, .externalConnectionsPreserved)
%     .apiUsed      - 'createSubsystem' / 'manual_group' / 'manual_empty'
%     .antiPatternInfo - struct(.rule, .message, .suggestion) (如触发反模式#6)
%     .error        - 错误信息

    % ===== 默认参数 =====
    opts = struct();
    opts.blocksToGroup = {};
    opts.position = [200, 100, 400, 250];
    opts.inputPorts = 1;
    opts.outputPorts = 1;
    opts.loadModelIfNot = true;

    % ===== 解析 varargin =====
    i = 1;
    while i <= length(varargin)
        key = varargin{i};
        if ischar(key) || isstring(key)
            key = char(key);
            switch lower(key)
                case 'blockstogroup'
                    if i+1 <= length(varargin)
                        opts.blocksToGroup = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'blocksToGroup value missing');
                        return;
                    end
                case 'position'
                    if i+1 <= length(varargin)
                        opts.position = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'position value missing');
                        return;
                    end
                case 'inputports'
                    if i+1 <= length(varargin)
                        opts.inputPorts = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'inputPorts value missing');
                        return;
                    end
                case 'outputports'
                    if i+1 <= length(varargin)
                        opts.outputPorts = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'outputPorts value missing');
                        return;
                    end
                case 'loadmodelifnot'
                    if i+1 <= length(varargin)
                        opts.loadModelIfNot = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'loadModelIfNot value missing');
                        return;
                    end
                otherwise
                    result = struct('status', 'error', 'error', ['Unknown parameter: ' key]);
                    return;
            end
        else
            result = struct('status', 'error', 'error', ['Invalid parameter at position ' num2str(i)]);
            return;
        end
    end

    % ===== 输入验证 =====
    if nargin < 3 || isempty(modelName) || isempty(subsystemName) || isempty(mode)
        result = struct('status', 'error', 'error', 'modelName, subsystemName, and mode are required');
        return;
    end

    mode = lower(char(mode));
    if ~ismember(mode, {'group', 'empty'})
        result = struct('status', 'error', 'error', ['Invalid mode: ' mode '. Use ''group'' or ''empty''.']);
        return;
    end

    if strcmp(mode, 'group') && isempty(opts.blocksToGroup)
        result = struct('status', 'error', 'error', 'blocksToGroup is required for group mode');
        return;
    end

    % ===== 加载模型 =====
    try
        if opts.loadModelIfNot && ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch me
        result = struct('status', 'error', 'error', ['Failed to load model: ' me.message]);
        return;
    end

    % ===== 版本检测 =====
    matlabVer = ver('MATLAB');
    verNum = sscanf(matlabVer.Version, '%d.%d');
    % createSubsystem 从 R2009a 就有，但需要检查是否可用
    hasCreateSubsystem = false;
    try
        m = which('Simulink.BlockDiagram.createSubsystem');
        if ~isempty(m)
            hasCreateSubsystem = true;
        end
    catch
    end

    % ===== 目标路径 =====
    destPath = [modelName '/' subsystemName];

    % ===== 检查子系统是否已存在 =====
    existingBlocks = find_system(modelName, 'SearchDepth', 1, 'LookUnderMasks', 'none', 'BlockType', 'SubSystem');
    for ei = 1:length(existingBlocks)
        if strcmp(existingBlocks{ei}, destPath)
            result = struct('status', 'error', 'error', ['Subsystem already exists: ' destPath]);
            return;
        end
    end

    % ===== 根据模式执行 =====
    try
        if strcmp(mode, 'group')
            [result, apiUsed] = create_group_subsystem(modelName, subsystemName, destPath, opts, hasCreateSubsystem);
        else
            [result, apiUsed] = create_empty_subsystem(modelName, subsystemName, destPath, opts);
        end
    catch me
        result = struct('status', 'error', 'error', ['Failed to create subsystem: ' me.message]);
        return;
    end

    % ===== 验证 =====
    try
        verification = verify_subsystem(modelName, destPath, mode, opts);
        result.verification = verification;
    catch me
        result.verification = struct('subsystemExists', false, 'externalConnectionsPreserved', false);
    end

    % ===== 反模式检测 =====
    if strcmp(mode, 'group') && ~hasCreateSubsystem
        result.antiPatternInfo = struct( ...
            'rule', '#6-manual-subsystem-creation', ...
            'message', 'Manually creating subsystem via block manipulation is error-prone', ...
            'suggestion', 'Upgrade to R2017a+ to use Simulink.BlockDiagram.createSubsystem for reliable grouping');
    else
        result.antiPatternInfo = struct('rule', '', 'message', '', 'suggestion', '');
    end

    result.apiUsed = apiUsed;
end


function [result, apiUsed] = create_group_subsystem(modelName, subsystemName, destPath, opts, hasCreateSubsystem)
% CREATE_GROUP_SUBSYSTEM group模式创建子系统

    apiUsed = 'manual_group';

    if hasCreateSubsystem
        % ===== R2009a+: 使用 createSubsystem =====
        % 注意: createSubsystem(blocks) 的 blocks 参数是模块句柄（数值数组），不是字符串！
        try
            % 获取所有要分组的模块 handles
            blockHandles = zeros(1, length(opts.blocksToGroup));
            for bi = 1:length(opts.blocksToGroup)
                blockHandles(bi) = get_param(opts.blocksToGroup{bi}, 'Handle');
            end
            
            % 调用 createSubsystem，用 Name 参数指定子系统名称
            Simulink.BlockDiagram.createSubsystem(blockHandles, 'Name', subsystemName);

            apiUsed = 'createSubsystem';
        catch me
            % createSubsystem 失败，回退到手动实现
            apiUsed = 'manual_group';
            % 继续执行手动实现
            [result, apiUsed] = manual_group_subsystem(modelName, subsystemName, destPath, opts);
            return;
        end

        % 获取子系统信息
        actualPath = [modelName '/' subsystemName];
        innerBlocks = find_system(actualPath, 'SearchDepth', 1, 'LookUnderMasks', 'none');
        innerBlocks = setdiff(innerBlocks, actualPath, 'stable'); % 排除子系统自身

        inportCount = 0;
        outportCount = 0;
        internalNames = {};
        for ib = 1:length(innerBlocks)
            bt = get_param(innerBlocks{ib}, 'BlockType');
            if strcmp(bt, 'Inport')
                inportCount = inportCount + 1;
            elseif strcmp(bt, 'Outport')
                outportCount = outportCount + 1;
            else
                [~, n, ~] = fileparts(innerBlocks{ib});
                internalNames{end+1} = n;
            end
        end

        result = struct('status', 'ok');
        result.subsystem = struct( ...
            'path', actualPath, ...
            'mode', 'group', ...
            'inputPorts', inportCount, ...
            'outputPorts', outportCount, ...
            'internalBlocks', internalNames);
        return;
    end

    % ===== R2016a 回退: 手动实现 =====
    [result, apiUsed] = manual_group_subsystem(modelName, subsystemName, destPath, opts);
end


function [result, apiUsed] = manual_group_subsystem(modelName, subsystemName, destPath, opts)
% MANUAL_GROUP_SUBSYSTEM 手动 group 模式创建子系统（R2016a 回退）

    apiUsed = 'manual_group';
    blocksToGroup = opts.blocksToGroup;

    % ===== 1. 记录外部连线信息 =====
    externalConns = {};
    for bi = 1:length(blocksToGroup)
        blockPath = blocksToGroup{bi};
        ports = get_param(blockPath, 'PortHandles');
        % 记录输入端口的外部连线
        if isfield(ports, 'Inport')
            for pi = 1:length(ports.Inport)
                lh = ports.Inport(pi);
                if lh ~= 0
                    srcPorts = get(lh, 'SrcPortHandle');
                    if srcPorts ~= 0
                        srcBlock = get(get(srcPorts, 'Parent'), 'Handle');
                        srcPath = get_param(srcBlock, 'Path');
                        if ~isempty(strfind(srcPath, modelName)) && ~ismember(srcPath, blocksToGroup)
                            % 来自外部的连线
                            srcPortName = get_port_name(srcPorts);
                            dstPortName = get_port_name(lh);
                            externalConns{end+1} = struct('srcPath', srcPath, 'srcPort', srcPortName, ...
                                'dstBlock', blockPath, 'dstPort', dstPortName, 'type', 'input');
                        end
                    end
                end
            end
        end
        % 记录输出端口的外部连线
        if isfield(ports, 'Outport')
            for pi = 1:length(ports.Outport)
                lh = ports.Outport(pi);
                if lh ~= 0
                    dstPorts = get(lh, 'DstPortHandle');
                    dstPorts = dstPorts(:)';
                    for di = 1:length(dstPorts)
                        if dstPorts(di) ~= 0
                            dstBlock = get(get(dstPorts(di), 'Parent'), 'Handle');
                            dstPath = get_param(dstBlock, 'Path');
                            if ~isempty(strfind(dstPath, modelName)) && ~ismember(dstPath, blocksToGroup)
                                srcPortName = get_port_name(lh);
                                dstPortName = get_port_name(dstPorts(di));
                                externalConns{end+1} = struct('srcBlock', blockPath, 'srcPort', srcPortName, ...
                                    'dstPath', dstPath, 'dstPort', dstPortName, 'type', 'output');
                            end
                        end
                    end
                end
            end
        end
    end

    % ===== 2. 获取所有模块的位置信息 =====
    blockPositions = struct();
    blockParams = struct();
    blockTypes = struct();
    for bi = 1:length(blocksToGroup)
        bp = blocksToGroup{bi};
        [~, bn, ~] = fileparts(bp);
        blockPositions.(genvarname(bn)) = get_param(bp, 'Position');
        blockTypes.(genvarname(bn)) = get_param(bp, 'BlockType');
        % 保存关键参数
        try
            bpParams = get(bp, 'DialogParameters');
            if ~isempty(bpParams)
                paramNames = fieldnames(bpParams);
                paramStruct = struct();
                for pi = 1:length(paramNames)
                    try
                        paramStruct.(genvarname(paramNames{pi})) = get_param(bp, paramNames{pi});
                    catch
                        % 跳过无法获取的参数
                    end
                end
                blockParams.(genvarname(bn)) = paramStruct;
            end
        catch
            % 某些模块没有 DialogParameters
        end
    end

    % ===== 3. 删除外部连线 =====
    for bi = 1:length(blocksToGroup)
        blockPath = blocksToGroup{bi};
        try
            ports = get_param(blockPath, 'PortHandles');
            allPortHandles = [];
            if isfield(ports, 'Inport'), allPortHandles = [allPortHandles, ports.Inport(:)']; end
            if isfield(ports, 'Outport'), allPortHandles = [allPortHandles, ports.Outport(:)']; end
            for pi = 1:length(allPortHandles)
                ph = allPortHandles(pi);
                if ph ~= 0
                    lh = get(ph, 'Line');
                    if lh ~= 0
                        try
                            delete_line(lh);
                        catch
                            % 连线可能已删除
                        end
                    end
                end
            end
        catch
            % 跳过
        end
    end

    % ===== 4. 创建子系统 =====
    add_block('simulink/Ports & Subsystems/Subsystem', destPath);

    % ===== 5. 删除子系统内的默认连线 =====
    try
        defaultLine = get_param([destPath '/Out1'], 'Line');
        if defaultLine ~= 0
            delete_line(defaultLine);
        end
    catch
        % 可能已经没有默认连线
    end
    try
        defaultLine = get_param([destPath '/In1'], 'Line');
        if defaultLine ~= 0
            delete_line(defaultLine);
        end
    catch
        % 可能已经没有默认连线
    end

    % ===== 6. 删除默认的 In1 和 Out1（稍后根据需要重建） =====
    try delete_block([destPath '/In1']); catch, end
    try delete_block([destPath '/Out1']); catch, end

    % ===== 7. 将模块移到子系统内部 =====
    movedBlocks = {};
    for bi = 1:length(blocksToGroup)
        bp = blocksToGroup{bi};
        [~, bn, ~] = fileparts(bp);

        % 获取源模块类型
        srcLib = get_param(bp, 'BlockType');

        % 复制模块到子系统内部
        innerPath = [destPath '/' bn];
        try
            add_block(bp, innerPath, 'MakeNameUnique', 'on');
        catch
            % 如果 add_block 复制失败，尝试其他方式
            try
                copy_block(bp, innerPath);
            catch me2
                % 最后的尝试
                try
                    add_block(['simulink/' srcLib], innerPath);
                catch
                    % 无法复制，跳过
                end
            end
        end

        % 设置位置
        try
            pos = get_param(bp, 'Position');
            set_param(innerPath, 'Position', pos);
        catch
            % 保留原始位置
        end

        % 复制参数
        try
            vn = genvarname(bn);
            if isfield(blockParams, vn)
                ps = blockParams.(vn);
                pNames = fieldnames(ps);
                for pi = 1:length(pNames)
                    try
                        origParamName = get_original_param_name(pNames{pi});
                        set_param(innerPath, origParamName, ps.(pNames{pi}));
                    catch
                        % 跳过
                    end
                end
            end
        catch
            % 跳过
        end

        movedBlocks{end+1} = innerPath;
    end

    % ===== 8. 删除原模块 =====
    for bi = 1:length(blocksToGroup)
        try
            delete_block(blocksToGroup{bi});
        catch
            % 跳过
        end
    end

    % ===== 9. 添加 Inport/Outport 并建立外部连线 =====
    inIdx = 1;
    outIdx = 1;

    for ci = 1:length(externalConns)
        conn = externalConns{ci};
        if strcmp(conn.type, 'input')
            % 添加 Inport 到子系统
            inPortName = ['In' num2str(inIdx)];
            inPortPath = [destPath '/' inPortName];
            try
                add_block('simulink/Sources/In1', inPortPath);
            catch
                % 可能已存在
            end

            % 在子系统内部连线 Inport → 目标模块
            try
                [~, dstBlockName, ~] = fileparts(conn.dstBlock);
                innerDst = [destPath '/' dstBlockName];
                add_line(destPath, [inPortName '/1'], [dstBlockName '/1'], 'autorouting', 'on');
            catch
                % 连线失败，跳过
            end

            % 在子系统外部连线 源 → 子系统 Inport
            try
                add_line(modelName, [conn.srcPath '/' conn.srcPort], [destPath '/' inPortName], 'autorouting', 'on');
            catch
                % 连线失败，跳过
            end

            inIdx = inIdx + 1;

        elseif strcmp(conn.type, 'output')
            % 添加 Outport 到子系统
            outPortName = ['Out' num2str(outIdx)];
            outPortPath = [destPath '/' outPortName];
            try
                add_block('simulink/Sinks/Out1', outPortPath);
            catch
                % 可能已存在
            end

            % 在子系统内部连线 源模块 → Outport
            try
                [~, srcBlockName, ~] = fileparts(conn.srcBlock);
                add_line(destPath, [srcBlockName '/' conn.srcPort], [outPortName '/1'], 'autorouting', 'on');
            catch
                % 连线失败，跳过
            end

            % 在子系统外部连线 子系统 Outport → 目标
            try
                add_line(modelName, [destPath '/' outPortName], [conn.dstPath '/' conn.dstPort], 'autorouting', 'on');
            catch
                % 连线失败，跳过
            end

            outIdx = outIdx + 1;
        end
    end

    % ===== 10. 返回结果 =====
    innerBlocks = find_system(destPath, 'SearchDepth', 1, 'LookUnderMasks', 'none');
    innerBlocks = setdiff(innerBlocks, destPath, 'stable');

    internalNames = {};
    for ib = 1:length(innerBlocks)
        [~, n, ~] = fileparts(innerBlocks{ib});
        internalNames{end+1} = n;
    end

    result = struct('status', 'ok');
    result.subsystem = struct( ...
        'path', destPath, ...
        'mode', 'group', ...
        'inputPorts', inIdx - 1, ...
        'outputPorts', outIdx - 1, ...
        'internalBlocks', internalNames);
end


function [result, apiUsed] = create_empty_subsystem(modelName, subsystemName, destPath, opts)
% CREATE_EMPTY_SUBSYSTEM empty模式创建子系统

    apiUsed = 'manual_empty';

    % ===== 1. 添加子系统模块 =====
    add_block('simulink/Ports & Subsystems/Subsystem', destPath, 'Position', opts.position);

    % ===== 2. 删除子系统内默认连线 =====
    try
        % 获取所有内部连线
        innerLines = find_system(destPath, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'line');
        for li = 1:length(innerLines)
            try
                delete_line(innerLines(li));
            catch
                % 跳过
            end
        end
    catch
        % 可能没有连线
    end

    % ===== 3. 删除默认的 In1 和 Out1 =====
    try delete_block([destPath '/In1']); catch, end
    try delete_block([destPath '/Out1']); catch, end

    % ===== 4. 添加指定数量的输入端口 =====
    for pi = 1:opts.inputPorts
        portName = ['In' num2str(pi)];
        portPath = [destPath '/' portName];
        try
            add_block('simulink/Sources/In1', portPath);
            % 设置端口编号
            set_param(portPath, 'Port', num2str(pi));
        catch me
            % 端口可能已存在
        end
    end

    % ===== 5. 添加指定数量的输出端口 =====
    for pi = 1:opts.outputPorts
        portName = ['Out' num2str(pi)];
        portPath = [destPath '/' portName];
        try
            add_block('simulink/Sinks/Out1', portPath);
            % 设置端口编号
            set_param(portPath, 'Port', num2str(pi));
        catch me
            % 端口可能已存在
        end
    end

    % ===== 6. 返回结果 =====
    result = struct('status', 'ok');
    result.subsystem = struct();
    result.subsystem.path = destPath;
    result.subsystem.mode = 'empty';
    result.subsystem.inputPorts = opts.inputPorts;
    result.subsystem.outputPorts = opts.outputPorts;
    result.subsystem.internalBlocks = {};
end


function verification = verify_subsystem(modelName, destPath, mode, opts)
% VERIFY_SUBSYSTEM 验证子系统创建结果

    verification = struct();

    % 检查子系统是否存在
    try
        allBlocks = find_system(modelName, 'SearchDepth', 1, 'LookUnderMasks', 'none');
        subsystemExists = false;
        for ai = 1:length(allBlocks)
            if strcmp(allBlocks{ai}, destPath)
                subsystemExists = true;
                break;
            end
        end
        verification.subsystemExists = subsystemExists;
    catch
        verification.subsystemExists = false;
    end

    % 检查外部连线保持（group 模式）
    if strcmp(mode, 'group')
        try
            % 检查子系统的 Inport/Outport 是否有外部连线
            innerBlocks = find_system(destPath, 'SearchDepth', 1, 'LookUnderMasks', 'none');
            hasExternalConn = false;
            for ib = 1:length(innerBlocks)
                bt = get_param(innerBlocks{ib}, 'BlockType');
                if strcmp(bt, 'Inport') || strcmp(bt, 'Outport')
                    ports = get_param(innerBlocks{ib}, 'PortHandles');
                    if isfield(ports, 'Outport') && any(ports.Outport ~= 0)
                        hasExternalConn = true;
                    end
                    if isfield(ports, 'Inport') && any(ports.Inport ~= 0)
                        hasExternalConn = true;
                    end
                end
            end
            verification.externalConnectionsPreserved = hasExternalConn;
        catch
            verification.externalConnectionsPreserved = false;
        end
    else
        % empty 模式不需要检查外部连线
        verification.externalConnectionsPreserved = true;
    end
end


function portName = get_port_name(portHandle)
% GET_PORT_NAME 从端口句柄获取端口标识名称
    try
        parentHandle = get(portHandle, 'Parent');
        parentPath = get_param(parentHandle, 'Path');
        parentType = get_param(parentHandle, 'BlockType');
        portNum = get(portHandle, 'PortNumber');

        if strcmp(parentType, 'Inport')
            portName = ['In' num2str(portNum) '/1'];
        elseif strcmp(parentType, 'Outport')
            portName = ['Out' num2str(portNum) '/1'];
        else
            % 对于非端口模块，使用端口号
            portName = num2str(portNum);
        end
    catch
        portName = '1';
    end
end


function origName = get_original_param_name(varName)
% GET_ORIGINAL_PARAM_NAME 将 genvarname 转换后的名称还原
% genvarname 会将特殊字符替换为下划线等，这里做简单还原
    origName = strrep(varName, '_', ' ');
    % 这是一个近似还原，可能不完全准确
    % 但在大多数情况下足够使用
end
