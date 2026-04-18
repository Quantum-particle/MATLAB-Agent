function result = sl_replace_block(modelName, blockPath, newBlockType, varargin)
% SL_REPLACE_BLOCK 替换模块 — 保留连线 + 参数迁移 + 新模块自动对齐端口位置
%   result = sl_replace_block('MyModel', 'MyModel/Gain1', 'Sine Wave')
%   result = sl_replace_block('MyModel', 'MyModel/Gain1', 'simulink/Sources/Sine Wave', ...
%       'preservePosition', true, 'migrateParams', struct('Gain', 'Amplitude'))
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName        - 模型名称（必选）
%     blockPath        - 要替换的模块完整路径（必选）
%     newBlockType     - 新模块类型或完整路径（必选）
%     'preservePosition' - 保留原位置，默认 true
%     'migrateParams'  - struct，旧参数名→新参数名映射，如 struct('Gain','Amplitude')
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .replaced     - struct(.oldBlock, .newBlock, .connectionsPreserved, .paramsMigrated)
%     .verification - struct(.newBlockExists, .allConnectionsRestored)
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'preservePosition', true, ...
        'migrateParams', struct(), ...
        'loadModelIfNot', true);
    
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end
    
    result = struct('status', 'ok', 'replaced', struct(), ...
        'verification', struct(), 'error', '');
    
    % ===== 确保模型已加载 =====
    if opts.loadModelIfNot
        try
            if ~bdIsLoaded(modelName)
                load_system(modelName);
            end
        catch ME
            result.status = 'error';
            result.error = ['Model not loaded and cannot be loaded: ' ME.message];
            return;
        end
    else
        if ~bdIsLoaded(modelName)
            result.status = 'error';
            result.error = 'Model not loaded. Set loadModelIfNot=true to auto-load.';
            return;
        end
    end
    
    % ===== 验证旧模块存在 =====
    oldBlockType = '';
    try
        oldBlockType = get_param(blockPath, 'BlockType');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        return;
    end
    
    % ===== 记录旧模块信息 =====
    oldInfo = struct();
    oldInfo.path = blockPath;
    oldInfo.blockType = oldBlockType;
    
    % 记录位置
    try
        oldInfo.position = get_param(blockPath, 'Position');
    catch
        oldInfo.position = [100 100 190 140];
    end
    
    % 记录输入端口连线
    inputConnections = {};
    try
        ph = get_param(blockPath, 'PortHandles');
        if isfield(ph, 'Inport') && ~isempty(ph.Inport)
            for i = 1:length(ph.Inport)
                try
                    lineHandle = get_param(ph.Inport(i), 'Line');
                    if lineHandle ~= -1
                        conn = get_connection_info(modelName, lineHandle, 'input', i);
                        inputConnections{end+1} = conn; %#ok<AGROW>
                    end
                catch
                end
            end
        end
    catch
    end
    
    % 记录输出端口连线
    outputConnections = {};
    try
        ph = get_param(blockPath, 'PortHandles');
        if isfield(ph, 'Outport') && ~isempty(ph.Outport)
            for i = 1:length(ph.Outport)
                try
                    lineHandle = get_param(ph.Outport(i), 'Line');
                    if lineHandle ~= -1
                        conn = get_connection_info(modelName, lineHandle, 'output', i);
                        outputConnections{end+1} = conn; %#ok<AGROW>
                    end
                catch
                end
            end
        end
    catch
    end
    
    % 记录旧参数值（用于迁移）
    oldParamValues = struct();
    if ~isempty(fieldnames(opts.migrateParams))
        oldParamNames = fieldnames(opts.migrateParams);
        for i = 1:length(oldParamNames)
            try
                oldParamValues.(oldParamNames{i}) = get_param(blockPath, oldParamNames{i});
            catch
                % 参数不存在，跳过
            end
        end
    end
    
    % ===== 解析新模块路径 =====
    srcBlock = newBlockType;
    if isempty(strfind(srcBlock, '/'))
        srcBlock = sl_block_registry(srcBlock);
    end
    
    % ===== 删除旧模块（delete_block 自动删除关联连线）=====
    try
        delete_block(blockPath);
    catch ME
        result.status = 'error';
        result.error = ['Failed to delete old block: ' ME.message];
        return;
    end
    
    % ===== 添加新模块 =====
    try
        if opts.preservePosition && ~isempty(oldInfo.position)
            add_block(srcBlock, blockPath, 'Position', oldInfo.position);
        else
            add_block(srcBlock, blockPath);
        end
    catch ME
        result.status = 'error';
        result.error = ['Failed to add new block: ' ME.message];
        result.replaced.oldBlock = oldInfo;
        return;
    end
    
    % 验证新模块已添加
    try
        get_param(blockPath, 'BlockType');
    catch
        result.status = 'error';
        result.error = 'New block added but cannot be verified';
        return;
    end
    
    % ===== 参数迁移 =====
    paramsMigrated = {};
    paramsFailed = {};
    if ~isempty(fieldnames(opts.migrateParams))
        oldParamNames = fieldnames(opts.migrateParams);
        for i = 1:length(oldParamNames)
            oldName = oldParamNames{i};
            newName = opts.migrateParams.(oldName);
            if isfield(oldParamValues, oldName)
                try
                    val = oldParamValues.(oldName);
                    set_param_value(blockPath, newName, val);
                    paramsMigrated{end+1} = struct('from', oldName, 'to', newName, 'value', val); %#ok<AGROW>
                catch ME
                    paramsFailed{end+1} = struct('from', oldName, 'to', newName, 'error', ME.message); %#ok<AGROW>
                end
            end
        end
    end
    
    % ===== 重新连线 =====
    connectionsRestored = 0;
    connectionErrors = {};
    totalConnections = length(inputConnections) + length(outputConnections);
    
    % 获取新模块的短名称（用于连线）
    [~, newBlockName, ~] = fileparts(blockPath);
    
    % 恢复输入连线: 从源模块输出 → 新模块输入端口
    for i = 1:length(inputConnections)
        conn = inputConnections{i};
        try
            srcBlockPath = conn.srcBlock;
            srcPortIdx = conn.srcPortIdx;
            dstPortIdx = min(conn.dstPortIdx, get_num_ports(blockPath, 'Inport'));
            
            if dstPortIdx >= 1
                % 使用 'BlockName/portIdx' 字符串格式连线
                [~, srcName, ~] = fileparts(srcBlockPath);
                srcPortStr = [srcName '/' num2str(srcPortIdx)];
                dstPortStr = [newBlockName '/' num2str(dstPortIdx)];
                add_line(modelName, srcPortStr, dstPortStr, 'autorouting', 'on');
                connectionsRestored = connectionsRestored + 1;
            end
        catch ME
            connectionErrors{end+1} = struct('type', 'input', 'index', i, 'error', ME.message); %#ok<AGROW>
        end
    end
    
    % 恢复输出连线: 从新模块输出端口 → 目标模块输入
    for i = 1:length(outputConnections)
        conn = outputConnections{i};
        try
            srcPortIdx = min(conn.srcPortIdx, get_num_ports(blockPath, 'Outport'));
            dstBlockPath = conn.dstBlock;
            dstPortIdx = conn.dstPortIdx;
            
            if srcPortIdx >= 1
                [~, dstName, ~] = fileparts(dstBlockPath);
                srcPortStr = [newBlockName '/' num2str(srcPortIdx)];
                dstPortStr = [dstName '/' num2str(dstPortIdx)];
                add_line(modelName, srcPortStr, dstPortStr, 'autorouting', 'on');
                connectionsRestored = connectionsRestored + 1;
            end
        catch ME
            connectionErrors{end+1} = struct('type', 'output', 'index', i, 'error', ME.message); %#ok<AGROW>
        end
    end
    
    % ===== 组装 replaced 信息 =====
    newInfo = struct();
    newInfo.path = blockPath;
    try newInfo.blockType = get_param(blockPath, 'BlockType'); catch newInfo.blockType = ''; end
    try newInfo.position = get_param(blockPath, 'Position'); catch newInfo.position = []; end
    
    result.replaced = struct();
    result.replaced.oldBlock = oldInfo;
    result.replaced.newBlock = newInfo;
    result.replaced.connectionsPreserved = connectionsRestored;
    result.replaced.totalConnections = totalConnections;
    result.replaced.paramsMigrated = paramsMigrated;
    result.replaced.paramsFailed = paramsFailed;
    result.replaced.connectionErrors = connectionErrors;
    
    % ===== 验证 =====
    verification = struct();
    try
        get_param(blockPath, 'BlockType');
        verification.newBlockExists = true;
    catch
        verification.newBlockExists = false;
    end
    
    verification.allConnectionsRestored = (connectionsRestored == totalConnections) && (totalConnections > 0);
    if totalConnections == 0
        verification.allConnectionsRestored = true;  % 无连线也算成功
    end
    
    result.verification = verification;
    
    % ===== 设置 message =====
    result.message = sprintf('Replaced %s with %s (%d/%d connections restored, %d params migrated)', ...
        oldInfo.blockType, newInfo.blockType, connectionsRestored, totalConnections, length(paramsMigrated));
end


% ===== 辅助函数: 获取连线信息 =====
function conn = get_connection_info(modelName, lineHandle, direction, portIdx)
% 获取一条连线的源/目标信息
    conn = struct();
    conn.direction = direction;
    conn.portIdx = portIdx;
    
    try
        srcPH = get_param(lineHandle, 'SrcPortHandle');
        if srcPH ~= 0
            srcBH = get_param(srcPH, 'Parent');
            srcName = get_param(srcBH, 'Name');
            srcParent = get_param(srcBH, 'Parent');
            if strcmpi(srcParent, modelName)
                conn.srcBlock = [modelName '/' srcName];
            else
                conn.srcBlock = [srcParent '/' srcName];
            end
            % 计算源端口索引
            try
                srcPHs = get_param(srcBH, 'PortHandles');
                if isfield(srcPHs, 'Outport')
                    for si = 1:length(srcPHs.Outport)
                        if srcPHs.Outport(si) == srcPH
                            conn.srcPortIdx = si;
                            break;
                        end
                    end
                end
            catch
                conn.srcPortIdx = 1;
            end
        end
    catch
        conn.srcBlock = '';
        conn.srcPortIdx = 1;
    end
    
    try
        dstPHs = get_param(lineHandle, 'DstPortHandle');
        if ~isempty(dstPHs) && dstPHs(1) ~= 0
            dstPH = dstPHs(1);
            dstBH = get_param(dstPH, 'Parent');
            dstName = get_param(dstBH, 'Name');
            dstParent = get_param(dstBH, 'Parent');
            if strcmpi(dstParent, modelName)
                conn.dstBlock = [modelName '/' dstName];
            else
                conn.dstBlock = [dstParent '/' dstName];
            end
            % 计算目标端口索引
            try
                dstPHsAll = get_param(dstBH, 'PortHandles');
                if isfield(dstPHsAll, 'Inport')
                    for di = 1:length(dstPHsAll.Inport)
                        if dstPHsAll.Inport(di) == dstPH
                            conn.dstPortIdx = di;
                            break;
                        end
                    end
                end
            catch
                conn.dstPortIdx = 1;
            end
        end
    catch
        conn.dstBlock = '';
        conn.dstPortIdx = 1;
    end
end


% ===== 辅助函数: 获取端口数量 =====
function n = get_num_ports(blockPath, portType)
% 获取模块指定类型端口数量
    n = 0;
    try
        ph = get_param(blockPath, 'PortHandles');
        if isfield(ph, portType)
            n = length(ph.(portType));
        end
    catch
        n = 1;  % 默认至少1个端口
    end
    if n == 0
        n = 1;
    end
end


% ===== 辅助函数: 设置参数值（类型感知）=====
function set_param_value(blockPath, paramName, value)
% 根据值类型正确设置参数
    if isnumeric(value)
        set_param(blockPath, paramName, num2str(value));
    elseif islogical(value)
        if value
            set_param(blockPath, paramName, 'on');
        else
            set_param(blockPath, paramName, 'off');
        end
    else
        set_param(blockPath, paramName, value);
    end
end
