function result = sl_auto_layout(modelName, varargin)
% SL_AUTO_LAYOUT 自动排版 — R2023a+ arrangeSystem 优先 / 旧版手动回退
%   result = sl_auto_layout('MyModel')
%   result = sl_auto_layout('MyModel', 'target', 'top', 'routeExistingLines', true)
%
%   版本策略:
%     R2023a+ — Simulink.BlockDiagram.arrangeSystem('FullLayout','true') + routeLine
%     R2016a~R2022b — BFS 拓扑排序手动布局 + 信号线重连
%
%   注意事项:
%     - arrangeSystem 的 FullLayout 参数接受字符串 'true'/'false'，不是逻辑值！
%     - routeLine 接受 line handles 数组，不是模型名
%     - R2024b+ 支持 resizeBlocksToFitContent
%
%   输入:
%     modelName            - 模型名称（必选）
%     'target'             - 'top'（默认）或具体子系统路径
%     'routeExistingLines' - 是否自动布线已有信号线，默认 true
%     'resizeBlocks'       - 是否调整模块大小（R2024b+），默认 false
%     'loadModelIfNot'     - 默认 true
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .layout   - struct(.target, .blocksRearranged, .linesRouted, .method)
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'target', 'top', ...
        'routeExistingLines', true, ...
        'resizeBlocks', false, ...
        'loadModelIfNot', true, ...
        'recursive', true);  % v11.1: 默认递归排版子系统内部
    
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
    
    result = struct('status', 'ok', 'layout', struct(), 'error', '');
    
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
    
    % ===== 确定 target 路径 =====
    if strcmpi(opts.target, 'top')
        targetPath = modelName;
    else
        targetPath = opts.target;
    end
    
    % ===== 检测 MATLAB 版本 =====
    hasArrangeSystem = false;
    hasRouteLine = false;
    hasResizeBlocks = false;
    
    try
        matlabVer = ver('MATLAB');
        verNum = sscanf(matlabVer.Version, '%d.%d');
        % R2023a = 23.2, R2023b = 24.1, R2024b = 24.2
        % 注意: sscanf('%d.%d') 对 '24.1' 返回 [24; 1]，对 '9.0' 返回 [9; 0]
        if length(verNum) >= 2
            hasArrangeSystem = verNum(1) > 23 || (verNum(1) == 23 && verNum(2) >= 2);
            hasRouteLine = hasArrangeSystem;
            hasResizeBlocks = verNum(1) > 24 || (verNum(1) == 24 && verNum(2) >= 2);
        end
    catch
        % 版本检测失败，尝试用 which 检测
        try
            m = which('Simulink.BlockDiagram.arrangeSystem');
            if ~isempty(m)
                hasArrangeSystem = true;
                hasRouteLine = true;
            end
        catch
        end
    end
    
    % ===== 获取目标下的模块数量 =====
    blockPaths = {};
    try
        allBlocks = find_system(targetPath, 'SearchDepth', 1, 'LookUnderMasks', 'all');
        if length(allBlocks) > 1
            blockPaths = allBlocks(2:end);  % 去掉自身
        end
    catch ME
        result.status = 'error';
        result.error = ['find_system failed: ' ME.message];
        return;
    end
    
    if isempty(blockPaths)
        result.layout = struct('target', targetPath, 'blocksRearranged', 0, ...
            'linesRouted', 0, 'method', 'none');
        result.message = 'No blocks to layout';
        return;
    end
    
    % ===== 执行布局 =====
    if hasArrangeSystem
        result = layout_native(targetPath, blockPaths, opts, hasRouteLine, hasResizeBlocks, result);
    else
        result = layout_fallback(targetPath, blockPaths, opts, result);
    end
end


% ===== 高版本: arrangeSystem + routeLine =====
function result = layout_native(targetPath, blockPaths, opts, hasRouteLine, hasResizeBlocks, result)
    nBlocks = length(blockPaths);
    linesRouted = 0;
    errors = {};
    
    % 1. arrangeSystem — FullLayout='true' 强制完整布局
    %    注意: FullLayout 接受字符串 'true'/'false'，不是逻辑值！
    blocksRearranged = nBlocks;
    try
        % Save before arrange to preserve state
        try save_system(targetPath); catch, end
        Simulink.BlockDiagram.arrangeSystem(targetPath, 'FullLayout', 'true');
        % Save after arrange to persist layout changes
        try save_system(targetPath); catch, end
        % Verify blocks still exist after arrangeSystem
        verifyBlocks = find_system(targetPath, 'SearchDepth', 1, 'LookUnderMasks', 'all');
        if length(verifyBlocks) <= 1
            % arrangeSystem may have corrupted model state
            % Try reloading from saved version
            try
                close_system(targetPath, 0);
                load_system(targetPath);
                verifyBlocks2 = find_system(targetPath, 'SearchDepth', 1, 'LookUnderMasks', 'all');
                if length(verifyBlocks2) <= 1
                    errors{end+1} = 'arrangeSystem appears to have removed blocks, reload also failed'; %#ok<AGROW>
                    blocksRearranged = 0;
                else
                    errors{end+1} = 'arrangeSystem caused state issue, reloaded model'; %#ok<AGROW>
                end
            catch
                errors{end+1} = 'arrangeSystem may have corrupted model state'; %#ok<AGROW>
                blocksRearranged = 0;
            end
        end
    catch ME
        errors{end+1} = ['arrangeSystem failed: ' ME.message]; %#ok<AGROW>
        blocksRearranged = 0;
    end
    
    % 2. routeLine — 自动布线已有信号线
    if opts.routeExistingLines && hasRouteLine
        try
            lineHandles = find_system(targetPath, 'SearchDepth', 1, ...
                'FindAll', 'on', 'Type', 'Line');
            if ~isempty(lineHandles)
                % routeLine 接受 line handles 数组，不是模型名！
                Simulink.BlockDiagram.routeLine(lineHandles);
                linesRouted = length(lineHandles);
            end
        catch ME
            errors{end+1} = ['routeLine failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 3. 递归排版子系统内部（v11.1 新增）
    % arrangeSystem 只排版当前层级，需要手动递归处理子系统
    totalSubBlocks = 0;
    if opts.recursive
        try
            subSystems = find_system(targetPath, 'SearchDepth', 1, ...
                'LookUnderMasks', 'all', 'BlockType', 'SubSystem');
            for si = 1:length(subSystems)
                subPath = subSystems{si};
                % 跳过当前层级自身
                if strcmp(subPath, targetPath)
                    continue;
                end
                try
                    Simulink.BlockDiagram.arrangeSystem(subPath, 'FullLayout', 'true');
                    % 统计子系统内部 blocks
                    subBlks = find_system(subPath, 'SearchDepth', 1, 'LookUnderMasks', 'none');
                    totalSubBlocks = totalSubBlocks + length(subBlks) - 1; % 减1排除子系统自身
                    % 递归路由子系统内部线
                    if hasRouteLine
                        subLines = find_system(subPath, 'SearchDepth', 1, ...
                            'FindAll', 'on', 'Type', 'Line');
                        if ~isempty(subLines)
                            Simulink.BlockDiagram.routeLine(subLines);
                        end
                    end
                catch
                    % 某些子系统可能不支持排版（如库链接），跳过
                end
            end
        catch ME
            errors{end+1} = ['Recursive layout failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 更新 blocksRearranged 统计（包含子系统内部）
    blocksRearranged = blocksRearranged + totalSubBlocks;
    
    % 3. R2024b+: resizeBlocksToFitContent
    if opts.resizeBlocks && hasResizeBlocks
        try
            Simulink.BlockDiagram.resizeBlocksToFitContent(targetPath);
        catch ME
            errors{end+1} = ['resizeBlocksToFitContent failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 组装结果
    method = 'native_arrangeSystem';
    result.layout = struct( ...
        'target', targetPath, ...
        'blocksRearranged', blocksRearranged, ...
        'linesRouted', linesRouted, ...
        'method', method);
    
    result.message = sprintf('Auto-layout using arrangeSystem (%d blocks, %d lines routed)', ...
        blocksRearranged, linesRouted);
    
    if ~isempty(errors)
        result.warnings = errors;
    end
end


% ===== 旧版回退: BFS 拓扑排序手动布局 + 信号线重连 =====
function result = layout_fallback(targetPath, blockPaths, opts, result)
    nBlocks = length(blockPaths);
    linesRouted = 0;
    errors = {};
    
    % 1. 构建邻接表 + 入度
    adjList = cell(1, nBlocks);
    inDegree = zeros(1, nBlocks);
    edgeSrc = [];
    edgeDst = [];
    
    pathToIdx = struct();
    for i = 1:nBlocks
        safeKey = block_key(blockPaths{i}, targetPath);
        pathToIdx.(safeKey) = i;
    end
    
    % 从连线获取信号流关系
    try
        lineHandles = find_system(targetPath, 'SearchDepth', 1, ...
            'FindAll', 'on', 'Type', 'Line');
        
        for li = 1:length(lineHandles)
            try
                lh = lineHandles(li);
                srcIdx = 0;
                dstIdx = 0;
                
                try
                    srcPH = get_param(lh, 'SrcPortHandle');
                    if srcPH ~= 0
                        srcBH = get_param(srcPH, 'Parent');
                        srcName = get_param(srcBH, 'Name');
                        srcParent = get_param(srcBH, 'Parent');
                        if strcmpi(srcParent, targetPath)
                            srcPath = [targetPath '/' srcName];
                        else
                            srcPath = [srcParent '/' srcName];
                        end
                        srcKey = block_key(srcPath, targetPath);
                        if isfield(pathToIdx, srcKey)
                            srcIdx = pathToIdx.(srcKey);
                        end
                    end
                catch
                end
                
                try
                    dstPHs = get_param(lh, 'DstPortHandle');
                    if ~isempty(dstPHs) && dstPHs(1) ~= 0
                        dstPH = dstPHs(1);
                        dstBH = get_param(dstPH, 'Parent');
                        dstName = get_param(dstBH, 'Name');
                        dstParent = get_param(dstBH, 'Parent');
                        if strcmpi(dstParent, targetPath)
                            dstPath = [targetPath '/' dstName];
                        else
                            dstPath = [dstParent '/' dstName];
                        end
                        dstKey = block_key(dstPath, targetPath);
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
                        edgeSrc(end+1) = srcIdx; %#ok<AGROW>
                        edgeDst(end+1) = dstIdx; %#ok<AGROW>
                    end
                end
            catch
            end
        end
    catch
    end
    
    % 2. 贪心拓扑排序
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
    
    % 3. 按层分组
    nLayers = max(layer) + 1;
    if nLayers == 0, nLayers = 1; end
    
    layerBlocks = cell(1, nLayers);
    for li = 1:nLayers
        layerBlocks{li} = [];
    end
    for i = 1:nBlocks
        layerBlocks{layer(i)+1} = [layerBlocks{layer(i)+1}, i]; %#ok<AGROW>
    end
    
    % 4. 获取模块尺寸
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
    
    % 5. 布局计算与设置
    margin = [80 80];
    layerGap = 400;
    blockGap = 200;
    blocksRearranged = 0;
    
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
                blocksRearranged = blocksRearranged + 1;
            catch ME
                errors{end+1} = ['Failed to position ' blockPaths{bIdx} ': ' ME.message]; %#ok<AGROW>
            end
            yStart = yStart + h + blockGap;
        end
    end
    
    % 6. 信号线重连（delete_line + add_line autorouting）
    if opts.routeExistingLines
        try
            % 收集所有连线信息后删除重连
            lineInfoList = {};
            lineHandles = find_system(targetPath, 'SearchDepth', 1, ...
                'FindAll', 'on', 'Type', 'Line');
            
            for li = 1:length(lineHandles)
                try
                    lh = lineHandles(li);
                    info = struct();
                    
                    srcPH = get_param(lh, 'SrcPortHandle');
                    if srcPH == 0, continue; end
                    
                    srcBH = get_param(srcPH, 'Parent');
                    srcName = get_param(srcBH, 'Name');
                    srcParent = get_param(srcBH, 'Parent');
                    if strcmpi(srcParent, targetPath)
                        info.srcPath = [targetPath '/' srcName];
                    else
                        info.srcPath = [srcParent '/' srcName];
                    end
                    
                    % 源端口索引
                    srcPHs = get_param(srcBH, 'PortHandles');
                    if isfield(srcPHs, 'Outport')
                        for si = 1:length(srcPHs.Outport)
                            if srcPHs.Outport(si) == srcPH
                                info.srcPort = si;
                                break;
                            end
                        end
                    end
                    
                    dstPHs = get_param(lh, 'DstPortHandle');
                    if isempty(dstPHs) || dstPHs(1) == 0, continue; end
                    dstPH = dstPHs(1);
                    dstBH = get_param(dstPH, 'Parent');
                    dstName = get_param(dstBH, 'Name');
                    dstParent = get_param(dstBH, 'Parent');
                    if strcmpi(dstParent, targetPath)
                        info.dstPath = [targetPath '/' dstName];
                    else
                        info.dstPath = [dstParent '/' dstName];
                    end
                    
                    dstPHsAll = get_param(dstBH, 'PortHandles');
                    if isfield(dstPHsAll, 'Inport')
                        for di = 1:length(dstPHsAll.Inport)
                            if dstPHsAll.Inport(di) == dstPH
                                info.dstPort = di;
                                break;
                            end
                        end
                    end
                    
                    if isfield(info, 'srcPath') && isfield(info, 'dstPath') && ...
                       isfield(info, 'srcPort') && isfield(info, 'dstPort')
                        lineInfoList{end+1} = info; %#ok<AGROW>
                    end
                catch
                end
            end
            
            % 删除所有旧连线
            for li = 1:length(lineHandles)
                try
                    delete_line(lineHandles(li));
                catch
                end
            end
            
            % 用 autorouting 重新添加
            for li = 1:length(lineInfoList)
                try
                    info = lineInfoList{li};
                    add_line(targetPath, info.srcPath, info.srcPort, ...
                        info.dstPath, info.dstPort, 'autorouting', 'on');
                    linesRouted = linesRouted + 1;
                catch ME
                    errors{end+1} = ['Re-route failed: ' ME.message]; %#ok<AGROW>
                end
            end
        catch ME
            errors{end+1} = ['Line re-routing failed: ' ME.message]; %#ok<AGROW>
        end
    end
    
    % 组装结果
    result.layout = struct( ...
        'target', targetPath, ...
        'blocksRearranged', blocksRearranged, ...
        'linesRouted', linesRouted, ...
        'method', 'fallback_topological', ...
        'layerCount', nLayers);
    
    result.message = sprintf('Auto-layout using topological sort (%d blocks in %d layers, %d lines re-routed)', ...
        blocksRearranged, nLayers, linesRouted);
    
    if ~isempty(errors)
        result.warnings = errors;
    end
end


% ===== 辅助函数: 生成安全的 struct key =====
function key = block_key(blockPath, modelName)
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
