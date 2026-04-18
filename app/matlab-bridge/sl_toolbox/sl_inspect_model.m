function result = sl_inspect_model(modelName, varargin)
% SL_INSPECT_MODEL 模型全景检查 — 让 AI 能"看到"模型完整状态
%   result = sl_inspect_model(modelName)
%   result = sl_inspect_model(modelName, 'depth', 1, 'includeParams', true, ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName     - 模型名称（必选）
%     'depth'       - 检查深度，默认 1（仅顶层），0=全部
%     'includeParams'  - 是否包含模块参数，默认 true
%     'includePorts'   - 是否包含端口信息，默认 true
%     'includeLines'   - 是否包含连线信息，默认 true
%     'includeCallbacks' - 是否包含回调，默认 false
%     'includeConfig'  - 是否包含模型配置，默认 false
%     'blockFilter'    - 只检查特定 BlockType，默认 ''（全部）
%
%   输出: struct（由 sl_jsonencode 序列化为 JSON）
%     .status   - 'ok' 或 'error'
%     .model    - 模型全景信息 struct
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'depth', 1, ...
        'includeParams', true, ...
        'includePorts', true, ...
        'includeLines', true, ...
        'includeCallbacks', false, ...
        'includeConfig', false, ...
        'blockFilter', '');
    
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
    
    % ===== 确保模型已加载 =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['Failed to load model: ' ME.message]);
        return;
    end
    
    % ===== 获取模块列表 =====
    searchDepth = opts.depth;
    if searchDepth == 0
        searchDepth = [];  % find_system 不传 SearchDepth = 全部层级
    end
    
    try
        if isempty(searchDepth)
            allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        else
            allBlocks = find_system(modelName, 'SearchDepth', searchDepth, 'LookUnderMasks', 'all');
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['find_system failed: ' ME.message]);
        return;
    end
    
    % 过滤: 去掉模型自身（第一个元素）
    if length(allBlocks) > 1
        blockPaths = allBlocks(2:end);
    else
        blockPaths = {};
    end
    
    % 按 blockFilter 过滤
    if ~isempty(opts.blockFilter)
        filteredPaths = {};
        for i = 1:length(blockPaths)
            try
                bt = get_param(blockPaths{i}, 'BlockType');
                if strcmpi(bt, opts.blockFilter)
                    filteredPaths{end+1} = blockPaths{i}; %#ok<AGROW>
                end
            catch
            end
        end
        blockPaths = filteredPaths;
    end
    
    % ===== 逐模块收集信息 =====
    nBlocks = length(blockPaths);
    blocks = cell(1, nBlocks);
    unconnectedPorts = {};
    subsystemCount = 0;
    
    for i = 1:nBlocks
        bp = blockPaths{i};
        blk = struct();
        
        try
            blk.path = bp;
            blk.type = get_param(bp, 'BlockType');
            
            % 来源库路径
            try
                blk.library = get_param(bp, 'SourceBlock');
            catch
                blk.library = '';
            end
            
            % 位置
            try
                blk.position = get_param(bp, 'Position');
            catch
                blk.position = [];
            end
            
            % 父子系统
            try
                parent = get_param(bp, 'Parent');
                blk.parentSubsystem = parent;
            catch
                blk.parentSubsystem = '';
            end
            
            % 统计子系统
            if strcmpi(blk.type, 'SubSystem')
                subsystemCount = subsystemCount + 1;
            end
            
            % 端口信息
            if opts.includePorts
                [portInfo, unconnNew] = get_port_info(bp);
                blk.ports = portInfo;
                unconnectedPorts = [unconnectedPorts, unconnNew]; %#ok<AGROW>
            end
            
            % 参数信息
            if opts.includeParams
                blk.params = get_block_params(bp);
            end
            
            % 回调信息
            if opts.includeCallbacks
                blk.callbacks = get_block_callbacks(bp);
            end
            
            % Mask 信息
            try
                maskVal = get_param(bp, 'Mask');
                if strcmpi(maskVal, 'on') || (isnumeric(maskVal) && maskVal == 1)
                    blk.maskInfo = struct('hasMask', true);
                    try
                        blk.maskInfo.maskType = get_param(bp, 'MaskType');
                    catch
                        blk.maskInfo.maskType = '';
                    end
                else
                    blk.maskInfo = struct('hasMask', false);
                end
            catch
                blk.maskInfo = struct('hasMask', false);
            end
            
            blocks{i} = blk;
        catch ME
            blocks{i} = struct('path', bp, 'error', ME.message);
        end
    end
    
    % ===== 连线信息 =====
    linesInfo = {};
    if opts.includeLines
        linesInfo = get_lines_info(modelName, blockPaths);
    end
    
    % ===== 模型配置 =====
    configInfo = struct();
    if opts.includeConfig
        try
            configInfo.solver = get_param(modelName, 'Solver');
            configInfo.stopTime = get_param(modelName, 'StopTime');
            configInfo.fixedStep = get_param(modelName, 'FixedStep');
            configInfo.solverType = get_param(modelName, 'SolverType');
        catch
        end
    end
    
    % ===== 组装返回 =====
    % 统计 Inport/Outport 模块数量
    inportCount = 0;
    outportCount = 0;
    for i = 1:nBlocks
        try
            bt = get_param(blockPaths{i}, 'BlockType');
            if strcmpi(bt, 'Inport'), inportCount = inportCount + 1; end
            if strcmpi(bt, 'Outport'), outportCount = outportCount + 1; end
        catch
        end
    end
    
    result = struct();
    result.status = 'ok';
    result.model = struct();
    result.model.name = modelName;
    result.model.blockCount = nBlocks;
    result.model.subsystemCount = subsystemCount;
    result.model.lineCount = length(linesInfo);
    result.model.inportCount = inportCount;
    result.model.outportCount = outportCount;
    result.model.blocks = blocks;
    if ~isempty(linesInfo)
        result.model.lines = linesInfo;
    end
    if ~isempty(unconnectedPorts)
        result.model.unconnectedPorts = unconnectedPorts;
    end
    if opts.includeConfig
        result.model.config = configInfo;
    end
end

% ===== 辅助函数：获取端口信息 =====
function [portInfo, unconnectedPorts] = get_port_info(blockPath)
    portInfo = struct();
    portInfo.inputs = {};
    portInfo.outputs = {};
    unconnectedPorts = {};
    
    % 输入端口
    try
        ph = get_param(blockPath, 'PortHandles');
        inHandles = ph.Inport;
        if ~isempty(inHandles)
            for j = 1:length(inHandles)
                p = struct();
                p.index = j;
                try p.name = get_param(inHandles(j), 'Name'); catch p.name = ''; end
                try p.dataType = get_param(inHandles(j), 'OutDataTypeStr'); catch p.dataType = ''; end
                try p.dimensions = get_param(inHandles(j), 'PortDimensions'); catch p.dimensions = ''; end
                
                try
                    lineH = get_param(inHandles(j), 'Line');
                    if lineH == -1
                        p.connected = false;
                        unconnectedPorts{end+1} = struct('block', blockPath, 'portType', 'input', 'portIndex', j); %#ok<AGROW>
                    else
                        p.connected = true;
                    end
                catch
                    p.connected = false;
                end
                
                portInfo.inputs{end+1} = p; %#ok<AGROW>
            end
        end
    catch
    end
    
    % 输出端口
    try
        ph = get_param(blockPath, 'PortHandles');
        outHandles = ph.Outport;
        if ~isempty(outHandles)
            for j = 1:length(outHandles)
                p = struct();
                p.index = j;
                try p.name = get_param(outHandles(j), 'Name'); catch p.name = ''; end
                try p.dataType = get_param(outHandles(j), 'OutDataTypeStr'); catch p.dataType = ''; end
                try p.dimensions = get_param(outHandles(j), 'PortDimensions'); catch p.dimensions = ''; end
                
                try
                    lineH = get_param(outHandles(j), 'Line');
                    if lineH == -1
                        p.connected = false;
                        unconnectedPorts{end+1} = struct('block', blockPath, 'portType', 'output', 'portIndex', j); %#ok<AGROW>
                    else
                        p.connected = true;
                    end
                catch
                    p.connected = false;
                end
                
                portInfo.outputs{end+1} = p; %#ok<AGROW>
            end
        end
    catch
    end
end

% ===== 辅助函数：获取连线信息（通过 Line handle 遍历） =====
function linesInfo = get_lines_info(modelName, blockPaths)
    linesInfo = {};
    
    try
        lineHandles = find_system(modelName, 'SearchDepth', 1, ...
            'FindAll', 'on', 'Type', 'Line');
        if isempty(lineHandles), return; end
        
        % 建立路径→handle 的映射（用于从 handle 反查 block path）
        pathMap = containers.Map;
        for i = 1:length(blockPaths)
            try
                bh = get_param(blockPaths{i}, 'Handle');
                pathMap(num2str(bh)) = blockPaths{i};
            catch
            end
        end
        
        for i = 1:length(lineHandles)
            try
                lh = lineHandles(i);
                ln = struct();
                
                % 源端口
                try
                    srcPH = get_param(lh, 'SrcPortHandle');
                    srcBH = get_param(srcPH, 'Parent');
                    srcKey = num2str(srcBH);
                    if pathMap.isKey(srcKey)
                        ln.srcBlock = pathMap(srcKey);
                    else
                        % 用 Name + Parent 构造路径
                        ln.srcBlock = build_block_path(srcBH, modelName);
                    end
                    ln.srcPort = double(get_param(srcPH, 'PortNumber'));
                catch
                    ln.srcBlock = '';
                    ln.srcPort = 0;
                end
                
                % 目标端口
                try
                    dstPHs = get_param(lh, 'DstPortHandle');
                    if ~isempty(dstPHs)
                        dstPH = dstPHs(1);
                        dstBH = get_param(dstPH, 'Parent');
                        dstKey = num2str(dstBH);
                        if pathMap.isKey(dstKey)
                            ln.dstBlock = pathMap(dstKey);
                        else
                            ln.dstBlock = build_block_path(dstBH, modelName);
                        end
                        ln.dstPort = double(get_param(dstPH, 'PortNumber'));
                    else
                        ln.dstBlock = '';
                        ln.dstPort = 0;
                    end
                catch
                    ln.dstBlock = '';
                    ln.dstPort = 0;
                end
                
                linesInfo{end+1} = ln; %#ok<AGROW>
            catch
            end
        end
    catch
    end
end

% ===== 辅助函数：从 block handle 构造完整路径 =====
function bp = build_block_path(bh, modelName)
    try
        nm = get_param(bh, 'Name');
        pr = get_param(bh, 'Parent');
        if strcmpi(pr, modelName)
            bp = [modelName '/' nm];
        else
            bp = [pr '/' nm];
        end
    catch
        bp = '';
    end
end

% ===== 辅助函数：获取模块参数 =====
function params = get_block_params(blockPath)
    params = struct();
    try
        dialogParams = get_param(blockPath, 'DialogParameters');
        if ~isempty(dialogParams)
            paramNames = fieldnames(dialogParams);
            for k = 1:length(paramNames)
                try
                    val = get_param(blockPath, paramNames{k});
                    if isnumeric(val)
                        params.(paramNames{k}) = val;
                    elseif islogical(val)
                        params.(paramNames{k}) = val;
                    else
                        params.(paramNames{k}) = val;
                    end
                catch
                end
            end
        end
    catch
    end
end

% ===== 辅助函数：获取回调信息 =====
function callbacks = get_block_callbacks(blockPath)
    callbacks = struct();
    cbNames = {'InitFcn', 'StartFcn', 'PauseFcn', 'ContinueFcn', 'StopFcn', ...
               'CopyFcn', 'DeleteFcn', 'LoadFcn', 'ModelCloseFcn', 'PreSaveFcn', ...
               'PostSaveFcn', 'OpenFcn', 'CloseFcn'};
    for k = 1:length(cbNames)
        try
            val = get_param(blockPath, cbNames{k});
            if ~isempty(val)
                callbacks.(cbNames{k}) = val;
            end
        catch
        end
    end
end
