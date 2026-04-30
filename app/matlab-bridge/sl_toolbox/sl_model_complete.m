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
%   assignin('base', ['model_completed_' modelName], true)

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
        if ~bdIsLoaded(modelName)
            load_system(modelName);
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
    mustPassChecks = {'unconnected', 'compilation'};
    mustPassPassed = true;
    failReasons = {};

    for i = 1:length(validateResult.checks)
        check = validateResult.checks(i);
        checkName = check.name;
        checkStatus = check.status;

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

    % ===== [v11.3.1] Orphaned blocks check =====
    if isfield(issuesResult, 'orphanedBlocks') && ~isempty(issuesResult.orphanedBlocks)
        nOrph = length(issuesResult.orphanedBlocks);
        mustPassPassed = false;
        failReasons{end+1} = sprintf('[orphaned] %d orphaned block(s) with no connections.', nOrph);
        for i = 1:min(5, nOrph)
            ob = issuesResult.orphanedBlocks{i};
            failReasons{end+1} = sprintf('  %s (%s)', ob.block, ob.blockType);
        end
    end

    % ===== Build result =====
    result = struct();
    result.status = 'ok';
    result.passed = mustPassPassed;
    result.overall = validateResult.overall;
    result.checkResults = validateResult.checks;
    result.mustPassChecks = {mustPassChecks};
    result.unconnectedCount = issuesResult.unconnectedCount;
    result.unconnectedList = issuesResult.unconnectedBlocks;
    result.gotoFromIssues = issuesResult.gotoFromIssues;
    result.orphanedBlocks = issuesResult.orphanedBlocks;

    if mustPassPassed
        result.canProceed = true;
        result.suggestions = {};
        result.status = 'ok';

        % If action='complete', set the completion flag
        if strcmpi(action, 'complete')
            flagVar = ['model_completed_' modelName];
            assignin('base', flagVar, true);
            result.message = sprintf('Model %s completed and locked. All must-pass checks passed.', modelName);
        else
            result.message = sprintf('All must-pass checks passed. Model %s can proceed to simulation.', modelName);
        end
    else
        result.canProceed = false;
        result.status = 'blocked';
        result.suggestions = failReasons;
        result.message = sprintf('Model completion BLOCKED: %d must-pass check(s) failed. Unconnected ports: %d.', ...
            length(failReasons), issuesResult.unconnectedCount);
        % Add specific fix suggestions
        if issuesResult.unconnectedCount > 0
            result.suggestions{end+1} = sprintf('Run sl_get_model_issues(''%s'') for detailed unconnected port list.', modelName);
            result.suggestions{end+1} = 'Connect all unconnected ports before retrying sl_model_complete.';
        end
    end
end
