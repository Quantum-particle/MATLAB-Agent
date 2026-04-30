function result = sl_framework_verify_built(modelName, macroFramework)
% SL_FRAMEWORK_VERIFY_BUILT Verify built model against approved framework (v11.4)
%   Compares the ACTUAL Simulink model against the approved framework design.
%   Checks that every planned subsystem/signal/goto exists in the model.
%
%   result = sl_framework_verify_built(modelName, macroFramework)
%
% Inputs:
%   modelName      - model name (required)
%   macroFramework - framework struct from sl_framework_design (required)
%
% Returns:
%   status: 'ok' | 'mismatch'
%   passed: true/false
%   checks: [{item, passed, details}, ...]
%   mismatches: [{type, framework, actual, suggestion}, ...]
%   summary: human-readable summary

    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result = struct('status', 'error', 'message', ['Model not loaded: ' ME.message]);
        return;
    end

    mismatches = {};
    checks = {};

    % ===== Check 1: Subsystem existence =====
    plannedSubs = {};
    if isfield(macroFramework, 'subsystems')
        for i = 1:length(macroFramework.subsystems)
            plannedSubs{end+1} = macroFramework.subsystems(i).name;
        end
    end

    actualSubs = {};
    blks = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'SubSystem');
    for i = 1:length(blks)
        [~, name] = fileparts(blks{i});
        actualSubs{end+1} = name;
    end

    missingSubs = setdiff(plannedSubs, actualSubs);
    extraSubs = setdiff(actualSubs, plannedSubs);

    if ~isempty(missingSubs)
        for i = 1:length(missingSubs)
            mismatches{end+1} = struct('type', 'missing_subsystem', ...
                'framework', missingSubs{i}, 'actual', '', ...
                'suggestion', sprintf('Create subsystem: sl_subsystem_create(''%s'', ''%s'', ''empty'')', modelName, missingSubs{i}));
        end
    end
    if ~isempty(extraSubs)
        for i = 1:length(extraSubs)
            mismatches{end+1} = struct('type', 'extra_subsystem', ...
                'framework', '', 'actual', extraSubs{i}, ...
                'suggestion', sprintf('Subsystem "%s" exists but not in framework. Remove or update framework.', extraSubs{i}));
        end
    end
    checks{end+1} = struct('item', 'subsystem_existence', ...
        'passed', isempty(missingSubs) && isempty(extraSubs), ...
        'details', struct('missing', {missingSubs}, 'extra', {extraSubs}));

    % ===== Check 2: Signal flow verification =====
    if isfield(macroFramework, 'signalFlow') && ~isempty(macroFramework.signalFlow)
        for i = 1:length(macroFramework.signalFlow)
            if iscell(macroFramework.signalFlow)
                sf = macroFramework.signalFlow{i};
            else
                sf = macroFramework.signalFlow(i);
            end
            srcSub = [modelName '/' sf.srcSubsystem];
            dstSub = [modelName '/' sf.dstSubsystem];

            % Check if actual lines exist between these subsystems
            try
                lines = find_system(modelName, 'FindAll', 'on', 'Type', 'Line');
                found = false;
                for j = 1:length(lines)
                    srcH = get_param(lines(j), 'SrcBlockHandle');
                    dstH = get_param(lines(j), 'DstBlockHandle');
                    if srcH > 0 && dstH > 0
                        srcName = getfullname(srcH);
                        dstName = getfullname(dstH);
                        if strcmp(srcName, srcSub) && strcmp(dstName, dstSub)
                            found = true; break;
                        end
                    end
                end
                if ~found
                    mismatches{end+1} = struct('type', 'missing_signal_flow', ...
                        'framework', [sf.srcSubsystem ' -> ' sf.dstSubsystem ' (' sf.signalName ')'], ...
                        'actual', 'No line found', ...
                        'suggestion', sprintf('add_line: %s output -> %s input for signal "%s"', sf.srcSubsystem, sf.dstSubsystem, sf.signalName));
                end
            catch
            end
        end
    end
    checks{end+1} = struct('item', 'signal_flow_verified', ...
        'passed', isempty(mismatches), ...
        'details', struct('checked', length(macroFramework.signalFlow)));

    % ===== Check 3: Goto/From verification =====
    if isfield(macroFramework, 'gotoFromPlan') && ~isempty(macroFramework.gotoFromPlan)
        for i = 1:length(macroFramework.gotoFromPlan)
            if iscell(macroFramework.gotoFromPlan)
                gf = macroFramework.gotoFromPlan{i};
            else
                gf = macroFramework.gotoFromPlan(i);
            end
            tag = gf.tag;
            % Check if Goto block exists
            gotos = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'Goto');
            foundGoto = false;
            for j = 1:length(gotos)
                try
                    if strcmp(get_param(gotos{j}, 'GotoTag'), tag)
                        foundGoto = true; break;
                    end
                catch
                end
            end
            % Check if From block(s) exist
            froms = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'From');
            foundFrom = false;
            for j = 1:length(froms)
                try
                    if strcmp(get_param(froms{j}, 'GotoTag'), tag)
                        foundFrom = true; break;
                    end
                catch
                end
            end

            if ~foundGoto || ~foundFrom
                mismatches{end+1} = struct('type', 'missing_goto_from', ...
                    'framework', ['tag: ' tag], ...
                    'actual', sprintf('Goto=%d From=%d', foundGoto, foundFrom), ...
                    'suggestion', sprintf('Ensure Goto block (tag="%s") and From block(s) both exist.', tag));
            end
        end
    end
    checks{end+1} = struct('item', 'goto_from_verified', ...
        'passed', isempty(mismatches), ...
        'details', struct('checked', length(macroFramework.gotoFromPlan)));

    % ===== Build result =====
    allPassed = true;
    for i = 1:length(checks)
        if ~checks{i}.passed, allPassed = false; break; end
    end

    nMM = length(mismatches);
    if nMM == 0
        summary = 'All framework elements verified in built model.';
    else
        summary = sprintf('%d mismatch(es) between framework design and built model.', nMM);
    end

    result = struct();
    result.status = 'ok';
    result.passed = allPassed;
    result.checks = {checks};
    result.mismatches = {mismatches};
    result.mismatchCount = nMM;
    result.summary = summary;
end
