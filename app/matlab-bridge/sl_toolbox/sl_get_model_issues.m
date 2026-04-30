function result = sl_get_model_issues(modelName)
% SL_GET_MODEL_ISSUES Get detailed model issue list (v11.3)
%   Returns all unconnected ports with exact block path, port type, and port index.
%   This is the primary diagnostic tool for the verify->fix->re-verify loop.
%
%   result = sl_get_model_issues(modelName)
%
% Inputs:
%   modelName - model name (required)
%
% Returns:
%   status: 'ok'
%   unconnectedBlocks: [{block, portType, portIndex, isSubsystem, parentSubsystem}, ...]
%   unconnectedCount: total number of unconnected ports
%   unconnectedBySubsystem: {name, count, blocks} per subsystem summary
%   undefinedVariables: [{block, param, variable}, ...]
%   suggestions: cell of fix suggestions

    % ===== Ensure model loaded =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result = struct('status', 'error', 'error', ['Model not loaded: ' ME.message]);
        return;
    end

    % ===== Scan all blocks for unconnected ports =====
    unconnectedBlocks = {};
    undefinedVariables = {};

    try
        % Get ALL blocks including those inside subsystems
        blocks = find_system(modelName, 'LookUnderMasks', 'all');

        for i = 2:length(blocks)  % skip model root
            bp = blocks{i};
            try
                ph = get_param(bp, 'PortHandles');
                blockType = get_param(bp, 'BlockType');
                isSubsys = strcmp(blockType, 'SubSystem');

                % Determine parent subsystem
                parentSubsys = '';
                slashIdx = strfind(bp, '/');
                if length(slashIdx) >= 2
                    parentSubsys = bp(1:slashIdx(end)-1);
                elseif length(slashIdx) == 1
                    parentSubsys = modelName;
                end

                % Check input ports
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH == -1
                                unconnectedBlocks{end+1} = struct( ...
                                    'block', bp, ...
                                    'portType', 'input', ...
                                    'portIndex', j, ...
                                    'isSubsystem', isSubsys, ...
                                    'parentSubsystem', parentSubsys);
                            end
                        catch
                        end
                    end
                end

                % Check output ports
                if ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH == -1
                                unconnectedBlocks{end+1} = struct( ...
                                    'block', bp, ...
                                    'portType', 'output', ...
                                    'portIndex', j, ...
                                    'isSubsystem', isSubsys, ...
                                    'parentSubsystem', parentSubsys);
                            end
                        catch
                        end
                    end
                end

                % Check for undefined variables in block parameters
                try
                    dialogParams = get_param(bp, 'DialogParameters');
                    if ~isempty(dialogParams)
                        paramNames = fieldnames(dialogParams);
                        for j = 1:length(paramNames)
                            try
                                val = get_param(bp, paramNames{j});
                                if ischar(val) && ~isempty(val)
                                    vars = extract_var_names(val);
                                    for k = 1:length(vars)
                                        try
                                            exists = evalin('base', ...
                                                ['exist(''' vars{k} ''', ''var'')']);
                                            if exists == 0
                                                undefinedVariables{end+1} = struct( ...
                                                    'block', bp, ...
                                                    'param', paramNames{j}, ...
                                                    'variable', vars{k});
                                            end
                                        catch
                                        end
                                    end
                                end
                            catch
                            end
                        end
                    end
                catch
                end

            catch
            end
        end
    catch ME
        result = struct('status', 'error', 'error', ME.message);
        return;
    end

    % ===== Group by subsystem =====
    subsystemMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
    for i = 1:length(unconnectedBlocks)
        ub = unconnectedBlocks{i};
        subsys = ub.parentSubsystem;
        if isempty(subsys)
            subsys = modelName;
        end
        if ~subsystemMap.isKey(subsys)
            subsystemMap(subsys) = struct('name', subsys, 'count', 0, 'blocks', {{}});
        end
        entry = subsystemMap(subsys);
        entry.count = entry.count + 1;
        entry.blocks{end+1} = ub;
        subsystemMap(subsys) = entry;
    end

    unconnectedBySubsystem = {};
    keys = subsystemMap.keys;
    for i = 1:length(keys)
        unconnectedBySubsystem{end+1} = subsystemMap(keys{i});
    end

    % ===== Build suggestions =====
    n = length(unconnectedBlocks);
    suggestions = {};

    if n == 0
        suggestions{1} = 'All ports connected.';
    else
        suggestions{1} = sprintf('%d unconnected port(s) found.', n);

        % Count by type
        inputCount = 0;
        outputCount = 0;
        subsysCount = 0;
        % v11.3.1: Fine-grained block-type classification
        inportOutUnwired = 0;   % Inport output not connected (CRITICAL)
        outportInUnwired = 0;   % Outport input not connected (CRITICAL)
        fromOutUnwired = 0;     % From output not connected (INFO-level, acceptable)
        gotoInUnwired = 0;      % Goto input not connected (WARNING)
        gainInUnwired = 0;      % Gain input not connected (WARNING)
        otherUnwired = 0;       % Other blocks
        for i = 1:n
            ub = unconnectedBlocks{i};
            if strcmp(ub.portType, 'input')
                inputCount = inputCount + 1;
            else
                outputCount = outputCount + 1;
            end
            if ub.isSubsystem
                subsysCount = subsysCount + 1;
            end
            % v11.3.1: Fine-grained block-type classification
            try
                btype = get_param(ub.block, 'BlockType');
                if strcmpi(btype, 'Inport')
                    if strcmp(ub.portType, 'output')
                        inportOutUnwired = inportOutUnwired + 1;
                    end
                elseif strcmpi(btype, 'Outport')
                    if strcmp(ub.portType, 'input')
                        outportInUnwired = outportInUnwired + 1;
                    end
                elseif strcmpi(btype, 'From')
                    if strcmp(ub.portType, 'output')
                        fromOutUnwired = fromOutUnwired + 1;
                    end
                elseif strcmpi(btype, 'Goto')
                    if strcmp(ub.portType, 'input')
                        gotoInUnwired = gotoInUnwired + 1;
                    end
                elseif strcmpi(btype, 'Gain')
                    if strcmp(ub.portType, 'input')
                        gainInUnwired = gainInUnwired + 1;
                    else
                        otherUnwired = otherUnwired + 1;
                    end
                else
                    otherUnwired = otherUnwired + 1;
                end
            catch
                otherUnwired = otherUnwired + 1;
            end
        end

        suggestions{end+1} = sprintf('%d input port(s), %d output port(s), %d on subsystems.', ...
            inputCount, outputCount, subsysCount);

        % v11.3.1: Block-type specific diagnostics
        if inportOutUnwired > 0
            suggestions{end+1} = sprintf('CRITICAL: %d Inport block(s) with UNWIRED output!', inportOutUnwired);
            suggestions{end+1} = '  Signal enters subsystem through Inport but goes nowhere internally.';
            suggestions{end+1} = '  Fix: add_line inside the subsystem from Inport output to a logic block.';
        end
        if outportInUnwired > 0
            suggestions{end+1} = sprintf('CRITICAL: %d Outport block(s) with UNWIRED input!', outportInUnwired);
            suggestions{end+1} = '  Subsystem has an output port but nothing generates the signal internally.';
            suggestions{end+1} = '  Fix: add_line from a logic block output to the Outport input inside the subsystem.';
        end
        if gotoInUnwired > 0
            suggestions{end+1} = sprintf('WARNING: %d Goto block(s) with no signal input!', gotoInUnwired);
            suggestions{end+1} = '  Goto tag exists but no signal is being written to it.';
            suggestions{end+1} = '  Fix: add_line from signal source to Goto input, or delete unused Goto block.';
        end
        if fromOutUnwired > 0
            suggestions{end+1} = sprintf('INFO: %d From block(s) output unused (reads signal but not consumed).', fromOutUnwired);
            suggestions{end+1} = '  Acceptable if signal is intentionally unused. Add Terminator to silence the gate.';
        end
        if gainInUnwired > 0
            suggestions{end+1} = sprintf('WARNING: %d Gain block(s) with no input signal.', gainInUnwired);
            suggestions{end+1} = '  Fix: connect a signal source, or replace with Constant if value is fixed.';
        end
        if otherUnwired > 0
            suggestions{end+1} = sprintf('%d other unconnected port(s) on non-classified blocks.', otherUnwired);
        end
    end

    % ===== Check Goto/From pairing (v11.3.1) =====
    gotoFromIssues = {};
    try
        gotos = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'Goto');
        froms = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'From');

        gotoTags = {};
        gotoPaths = {};
        for i = 1:length(gotos)
            try
                tag = get_param(gotos{i}, 'GotoTag');
                gotoTags{end+1} = tag;
                gotoPaths{end+1} = gotos{i};
            catch
            end
        end

        fromTags = {};
        fromPaths = {};
        for i = 1:length(froms)
            try
                tag = get_param(froms{i}, 'GotoTag');
                fromTags{end+1} = tag;
                fromPaths{end+1} = froms{i};
            catch
            end
        end

        % Check From blocks that reference non-existent Goto tags
        for i = 1:length(fromTags)
            ftag = fromTags{i};
            if ~any(strcmp(gotoTags, ftag))
                gotoFromIssues{end+1} = struct( ...
                    'type', 'From_without_Goto', ...
                    'block', fromPaths{i}, ...
                    'tag', ftag, ...
                    'issue', sprintf('From block references GotoTag "%s" but no matching Goto block exists', ftag));
            end
        end

        % Check Goto blocks that have no matching From blocks
        for i = 1:length(gotoTags)
            gtag = gotoTags{i};
            if ~any(strcmp(fromTags, gtag))
                gotoFromIssues{end+1} = struct( ...
                    'type', 'Goto_without_From', ...
                    'block', gotoPaths{i}, ...
                    'tag', gtag, ...
                    'issue', sprintf('Goto block with tag "%s" has no matching From block', gtag));
            end
        end

        if ~isempty(gotoFromIssues)
            suggestions{end+1} = sprintf('%d Goto/From pairing issue(s) found.', length(gotoFromIssues));
        end
    catch
    end

    % ===== Check orphaned blocks (v11.3.1) =====
    orphanedBlocks = {};
    try
        blocks = find_system(modelName, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)
            bp = blocks{i};
            try
                btype = get_param(bp, 'BlockType');
                % Skip: Inport, Outport, SubSystem, Goto, From, Ground, Terminator, Constant, Scope
                skipTypes = {'Inport', 'Outport', 'SubSystem', 'Goto', 'From', ...
                             'Ground', 'Terminator', 'Constant', 'Scope'};
                if any(strcmp(btype, skipTypes))
                    continue;
                end

                ph = get_param(bp, 'PortHandles');
                allConnected = true;
                for j = 1:length(ph.Inport)
                    try
                        if get_param(ph.Inport(j), 'Line') == -1
                            allConnected = false; break;
                        end
                    catch, allConnected = false; break;
                    end
                end
                for j = 1:length(ph.Outport)
                    try
                        if get_param(ph.Outport(j), 'Line') == -1
                            allConnected = false; break;
                        end
                    catch, allConnected = false; break;
                    end
                end

                % If ALL ports are disconnected, block is orphaned
                if ~allConnected && isempty(ph.Inport) == isempty(ph.Outport)
                    % Check if truly orphaned (no connections on any port)
                    trulyOrphaned = true;
                    for j = 1:length(ph.Inport)
                        try, if get_param(ph.Inport(j),'Line') ~= -1, trulyOrphaned=false; end; catch; end
                    end
                    for j = 1:length(ph.Outport)
                        try, if get_param(ph.Outport(j),'Line') ~= -1, trulyOrphaned=false; end; catch; end
                    end
                    if trulyOrphaned
                        orphanedBlocks{end+1} = struct( ...
                            'block', bp, 'blockType', btype);
                    end
                end
            catch
            end
        end

        if ~isempty(orphanedBlocks)
            suggestions{end+1} = sprintf('%d orphaned block(s) with no connections.', length(orphanedBlocks));
            suggestions{end+1} = 'Orphaned blocks should be connected or removed (delete_block).';
        end
    catch
    end

    % ===== Build result =====
    result = struct();
    result.status = 'ok';
    result.unconnectedBlocks = unconnectedBlocks;
    result.unconnectedCount = n;
    result.unconnectedBySubsystem = unconnectedBySubsystem;
    result.undefinedVariables = undefinedVariables;
    result.gotoFromIssues = gotoFromIssues;
    result.orphanedBlocks = orphanedBlocks;

    % Sort suggestions as cell array
    result.suggestions = suggestions;
end

% ===== Helper: extract variable names from parameter values =====
function vars = extract_var_names(val)
    vars = {};
    if isempty(val), return; end
    if ~isnan(str2double(val)), return; end

    % Skip Simulink built-in enum values
    skipPatterns = { ...
        '^\[', '^\(', '^[0-9]', '^[-+]', '^on$', '^off$', '^auto$', ...
        '^inherit', '^Inherit', '^double$', '^single$', '^int', '^uint', ...
        '^boolean$', '^Floor$', '^Ceiling$', '^Manual$', '^Auto$', ...
        '^None$', '^Wrap$', '^round$', '^rectangular$', '^\|', ...
        '^\+', '^\-', '^Element', '^Channels', '^Dataset$', ...
        '^Array$', '^Structure$', '^Bottom', '^Top$', '^Off$', ...
        '^%<', '^%', ' ' ...
    };

    isSimple = false;
    for i = 1:length(skipPatterns)
        try
            if ~isempty(regexp(val, skipPatterns{i}, 'once'))
                isSimple = true; break;
            end
        catch
        end
    end

    if ~isSimple && ~isempty(val)
        if ~isempty(regexp(val, '^[a-zA-Z_][a-zA-Z0-9_]*$', 'once'))
            vars{1} = val;
        end
    end
end
