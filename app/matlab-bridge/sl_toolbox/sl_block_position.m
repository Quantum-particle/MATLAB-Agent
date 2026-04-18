function result = sl_block_position(modelName, varargin)
% SL_BLOCK_POSITION 模块位置操作（替代裸 Position 向量）
%   result = sl_block_position('MyModel', 'action', 'get', 'blockPath', 'MyModel/Gain1')
%   result = sl_block_position('MyModel', 'action', 'set', 'blockPath', 'MyModel/Gain1', 'position', [200 100 280 140])
%   result = sl_block_position('MyModel', 'action', 'arrange', 'blockPaths', {'MyModel/Step','MyModel/Gain1'}, 'spacing', 150)
%   result = sl_block_position('MyModel', 'action', 'align', 'blockPaths', {'MyModel/Step','MyModel/Gain1'}, 'alignDirection', 'horizontal')
%
%   反模式 #2 的正确替代方案: 裸 Position 向量 → sl_block_position 封装
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName        - 模型名称（必选）
%     'action'         - 'get'/'set'/'arrange'/'align'（必选）
%     'blockPath'      - 模块路径（get/set 时必选）
%     'blockPaths'     - cell{char}，多个模块路径（arrange/align 时必选）
%     'position'       - [left, top, right, bottom]（set 时必选）
%     'relativeMove'   - [dx, dy]（可选，set 时使用）
%     'alignDirection' - 'horizontal'/'vertical'（align 时必选）
%     'spacing'        - double，间距（arrange/align 时使用，默认 150）
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status         - 'ok' 或 'error'
%     .blockPosition  - struct（结构因 action 不同而异）
%     .error          - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'action', '', ...
        'blockPath', '', ...
        'blockPaths', {{}}, ...
        'position', [], ...
        'relativeMove', [], ...
        'alignDirection', '', ...
        'spacing', 150, ...
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
    
    result = struct('status', 'ok', 'blockPosition', struct(), 'error', '');
    
    % ===== 验证 action =====
    if isempty(opts.action)
        result.status = 'error';
        result.error = 'action is required: ''get'', ''set'', ''arrange'', or ''align''';
        return;
    end
    
    validActions = {'get', 'set', 'arrange', 'align'};
    isValidAction = false;
    for i = 1:length(validActions)
        if strcmpi(opts.action, validActions{i})
            isValidAction = true;
            break;
        end
    end
    if ~isValidAction
        result.status = 'error';
        result.error = ['Invalid action: ' opts.action '. Must be get/set/arrange/align.'];
        return;
    end
    
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
    
    % ===== 分发到对应 action =====
    switch lower(opts.action)
        case 'get'
            result = action_get(modelName, opts, result);
        case 'set'
            result = action_set(modelName, opts, result);
        case 'arrange'
            result = action_arrange(modelName, opts, result);
        case 'align'
            result = action_align(modelName, opts, result);
    end
end


% ===== action='get': 获取模块位置信息 =====
function result = action_get(modelName, opts, result)
    blockPath = opts.blockPath;
    if isempty(blockPath)
        result.status = 'error';
        result.error = 'blockPath is required for action=''get''';
        return;
    end
    
    try
        pos = get_param(blockPath, 'Position');  % [left, top, right, bottom]
        width = pos(3) - pos(1);
        height = pos(4) - pos(2);
        centerX = (pos(1) + pos(3)) / 2;
        centerY = (pos(2) + pos(4)) / 2;
        
        result.blockPosition = struct( ...
            'blockPath', blockPath, ...
            'position', pos, ...
            'dimensions', struct('width', width, 'height', height), ...
            'center', struct('x', centerX, 'y', centerY));
    catch ME
        result.status = 'error';
        result.error = ['Failed to get position for ' blockPath ': ' ME.message];
    end
end


% ===== action='set': 设置模块位置 =====
function result = action_set(modelName, opts, result)
    blockPath = opts.blockPath;
    if isempty(blockPath)
        result.status = 'error';
        result.error = 'blockPath is required for action=''set''';
        return;
    end
    
    % 获取当前位置
    oldPos = [];
    try
        oldPos = get_param(blockPath, 'Position');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        return;
    end
    
    % 计算新位置
    newPos = [];
    if ~isempty(opts.relativeMove)
        % 相对移动模式
        dx = opts.relativeMove(1);
        dy = opts.relativeMove(2);
        newPos = oldPos + [dx, dy, dx, dy];
    elseif ~isempty(opts.position)
        % 绝对位置模式
        newPos = opts.position;
    else
        result.status = 'error';
        result.error = 'Either ''position'' or ''relativeMove'' must be specified for action=''set''';
        return;
    end
    
    % 设置新位置
    try
        set_param(blockPath, 'Position', newPos);
    catch ME
        result.status = 'error';
        result.error = ['Failed to set position for ' blockPath ': ' ME.message];
        return;
    end
    
    % 验证位置已更新
    verifiedPos = [];
    try
        verifiedPos = get_param(blockPath, 'Position');
    catch
    end
    
    result.blockPosition = struct( ...
        'blockPath', blockPath, ...
        'oldPosition', oldPos, ...
        'newPosition', newPos, ...
        'verifiedPosition', verifiedPos, ...
        'verified', is_equal_pos(newPos, verifiedPos));
end


% ===== action='arrange': BFS 拓扑排序排列 =====
function result = action_arrange(modelName, opts, result)
    blockPaths = opts.blockPaths;
    if isempty(blockPaths)
        result.status = 'error';
        result.error = 'blockPaths is required for action=''arrange''';
        return;
    end
    
    nBlocks = length(blockPaths);
    spacing = opts.spacing;
    
    % 建立 path → index 映射
    pathToIdx = struct();
    for i = 1:nBlocks
        safeKey = make_safe_key(blockPaths{i}, modelName);
        pathToIdx.(safeKey) = i;
    end
    
    % 构建邻接表 + 入度
    adjList = cell(1, nBlocks);
    inDegree = zeros(1, nBlocks);
    edgeSrc = [];
    edgeDst = [];
    
    % 从连线获取信号流关系
    try
        lineHandles = find_system(modelName, 'SearchDepth', 1, ...
            'FindAll', 'on', 'Type', 'Line');
        
        for li = 1:length(lineHandles)
            try
                lh = lineHandles(li);
                srcIdx = 0;
                dstIdx = 0;
                
                % 获取源模块
                try
                    srcPH = get_param(lh, 'SrcPortHandle');
                    if srcPH ~= 0
                        srcBH = get_param(srcPH, 'Parent');
                        srcName = get_param(srcBH, 'Name');
                        srcParent = get_param(srcBH, 'Parent');
                        if strcmpi(srcParent, modelName)
                            srcPath = [modelName '/' srcName];
                        else
                            srcPath = [srcParent '/' srcName];
                        end
                        srcKey = make_safe_key(srcPath, modelName);
                        if isfield(pathToIdx, srcKey)
                            srcIdx = pathToIdx.(srcKey);
                        end
                    end
                catch
                end
                
                % 获取目标模块
                try
                    dstPHs = get_param(lh, 'DstPortHandle');
                    if ~isempty(dstPHs) && dstPHs(1) ~= 0
                        dstPH = dstPHs(1);
                        dstBH = get_param(dstPH, 'Parent');
                        dstName = get_param(dstBH, 'Name');
                        dstParent = get_param(dstBH, 'Parent');
                        if strcmpi(dstParent, modelName)
                            dstPath = [modelName '/' dstName];
                        else
                            dstPath = [dstParent '/' dstName];
                        end
                        dstKey = make_safe_key(dstPath, modelName);
                        if isfield(pathToIdx, dstKey)
                            dstIdx = pathToIdx.(dstKey);
                        end
                    end
                catch
                end
                
                if srcIdx > 0 && dstIdx > 0 && srcIdx ~= dstIdx
                    % 避免重复边
                    alreadyExists = false;
                    for ai = 1:length(adjList{srcIdx})
                        if adjList{srcIdx}{ai} == dstIdx
                            alreadyExists = true;
                            break;
                        end
                    end
                    if ~alreadyExists
                        adjList{srcIdx}{end+1} = dstIdx; %#ok<AGROW>
                        inDegree(dstIdx) = inDegree(dstIdx) + 1;
                        edgeSrc(end+1) = srcIdx; %#ok<AGROW>
                        edgeDst(end+1) = dstIdx; %#ok<AGROW>
                    end
                end
            catch
            end
        end
    catch
    end
    
    % 贪心拓扑排序
    layer = zeros(1, nBlocks);
    tempInDeg = inDegree;
    processed = false(1, nBlocks);
    
    for step = 1:nBlocks
        bestIdx = 0;
        bestDeg = nBlocks + 1;
        for i = 1:nBlocks
            if ~processed(i) && tempInDeg(i) < bestDeg
                bestDeg = tempInDeg(i);
                bestIdx = i;
            end
        end
        if bestIdx == 0, break; end
        processed(bestIdx) = true;
        
        bestLayer = 0;
        for ei = 1:length(edgeSrc)
            if edgeDst(ei) == bestIdx && processed(edgeSrc(ei))
                bestLayer = max(bestLayer, layer(edgeSrc(ei)) + 1);
            end
        end
        layer(bestIdx) = bestLayer;
        
        for ai = 1:length(adjList{bestIdx})
            nxt = adjList{bestIdx}{ai};
            tempInDeg(nxt) = tempInDeg(nxt) - 1;
        end
    end
    
    % 按层分组
    nLayers = max(layer) + 1;
    if nLayers == 0, nLayers = 1; end
    
    layerBlocks = cell(1, nLayers);
    for li = 1:nLayers
        layerBlocks{li} = [];
    end
    for i = 1:nBlocks
        layerBlocks{layer(i)+1} = [layerBlocks{layer(i)+1}, i]; %#ok<AGROW>
    end
    
    % 获取模块尺寸
    blockSizes = zeros(nBlocks, 2);
    for i = 1:nBlocks
        try
            pos = get_param(blockPaths{i}, 'Position');
            blockSizes(i, 1) = pos(3) - pos(1);
            blockSizes(i, 2) = pos(4) - pos(2);
        catch
            blockSizes(i, :) = [90 40];
        end
    end
    
    % BFS 拓扑排序布局
    margin = [80 80];
    layerGap = spacing * 2.5;
    blockGap = spacing * 0.8;
    movedBlocks = {};
    
    for li = 1:nLayers
        blocksInLayer = layerBlocks{li};
        nInLayer = length(blocksInLayer);
        if nInLayer == 0, continue; end
        
        xLeft = margin(1) + (li - 1) * layerGap;
        
        % 计算该层总高度
        totalHeight = 0;
        for bi = 1:nInLayer
            totalHeight = totalHeight + blockSizes(blocksInLayer(bi), 2);
        end
        totalHeight = totalHeight + (nInLayer - 1) * blockGap;
        
        yStart = margin(2);
        
        for bi = 1:nInLayer
            bIdx = blocksInLayer(bi);
            w = blockSizes(bIdx, 1);
            h = blockSizes(bIdx, 2);
            newPos = [xLeft, yStart, xLeft + w, yStart + h];
            
            try
                set_param(blockPaths{bIdx}, 'Position', newPos);
                movedBlocks{end+1} = struct('path', blockPaths{bIdx}, ... %#ok<AGROW>
                    'position', newPos, 'layer', li);
            catch ME
                movedBlocks{end+1} = struct('path', blockPaths{bIdx}, ... %#ok<AGROW>
                    'position', [], 'layer', li, 'error', ME.message);
            end
            yStart = yStart + h + blockGap;
        end
    end
    
    result.blockPosition = struct( ...
        'action', 'arrange', ...
        'blocksMoved', length(movedBlocks), ...
        'layerCount', nLayers, ...
        'arranged', movedBlocks);
end


% ===== action='align': 对齐模块 =====
function result = action_align(modelName, opts, result)
    blockPaths = opts.blockPaths;
    if isempty(blockPaths)
        result.status = 'error';
        result.error = 'blockPaths is required for action=''align''';
        return;
    end
    
    alignDir = lower(opts.alignDirection);
    if isempty(alignDir) || (~strcmpi(alignDir, 'horizontal') && ~strcmpi(alignDir, 'vertical'))
        result.status = 'error';
        result.error = 'alignDirection must be ''horizontal'' or ''vertical''';
        return;
    end
    
    nBlocks = length(blockPaths);
    spacing = opts.spacing;
    
    % 获取所有模块当前位置和尺寸
    positions = zeros(nBlocks, 4);
    sizes = zeros(nBlocks, 2);
    validBlock = true(1, nBlocks);
    
    for i = 1:nBlocks
        try
            pos = get_param(blockPaths{i}, 'Position');
            positions(i, :) = pos;
            sizes(i, 1) = pos(3) - pos(1);
            sizes(i, 2) = pos(4) - pos(2);
        catch ME
            validBlock(i) = false;
        end
    end
    
    movedBlocks = {};
    
    if strcmpi(alignDir, 'horizontal')
        % 水平对齐: 统一 top 坐标（取平均值），水平等间距
        avgTop = mean(positions(validBlock, 2));
        
        % 按当前 left 坐标排序
        validIdx = find(validBlock);
        leftOrder = sortrows([positions(validIdx, 1), validIdx(:)], 1);
        
        xCursor = leftOrder(1, 1);  % 从最左边的位置开始
        for oi = 1:size(leftOrder, 1)
            i = leftOrder(oi, 2);
            w = sizes(i, 1);
            h = sizes(i, 2);
            newPos = [xCursor, avgTop, xCursor + w, avgTop + h];
            
            try
                set_param(blockPaths{i}, 'Position', newPos);
                movedBlocks{end+1} = struct('path', blockPaths{i}, ... %#ok<AGROW>
                    'oldPosition', positions(i, :), 'newPosition', newPos);
            catch ME
                movedBlocks{end+1} = struct('path', blockPaths{i}, ... %#ok<AGROW>
                    'error', ME.message);
            end
            xCursor = xCursor + w + spacing;
        end
    else
        % 垂直对齐: 统一 left 坐标（取平均值），垂直等间距
        avgLeft = mean(positions(validBlock, 1));
        
        % 按当前 top 坐标排序
        validIdx = find(validBlock);
        topOrder = sortrows([positions(validIdx, 2), validIdx(:)], 1);
        
        yCursor = topOrder(1, 1);  % 从最上面的位置开始
        for oi = 1:size(topOrder, 1)
            i = topOrder(oi, 2);
            w = sizes(i, 1);
            h = sizes(i, 2);
            newPos = [avgLeft, yCursor, avgLeft + w, yCursor + h];
            
            try
                set_param(blockPaths{i}, 'Position', newPos);
                movedBlocks{end+1} = struct('path', blockPaths{i}, ... %#ok<AGROW>
                    'oldPosition', positions(i, :), 'newPosition', newPos);
            catch ME
                movedBlocks{end+1} = struct('path', blockPaths{i}, ... %#ok<AGROW>
                    'error', ME.message);
            end
            yCursor = yCursor + h + spacing;
        end
    end
    
    result.blockPosition = struct( ...
        'action', 'align', ...
        'alignDirection', alignDir, ...
        'spacing', spacing, ...
        'blocksMoved', length(movedBlocks), ...
        'aligned', movedBlocks);
end


% ===== 辅助函数: 比较位置是否相等 =====
function eq = is_equal_pos(pos1, pos2)
% 比较两个 Position 向量是否相等（允许微小浮点误差）
    if isempty(pos1) || isempty(pos2)
        eq = false;
        return;
    end
    eq = all(abs(pos1 - pos2) < 0.5);
end


% ===== 辅助函数: 生成安全的 struct key =====
function key = make_safe_key(blockPath, modelName)
% 生成 MATLAB 有效的 struct 字段名
    if length(blockPath) > length(modelName) + 1
        rest = blockPath(length(modelName)+2:end);
    else
        rest = modelName;
    end
    key = strrep(rest, '/', '_');
    key = strrep(key, ' ', '_');
    key = strrep(key, '-', '_');
    if ~isempty(key) && (key(1) >= '0' && key(1) <= '9')
        key = ['b_' key];
    end
end
