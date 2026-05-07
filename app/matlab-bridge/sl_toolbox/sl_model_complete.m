function result = sl_model_complete(modelName, varargin)
% SL_MODEL_COMPLETE Model Completion Gate (v11.3)
%   Runs all 12 validation checks. unconnected must pass (0 unconnected ports)
%   before the model is considered complete.
%
%   result = sl_model_complete(modelName)
%   result = sl_model_complete(modelName, 'action', 'check')    % default
%   result = sl_model_complete(modelName, 'action', 'complete') % set completed flag
%
% Inputs:
%   modelName - model name (required)
%   'action'  - 'check' (default) | 'complete'
%
% Returns:
%   status: 'ok' | 'blocked'
%   passed: true/false
%   overall: 'pass'/'warning'/'fail'
%   checkResults: [{name, status, message, details}, ...]
%   unconnectedCount: number of unconnected ports
%   unconnectedList: [{block, portType, portIndex, isSubsystem}, ...]
%   canProceed: true/false  % must-pass checks all pass
%   mustPassChecks: cell of required check names
%   suggestions: cell of strings
%
% Must-Pass Rules:
%   - unconnected must pass (0 unconnected ports)
%   - compilation must pass
%   - Any must-pass failure -> canProceed = false
%
% On action='complete' success:
%   [P0-1 FIX] modelName sanitized: '/' → '__', ' ' → '_'
%   assignin('base', ['model_completed_' model_safe], true)

    % ===== Parse arguments =====
    action = 'check';
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if strcmpi(key, 'action')
                action = val;
            end
            idx = idx + 2;
        else
            idx = idx + 1;
        end
    end

    % ===== Ensure model loaded =====
    try
        model_safe = strrep(modelName, '/', '__'); if isempty(strfind(modelName, '/')), topModel = modelName; else topModel = modelName(1:strfind(modelName, '/')-1); end; if ~bdIsLoaded(topModel)
            load_system(topModel);
        end
    catch ME
        result = struct('status', 'blocked', ...
            'passed', false, 'overall', 'fail', 'checkResults', {{}}, ...
            'unconnectedCount', -1, 'unconnectedList', {{}}, ...
            'canProceed', false, ...
            'mustPassChecks', {{'unconnected', 'compilation'}}, ...
            'suggestions', {{['Model not loaded: ' ME.message]}});
        return;
    end

    % ===== [v11.6 P1-6] Detect sub-path mode =====
    % When modelName contains '/', we are operating on a SubSystem, not a top-level model.
    % Subsystems cannot be independently compiled (sim() fails on SubSystem blocks).
    % They also lack model-level params like SolverType.
    % We skip these checks but add port connectivity verification.
    isSubPath = ~isempty(strfind(modelName, '/'));
    % [P2-7 FIX v11.7] Modern MATLAB syntax (R2016b+): use contains()
    % Kept strfind for R2016a backward compatibility
    try
        isSubPath = contains(modelName, '/');
    catch
        isSubPath = ~isempty(strfind(modelName, '/'));
    end
    subPathSkipChecks = {};
    if isSubPath
        subPathSkipChecks = {'compilation', 'config_issue', 'sample_time', 'model_ref'};
    end

    % ===== Run validation =====
    validateResult = sl_validate_model(modelName, 'checks', 'all');

    % ===== Get detailed unconnected list =====
    issuesResult = sl_get_model_issues(modelName);

    % ===== [v11.3.1] Mandatory Auto-Layout =====
    % Layout the model and ALL subsystems. This is a non-bypassable step.
    layoutWarnings = {};
    try
        warning('off', 'Simulink:Engine:MdlFileShadowing');
        % Layout top-level model
        Simulink.BlockDiagram.arrangeSystem(modelName, 'FullLayout', 'true');
        % Layout all subsystems (including nested)
        subs = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'SubSystem');
        for i = 1:length(subs)
            try
                Simulink.BlockDiagram.arrangeSystem(subs{i}, 'FullLayout', 'true');
            catch
            end
        end
        warning('on', 'Simulink:Engine:MdlFileShadowing');
    catch ME
        layoutWarnings{end+1} = ['Auto-layout failed: ' ME.message];
    end

    % ===== Determine must-pass status =====
    mustPassChecks = {'unconnected'};
    if ~isSubPath
        mustPassChecks{end+1} = 'compilation';
    end
    mustPassPassed = true;
    failReasons = {};

    for i = 1:length(validateResult.checks)
        check = validateResult.checks(i);
        checkName = check.name;
        checkStatus = check.status;

        % [v11.6 P1-6] Skip subPath-inapplicable checks
        if isSubPath && any(strcmp(subPathSkipChecks, checkName))
            % Override status to 'skipped' for subpath-inapplicable checks
            checkStatus = 'skipped';
            continue;
        end

        % Check if this is a must-pass check and it failed
        if any(strcmp(mustPassChecks, checkName))
            if ~strcmpi(checkStatus, 'pass')
                mustPassPassed = false;
                failReasons{end+1} = sprintf('[%s] %s: %s', checkName, checkStatus, check.message);
            end
        end
    end

    % ===== [v11.3.1] Goto/From pairing check =====
    if isfield(issuesResult, 'gotoFromIssues') && ~isempty(issuesResult.gotoFromIssues)
        nGf = length(issuesResult.gotoFromIssues);
        mustPassPassed = false;
        failReasons{end+1} = sprintf('[goto_from] %d Goto/From pairing issue(s) found.', nGf);
        for i = 1:min(5, nGf)
            gi = issuesResult.gotoFromIssues{i};
            failReasons{end+1} = sprintf('  %s: %s', gi.type, gi.issue);
        end
    end

    % ===== [v11.6] Sub-path port connectivity check =====
    if isSubPath
        try
            ports = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Inport');
            for pi = 1:numel(ports)
                try
                    ph = get_param(ports{pi}, 'PortHandles');
                    line = get_param(ph.Outport, 'Line');
                    if line == -1
                        failReasons{end+1} = sprintf('[subpath_port] Inport "%s" has no output connection inside sandbox.', ports{pi});
                    end
                catch
                end
            end
            ports = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Outport');
            for po = 1:numel(ports)
                try
                    ph = get_param(ports{po}, 'PortHandles');
                    line = get_param(ph.Inport, 'Line');
                    if line == -1
                        failReasons{end+1} = sprintf('[subpath_port] Outport "%s" has no input connection inside sandbox.', ports{po});
                    end
                catch
                end
            end
        catch
        end
    end
    if isfield(issuesResult, 'orphanedBlocks') && ~isempty(issuesResult.orphanedBlocks)
        nOrph = length(issuesResult.orphanedBlocks);
        mustPassPassed = false;
        failReasons{end+1} = sprintf('[orphaned] %d orphaned block(s) with no connections.', nOrph);
        for i = 1:min(5, nOrph)
            ob = issuesResult.orphanedBlocks{i};
            failReasons{end+1} = sprintf('  %s (%s)', ob.block, ob.blockType);
        end
    end
    
    % ===== [P2 FIX v11.6.7] Auto-terminate unconnected Integrator outputs =====
    % Opt-in feature: when enabled, automatically adds Terminator blocks to
    % unconnected Integrator output ports. This prevents "dangling output"
    % warnings and reduces manual cleanup steps.
    autoTerm = false;
    idx2 = 1;
    while idx2 <= length(varargin)
        if ischar(varargin{idx2}) && strcmpi(varargin{idx2}, 'autoTerminateIntegrators')
            autoTerm = true;
            break;
        elseif ischar(varargin{idx2}) && idx2 < length(varargin)
            idx2 = idx2 + 2;
        else
            idx2 = idx2 + 1;
        end
    end
    if autoTerm
        try
            allInt = find_system(modelName, 'BlockType', 'Integrator');
            for ii = 1:length(allInt)
                intBlk = allInt{ii};
                intPH = get_param(intBlk, 'PortHandles');
                if ~isempty(intPH.Outport)
                    outLine = get_param(intPH.Outport(1), 'Line');
                    if outLine == -1
                        [p, nm] = fileparts(intBlk);
                        termPath = [intBlk '_Term'];
                        try
                            add_block('simulink/Sinks/Terminator', termPath);
                            add_line(p, [nm '/1'], [nm '_Term/1']);
                        catch
                        end
                    end
                end
            end
        catch
        end
    end

    % ===== [v11.6.8 FIX] Filter template default In1/Out1 from unconnected count =====
    % SubSystem blocks come with default In1/Out1 that AI may not use.
    % Check: for each SubSystem block, look inside for default-named In1/Out1
    % ports (named exactly 'In1' or 'Out1') that are unconnected internally.
    % If the subsystem-level unconnected port maps to such a default internal port,
    % exclude it from the count.
    templateUnconnected = 0;
    try
        allSubs = find_system(modelName, 'BlockType', 'SubSystem');
        for si = 1:length(allSubs)
            ss = allSubs{si};
            % Map subsystem port numbers to internal Inport/Outport blocks
            ss_ph = get_param(ss, 'PortHandles');
            
            % Check input ports
            for ip_idx = 1:length(ss_ph.Inport)
                ip_h = ss_ph.Inport(ip_idx);
                ip_line = get_param(ip_h, 'Line');
                if ip_line == -1
                    % This subsystem input port is unconnected at parent level
                    % Check if it maps to a default In1 inside
                    try
                        in_blks = find_system(ss, 'SearchDepth', 1, 'BlockType', 'Inport');
                        if ip_idx <= length(in_blks)
                            in_blk = in_blks{ip_idx};
                            [~, in_name] = fileparts(in_blk);
                            if strcmp(in_name, 'In1')
                                % Default In1 - check internal connection
                                in_ph = get_param(in_blk, 'PortHandles');
                                in_line = get_param(in_ph.Outport, 'Line');
                                if in_line == -1
                                    templateUnconnected = templateUnconnected + 1;
                                end
                            end
                        end
                    catch
                    end
                end
            end
            
            % Check output ports
            for op_idx = 1:length(ss_ph.Outport)
                op_h = ss_ph.Outport(op_idx);
                op_line = get_param(op_h, 'Line');
                if op_line == -1
                    try
                        out_blks = find_system(ss, 'SearchDepth', 1, 'BlockType', 'Outport');
                        if op_idx <= length(out_blks)
                            out_blk = out_blks{op_idx};
                            [~, out_name] = fileparts(out_blk);
                            if strcmp(out_name, 'Out1')
                                out_ph = get_param(out_blk, 'PortHandles');
                                out_line = get_param(out_ph.Inport, 'Line');
                                if out_line == -1
                                    templateUnconnected = templateUnconnected + 1;
                                end
                            end
                        end
                    catch
                    end
                end
            end
        end
    catch
    end
    adjustedUnconnected = max(0, issuesResult.unconnectedCount - templateUnconnected);

    % ===== Build result =====
    result = struct();
    result.status = 'ok';
    result.passed = mustPassPassed;
    result.overall = validateResult.overall;
    result.checkResults = validateResult.checks;
    result.mustPassChecks = {mustPassChecks};
    result.unconnectedCount = adjustedUnconnected;
    if isSubPath
        result.isSubPath = true;
        result.subPathSkippedChecks = subPathSkipChecks;
    end
    result.gotoFromIssues = issuesResult.gotoFromIssues;
    result.orphanedBlocks = issuesResult.orphanedBlocks;

    if mustPassPassed
        result.canProceed = true;
        result.suggestions = {};
        result.status = 'ok';

        % If action='complete', set the completion flag
        if strcmpi(action, 'complete')
            % [P0-1 FIX] Sanitize modelName: '/' not allowed in MATLAB variable names
            model_safe = strrep(strrep(modelName, '/', '__'), ' ', '_');
            flagVar = ['model_completed_' model_safe];
            assignin('base', flagVar, true);
            result.message = sprintf('Model %s completed and locked. All must-pass checks passed.', modelName);
        else
            result.message = sprintf('All must-pass checks passed. Model %s can proceed to simulation.', modelName);
        end
    else
        result.canProceed = false;
        result.status = 'blocked';
        result.suggestions = failReasons;
        result.message = sprintf('Model completion BLOCKED: %d must-pass check(s) failed. Unconnected ports: %d (excl. %d template default).', ...
            length(failReasons), adjustedUnconnected, templateUnconnected);
        % Add specific fix suggestions
        if adjustedUnconnected > 0
            result.suggestions{end+1} = sprintf('Run sl_get_model_issues(''%s'') for detailed unconnected port list.', modelName);
            result.suggestions{end+1} = 'Connect all unconnected ports before retrying sl_model_complete.';
        end
    end
end
