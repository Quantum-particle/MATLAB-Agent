function result = sl_find_blocks(modelName, varargin)
% SL_FIND_BLOCKS 高级查找 — 按类型/参数/连接状态过滤
%   result = sl_find_blocks(modelName)
%   result = sl_find_blocks(modelName, 'blockType', 'Gain', 'searchDepth', 1, ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName     - 模型名称（必选）
%     'blockType'   - 按 BlockType 过滤，如 'Gain'，默认 ''（全部）
%     'paramFilter' - struct，按参数值过滤，如 struct('Gain','2.5')
%     'connectionFilter' - 按连接状态过滤:
%                         'unconnected_input' / 'unconnected_output' / 'connected'
%                         默认 ''（不过滤）
%     'connected'   - 快捷参数: true=已连接, false=未连接输入
%     'maskFilter'  - 只返回有 Mask 的模块，默认 false
%     'searchDepth' - 搜索深度，0=全部层级，默认 1
%
%   输出: struct
%     .status - 'ok' 或 'error'
%     .count  - 匹配模块数
%     .blocks - cell 数组，每项 { path, type, params }
%     .error  - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'blockType', '', ...
        'paramFilter', struct(), ...
        'connectionFilter', '', ...
        'maskFilter', false, ...
        'searchDepth', 1);
    
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            % 别名映射: 'connected' -> 'connectionFilter'
            if strcmpi(key, 'connected')
                if val == false || (ischar(val) && strcmpi(val, 'false'))
                    opts.connectionFilter = 'unconnected_input';
                else
                    opts.connectionFilter = 'connected';
                end
            elseif isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end
    
    % ===== 确保模型已加载 =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['Model not loaded: ' ME.message]);
        return;
    end
    
    % ===== 获取模块列表 =====
    try
        if opts.searchDepth == 0
            allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        else
            allBlocks = find_system(modelName, 'SearchDepth', opts.searchDepth, ...
                'LookUnderMasks', 'all');
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['find_system failed: ' ME.message]);
        return;
    end
    
    % 去掉模型自身
    if length(allBlocks) > 1
        blockPaths = allBlocks(2:end);
    else
        blockPaths = {};
    end
    
    % ===== 按 BlockType 过滤 =====
    if ~isempty(opts.blockType)
        filteredPaths = {};
        for i = 1:length(blockPaths)
            try
                bt = get_param(blockPaths{i}, 'BlockType');
                if strcmpi(bt, opts.blockType)
                    filteredPaths{end+1} = blockPaths{i}; %#ok<AGROW>
                end
            catch
            end
        end
        blockPaths = filteredPaths;
    end
    
    % ===== 按参数过滤 =====
    if ~isempty(fieldnames(opts.paramFilter))
        filteredPaths = {};
        paramNames = fieldnames(opts.paramFilter);
        for i = 1:length(blockPaths)
            match = true;
            for j = 1:length(paramNames)
                try
                    actualVal = get_param(blockPaths{i}, paramNames{j});
                    expectedVal = opts.paramFilter.(paramNames{j});
                    % 字符串比较（不区分大小写）
                    if ischar(actualVal) && ischar(expectedVal)
                        if ~strcmpi(actualVal, expectedVal)
                            match = false; break;
                        end
                    elseif isnumeric(actualVal) && isnumeric(expectedVal)
                        if actualVal ~= expectedVal
                            match = false; break;
                        end
                    else
                        % 类型不匹配，尝试字符串比较
                        if ~strcmpi(num2str(actualVal), num2str(expectedVal))
                            match = false; break;
                        end
                    end
                catch
                    match = false; break;
                end
            end
            if match
                filteredPaths{end+1} = blockPaths{i}; %#ok<AGROW>
            end
        end
        blockPaths = filteredPaths;
    end
    
    % ===== 按连接状态过滤 =====
    if ~isempty(opts.connectionFilter)
        filteredPaths = {};
        for i = 1:length(blockPaths)
            connStatus = get_connection_status(blockPaths{i}, opts.connectionFilter);
            if connStatus
                filteredPaths{end+1} = blockPaths{i}; %#ok<AGROW>
            end
        end
        blockPaths = filteredPaths;
    end
    
    % ===== 按 Mask 过滤 =====
    if opts.maskFilter
        filteredPaths = {};
        for i = 1:length(blockPaths)
            try
                maskVal = get_param(blockPaths{i}, 'Mask');
                if strcmpi(maskVal, 'on') || maskVal == 1
                    filteredPaths{end+1} = blockPaths{i}; %#ok<AGROW>
                end
            catch
            end
        end
        blockPaths = filteredPaths;
    end
    
    % ===== 收集匹配模块信息 =====
    blocks = cell(1, length(blockPaths));
    for i = 1:length(blockPaths)
        bp = blockPaths{i};
        blk = struct();
        blk.path = bp;
        try blk.type = get_param(bp, 'BlockType'); catch blk.type = ''; end
        
        % 收集关键参数摘要
        blk.params = struct();
        try
            dialogParams = get_param(bp, 'DialogParameters');
            if ~isempty(dialogParams)
                pNames = fieldnames(dialogParams);
                for j = 1:min(length(pNames), 10)  % 限制最多10个参数
                    try
                        blk.params.(pNames{j}) = get_param(bp, pNames{j});
                    catch
                    end
                end
            end
        catch
        end
        
        blocks{i} = blk;
    end
    
    % ===== 组装返回 =====
    result = struct();
    result.status = 'ok';
    result.count = length(blockPaths);
    result.blocks = blocks;
end

% ===== 辅助函数: 判断模块连接状态 =====
function matched = get_connection_status(blockPath, filterType)
    matched = false;
    try
        ph = get_param(blockPath, 'PortHandles');
        
        switch lower(filterType)
            case 'unconnected_input'
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH == -1
                                matched = true; return;
                            end
                        catch
                        end
                    end
                end
                
            case 'unconnected_output'
                if ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH == -1
                                matched = true; return;
                            end
                        catch
                        end
                    end
                end
                
            case 'connected'
                % 至少有一个输入或输出端口已连接
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH ~= -1
                                matched = true; return;
                            end
                        catch
                        end
                    end
                end
                if ~matched && ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH ~= -1
                                matched = true; return;
                            end
                        catch
                        end
                    end
                end
                
            otherwise
                matched = true;  % 未知过滤类型，不过滤
        end
    catch
        matched = true;  % 无法读取端口信息，不过滤
    end
end
