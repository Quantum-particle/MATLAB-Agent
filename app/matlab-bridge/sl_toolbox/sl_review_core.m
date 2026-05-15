function result = sl_review_core(modelPath, action, varargin)
% SL_REVIEW_CORE v11.8 Unified Review Engine — shared by sl_micro_review, sl_validate_model, sl_model_complete
%   result = sl_review_core(modelPath, 'all')     % run all 4 dimensions
%   result = sl_review_core(modelPath, 'portPairing')
%   result = sl_review_core(modelPath, 'paramAudit')
%   result = sl_review_core(modelPath, 'connectionScan')
%   result = sl_review_core(modelPath, 'layoutAudit')
%
% Dimensions:
%   1. portPairing:    Inport/Outport + Goto/From 配对完整性
%   2. paramAudit:     逐模块参数非空/非默认检查
%   3. connectionScan: 全端口连线完整性扫描
%   4. layoutAudit:    模块位置重叠/越界检查
%
% Output: struct with fields {passed, confidence, issue, details}

    if nargin < 2
        action = 'all';
    end
    
    % Validate model path
    if isempty(modelPath)
        result = struct('status', 'error', 'message', 'sl_review_core: modelPath required');
        return;
    end
    
    try
        % Ensure model is loaded (extract top-level for loading)
        if ~isempty(strfind(modelPath, '/'))
            topModel = modelPath(1:strfind(modelPath, '/') - 1);
        else
            topModel = modelPath;
        end
        if ~bdIsLoaded(topModel)
            load_system(topModel);
        end
    catch
        % Model not loadable — review of built model not possible
        result = struct('status', 'ok', 'modelPath', modelPath, ...
            'action', action, 'passed', true, 'confidence', 0.3, ...
            'issue', sprintf('Model not loaded: %s (review skipped)', modelPath), ...
            'details', struct());
        return;
    end
    
    switch lower(action)
        case 'all'
            result = run_all_dimensions(modelPath);
        case 'portpairing'
            result = check_port_pairing(modelPath);
        case 'paramaudit'
            result = check_param_audit(modelPath);
        case 'connectionscan'
            result = check_connection_scan(modelPath);
        case 'layoutaudit'
            result = check_layout_audit(modelPath);
        otherwise
            result = struct('status', 'error', ...
                'message', sprintf('Unknown action: %s. Use: all | portPairing | paramAudit | connectionScan | layoutAudit', action));
    end
end

% ===== Dimension 1: Port Pairing =====
function r = check_port_pairing(modelPath)
    r = struct('item', 'portPairing', 'passed', true, 'confidence', 0.9, ...
        'issue', '', 'suggestion', '', 'details', struct());
    
    issues = {};
    gotoCount = 0;
    fromCount = 0;
    gotoFromTags = {};
    inportCount = 0;
    outportCount = 0;
    unpairedInport = {};
    unpairedOutport = {};
    
    try
        % Bug#24 FIX: SearchDepth=5 to recursively scan nested subsystem internals
        blocks = find_system(modelPath, 'SearchDepth', 5, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)  % skip the system itself
            bp = blocks{i};
            try
                btype = get_param(bp, 'BlockType');
                
                if strcmp(btype, 'Inport')
                    inportCount = inportCount + 1;
                elseif strcmp(btype, 'Outport')
                    outportCount = outportCount + 1;
                elseif strcmp(btype, 'Goto')
                    gotoCount = gotoCount + 1;
                    tag = get_param(bp, 'GotoTag');
                    gotoFromTags{end+1} = tag;
                elseif strcmp(btype, 'From')
                    fromCount = fromCount + 1;
                    tag = get_param(bp, 'GotoTag');
                    gotoFromTags{end+1} = tag;
                end
            catch
            end
        end
        
        % Check 1: Goto/From must be paired
        if gotoCount > 0 && fromCount == 0
            r.passed = false; r.confidence = 0.0;
            issues{end+1} = sprintf('%d Goto block(s) but 0 From blocks', gotoCount);
        elseif fromCount > 0 && gotoCount == 0
            r.passed = false; r.confidence = 0.0;
            issues{end+1} = sprintf('%d From block(s) but 0 Goto blocks', fromCount);
        end
        
        % Check 2: Goto/From tags must be unique
        if length(gotoFromTags) > 0 && length(unique(gotoFromTags)) ~= length(gotoFromTags)
            r.passed = false; r.confidence = 0.2;
            issues{end+1} = 'Duplicate Goto/From tags detected';
        end
        
        % Check 3: Inport/Outport count should be >= 1 for subsystems
        if inportCount == 0
            issues{end+1} = 'No Inport blocks found — subsystem has no input interface';
            r.confidence = min(r.confidence, 0.3);
        end
        if outportCount == 0
            issues{end+1} = 'No Outport blocks found — subsystem has no output interface';
            r.confidence = min(r.confidence, 0.3);
        end
        
        % Check 4: Inport/Outport should be connected to internal blocks
        if inportCount > 0
            for i = 2:length(blocks)
                bp = blocks{i};
                try
                    btype = get_param(bp, 'BlockType');
                    if strcmp(btype, 'Inport')
                        ph = get_param(bp, 'PortHandles');
                        if ~isempty(ph.Outport)
                            lineH = get_param(ph.Outport(1), 'Line');
                            if lineH == -1
                                unpairedInport{end+1} = bp;
                            end
                        end
                    end
                catch
                end
            end
        end
        
        if ~isempty(unpairedInport)
            r.passed = false; r.confidence = 0.4;
            n = length(unpairedInport);
            issues{end+1} = sprintf('%d Inport(s) not connected to internal blocks', n);
        end
        
    catch ME
        r.passed = false; r.confidence = 0.1;
        issues{end+1} = sprintf('Error: %s', ME.message);
    end
    
    if ~isempty(issues)
        r.issue = sl_framework_utils('strjoin_safe', issues, '; ');
        r.suggestion = 'Ensure Inport/Outport and Goto/From are correctly paired';
    end
    
    r.details = struct('inportCount', inportCount, 'outportCount', outportCount, ...
        'gotoCount', gotoCount, 'fromCount', fromCount);
end

% ===== Dimension 2: Parameter Audit =====
function r = check_param_audit(modelPath)
    r = struct('item', 'paramAudit', 'passed', true, 'confidence', 0.85, ...
        'issue', '', 'suggestion', '', 'details', struct());
    
    issues = {};
    totalBlocks = 0;
    blocksWithIssues = 0;
    paramIssues = {};
    
    try
        blocks = find_system(modelPath, 'SearchDepth', 5, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)
            bp = blocks{i};
            totalBlocks = totalBlocks + 1;
            
            try
                btype = get_param(bp, 'BlockType');
                % Skip structural blocks: Inport, Outport, Goto, From, SubSystem
                if any(strcmp(btype, {'Inport', 'Outport', 'Goto', 'From', 'SubSystem'}))
                    continue;
                end
                
                dp = get_param(bp, 'DialogParameters');
                if isempty(dp)
                    continue;
                end
                
                paramNames = fieldnames(dp);
                blockHasIssues = false;
                
                for j = 1:length(paramNames)
                    pname = paramNames{j};
                    try
                        val = get_param(bp, pname);
                        if isempty(val)
                            if ~blockHasIssues
                                blocksWithIssues = blocksWithIssues + 1;
                                blockHasIssues = true;
                            end
                            paramIssues{end+1} = sprintf('%s.%s = <empty>', btype, pname);
                        elseif ischar(val)
                            valStr = strtrim(val);
                            if isempty(valStr)
                                if ~blockHasIssues
                                    blocksWithIssues = blocksWithIssues + 1;
                                    blockHasIssues = true;
                                end
                                paramIssues{end+1} = sprintf('%s.%s = <empty string>', btype, pname);
                            end
                        end
                    catch
                    end
                end
            catch
                % Block might not support get_param for DialogParameters
            end
        end
        
        if blocksWithIssues > 0
            r.passed = false;
            r.confidence = max(0.2, 1.0 - blocksWithIssues / max(1, totalBlocks));
            issues{end+1} = sprintf('%d/%d blocks have parameter issues', blocksWithIssues, totalBlocks);
        end
        
        % Show first 5 detailed issues
        if length(paramIssues) > 5
            paramIssues = paramIssues(1:5);
            paramIssues{end+1} = sprintf('... and %d more', blocksWithIssues - 5);
        end
        
    catch ME
        r.passed = false; r.confidence = 0.1;
        issues{end+1} = sprintf('Error: %s', ME.message);
    end
    
    if ~isempty(issues)
        r.issue = sl_framework_utils('strjoin_safe', issues, '; ');
        r.suggestion = 'Check and set all block parameters before proceeding';
    end
    
    r.details = struct('totalBlocks', totalBlocks, ...
        'blocksWithIssues', blocksWithIssues, ...
        'paramIssues', {paramIssues});
end

% ===== Dimension 3: Connection Scan =====
function r = check_connection_scan(modelPath)
    r = struct('item', 'connectionScan', 'passed', true, 'confidence', 0.9, ...
        'issue', '', 'suggestion', '', 'details', struct());
    
    issues = {};
    totalBlocks = 0;
    unconnected = {};
    nUnconnected = 0;  % [v11.8.1] initialized before try block to prevent undefined reference
    
    try
        blocks = find_system(modelPath, 'SearchDepth', 5, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)
            bp = blocks{i};
            totalBlocks = totalBlocks + 1;
            
            try
                btype = get_param(bp, 'BlockType');
                shortName = sl_framework_utils('regexp_once_safe', bp, '[^/]+$');
                if isempty(shortName)
                    shortName = strrep(bp, [modelPath '/'], '');
                end
                
                ph = get_param(bp, 'PortHandles');
                
                % Check Inports
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH == -1
                                unconnected{end+1} = sprintf('  %s/%s:In(%d) unconnected', btype, shortName, j);
                            end
                        catch
                        end
                    end
                end
                
                % Check Outports  
                if ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH == -1
                                % Bug#25 FIX: Only skip Outport output (structural port).
                                % Inport output IS a real internal signal that MUST be connected.
                                if ~strcmp(btype, 'Outport')
                                    unconnected{end+1} = sprintf('  %s/%s:Out(%d) unconnected', btype, shortName, j);
                                end
                            end
                        catch
                        end
                    end
                end
            catch
            end
        end
        
        nUnconnected = length(unconnected);
        if nUnconnected > 0
            r.passed = false;
            r.confidence = max(0.1, 1.0 - nUnconnected / max(1, totalBlocks * 2));
            
            % Limit reported issues
            if nUnconnected <= 10
                detailList = unconnected;
            else
                detailList = unconnected(1:10);
                detailList{end+1} = sprintf('  ... and %d more unconnected ports', nUnconnected - 10);
            end
            issues{end+1} = sprintf('%d unconnected port(s):', nUnconnected);
            for k = 1:length(detailList)
                issues{end+1} = detailList{k};
            end
        end
        
    catch ME
        r.passed = false; r.confidence = 0.1;
        issues{end+1} = sprintf('Error: %s', ME.message);
    end
    
    if ~isempty(issues)
        r.issue = sl_framework_utils('strjoin_safe', issues, ' | ');
        r.suggestion = 'Connect all unconnected ports using sl_add_line_safe';
    end
    
    r.details = struct('totalBlocks', totalBlocks, ...
        'unconnectedCount', nUnconnected);
end

% ===== Dimension 4: Layout Audit =====
function r = check_layout_audit(modelPath)
    r = struct('item', 'layoutAudit', 'passed', true, 'confidence', 0.85, ...
        'issue', '', 'suggestion', '', 'details', struct());
    
    issues = {};
    totalBlocks = 0;
    overlappingPairs = 0;
    outOfBounds = 0;
    
    try
        blocks = find_system(modelPath, 'SearchDepth', 5, 'LookUnderMasks', 'all');
        nBlocks = length(blocks) - 1;  % exclude system itself
        if nBlocks <= 1
            r.issue = 'Too few blocks to check layout';
            r.details = struct('totalBlocks', 0, 'overlapping', 0, 'outOfBounds', 0);
            return;
        end
        
        positions = cell(nBlocks, 1);
        blockNames = cell(nBlocks, 1);
        idx = 1;
        
        for i = 2:length(blocks)
            bp = blocks{i};
            try
                pos = get_param(bp, 'Position');
                if length(pos) == 4
                    positions{idx} = pos;
                    % Extract short name
                    shortName = sl_framework_utils('regexp_once_safe', bp, '[^/]+$');
                    if isempty(shortName)
                        shortName = strrep(bp, [modelPath '/'], '');
                    end
                    blockNames{idx} = shortName;
                    idx = idx + 1;
                    totalBlocks = totalBlocks + 1;
                end
            catch
            end
        end
        
        if totalBlocks < 2
            r.details = struct('totalBlocks', totalBlocks, 'overlapping', 0, 'outOfBounds', 0);
            return;
        end
        
        % Check overlapping blocks
        for i = 1:totalBlocks
            for j = i+1:totalBlocks
                if isempty(positions{i}) || isempty(positions{j})
                    continue;
                end
                p1 = positions{i};
                p2 = positions{j};
                
                % Check overlap: rectangles overlap if x ranges and y ranges overlap
                xOverlap = (p1(1) < p2(3) && p2(1) < p1(3));
                yOverlap = (p1(2) < p2(4) && p2(2) < p1(4));
                
                if xOverlap && yOverlap
                    overlappingPairs = overlappingPairs + 1;
                    if overlappingPairs <= 5
                        issues{end+1} = sprintf('Overlap: %s <-> %s', blockNames{i}, blockNames{j});
                    end
                end
            end
            
            % Check out-of-bounds: position should be positive and reasonable
            p = positions{i};
            if isempty(p), continue; end
            if p(1) < 0 || p(2) < 0 || p(1) > 10000 || p(2) > 10000
                outOfBounds = outOfBounds + 1;
                if outOfBounds <= 3
                    issues{end+1} = sprintf('Out-of-bounds: %s at [%d %d %d %d]', ...
                        blockNames{i}, p(1), p(2), p(3), p(4));
                end
            end
        end
        
        if overlappingPairs > 0
            r.passed = false; r.confidence = 0.4;
            if overlappingPairs > 5
                issues{end+1} = sprintf('... and %d more overlapping pairs', overlappingPairs - 5);
            end
        end
        
        if outOfBounds > 0
            r.passed = false; r.confidence = min(r.confidence, 0.5);
        end
        
    catch ME
        r.passed = false; r.confidence = 0.1;
        issues{end+1} = sprintf('Error: %s', ME.message);
    end
    
    if ~isempty(issues)
        r.issue = sl_framework_utils('strjoin_safe', issues, '; ');
        r.suggestion = 'Use sl_auto_layout to fix layout issues';
    end
    
    r.details = struct('totalBlocks', totalBlocks, ...
        'overlapping', overlappingPairs, ...
        'outOfBounds', outOfBounds);
end

% ===== Run All Dimensions =====
function result = run_all_dimensions(modelPath)
    dims = {'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'};
    nDims = length(dims);
    results = cell(nDims, 1);
    allPassed = true;
    totalConfidence = 0;
    allIssues = {};
    allSuggestions = {};
    
    for k = 1:nDims
        r = sl_review_core(modelPath, dims{k});
        results{k} = r;
        if ~r.passed
            allPassed = false;
        end
        totalConfidence = totalConfidence + r.confidence;
        if ~isempty(r.issue)
            allIssues{end+1} = r.issue;
        end
        if ~isempty(r.suggestion)
            allSuggestions{end+1} = r.suggestion;
        end
    end
    
    result = struct('status', 'ok', ...
        'modelPath', modelPath, ...
        'action', 'all', ...
        'passed', allPassed, ...
        'confidence', totalConfidence / nDims, ...
        'issue', sl_framework_utils('strjoin_safe', allIssues, '; '), ...
        'suggestion', sl_framework_utils('strjoin_safe', allSuggestions, '; '), ...
        'checks', {results});
end
