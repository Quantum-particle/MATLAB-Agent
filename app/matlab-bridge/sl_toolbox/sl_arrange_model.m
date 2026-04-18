function result = sl_arrange_model(modelName, varargin)
% SL_ARRANGE_MODEL 整理模型布局 — 让 AI 构建的模型人类可读
%   result = sl_arrange_model(modelName)
%   result = sl_arrange_model(modelName, 'routeLines', true, 'scale', 1.0, ...)
%
%   核心策略:
%     R2018b+ — 等同于 Simulink 界面的"自动布局"按钮:
%              arrangeSystem('FullLayout','true') + routeLine
%              默认不做任何后处理，scale>1.0 时才缩放
%              注意: arrangeSystem 不会改变模块尺寸，只改变位置
%     R2016a~R2018a — 拓扑排序 + 反馈边断开 + 分层居中布局
%
%   输入:
%     modelName      - 模型名称（必选）
%     'routeLines'   - 是否整理连线走向，默认 true
%     'scale'        - arrangeSystem 后的缩放因子（仅 native），默认 1.0（不缩放）
%     'spacing'      - 同层模块垂直间距（仅 fallback），默认 200
%     'layerGap'     - 层间水平间距（仅 fallback），默认 400
%     'blockGap'     - 同层相邻模块间垂直间距（仅 fallback），默认同 spacing
%     'margin'       - 左上角起始边距 [x,y]，默认 [80 80]
%     'layoutGuide'  - 布局语义指导 struct（可选，详见下方）
%     'forceNative'  - 强制使用高版本 API（调试用），默认 false
%     'forceFallback'- 强制使用回退方案（调试用），默认 false
%
%   layoutGuide — 让 AI agent 按物理意义指导布局:
%     .lanes     - 水平通道定义，cell of struct:
%                  {struct('name','forward','blocks',{'Sum','PID','Plant'},'yCenter',100), ...}
%                  每个 lane 指定: 名称、包含的模块名列表、Y 中心坐标
%     .feedbacks - 反馈通道定义，cell of struct:
%                  {struct('blocks',{'Gain'},'yOffset',150), ...}
%                  yOffset: 相对 forward 通道向下偏移的像素数
%     如果提供了 layoutGuide，将优先按其排布，再调用 arrangeSystem/fallback 微调
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .method   - 'native' / 'fallback' / 'guided_native' / 'guided_fallback'
%     .message  - 人类可读的描述信息
%     .blocks   - 整理后的模块位置信息
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'routeLines', true, ...
        'scale', 1.0, ...
        'spacing', 200, ...
        'layerGap', 400, ...
        'blockGap', [], ...
        'margin', [80 80], ...
        'layoutGuide', [], ...
        'forceNative', false, ...
        'forceFallback', false);
    
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
    
    % blockGap 默认等于 spacing
    if isempty(opts.blockGap)
        opts.blockGap = opts.spacing;
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
    
    % ===== 获取顶层模块列表 =====
    try
        allBlocks = find_system(modelName, 'SearchDepth', 1, 'LookUnderMasks', 'all');
    catch ME
        result = struct('status', 'error', 'error', ...
            ['find_system failed: ' ME.message]);
        return;
    end
    
    % 过滤掉模型自身
    if length(allBlocks) > 1
        blockPaths = allBlocks(2:end);
    else
        blockPaths = {};
    end
    
    if isempty(blockPaths)
        result = struct('status', 'ok', 'method', 'none', 'blocks', {}, ...
            'message', 'No blocks to arrange');
        return;
    end
    
    % ===== 判断使用哪种方法 =====
    useNative = false;
    
    if ~opts.forceFallback
        hasArrange = false;
        try
            m = which('Simulink.BlockDiagram.arrangeSystem');
            if ~isempty(m)
                hasArrange = true;
            end
        catch
        end
        if ~hasArrange
            try
                v = version;
                rp = strfind(v, 'R');
                if ~isempty(rp)
                    verStr = v(rp(1):rp(1)+5);
                    yr = sscanf(verStr(2:5), '%d');
                    rel = verStr(6);
                    if yr > 2018 || (yr == 2018 && rel >= 'b')
                        hasArrange = true;
                    end
                end
            catch
            end
        end
        if hasArrange || opts.forceNative
            useNative = true;
        end
    end
    
    % ===== 如果有 layoutGuide，优先按语义指导排布 =====
    if ~isempty(opts.layoutGuide)
        result = arrange_guided(modelName, blockPaths, opts, useNative);
    elseif useNative
        result = arrange_native(modelName, blockPaths, opts);
    else
        result = arrange_fallback(modelName, blockPaths, opts);
    end
end

% ===== 语义指导布局: AI agent 按物理意义指定布局 =====
function result = arrange_guided(modelName, blockPaths, opts, useNative)
    guide = opts.layoutGuide;
    nBlocks = length(blockPaths);
    errors = {};
    movedBlocks = {};
    
    % 建立模块名 → 路径 映射
    nameToPath = struct();
    nameToIdx = struct();
    for i = 1:nBlocks
        % 取最后一段作为名称
        parts = strsplit(blockPaths{i}, '/');
        bname = parts{end};
        nameToPath.(bname) = blockPaths{i};
        nameToIdx.(bname) = i;
    end
    
    % 获取每个模块的尺寸
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
    
    % 已定位的模块集合
    positioned = false(1, nBlocks);
    
    % 1. 处理 lanes（前向通道）
    lanes = [];
    if isfield(guide, 'lanes') && ~isempty(guide.lanes)
        lanes = guide.lanes;
    end
    
    % 计算前向通道的 Y 中心（默认在 margin(2)）
    forwardY = opts.margin(2);
    if isfield(guide, 'forwardY')
        forwardY = guide.forwardY;
    end
    
    % 每个前向 lane 从左到右依次排列
    xCursor = opts.margin(1);
    laneGap = opts.layerGap;
    
    for li = 1:length(lanes)
        lane = lanes{li};
        laneBlocks = [];
        if isfield(lane, 'blocks')
            laneBlocks = lane.blocks;
        end
        
        % 该 lane 的 Y 中心
        laneY = forwardY;
        if isfield(lane, 'yCenter')
            laneY = lane.yCenter;
        end
        
        % 该 lane 内模块从左到右依次排列
        for bi = 1:length(laneBlocks)
            bname = laneBlocks{bi};
            if isfield(nameToIdx, bname)
                idx = nameToIdx.(bname);
                w = blockSizes(idx, 1);
                h = blockSizes(idx, 2);
                newPos = [xCursor, laneY - h/2, xCursor + w, laneY + h/2];
                
                try
                    set_param(blockPaths{idx}, 'Position', newPos);
                    movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                        'position', newPos, 'lane', li);
                catch ME
                    movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                        'position', [], 'lane', li, 'error', ME.message);
                end
                positioned(idx) = true;
                xCursor = xCursor + w + opts.spacing * 0.5;  % 同 lane 内紧凑一些
            end
        end
        % lane 之间留大间距
        xCursor = xCursor + laneGap - opts.spacing * 0.5;
    end
    
    % 2. 处理 feedbacks（反馈通道）
    feedbacks = [];
    if isfield(guide, 'feedbacks') && ~isempty(guide.feedbacks)
        feedbacks = guide.feedbacks;
    end
    
    for fi = 1:length(feedbacks)
        fb = feedbacks{fi};
        fbBlocks = [];
        if isfield(fb, 'blocks')
            fbBlocks = fb.blocks;
        end
        
        % 反馈通道的 Y 偏移（相对 forwardY 向下）
        yOffset = 150;
        if isfield(fb, 'yOffset')
            yOffset = fb.yOffset;
        end
        fbY = forwardY + yOffset;
        
        % 反馈模块从右到左排列（与信号流方向一致）
        fxCursor = xCursor - laneGap;  % 从前向通道末端开始
        for bi = length(fbBlocks):-1:1
            bname = fbBlocks{bi};
            if isfield(nameToIdx, bname)
                idx = nameToIdx.(bname);
                w = blockSizes(idx, 1);
                h = blockSizes(idx, 2);
                newPos = [fxCursor, fbY - h/2, fxCursor + w, fbY + h/2];
                
                try
                    set_param(blockPaths{idx}, 'Position', newPos);
                    movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                        'position', newPos, 'feedback', fi);
                catch ME
                    movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                        'position', [], 'feedback', fi, 'error', ME.message);
                end
                positioned(idx) = true;
                fxCursor = fxCursor - w - opts.spacing * 0.5;
            end
        end
    end
    
    % 3. 未被 guide 覆盖的模块 — 用 arrangeSystem/fallback 自动排布
    unpositionedIdxs = find(~positioned);
    if ~isempty(unpositionedIdxs)
        if useNative
            try
                Simulink.BlockDiagram.arrangeSystem(modelName, 'FullLayout', 'true');
            catch
            end
            % 只调整未定位的模块到合理位置（放在已排布区域下方）
            placedBottom = 0;
            for i = 1:nBlocks
                if positioned(i)
                    try
                        p = get_param(blockPaths{i}, 'Position');
                        if p(4) > placedBottom
                            placedBottom = p(4);
                        end
                    catch
                    end
                end
            end
            
            yOffsetExtra = placedBottom + opts.blockGap;
            for ii = 1:length(unpositionedIdxs)
                idx = unpositionedIdxs(ii);
                try
                    p = get_param(blockPaths{idx}, 'Position');
                    p(2) = p(2) + yOffsetExtra;
                    p(4) = p(4) + yOffsetExtra;
                    set_param(blockPaths{idx}, 'Position', p);
                    movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                        'position', p, 'auto', true);
                catch
                end
            end
        end
    end
    
    % 4. routeLine
    if opts.routeLines && useNative
        try
            lineHandles = find_system(modelName, 'SearchDepth', 1, ...
                'FindAll', 'on', 'Type', 'Line');
            if ~isempty(lineHandles)
                Simulink.BlockDiagram.routeLine(lineHandles);
            end
        catch
        end
    end
    
    % 收集最终位置
    blocksInfo = collect_positions(blockPaths);
    
    result = struct();
    result.status = 'ok';
    if useNative
        result.method = 'guided_native';
    else
        result.method = 'guided_fallback';
    end
    result.message = 'Layout arranged using semantic guide + auto-arrange';
    result.blocks = blocksInfo;
    result.guideApplied = true;
    if ~isempty(errors)
        result.warnings = errors;
    end
end

% ===== 高版本: arrangeSystem + routeLine — 等同于 Simulink "自动布局" 按钮 =====
function result = arrange_native(modelName, blockPaths, opts)
    errors = {};
    nBlocks = length(blockPaths);
    
    % 1. arrangeSystem(FullLayout='true') — 等同于 Simulink 界面的"自动布局"按钮
    %    不带 FullLayout 时，arrangeSystem 仅在"预期优于原始布局"时才生效
    %    对于 AI 构建的模型，原始布局通常是随机的，必须强制应用
    %    arrangeSystem 不会改变模块尺寸，只改变位置
    try
        % FullLayout 接受字符串 'true'/'false'，不是逻辑值
        Simulink.BlockDiagram.arrangeSystem(modelName, 'FullLayout', 'true');
    catch ME
        errors{end+1} = ['arrangeSystem failed: ' ME.message]; %#ok<AGROW>
    end
    
    % 2. 可选缩放（仅当 scale > 1.0 时）
    scale = opts.scale;
    if scale > 1.0
        try
            positions = [];
            for i = 1:nBlocks
                try
                    pos = get_param(blockPaths{i}, 'Position');
                    positions(end+1, 1:4) = pos; %#ok<AGROW>
                catch
                    positions(end+1, 1:4) = [0 0 90 40]; %#ok<AGROW>
                end
            end
            
            if ~isempty(positions)
                centers = [positions(:,1) + positions(:,3), positions(:,2) + positions(:,4)] / 2;
                centroid = mean(centers, 1);
                margin = opts.margin;
                
                % 以质心为原点缩放位置，保持 arrangeSystem 输出的模块尺寸不变
                for i = 1:nBlocks
                    try
                        pos = get_param(blockPaths{i}, 'Position');
                        cx = (pos(1) + pos(3)) / 2;
                        cy = (pos(2) + pos(4)) / 2;
                        w = pos(3) - pos(1);
                        h = pos(4) - pos(2);
                        newCx = centroid(1) + (cx - centroid(1)) * scale;
                        newCy = centroid(2) + (cy - centroid(2)) * scale;
                        newPos = [newCx - w/2, newCy - h/2, newCx + w/2, newCy + h/2];
                        set_param(blockPaths{i}, 'Position', newPos);
                    catch
                    end
                end
                
                % 缩放后边界修正
                allPos = [];
                for i = 1:nBlocks
                    try
                        p = get_param(blockPaths{i}, 'Position');
                        allPos(end+1, 1:4) = p; %#ok<AGROW>
                    catch
                    end
                end
                
                if ~isempty(allPos)
                    minLeft = min(allPos(:, 1));
                    minTop = min(allPos(:, 2));
                    offsetX = 0;
                    offsetY = 0;
                    if minLeft < margin(1), offsetX = margin(1) - minLeft; end
                    if minTop < margin(2), offsetY = margin(2) - minTop; end
                    
                    if offsetX > 0 || offsetY > 0
                        for i = 1:nBlocks
                            try
                                p = get_param(blockPaths{i}, 'Position');
                                p([1 3]) = p([1 3]) + offsetX;
                                p([2 4]) = p([2 4]) + offsetY;
                                set_param(blockPaths{i}, 'Position', p);
                            catch
                            end
                        end
                    end
                end
            end
        catch ME
            errors{end+1} = ['Scale fix failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 3. routeLine — 等同于 Simulink 界面的"整理连线"按钮
    if opts.routeLines
        try
            lineHandles = find_system(modelName, 'SearchDepth', 1, ...
                'FindAll', 'on', 'Type', 'Line');
            if ~isempty(lineHandles)
                Simulink.BlockDiagram.routeLine(lineHandles);
            end
        catch ME
            errors{end+1} = ['routeLine failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 4. 收集结果
    blocksInfo = collect_positions(blockPaths);
    
    result = struct();
    result.status = 'ok';
    result.method = 'native';
    if scale > 1.0
        result.message = sprintf('Layout arranged using arrangeSystem (scale %.1fx)', scale);
    else
        result.message = 'Layout arranged using Simulink auto-layout (arrangeSystem + routeLine)';
    end
    result.blocks = blocksInfo;
    if ~isempty(errors)
        result.warnings = errors;
    end
end

% ===== 低版本回退: 拓扑排序 + 断开反馈边 + 分层居中布局 =====
function result = arrange_fallback(modelName, blockPaths, opts)
    nBlocks = length(blockPaths);
    
    % 1. 构建邻接表 + 边列表
    adjList = cell(1, nBlocks);
    inDegree = zeros(1, nBlocks);
    edgeSrc = zeros(1, 1000);  % 预分配，避免 R2016a 动态增长问题
    edgeDst = zeros(1, 1000);
    edgeCount = 0;
    
    pathToIdx = struct();
    for i = 1:nBlocks
        safeKey = block_key(blockPaths{i}, modelName);
        pathToIdx.(safeKey) = i;
    end
    
    % 2. 从连线获取信号流关系
    try
        lineHandles = find_system(modelName, 'SearchDepth', 1, ...
            'FindAll', 'on', 'Type', 'Line');
        
        for li = 1:length(lineHandles)
            try
                lh = lineHandles(li);
                srcIdx = 0;
                dstIdx = 0;
                
                try
                    srcPH = get_param(lh, 'SrcPortHandle');
                    srcBH = get_param(srcPH, 'Parent');
                    srcName = get_param(srcBH, 'Name');
                    srcParent = get_param(srcBH, 'Parent');
                    if strcmpi(srcParent, modelName)
                        srcPath = [modelName '/' srcName];
                    else
                        srcPath = [srcParent '/' srcName];
                    end
                    srcKey = block_key(srcPath, modelName);
                    if isfield(pathToIdx, srcKey)
                        srcIdx = pathToIdx.(srcKey);
                    end
                catch
                end
                
                try
                    dstPHs = get_param(lh, 'DstPortHandle');
                    if ~isempty(dstPHs)
                        dstPH = dstPHs(1);
                        dstBH = get_param(dstPH, 'Parent');
                        dstName = get_param(dstBH, 'Name');
                        dstParent = get_param(dstBH, 'Parent');
                        if strcmpi(dstParent, modelName)
                            dstPath = [modelName '/' dstName];
                        else
                            dstPath = [dstParent '/' dstName];
                        end
                        dstKey = block_key(dstPath, modelName);
                        if isfield(pathToIdx, dstKey)
                            dstIdx = pathToIdx.(dstKey);
                        end
                    end
                catch
                end
                
                if srcIdx > 0 && dstIdx > 0 && srcIdx ~= dstIdx
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
                        edgeCount = edgeCount + 1;
                        edgeSrc(edgeCount) = srcIdx;
                        edgeDst(edgeCount) = dstIdx;
                    end
                end
            catch
            end
        end
    catch
    end
    
    % 裁剪边数组
    edgeSrc = edgeSrc(1:edgeCount);
    edgeDst = edgeDst(1:edgeCount);
    
    % 3. 贪心拓扑排序 — 遇环时选最小 inDegree 节点继续
    %    简单有效：优先处理 inDegree=0 的节点，当无此节点时选最小 inDegree
    layer = zeros(1, nBlocks);
    tempInDeg = inDegree;
    processed = false(1, nBlocks);
    
    for step = 1:nBlocks
        % 找下一个要处理的节点：优先 inDegree=0，否则最小 inDegree
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
        
        % 计算此节点的层 = max(所有已处理前驱的层) + 1
        bestLayer = 0;
        for ei = 1:edgeCount
            if edgeDst(ei) == bestIdx && processed(edgeSrc(ei))
                bestLayer = max(bestLayer, layer(edgeSrc(ei)) + 1);
            end
        end
        layer(bestIdx) = bestLayer;
        
        % 更新后继的 inDegree
        for ai = 1:length(adjList{bestIdx})
            nxt = adjList{bestIdx}{ai};
            tempInDeg(nxt) = tempInDeg(nxt) - 1;
        end
    end
    
    % 6. 按层分组
    nLayers = max(layer) + 1;
    if nLayers == 0, nLayers = 1; end
    
    layerBlocks = cell(1, nLayers);
    for li = 1:nLayers
        layerBlocks{li} = [];
    end
    for i = 1:nBlocks
        layerBlocks{layer(i)+1} = [layerBlocks{layer(i)+1}, i]; %#ok<AGROW>
    end
    
    % 7. 计算模块尺寸
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
    
    % 8. 垂直居中 + 水平分层排列
    margin = opts.margin;
    blockGap = opts.blockGap;
    layerGap = opts.layerGap;
    
    % 计算最大层高度用于居中
    maxTotalHeight = 0;
    for li = 1:nLayers
        totalH = 0;
        for bi = 1:length(layerBlocks{li})
            totalH = totalH + blockSizes(layerBlocks{li}(bi), 2);
        end
        totalH = totalH + max(0, length(layerBlocks{li}) - 1) * blockGap;
        if totalH > maxTotalHeight
            maxTotalHeight = totalH;
        end
    end
    centerY = margin(2) + maxTotalHeight / 2;
    
    movedBlocks = {};
    for li = 1:nLayers
        blocksInLayer = layerBlocks{li};
        nInLayer = length(blocksInLayer);
        if nInLayer == 0, continue; end
        
        xLeft = margin(1) + (li - 1) * layerGap;
        
        % 该层总高度
        totalHeight = 0;
        for bi = 1:nInLayer
            totalHeight = totalHeight + blockSizes(blocksInLayer(bi), 2);
        end
        totalHeight = totalHeight + (nInLayer - 1) * blockGap;
        
        yStart = centerY - totalHeight / 2;
        
        for bi = 1:nInLayer
            idx = blocksInLayer(bi);
            w = blockSizes(idx, 1);
            h = blockSizes(idx, 2);
            newPos = [xLeft, yStart, xLeft + w, yStart + h];
            
            try
                set_param(blockPaths{idx}, 'Position', newPos);
                movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                    'position', newPos, 'layer', li);
            catch ME
                movedBlocks{end+1} = struct('path', blockPaths{idx}, ... %#ok<AGROW>
                    'position', [], 'layer', li, 'error', ME.message);
            end
            yStart = yStart + h + blockGap;
        end
    end
    
    % 9. 尝试整理连线
    routeLineStatus = 'not_available';
    if opts.routeLines
        try
            set_param(modelName, 'SimulationCommand', 'update');
            routeLineStatus = 'updated';
        catch
            try
                save_system(modelName);
                load_system(modelName);
                routeLineStatus = 'reload_refreshed';
            catch
            end
        end
    end
    
    result = struct();
    result.status = 'ok';
    result.method = 'fallback';
    result.message = sprintf('Layout arranged using topological sort (%d layers, centered)', nLayers);
    result.blocks = movedBlocks;
    result.layerCount = nLayers;
    result.routeLineStatus = routeLineStatus;
end

% ===== 辅助函数: 收集模块位置 =====
function blocksInfo = collect_positions(blockPaths)
    blocksInfo = {};
    for i = 1:length(blockPaths)
        try
            bp = blockPaths{i};
            pos = get_param(bp, 'Position');
            blocksInfo{end+1} = struct('path', bp, 'position', pos); %#ok<AGROW>
        catch ME
            blocksInfo{end+1} = struct('path', blockPaths{i}, ... %#ok<AGROW>
                'position', [], 'error', ME.message);
        end
    end
end

% ===== 辅助函数: 生成安全的 struct key =====
function key = block_key(blockPath, modelName)
    path = blockPath;
    if length(path) > length(modelName) + 1
        rest = path(length(modelName)+2:end);
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
