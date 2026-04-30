function r = sl_check_signal_closure(fw)
% SL_CHECK_SIGNAL_CLOSURE Check signal flow references valid subsystems (v11.4)
    r = struct('item', 'signal_closure', 'passed', true, 'confidence', 0.95, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || ~isfield(fw, 'signalFlow') || isempty(fw.signalFlow)
        r.confidence = 0.8; return;
    end
    names = cell(1, length(fw.subsystems));
    for i = 1:length(fw.subsystems), names{i} = fw.subsystems(i).name; end
    issues = {};
    for i = 1:length(fw.signalFlow)
        if iscell(fw.signalFlow), sf = fw.signalFlow{i}; else sf = fw.signalFlow(i); end
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
