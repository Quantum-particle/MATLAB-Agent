function r = sl_check_port_completeness(fw)
% SL_CHECK_PORT_COMPLETENESS Check subsystem port completeness (v11.4)
%   Verifies every subsystem's Inport/Outport appears in signalFlow or gotoFromPlan.
    r = struct('item', 'port_completeness', 'passed', true, 'confidence', 0.95, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false; r.confidence = 0.3; r.issue = 'No subsystems defined'; return;
    end
    usedOut = struct(); usedIn = struct();
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        for i = 1:length(fw.signalFlow)
            if iscell(fw.signalFlow), sf = fw.signalFlow{i}; else sf = fw.signalFlow(i); end
            usedOut.(regexprep(sf.srcSubsystem, '[^a-zA-Z0-9]', '_')) = 1;
            usedIn.(regexprep(sf.dstSubsystem, '[^a-zA-Z0-9]', '_')) = 1;
        end
    end
    if isfield(fw, 'gotoFromPlan') && ~isempty(fw.gotoFromPlan)
        for i = 1:length(fw.gotoFromPlan)
            if iscell(fw.gotoFromPlan), gf = fw.gotoFromPlan{i}; else gf = fw.gotoFromPlan(i); end
            usedOut.(regexprep(gf.srcSubsystem, '[^a-zA-Z0-9]', '_')) = 1;
        end
    end
    issues = {};
    for i = 1:length(fw.subsystems)
        subsys = fw.subsystems(i); fname = regexprep(subsys.name, '[^a-zA-Z0-9]', '_');
        if isfield(subsys, 'outputs') && ~isempty(subsys.outputs) && ~isfield(usedOut, fname)
            issues{end+1} = sprintf('%s: outputs unused', subsys.name);
        end
        if isfield(subsys, 'inputs') && ~isempty(subsys.inputs) && ~isfield(usedIn, fname)
            issues{end+1} = sprintf('%s: inputs unused', subsys.name);
        end
    end
    if ~isempty(issues)
        r.passed = false; r.confidence = 0.5;
        r.issue = strjoin(issues, '; ');
        r.suggestion = 'Every subsystem Inport/Outport must appear in signalFlow or gotoFromPlan.';
    end
end
