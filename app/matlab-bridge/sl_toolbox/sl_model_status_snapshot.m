function result = sl_model_status_snapshot(modelName, varargin)
% SL_MODEL_STATUS_SNAPSHOT 获取模型的完整结构化状态快照
%   result = sl_model_status_snapshot(modelName)
%   result = sl_model_status_snapshot(modelName, 'format', 'both')
%   result = sl_model_status_snapshot(modelName, 'depth', 0)
%
%   输出包含:
%     - snapshot: 模型概览
%     - blocks: 块信息数组(含端口坐标!)
%     - lines: 线信息数组(含路由点!)
%     - unconnectedPorts: 未连接端口数组
%     - diagnostics: 诊断信息数组
%     - reportJson: JSON 格式报告
%     - reportComment: 注释格式报告(AI可解析)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容

    % ===== 解析参数 =====
    opts = struct( ...
        'format', 'both', ...      % 'json' | 'comment' | 'both'
        'depth', 1, ...            % 检查深度，0=全部
        'includeParams', true, ... % 包含模块参数
        'includeLines', true, ...  % 包含连线信息
        'includeHidden', false ... % 包含隐藏块
    );

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

    % ===== 初始化返回结构 =====
    result = struct();
    result.status = 'ok';
    result.error = '';
    result.snapshot = struct();
    result.blocks = {};
    result.lines = {};
    result.unconnectedPorts = {};
    result.diagnostics = {};

    % ===== 确保模型已加载 =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result.status = 'error';
        result.error = ['Failed to load model: ' ME.message];
        return;
    end

    % ===== 获取所有块 =====
    try
        if opts.depth == 0
            allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        else
            allBlocks = find_system(modelName, 'SearchDepth', opts.depth, 'LookUnderMasks', 'all');
        end
    catch ME
        result.status = 'error';
        result.error = ['find_system failed: ' ME.message];
        return;
    end

    % 过滤掉模型自身
    if length(allBlocks) > 1
        blockPaths = allBlocks(2:end);
    else
        blockPaths = {};
    end

    % 过滤隐藏块
    if ~opts.includeHidden
        visiblePaths = {};
        for i = 1:length(blockPaths)
            try
                vis = get_param(blockPaths{i}, 'Visible');
                if vis ~= 0
                    visiblePaths{end+1} = blockPaths{i};
                end
            catch
                visiblePaths{end+1} = blockPaths{i};
            end
        end
        blockPaths = visiblePaths;
    end

    nBlocks = length(blockPaths);

    % ===== 遍历收集块信息 =====
    unconnectedPorts = {};
    diagnostics = {};
    allLines = {};

    for i = 1:nBlocks
        bp = blockPaths{i};
        blk = struct();

        try
            blk.path = bp;
            blk.name = get_param(bp, 'Name');
            blk.type = get_param(bp, 'BlockType');

            % 位置信息 [left, bottom, right, top]
            try
                pos = get_param(bp, 'Position');
                blk.position = struct( ...
                    'left', pos(1), ...
                    'bottom', pos(2), ...
                    'right', pos(3), ...
                    'top', pos(4), ...
                    'center', struct('x', (pos(1)+pos(3))/2, 'y', (pos(2)+pos(4))/2));
            catch
                blk.position = struct('left', 0, 'bottom', 0, 'right', 0, 'top', 0, 'center', struct('x', 0, 'y', 0));
            end

            % 端口信息(含坐标!) - 关键信息供AI连线
            [portInfo, unconnNew] = get_port_info_with_position(bp, modelName);
            blk.ports = portInfo;
            unconnectedPorts = [unconnectedPorts, unconnNew];

            % 参数信息
            if opts.includeParams
                blk.params = get_block_params(bp);
            end

            % 句柄
            try
                blk.handle = double(get_param(bp, 'Handle'));
            catch
                blk.handle = 0;
            end

        catch ME
            blk = struct('path', bp, 'error', ME.message);
        end

        result.blocks{i} = blk;
    end

    % ===== 连线信息(含路由点!) =====
    if opts.includeLines
        [linesInfo, linesResult] = get_lines_with_routing(modelName, blockPaths);
        result.lines = linesInfo;
    else
        result.lines = {};
    end

    % ===== 未连接端口诊断 =====
    result.unconnectedPorts = unconnectedPorts;
    for i = 1:length(unconnectedPorts)
        up = unconnectedPorts{i};
        diagnostics{end+1} = struct( ...
            'level', 'WARNING', ...
            'code', 'PORT_UNCONNECTED', ...
            'message', ['Port ' num2str(up.portIndex) ' of block ''' up.block '''' ' is not connected'], ...
            'block', up.block, ...
            'portType', up.portType, ...
            'portIndex', up.portIndex, ...
            'suggestion', ['Add a signal line connecting to this ' up.portType ' port']);
    end

    % ===== v8.0: goto/from 配对验证 =====
    try
        gotoBlocks = find_system(modelName, 'SearchDepth', opts.depth, ...
            'BlockType', 'Goto', 'LookUnderMasks', 'all');
        fromBlocks = find_system(modelName, 'SearchDepth', opts.depth, ...
            'BlockType', 'From', 'LookUnderMasks', 'all');
        
        % 收集所有 goto 信号名
        gotoSignals = struct();
        gotoKeys = {};
        for i = 1:length(gotoBlocks)
            try
                tag = get_param(gotoBlocks{i}, 'GotoTag');
                if ~isempty(tag)
                    if ~isfield(gotoSignals, tag)
                        gotoSignals.(tag) = {};
                        gotoKeys{end+1} = tag;
                    end
                    existing = gotoSignals.(tag);
                    existing{end+1} = gotoBlocks{i};
                    gotoSignals.(tag) = existing;
                end
            catch
            end
        end
        
        % 收集所有 from 信号名
        fromSignals = struct();
        fromKeys = {};
        for i = 1:length(fromBlocks)
            try
                tag = get_param(fromBlocks{i}, 'GotoTag');
                if ~isempty(tag)
                    if ~isfield(fromSignals, tag)
                        fromSignals.(tag) = {};
                        fromKeys{end+1} = tag;
                    end
                    existing = fromSignals.(tag);
                    existing{end+1} = fromBlocks{i};
                    fromSignals.(tag) = existing;
                end
            catch
            end
        end
        
        % 检查每个 from 是否有对应的 goto
        for i = 1:length(fromBlocks)
            try
                tag = get_param(fromBlocks{i}, 'GotoTag');
                if isempty(tag)
                    diagnostics{end+1} = struct( ...
                        'level', 'ERROR', ...
                        'code', 'GOTO_FROM_UNPAIRED', ...
                        'message', ['From block ''' fromBlocks{i} ''' has empty GotoTag'], ...
                        'block', fromBlocks{i}, ...
                        'suggestion', 'Set GotoTag to match a Goto block');
                elseif ~isfield(gotoSignals, tag)
                    diagnostics{end+1} = struct( ...
                        'level', 'ERROR', ...
                        'code', 'GOTO_FROM_NO_MATCH', ...
                        'message', ['From block ''' fromBlocks{i} ''' references tag ''' tag ''' but no matching Goto found'], ...
                        'block', fromBlocks{i}, ...
                        'suggestion', ['Create a Goto block with tag ''' tag '''']);
                end
            catch
            end
        end
        
        % 检查每个 goto 是否有对应的 from
        for k = 1:length(gotoKeys)
            tag = gotoKeys{k};
            if ~isfield(fromSignals, tag)
                gotoList = gotoSignals.(tag);
                gotoStr = strjoin(gotoList, ', ');
                diagnostics{end+1} = struct( ...
                    'level', 'WARNING', ...
                    'code', 'GOTO_NO_FROM', ...
                    'message', ['Goto block(s) with tag ''' tag ''' have no matching From block'], ...
                    'block', gotoStr, ...
                    'suggestion', ['Create a From block with tag ''' tag '''']);
            end
        end
    catch
        % goto/from 检查失败不影响主功能
    end

    % ===== v8.0: 子系统框架完整性检查 =====
    try
        subsysBlocks = find_system(modelName, 'SearchDepth', opts.depth, ...
            'BlockType', 'SubSystem', 'LookUnderMasks', 'all');
        for i = 1:length(subsysBlocks)
            try
                % 检查子系统是否有 Inport/Outport
                inports = find_system(subsysBlocks{i}, 'SearchDepth', 1, ...
                    'BlockType', 'Inport', 'LookUnderMasks', 'on');
                outports = find_system(subsysBlocks{i}, 'SearchDepth', 1, ...
                    'BlockType', 'Outport', 'LookUnderMasks', 'on');
                
                if isempty(inports) && isempty(outports)
                    diagnostics{end+1} = struct( ...
                        'level', 'WARNING', ...
                        'code', 'SUBSYSTEM_NO_INTERFACE', ...
                        'message', ['Subsystem ''' subsysBlocks{i} ''' has no Inport or Outport'], ...
                        'block', subsysBlocks{i}, ...
                        'suggestion', 'Add In1/Out1 to define subsystem interface');
                end
            catch
            end
        end
    catch
        % 子系统检查失败不影响主功能
    end

    % ===== 模型概览 =====
    result.snapshot = struct( ...
        'modelName', modelName, ...
        'timestamp', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
        'totalBlocks', nBlocks, ...
        'totalLines', length(result.lines), ...
        'unconnectedPorts', length(unconnectedPorts), ...
        'diagnosticsCount', length(diagnostics));

    result.diagnostics = diagnostics;

    % ===== 生成格式报告 =====
    if strcmpi(opts.format, 'json') || strcmpi(opts.format, 'both')
        % [BUG FIX] Cannot use struct() + sl_jsonencode directly because
        % cell arrays of structs with inconsistent field dimensions cause
        % "Dimension mismatch" errors in MATLAB struct construction.
        % Solution: serialize each part separately, then manually assemble JSON.
        try
            jsonParts = {};
            jsonParts{end+1} = ['"snapshot":' sl_jsonencode(result.snapshot)];
            jsonParts{end+1} = ['"blocks":' sl_jsonencode(result.blocks)];
            jsonParts{end+1} = ['"lines":' sl_jsonencode(result.lines)];
            jsonParts{end+1} = ['"unconnectedPorts":' sl_jsonencode(result.unconnectedPorts)];
            jsonParts{end+1} = ['"diagnostics":' sl_jsonencode(result.diagnostics)];
            result.reportJson = ['{' strjoin(jsonParts, ',') '}'];
        catch ME
            % Fallback: try simple struct encode
            try
                result.reportJson = sl_jsonencode(struct( ...
                    'snapshot', result.snapshot, ...
                    'blocks', result.blocks, ...
                    'lines', result.lines, ...
                    'unconnectedPorts', result.unconnectedPorts, ...
                    'diagnostics', result.diagnostics));
            catch ME2
                result.reportJson = ['{"status":"error","message":"JSON encode failed: ' ME2.message '"}'];
            end
        end
    else
        result.reportJson = '';
    end

    if strcmpi(opts.format, 'comment') || strcmpi(opts.format, 'both')
        result.reportComment = generate_comment_report(result.snapshot, result.blocks, result.lines, result.unconnectedPorts, result.diagnostics);
    else
        result.reportComment = '';
    end
end


% ===== 辅助函数: 获取端口信息(含坐标) =====
function [portInfo, unconnectedPorts] = get_port_info_with_position(blockPath, modelName)
    portInfo = struct();
    portInfo.inputs = {};
    portInfo.outputs = {};
    unconnectedPorts = {};

    % 获取端口句柄
    try
        ph = get_param(blockPath, 'PortHandles');
    catch
        return;
    end

    % 输入端口
    try
        inHandles = ph.Inport;
        if ~isempty(inHandles)
            for j = 1:length(inHandles)
                p = struct();
                p.index = j;
                p.handle = double(inHandles(j));

                % 获取端口位置坐标 [x, y] - 关键信息!
                try
                    portPos = get_param(inHandles(j), 'Position');
                    p.position = struct('x', portPos(1), 'y', portPos(2));
                catch
                    p.position = struct('x', 0, 'y', 0);
                end

                % 端口名称
                try p.name = get_param(inHandles(j), 'Name'); catch, p.name = ''; end

                % 连接状态
                try
                    lineH = get_param(inHandles(j), 'Line');
                    if lineH == -1 || lineH == 0
                        p.connected = false;
                        unconnectedPorts{end+1} = struct('block', blockPath, 'portType', 'input', 'portIndex', j);
                        p.connectedTo = [];
                    else
                        p.connected = true;
                        % 获取连接信息
                        srcPort = get_param(lineH, 'SrcPortHandle');
                        srcBlock = get_param(srcPort, 'Parent');
                        p.connectedTo = struct('block', srcBlock, 'port', double(get_param(srcPort, 'PortNumber')), 'lineHandle', double(lineH));
                    end
                catch
                    p.connected = false;
                    p.connectedTo = [];
                end

                portInfo.inputs{end+1} = p;
            end
        end
    catch
    end

    % 输出端口
    try
        outHandles = ph.Outport;
        if ~isempty(outHandles)
            for j = 1:length(outHandles)
                p = struct();
                p.index = j;
                p.handle = double(outHandles(j));

                % 获取端口位置坐标 [x, y] - 关键信息!
                try
                    portPos = get_param(outHandles(j), 'Position');
                    p.position = struct('x', portPos(1), 'y', portPos(2));
                catch
                    p.position = struct('x', 0, 'y', 0);
                end

                % 端口名称
                try p.name = get_param(outHandles(j), 'Name'); catch, p.name = ''; end

                % 连接状态
                try
                    lineH = get_param(outHandles(j), 'Line');
                    if lineH == -1 || lineH == 0
                        p.connected = false;
                        unconnectedPorts{end+1} = struct('block', blockPath, 'portType', 'output', 'portIndex', j);
                        p.connectedTo = [];
                    else
                        p.connected = true;
                        % 获取所有连接目标
                        dstPorts = get_param(lineH, 'DstPortHandle');
                        connections = {};
                        for k = 1:length(dstPorts)
                            try
                                dstBlock = get_param(dstPorts(k), 'Parent');
                                connections{k} = struct('block', dstBlock, 'port', double(get_param(dstPorts(k), 'PortNumber')), 'lineHandle', double(lineH));
                            catch
                            end
                        end
                        p.connectedTo = connections;
                    end
                catch
                    p.connected = false;
                    p.connectedTo = [];
                end

                portInfo.outputs{end+1} = p;
            end
        end
    catch
    end
end


% ===== 辅助函数: 获取连线信息(含路由点) =====
function [linesInfo, linesResult] = get_lines_with_routing(modelName, blockPaths)
    linesInfo = {};
    linesResult = struct();

    try
        lineHandles = find_system(modelName, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'Line');
        if isempty(lineHandles), return; end

        % 建立句柄->路径映射
        pathMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
        for i = 1:length(blockPaths)
            try
                bh = get_param(blockPaths{i}, 'Handle');
                pathMap(num2str(double(bh))) = blockPaths{i};
            catch
            end
        end

        for i = 1:length(lineHandles)
            try
                lh = double(lineHandles(i));
                ln = struct();
                ln.handle = lh;

                % 信号线名称
                try ln.name = get_param(lh, 'Name'); catch ln.name = ''; end

                % 源端口信息
                try
                    srcPortH = get_param(lh, 'SrcPortHandle');
                    srcBlockH = get_param(srcPortH, 'Parent');
                    srcBlockKey = num2str(double(srcBlockH));
                    if pathMap.isKey(srcBlockKey)
                        ln.sourceBlock = pathMap(srcBlockKey);
                    else
                        ln.sourceBlock = get_param(srcBlockH, 'Name');
                    end
                    ln.sourcePort = double(get_param(srcPortH, 'PortNumber'));
                    % 源端口位置
                    try
                        srcPos = get_param(srcPortH, 'Position');
                        ln.sourcePosition = struct('x', srcPos(1), 'y', srcPos(2));
                    catch
                        ln.sourcePosition = struct('x', 0, 'y', 0);
                    end
                catch
                    ln.sourceBlock = '';
                    ln.sourcePort = 0;
                    ln.sourcePosition = struct('x', 0, 'y', 0);
                end

                % 目标端口信息
                try
                    dstPortHs = get_param(lh, 'DstPortHandle');
                    dsts = {};
                    for k = 1:length(dstPortHs)
                        try
                            dstPortH = dstPortHs(k);
                            dstBlockH = get_param(dstPortH, 'Parent');
                            dstBlockKey = num2str(double(dstBlockH));
                            if pathMap.isKey(dstBlockKey)
                                dstBlockPath = pathMap(dstBlockKey);
                            else
                                dstBlockPath = get_param(dstBlockH, 'Name');
                            end
                            dstPortNum = double(get_param(dstPortH, 'PortNumber'));
                            % 目标端口位置
                            try
                                dstPos = get_param(dstPortH, 'Position');
                                dstPos = struct('x', dstPos(1), 'y', dstPos(2));
                            catch
                                dstPos = struct('x', 0, 'y', 0);
                            end
                            dsts{k} = struct('block', dstBlockPath, 'port', dstPortNum, 'position', dstPos);
                        catch
                        end
                    end
                    ln.destinations = dsts;
                catch
                    ln.destinations = {};
                end

                % 路由点信息
                try
                    pts = get_param(lh, 'Points');
                    if ~isempty(pts)
                        routingPoints = {};
                        for k = 1:size(pts, 2)
                            routingPoints{k} = struct('x', pts(1,k), 'y', pts(2,k));
                        end
                        ln.routingPoints = routingPoints;
                    else
                        ln.routingPoints = {};
                    end
                catch
                    ln.routingPoints = {};
                end

                % 连接状态
                ln.isConnected = ~isempty(ln.destinations);

                linesInfo{end+1} = ln;
            catch
            end
        end
    catch
    end
end


% ===== 辅助函数: 获取模块参数 =====
function params = get_block_params(blockPath)
    params = struct();
    try
        dp = get_param(blockPath, 'DialogParameters');
        if ~isempty(dp)
            fn = fieldnames(dp);
            for k = 1:length(fn)
                try
                    val = get_param(blockPath, fn{k});
                    if isnumeric(val)
                        params.(fn{k}) = val;
                    else
                        params.(fn{k}) = val;
                    end
                catch
                end
            end
        end
    catch
    end
end


% ===== 辅助函数: 生成注释格式报告(AI可解析) =====
function report = generate_comment_report(snapshot, blocks, lines, unconnectedPorts, diagnostics)
    report = {};

    % 头部
    report{end+1} = '%% ============================================================';
    report{end+1} = ['%% Model Status Snapshot'];
    report{end+1} = ['%% Model: ' snapshot.modelName];
    report{end+1} = ['%% Time: ' snapshot.timestamp];
    report{end+1} = ['%% Blocks: ' num2str(snapshot.totalBlocks) ' | Lines: ' num2str(snapshot.totalLines) ' | Unconnected Ports: ' num2str(snapshot.unconnectedPorts)];
    report{end+1} = '%% ============================================================';
    report{end+1} = '';

    % 块列表
    report{end+1} = '%% -- Block List --';
    for i = 1:length(blocks)
        b = blocks{i};
        if isfield(b, 'error')
            report{end+1} = ['%% [BLOCK] ' b.path ' | ERROR: ' b.error];
            continue;
        end

        pos = b.position;
        report{end+1} = ['%% [BLOCK] ' b.path ' | Type: ' b.type ' | Pos: [' num2str(pos.left) ',' num2str(pos.bottom) ',' num2str(pos.right) ',' num2str(pos.top) '] | Center: [' num2str(pos.center.x) ',' num2str(pos.center.y) ']'];

        % 参数信息
        if isfield(b, 'params') && ~isempty(fieldnames(b.params))
            paramStr = '%%   Params: ';
            fn = fieldnames(b.params);
            paramVals = {};
            for k = 1:min(length(fn), 5)
                val = b.params.(fn{k});
                if isnumeric(val)
                    paramVals{k} = [fn{k} '=' num2str(val)];
                else
                    paramVals{k} = [fn{k} '=' char(val)];
                end
            end
            report{end+1} = [paramStr strjoin(paramVals, ', ')];
        end

        % 端口信息
        if isfield(b, 'ports')
            if isfield(b.ports, 'inputs') && ~isempty(b.ports.inputs)
                for j = 1:length(b.ports.inputs)
                    p = b.ports.inputs{j};
                    connStr = 'UNCONNECTED';
                    if p.connected && isfield(p, 'connectedTo') && ~isempty(p.connectedTo)
                        connStr = ['Connected -> ' p.connectedTo.block ':' num2str(p.connectedTo.port)];
                    end
                    report{end+1} = ['%%   Port-' num2str(p.index) '(IN): [' num2str(p.position.x) ',' num2str(p.position.y) '] -> ' connStr];
                end
            end
            if isfield(b.ports, 'outputs') && ~isempty(b.ports.outputs)
                for j = 1:length(b.ports.outputs)
                    p = b.ports.outputs{j};
                    if p.connected && isfield(p, 'connectedTo') && ~isempty(p.connectedTo)
                        connStrs = {};
                        for k = 1:length(p.connectedTo)
                            connStrs{k} = [p.connectedTo{k}.block ':' num2str(p.connectedTo{k}.port)];
                        end
                        connStr = ['Connected -> ' strjoin(connStrs, ', ')];
                    else
                        connStr = 'UNCONNECTED';
                    end
                    report{end+1} = ['%%   Port-' num2str(p.index) '(OUT): [' num2str(p.position.x) ',' num2str(p.position.y) '] -> ' connStr];
                end
            end
        end
    end

    report{end+1} = '';

    % 连线列表
    report{end+1} = '%% -- Signal Lines --';
    for i = 1:length(lines)
        l = lines{i};
        if isempty(l.sourceBlock)
            continue;
        end
        report{end+1} = ['%% [LINE] #' num2str(l.handle) ' ' l.sourceBlock ':' num2str(l.sourcePort) ' -> '];
        for j = 1:length(l.destinations)
            if j > 1, report{end} = [report{end} ', ']; end
            report{end} = [report{end} l.destinations{j}.block ':' num2str(l.destinations{j}.port)];
        end
        report{end+1} = [report{end} ' | ' upper(l.name)];

        % 路由点
        if ~isempty(l.routingPoints)
            routingStrs = {};
            for k = 1:length(l.routingPoints)
                routingStrs{k} = ['[' num2str(l.routingPoints{k}.x) ',' num2str(l.routingPoints{k}.y) ']'];
            end
            report{end+1} = ['%%   Routing: ' strjoin(routingStrs, ' -> ')];
        end
    end

    report{end+1} = '';

    % 未连接端口
    if ~isempty(unconnectedPorts)
        report{end+1} = '%% -- Unconnected Ports --';
        for i = 1:length(unconnectedPorts)
            up = unconnectedPorts{i};
            report{end+1} = ['%% [PORT] ' up.block ':' num2str(up.portIndex) '(' up.portType ') | UNCONNECTED'];
            report{end+1} = ['%%   Suggestion: Add a signal line connecting to this ' up.portType ' port'];
        end
        report{end+1} = '';
    end

    % 诊断信息
    if ~isempty(diagnostics)
        report{end+1} = '%% -- Diagnostics --';
        for i = 1:length(diagnostics)
            d = diagnostics{i};
            report{end+1} = ['%% [' upper(d.level) '] ' d.code ': ' d.message];
            report{end+1} = ['%%   Suggestion: ' d.suggestion];
        end
        report{end+1} = '';
    end

    % v8.0: goto/from 配对摘要
    gotoDiags = {};
    fromDiags = {};
    subsysDiags = {};
    for i = 1:length(diagnostics)
        d = diagnostics{i};
        if strcmp(d.code, 'GOTO_NO_FROM')
            gotoDiags{end+1} = d;
        elseif strcmp(d.code, 'GOTO_FROM_NO_MATCH') || strcmp(d.code, 'GOTO_FROM_UNPAIRED')
            fromDiags{end+1} = d;
        elseif strcmp(d.code, 'SUBSYSTEM_NO_INTERFACE')
            subsysDiags{end+1} = d;
        end
    end
    
    if ~isempty(gotoDiags) || ~isempty(fromDiags)
        report{end+1} = '%% -- Goto/From Pairing Status --';
        if isempty(gotoDiags) && isempty(fromDiags)
            report{end+1} = '%% All goto/from blocks are properly paired';
        else
            for i = 1:length(gotoDiags)
                report{end+1} = ['%% [UNPAIRED GOTO] ' gotoDiags{i}.message];
            end
            for i = 1:length(fromDiags)
                report{end+1} = ['%% [UNPAIRED FROM] ' fromDiags{i}.message];
            end
        end
        report{end+1} = '';
    end
    
    if ~isempty(subsysDiags)
        report{end+1} = '%% -- Subsystem Interface Status --';
        for i = 1:length(subsysDiags)
            report{end+1} = ['%% [NO INTERFACE] ' subsysDiags{i}.message];
        end
        report{end+1} = '';
    end

    % 转为字符串
    report = strjoin(report, char(10));
end