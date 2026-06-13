function r = sl_check_signal_closure(fw)
% SL_CHECK_SIGNAL_CLOSURE Check signal flow references valid subsystems (v11.4)
    % [v11.6.8] Normalize via global utility (idempotent)
    fw = sl_fw_normalize(fw);
    r = struct('item', 'signal_closure', 'passed', true, 'confidence', 0.95, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || ~isfield(fw, 'signalFlow') || isempty(fw.signalFlow)
        r.confidence = 0.8; return;
    end
    % [v30 B6 AUDIT] Build subsystem name list with guards for missing 'name' field
    nSubs = length(fw.subsystems);
    names = cell(1, nSubs);
    for i = 1:nSubs
        sub = sl_safe_index(fw.subsystems, i);
        if isstruct(sub) && isfield(sub, 'name')
            names{i} = sub.name;
        else
            names{i} = sprintf('_unnamed_%d', i);
        end
    end
    issues = {};
    nFlow = length(fw.signalFlow);
    for i = 1:nFlow
        % [v30 B6 AUDIT] Guard against non-struct elements in signalFlow array
        if iscell(fw.signalFlow)
            sf = fw.signalFlow{i};
        else
            sf = fw.signalFlow(i);
        end
        if ~isstruct(sf)
            issues{end+1} = sprintf('signalFlow[%d] is not a struct', i);
            continue;
        end
        if ~isfield(sf, 'srcSubsystem') || ~isfield(sf, 'dstSubsystem')
            issues{end+1} = sprintf('signalFlow[%d] missing srcSubsystem/dstSubsystem', i);
            continue;
        end
        if ~any(strcmp(names, sf.srcSubsystem))
            issues{end+1} = sprintf('src "%s" not in subsystems', sf.srcSubsystem);
        end
        if ~any(strcmp(names, sf.dstSubsystem))
            issues{end+1} = sprintf('dst "%s" not in subsystems', sf.dstSubsystem);
        end
    end
    if ~isempty(issues)
        r.passed = false; r.confidence = 0.4;
        r.issue = strjoin(issues, '; ');
        r.suggestion = 'Every signalFlow entry must reference valid subsystems.';
    end
end
