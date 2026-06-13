function result = sl_add_line_safe(modelName, varargin)
% SL_ADD_LINE_SAFE ---- - -----+----+-----+----
%   --1: result = sl_add_line_safe(modelName, srcBlock, srcPort, dstBlock, dstPort)
%   --2: result = sl_add_line_safe(modelName, 'srcBlock/portNum', 'dstBlock/portNum')
%   result = sl_add_line_safe(..., 'autoRouting', true, 'checkBusMatch', true)
%
%   ----: -- R2022b+-R2016a ----
%
%   v5.0 -----:
%     #3 connectBlocks -- - R2024b+ - Simulink.BlockDiagram.connectBlocks----- add_line
%     #8 -- mismatch error - ------------------
%
%   --:
%     modelName   - --------
%     --1-5---:
%       srcBlock    - ------- 'MyModel/Step'
%       srcPort     - -------1---
%       dstBlock    - -------- 'MyModel/Sum'
%       dstPort     - --------1---
%     --2-2----- add_line ---:
%       'srcBlock/portNum' - -----/------ 'Reference/1'
%       'dstBlock/portNum' - ------/------ 'Error_Sum/1'
%     'autoRouting'   - ------- true
%     'checkBusMatch' - -- Bus ------- false
%     'checkDimensions' - v5.0 ------------#8---- true
%     'skipAntiPatternCheck' - ---------- false
%
%   --: struct
%     .status       - 'ok' - 'error'
%     .line         - ---- struct
%     .verification - ---- struct
%     .antiPatternInfo - ----- struct-- apiUsed ---
%     .error        - ------ status='error' --

    % ===== ------ =====
    % [v11.5] -- MATLAB string --: - string -- char (--- "x" - --- 'x')
    if isstring(modelName), modelName = char(modelName); end
    if length(varargin) >= 1 && isstring(varargin{1}), varargin{1} = char(varargin{1}); end
    if length(varargin) >= 2 && isstring(varargin{2}), varargin{2} = char(varargin{2}); end
    
    % -----1 (5+--) ----2 (3--: model, 'src/port', 'dst/port')
    if length(varargin) >= 2 && ischar(varargin{1}) && ~isempty(strfind(varargin{1}, '/')) ...
            && ischar(varargin{2}) && ~isempty(strfind(varargin{2}, '/'))
        % --2: sl_add_line_safe(model, 'srcBlock/portNum', 'dstBlock/portNum', ...)
        srcFull = varargin{1};
        dstFull = varargin{2};
        [srcBlock, srcPort] = parse_block_port(srcFull, modelName);
        [dstBlock, dstPort] = parse_block_port(dstFull, modelName);
        extraArgs = varargin(3:end);
    else
        % --1: sl_add_line_safe(model, srcBlock, srcPort, dstBlock, dstPort, ...)
        srcBlock = varargin{1};
        srcPort = varargin{2};
        dstBlock = varargin{3};
        dstPort = varargin{4};
        extraArgs = varargin(5:end);
    end
    
    % ===== ------ =====
    opts = struct( ...
        'autoRouting', true, ...
        'checkBusMatch', false, ...
        'checkDimensions', true, ...
        'skipAntiPatternCheck', false, ...
        'autoReconnect', false);  % [v30 FIX v29-P1-BRANCH] auto-delete old line on dst port
    
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
    
    % ===== --: ------- =====
    try
        srcType = get_param(srcBlock, 'BlockType');
    catch
        result = struct('status', 'error', 'error', ...
            ['Source block not found: ' srcBlock], ...
            'suggestion', 'Check block path. Use sl_inspect_model to see all blocks.');
        return;
    end
    
    % ===== --: -------- =====
    try
        dstType = get_param(dstBlock, 'BlockType');
    catch
        result = struct('status', 'error', 'error', ...
            ['Destination block not found: ' dstBlock], ...
            'suggestion', 'Check block path. Use sl_inspect_model to see all blocks.');
        return;
    end
    
    % ===== --: --------- =====
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
    
    % ===== --: ---------- =====
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
    
    % ===== --: ------------ =====
    % -----------------------
    autoReconnected = false;
    try
        existingLine = get_param(dstPortHandle, 'Line');
        if existingLine ~= -1
            if opts.autoReconnect
                % [v30 FIX v29-P1-BRANCH] Auto-delete existing line and reconnect
                try
                    delete_line(existingLine);
                    autoReconnected = true;
                catch ME_reconnect
                    result = struct('status', 'error', 'error', ...
                        ['Destination port ' num2str(dstPort) ' of ' dstBlock ...
                         ' is already connected and auto-reconnect failed: ' ME_reconnect.message], ...
                        'suggestion', 'Manual deletion of existing line required.');
                    return;
                end
            else
                result = struct('status', 'error', 'error', ...
                    ['Destination port ' num2str(dstPort) ' of ' dstBlock ' is already connected'], ...
                    'suggestion', 'Delete the existing line first, or use autoReconnect=true.');
                return;
            end
        end
    catch
        % ---------
    end
    
    % ===== --: Bus ----------=====
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
            % -------
        end
    end
    
    % ===== v5.0 --: -- mismatch ------ #8-=====
    % simulink/skills ----: ----------
    dimensionInfo = struct('checked', false, 'srcDim', '', 'dstDim', '', 'compatible', true);
    if opts.checkDimensions && ~opts.skipAntiPatternCheck
        try
            srcDim = get_param(srcPortHandle, 'PortDimensions');
            dstDim = get_param(dstPortHandle, 'PortDimensions');
            dimensionInfo.checked = true;
            dimensionInfo.srcDim = srcDim;
            dimensionInfo.dstDim = dstDim;
            
            % -------
            % -1 - '1' ----/---- - ----
            % ---- - --
            % ---- - -----------/---
            if isnumeric(srcDim) && isnumeric(dstDim)
                % --------
                if srcDim == -1 || dstDim == -1
                    % -1 ----/-------
                    dimensionInfo.compatible = true;
                elseif srcDim == dstDim
                    dimensionInfo.compatible = true;
                elseif srcDim == 1 || dstDim == 1
                    % -------
                    dimensionInfo.compatible = true;
                else
                    % ----- - --- #8: ----
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
            % ----------------------
            dimensionInfo.checked = false;
        end
    end
    
    % ===== v5.0 ----: connectBlocks ------ #3-=====
    % simulink/skills ----: connectBlocks (R2024b+) > add_line
    apiUsed = 'add_line';  % --
    lineHandle = [];
    
    % v12.0 ----: -----------
    % add_line ----------------------
    % --: ------ Plant ------- Plant ----------
    [commonSys, srcRelPath, dstRelPath] = find_common_system(srcBlock, dstBlock, modelName);
    
    % ----- Simulink.BlockDiagram.connectBlocks
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
        % R2024b+: -- connectBlocks--- API-
        try
            lineHandle = Simulink.BlockDiagram.connectBlocks(modelName, srcBlock, dstBlock);
            apiUsed = 'connectBlocks';
        catch ME_connect
            % connectBlocks ------ add_line
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
        % ---: -- add_line
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
    
    % ===== -- =====
    verification = struct();
    verification.lineExists = true;
    
    % ----------
    try
        srcLineAfter = get_param(srcPortHandle, 'Line');
        verification.srcPortConnected = (srcLineAfter ~= -1);
    catch
        verification.srcPortConnected = false;  % [v12.0] fail-closed: default false on error (CN-07 FIX)
    end
    
    % -----------
    try
        dstLineAfter = get_param(dstPortHandle, 'Line');
        verification.dstPortConnected = (dstLineAfter ~= -1);
    catch
        verification.dstPortConnected = false;  % [v12.0] fail-closed: default false on error (CN-07 FIX)
    end
    
    % ===== [v30 FIX v29-P1-BRANCH] LineChildren verification =====
    % Check for bus-split branches (LineChildren) on the source side.
    % When a single output fans out to multiple destinations via bus-split,
    % the line handle has LineChildren. Track this for safe deletion.
    branchInfo = struct('isBranch', false, 'branchCount', 0, ...
        'lineChildren', [], 'autoReconnected', autoReconnected);
    try
        if lineHandle > 0
            lc = get_param(lineHandle, 'LineChildren');
            if ~isempty(lc)
                branchInfo.isBranch = true;
                branchInfo.branchCount = length(lc);
                branchInfo.lineChildren = lc;
            end
        end
    catch
        % LineChildren not available (pre-R2012b or line handle invalid)
    end
    verification.branchInfo = branchInfo;
    
    % ===== ---- =====
    lineInfo = struct();
    lineInfo.srcBlock = srcBlock;
    lineInfo.srcPort = srcPort;
    lineInfo.dstBlock = dstBlock;
    lineInfo.dstPort = dstPort;
    try
        lineInfo.handle = lineHandle;
    catch
    end
    
    result = struct('status', 'ok', 'line', lineInfo, 'verification', verification, ...
        'branchInfo', branchInfo);
    
    % v5.0 -----
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

% ===== v12.0 ----: -------------- =====
% --: commonSys = --------, srcRelPath = src----------, dstRelPath = dst----------
% -: src='M/Sub/Gain1', dst='M/Sub/Gain2', model='M'
%     -> commonSys='M/Sub', srcRelPath='Gain1', dstRelPath='Gain2'
% -: src='M/Step', dst='M/Gain', model='M'
%     -> commonSys='M', srcRelPath='Step', dstRelPath='Gain'
function [commonSys, srcRelPath, dstRelPath] = find_common_system(srcBlock, dstBlock, modelName)
    % -----------------
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
    
    % ------
    srcParts = strsplit(srcRel, '/');
    dstParts = strsplit(dstRel, '/');
    
    % ------
    minLen = min(length(srcParts), length(dstParts));
    commonParts = {};
    for i = 1:minLen
        if strcmpi(srcParts{i}, dstParts{i})
            commonParts{end+1} = srcParts{i}; %#ok<AGROW>
        else
            break;
        end
    end
    
    % --------
    if isempty(commonParts)
        % -------------
        commonSys = modelName;
        srcRelPath = srcRel;
        dstRelPath = dstRel;
    else
        commonSys = [modelName '/' strjoin(commonParts, '/')];
        % ---------------
        commonLen = length(commonParts);
        srcRemaining = srcParts(commonLen+1:end);
        dstRemaining = dstParts(commonLen+1:end);
        srcRelPath = strjoin(srcRemaining, '/');
        dstRelPath = strjoin(dstRemaining, '/');
    end
end

% ===== ----: ------------- =====
% 'test_p1/Step' + 'test_p1' - 'Step'
% 'test_p1/Sub/Gain' + 'test_p1' - 'Sub/Gain'
% 'Step' + 'test_p1' - 'Step' (-------)
function relPath = make_relative_path(blockPath, modelName)
    modelPrefix = [modelName '/'];
    prefixLen = length(modelPrefix);
    if length(blockPath) > prefixLen && strcmpi(blockPath(1:prefixLen), modelPrefix)
        relPath = blockPath(prefixLen+1:end);
    else
        relPath = blockPath;
    end
end

% ===== ----: -- 'BlockName/portNum' -- =====
% 'Reference/1' + 'pid_test_model' -> 'pid_test_model/Reference', 1
% 'pid_test_model/Reference/1' + 'pid_test_model' -> 'pid_test_model/Reference', 1
% 'Sub/Gain/2' + 'pid_test_model' -> 'pid_test_model/Sub/Gain', 2
function [blockPath, portNum] = parse_block_port(str, modelName)
    % ----- '/' ---
    slashPos = strfind(str, '/');
    if isempty(slashPos)
        % ------ 'Reference'------
        blockPath = [modelName '/' str];
        portNum = 1;
        return;
    end
    
    lastSlash = slashPos(end);
    afterSlash = str(lastSlash+1:end);
    
    % ------ '/' ------------
    portVal = str2double(afterSlash);
    if ~isnan(portVal) && portVal > 0
        % --------
        blockPart = str(1:lastSlash-1);
        portNum = round(portVal);
    else
        % --------------1
        blockPart = str;
        portNum = 1;
    end
    
    % -------
    modelPrefix = [modelName '/'];
    prefixLen = length(modelPrefix);
    if length(blockPart) > prefixLen && strcmpi(blockPart(1:prefixLen), modelPrefix)
        blockPath = blockPart;  % -------
    else
        blockPath = [modelName '/' blockPart];  % ----
    end
end
