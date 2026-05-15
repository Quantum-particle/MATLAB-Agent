function result = sl_framework_review(taskDescription, varargin)
% SL_FRAMEWORK_REVIEW Macro Framework Self-Review
%   result = sl_framework_review(taskDescription, 'domain', 'mechanical')
%   result = sl_framework_review(taskDescription, 'checkItems', {'physics', 'signalFlow'})
%   result = sl_framework_review(macroFrameworkStruct)  % pass struct directly
%
% v11.1: AI 自检大框架，输出检查结果和建议
%   - physics: 物理方程是否正确
%   - signalFlow: 信号流拓扑是否完备
%   - subsystem: 子系统划分是否合理
%   - gotoFrom: Goto/From 标签计划
%   - dimensionality: 量纲一致性

    % ===== Input Validation (P0-3 FIX) =====
    if nargin < 1
        result = struct('status', 'error', ...
            'message', 'sl_framework_review: taskDescription or macroFramework is required');
        return;
    end
    % Validate taskDescription type
    if ~isstruct(taskDescription) && ~ischar(taskDescription) && ~isstring(taskDescription)
        result = struct('status', 'error', ...
            'message', 'sl_framework_review: taskDescription must be a struct or string');
        return;
    end

    try
    % ===== 参数解析 =====
    % v11.8: 11 check items (original 5 + 6 hierarchy checks: Check 12-17)
    p = struct('domain', 'auto', 'checkItems', {{'physics', 'signalFlow', 'subsystem', 'gotoFrom', 'dimensionality', ...
        'nestingDepth', 'singleBlock', 'cohesion', 'crossLevelInterface', 'treeCompleteness', 'leafSubsystems'}});
    idx = 1;
    while idx <= length(varargin)
        % [v11.8.1 FIX] Convert string to char for REST API compatibility
        if isstring(varargin{idx})
            varargin{idx} = char(varargin{idx});
        end
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if isfield(p, key)
                p.(key) = val;
            end
            idx = idx + 2;
        else
            idx = idx + 1;
        end
    end

    % 如果 taskDescription 是 struct，直接作为 macroFramework 审查
    if isstruct(taskDescription)
        macroFramework = taskDescription;
    else
        % [P2-1 FIX] 优先从 workspace 读取已存在的框架，避免意外重新设计
        % 旧代码: macroFramework = sl_framework_design(taskDescription, 'domain', p.domain);
        % 问题: 意外触发重新设计，覆盖已审批的 workspace 变量
        taskStr = char(taskDescription);
        fw_var = ['mFW_' taskStr];
        fw_exists = evalin('base', sprintf('exist(''%s'', ''var'')', fw_var));
        if fw_exists
            macroFramework = evalin('base', fw_var);
        else
            result = struct('status', 'error', ...
                'message', sprintf('sl_framework_review: no existing framework found for "%s". Pass struct or call sl_framework_design first.', taskStr));
            return;
        end
    end
    
    % [v11.6.8] Normalize: ensure struct arrays for (i) indexing compatibility.
    % Uses global sl_fw_normalize utility (idempotent — no-op for struct arrays).
    macroFramework = sl_fw_normalize(macroFramework);

    % ===== 执行检查 =====
    checks = cell(length(p.checkItems), 1);
    checkIdx = 1;

    for i = 1:length(p.checkItems)
        item = p.checkItems{i};
        switch item
            case 'physics'
                checks{checkIdx} = check_physics(macroFramework);
                checkIdx = checkIdx + 1;
            case 'signalFlow'
                checks{checkIdx} = check_signal_flow(macroFramework);
                checkIdx = checkIdx + 1;
            case 'subsystem'
                checks{checkIdx} = check_subsystem(macroFramework);
                checkIdx = checkIdx + 1;
            case 'gotoFrom'
                checks{checkIdx} = check_goto_from(macroFramework);
                checkIdx = checkIdx + 1;
            case 'dimensionality'
                checks{checkIdx} = check_dimensionality(macroFramework);
                checkIdx = checkIdx + 1;
            % [v11.4 opt-in] standalone checks for port/signal completeness
            case 'port_completeness'
                checks{checkIdx} = sl_check_port_completeness(macroFramework);
                checkIdx = checkIdx + 1;
            case 'signal_closure'
                checks{checkIdx} = sl_check_signal_closure(macroFramework);
                checkIdx = checkIdx + 1;
            % [v11.8 NEW] Recursive hierarchy checks (Check 12-17)
            case 'nestingDepth'
                checks{checkIdx} = check_nesting_depth(macroFramework);
                checkIdx = checkIdx + 1;
            case 'singleBlock'
                checks{checkIdx} = check_single_block_subsystems(macroFramework);
                checkIdx = checkIdx + 1;
            case 'cohesion'
                checks{checkIdx} = check_subsystem_cohesion(macroFramework);
                checkIdx = checkIdx + 1;
            case 'crossLevelInterface'
                checks{checkIdx} = check_cross_level_interface(macroFramework);
                checkIdx = checkIdx + 1;
            case 'treeCompleteness'
                checks{checkIdx} = check_tree_completeness(macroFramework);
                checkIdx = checkIdx + 1;
            case 'leafSubsystems'
                checks{checkIdx} = check_leaf_subsystems(macroFramework);
                checkIdx = checkIdx + 1;
        end
    end

    % ===== 汇总结果 =====
    passedFlags = zeros(length(checks), 1);
    confidences = zeros(length(checks), 1);
    for i = 1:length(checks)
        passedFlags(i) = checks{i}.passed;
        confidences(i) = checks{i}.confidence;
    end
    allPassed = all(passedFlags);
    overallConfidence = mean(confidences);

    issues = {};
    suggestions = {};
    for i = 1:length(checks)
        if ~checks{i}.passed
            issues{end+1} = checks{i}.issue;
        end
        if isfield(checks{i}, 'suggestion') && ~isempty(checks{i}.suggestion)
            suggestions{end+1} = checks{i}.suggestion;
        end
    end

    result = struct('status', 'ok', ...
        'reviewResult', struct('passed', allPassed, ...
                               'checks', checks, ...
                               'overallConfidence', overallConfidence, ...
                               'issues', {issues}, ...
                               'suggestions', {suggestions}));

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_review failed at line %d: %s', ME.stack(1).line, ME.message), ...
            'identifier', ME.identifier);
    end
end

% ===== 检查项子函数 =====

% physics: 检查物理方程是否存在、有界、无奇异
function r = check_physics(fw)
    r = struct('item', 'physics', 'passed', true, 'confidence', 0.9, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'No subsystems defined in framework';
        r.suggestion = 'Define at least one subsystem with inputs and outputs';
        return;
    end
    % [v11.8.3 Bug#9 FIX] Use sl_safe_index for cell/struct array compatibility
    % 检查每个子系统是否有输入输出定义
    for i = 1:length(fw.subsystems)
        subsys = sl_safe_index(fw.subsystems, i);
        if ~isfield(subsys, 'inputs') || ~isfield(subsys, 'outputs')
            r.passed = false;
            r.confidence = 0.5;
            r.issue = sprintf('Subsystem %d missing inputs or outputs', i);
            r.suggestion = 'Define inputs and outputs for all subsystems';
            return;
        end
    end
end
% ===== [v11.8 NEW] Check 12: Nesting Depth =====
function r = check_nesting_depth(fw)
    r = struct('item', 'nestingDepth', 'passed', true, 'confidence', 0.95, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.confidence = 0.9;
        r.issue = 'No subsystems to check depth';
        return;
    end
    max_depth = compute_tree_depth(fw.subsystems, 1);
    if max_depth > 5
        r.passed = false;
        r.confidence = 0.0;
        r.issue = sprintf('SUBSYSTEM DEPTH EXCEEDED: %d levels (max 5). Design REJECTED.', max_depth);
        r.suggestion = 'Reduce nesting to <=5 levels. Flatten deepest layers or use Model Reference for sub-components.';
    elseif max_depth == 5
        r.passed = true;
        r.confidence = 0.5;
        r.issue = sprintf('Nesting depth is at maximum (5). Verify functional justification for every level.');
        r.suggestion = 'Depth 5 is the absolute limit. Ensure each level is functionally necessary.';
    elseif max_depth > 3
        r.passed = true;
        r.confidence = 0.6;
        r.issue = sprintf('Nesting depth is %d (recommended <= 3). Verify functional justification.', max_depth);
        r.suggestion = 'Ensure each nesting level has a clear functional purpose.';
    else
        r.confidence = 0.9;
        r.issue = sprintf('Max nesting depth: %d (within recommended range)', max_depth);
    end
end

% [v11.8.1 Bug#1 FIX] compute_tree_depth — per-element isfield + try/catch
function d = compute_tree_depth(subsystems, current_depth)
    if isempty(subsystems)
        d = current_depth - 1;
        return;
    end
    max_child_depth = current_depth;
    for i = 1:length(subsystems)
        child_subs = [];
        try
            if iscell(subsystems)
                elem = subsystems{i};
            else
                elem = subsystems(i);
            end
            if isstruct(elem) && isfield(elem, 'childSubsystems') && ~isempty(elem.childSubsystems)
                child_subs = elem.childSubsystems;
            end
        catch
            child_subs = [];
        end
        if ~isempty(child_subs)
            child_depth = compute_tree_depth(child_subs, current_depth + 1);
            max_child_depth = max(max_child_depth, child_depth);
        end
    end
    d = max_child_depth;
end

% signalFlow: 检查信号流连通性、无孤立节点
function r = check_signal_flow(fw)
    r = struct('item', 'signalFlow', 'passed', true, 'confidence', 0.95, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'No subsystems to build signal flow';
        r.suggestion = 'Define subsystems first';
        return;
    end
    % [v11.8.3 Bug#9 FIX] Use sl_safe_index for cell/struct array compatibility
    % 获取所有子系统名称
    n_subs = length(fw.subsystems);
    subsysNames = cell(1, n_subs);
    for i_s = 1:n_subs
        s = sl_safe_index(fw.subsystems, i_s);
        subsysNames{i_s} = s.name;
    end
    n = length(subsysNames);

    if n == 0
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'Empty subsystem list';
        return;
    end

    % 如果没有显式 signalFlow，生成默认的链式连接
    if ~isfield(fw, 'signalFlow') || isempty(fw.signalFlow)
        % 默认按顺序链式连接
        r.confidence = 0.8;
        r.suggestion = 'No explicit signalFlow defined; default chain connection assumed';
        return;
    end

    % 检查 signalFlow 中的连接是否有效
    signalFlow = fw.signalFlow;
    connectedFrom = {};
    connectedTo = {};
    for i = 1:length(signalFlow)
        if iscell(signalFlow)
            sf = signalFlow{i};
        else
            sf = signalFlow(i);
        end
        % [v11.8.2 Bug#2 FIX] 向后兼容: 自动映射 src/dst → srcSubsystem/dstSubsystem
        if ~isfield(sf, 'srcSubsystem') && isfield(sf, 'src')
            sf.srcSubsystem = sf.src;
        end
        if ~isfield(sf, 'dstSubsystem') && isfield(sf, 'dst')
            sf.dstSubsystem = sf.dst;
        end
        from = sf.srcSubsystem;
        to = sf.dstSubsystem;
        connectedFrom{end+1} = from;
        connectedTo{end+1} = to;
    end

    % 检查是否有孤立节点（既没有输出也没有输入）
    allConnected = unique([connectedFrom, connectedTo]);
    isolated = setdiff(subsysNames, allConnected);
    if ~isempty(isolated)
        r.passed = false;
        r.confidence = 0.6;
        r.issue = sprintf('Isolated subsystem(s): %s', sl_framework_utils('strjoin_safe', isolated, ', '));
        r.suggestion = 'Connect isolated subsystems or remove them from framework';
    end
    
    % [v11.9 Bug#24 FIX] Recursively check childSubsystems for internal signalFlow
    subtree_issues = {};
    for i_s = 1:n_subs
        s = sl_safe_index(fw.subsystems, i_s);
        if isfield(s, 'childSubsystems') && ~isempty(s.childSubsystems)
            % This is a container subsystem — it SHOULD have internal signalFlow
            if ~isfield(s, 'signalFlow') || isempty(s.signalFlow)
                subtree_issues{end+1} = sprintf('%s (container, no internal signalFlow)', s.name);
            else
                % Verify all child subsystems appear in internal signalFlow
                child_names = {};
                for j_c = 1:length(s.childSubsystems)
                    cs = sl_safe_index(s.childSubsystems, j_c);
                    child_names{end+1} = cs.name;
                end
                child_in_flow = {};
                for j_sf = 1:length(s.signalFlow)
                    sf = sl_safe_index(s.signalFlow, j_sf);
                    child_in_flow{end+1} = sf.srcSubsystem;
                    child_in_flow{end+1} = sf.dstSubsystem;
                end
                missing = setdiff(child_names, unique(child_in_flow));
                if ~isempty(missing)
                    subtree_issues{end+1} = sprintf('%s: child(ren) missing from signalFlow: %s', ...
                        s.name, sl_framework_utils('strjoin_safe', missing, ', '));
                end
            end
        end
    end
    if ~isempty(subtree_issues)
        r.confidence = max(0.4, r.confidence - 0.3);
        if isempty(r.issue)
            r.issue = '';
        else
            r.issue = [r.issue '; '];
        end
        r.issue = [r.issue 'Subtree signalFlow: ' sl_framework_utils('strjoin_safe', subtree_issues, ' | ')];
        r.suggestion = 'Define internal signalFlow for container subsystems with childSubsystems';
    end
end

% subsystem: 检查子系统数量 >= 1，无循环依赖
function r = check_subsystem(fw)
    r = struct('item', 'subsystem', 'passed', true, 'confidence', 0.8, 'issue', '', 'suggestion', '');
    try
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'No subsystems defined';
        r.suggestion = 'Define at least one subsystem';
        return;
    end
    n = length(fw.subsystems);
    if n < 1
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'At least one subsystem required';
        return;
    end
    % 检查重复名称
    names = {fw.subsystems.name};
    if length(unique(names)) ~= length(names)
        r.passed = false;
        r.confidence = 0.5;
        r.issue = 'Duplicate subsystem names found';
        r.suggestion = 'Use unique names for each subsystem';
        return;
    end
    % 检查循环依赖（简化版：检查直接的环形连接）
    % [v11.8.2 Bug#4 FIX] Inline has_valid_signalflow check to avoid scope issue
    has_sf = false;
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        sf_temp = fw.signalFlow;
        if isstruct(sf_temp)
            has_sf = true;
        elseif iscell(sf_temp)
            for si = 1:numel(sf_temp)
                if isstruct(sf_temp{si}), has_sf = true; break; end
            end
        end
    end
    if has_sf
        for i = 1:length(fw.signalFlow)
            if iscell(fw.signalFlow)
                sf = fw.signalFlow{i};
            else
                sf = fw.signalFlow(i);
            end
            if ~isstruct(sf), continue; end
            from = sf.srcSubsystem;
            to = sf.dstSubsystem;
            % 检查是否存在 from -> to -> from 的直接循环
            for j = 1:length(fw.signalFlow)
                if iscell(fw.signalFlow)
                    sf2 = fw.signalFlow{j};
                else
                    sf2 = fw.signalFlow(j);
                end
                if ~isstruct(sf2), continue; end
                from2 = sf2.srcSubsystem;
                to2 = sf2.dstSubsystem;
                if strcmp(to, from2) && strcmp(from, to2)
                    r.passed = false;
                    r.confidence = 0.6;
                    r.issue = sprintf('Circular dependency detected between %s and %s', from, to);
                    r.suggestion = 'Remove circular dependencies in signal flow';
                    return;
                end
            end
        end
    end
    catch ME
        r.passed = false;
        r.confidence = 0;
        r.issue = sprintf('SUBSYS_ERR line %d: %s', ME.stack(1).line, ME.message);
    end
end

% gotoFrom: 检查 Goto/From 标签成对
function r = check_goto_from(fw)
    r = struct('item', 'gotoFrom', 'passed', true, 'confidence', 1.0, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'gotoFromPlan') || isempty(fw.gotoFromPlan)
        % 没有 Goto/From 计划，这是合法的
        r.confidence = 0.9;
        return;
    end
    % 检查标签是否唯一
    nGf = length(fw.gotoFromPlan);
    tags = cell(nGf, 1);
    for i = 1:nGf
        if iscell(fw.gotoFromPlan)
            gf = fw.gotoFromPlan{i};
        else
            gf = fw.gotoFromPlan(i);
        end
        tags{i} = gf.tag;
    end
    if length(unique(tags)) ~= length(tags)
        r.passed = false;
        r.confidence = 0.7;
        r.issue = 'Duplicate Goto/From tag names';
        r.suggestion = 'Use unique tag names for each Goto/From pair';
        return;
    end
    % 检查每个 Goto 是否有对应的 From
    % [v11.8.3 Bug#9 FIX] Use sl_safe_index for cell/struct array compatibility
    n_s = length(fw.subsystems);
    subsysNames = cell(1, n_s);
    for i_s = 1:n_s
        s = sl_safe_index(fw.subsystems, i_s);
        subsysNames{i_s} = s.name;
    end
    for i = 1:nGf
        if iscell(fw.gotoFromPlan)
            gf = fw.gotoFromPlan{i};
        else
            gf = fw.gotoFromPlan(i);
        end
        srcSubsystem = gf.srcSubsystem;
        dstSubsystems = gf.dstSubsystems;
        % 检查 srcSubsystem 是否存在
        if ~any(strcmp(subsysNames, srcSubsystem))
            r.passed = false;
            r.confidence = 0.6;
            r.issue = sprintf('Goto source "%s" not found in subsystems', srcSubsystem);
            r.suggestion = 'Ensure Goto source subsystem exists';
            return;
        end
        % 检查 dstSubsystems 列表是否存在
        if iscell(dstSubsystems)
            for j = 1:length(dstSubsystems)
                if ~any(strcmp(subsysNames, dstSubsystems{j}))
                    r.passed = false;
                    r.confidence = 0.6;
                    r.issue = sprintf('Goto destination "%s" not found in subsystems', dstSubsystems{j});
                    r.suggestion = 'Ensure all Goto destination subsystems exist';
                    return;
                end
            end
        end
        % [P1-5 FIX] Check for cross-subsystem Goto/From usage (R2 enforcement)
        % If srcSubsystem != dstSubsystem(s), this is a cross-boundary violation
        % Goto/From must ONLY be used within a single subsystem
        if isfield(gf, 'srcSubsystem') && isfield(gf, 'dstSubsystems')
            dstList = gf.dstSubsystems;
            if iscell(dstList)
                for j = 1:length(dstList)
                    if ~strcmp(srcSubsystem, dstList{j})
                        r.passed = false;
                        r.confidence = 0.5;
                        r.issue = sprintf('CROSS-BOUNDARY: Goto tag "%s" spans from "%s" to "%s". Goto/From must NOT cross subsystem boundaries. Use Inport/Outport for subsystem interfaces.', gf.tag, srcSubsystem, dstList{j});
                        r.suggestion = 'Replace Goto/From with Inport/Outport standard interfaces between subsystems.';
                        return;
                    end
                end
            end
        end
    end
    % [P1-5 FIX] Also check the new format: gotoFromPlan with usedWithinSubsystem
    % If usedWithinSubsystem is specified, validate it exists in subsystems list
    for i = 1:nGf
        if iscell(fw.gotoFromPlan)
            gf = fw.gotoFromPlan{i};
        else
            gf = fw.gotoFromPlan(i);
        end
        if isfield(gf, 'usedWithinSubsystem') && ~isempty(gf.usedWithinSubsystem)
            if ~any(strcmp(subsysNames, gf.usedWithinSubsystem))
                r.passed = false;
                r.confidence = 0.6;
                r.issue = sprintf('Goto/From scope "%s" not found in subsystems list', gf.usedWithinSubsystem);
                r.suggestion = sprintf('Ensure usedWithinSubsystem references an existing subsystem: %s', sl_framework_utils('strjoin_safe', subsysNames, ', '));
                return;
            end
        end
        % [P1-5/R2-3 FIX v11.7] Check dstBlocks for cross-boundary violations
        % If any dstBlock references a subsystem name, it's a cross-boundary Goto/From
        if isfield(gf, 'dstBlocks') && ~isempty(gf.dstBlocks)
            dstBlocks = gf.dstBlocks;
            if ischar(dstBlocks)
                dstBlocks = {dstBlocks};
            end
            if iscell(dstBlocks)
                for db = 1:length(dstBlocks)
                    dst = dstBlocks{db};
                    if ischar(dst) && any(strcmp(dst, subsysNames))
                        r.passed = false;
                        r.confidence = 0.0;
                        r.issue = sprintf('CROSS-BOUNDARY: Goto tag "%s" targets subsystem "%s". Goto/From cannot cross subsystem boundaries.', gf.tag, dst);
                        r.suggestion = 'Use Inport/Outport for subsystem-to-subsystem signals. Goto/From is only for within-subsystem local routing.';
                        return;
                    end
                end
            end
        end
    end
end

% dimensionality: check signal count consistency between connected subsystems
% [v11.8.1 Bug#2 FIX] Aggregate per destination to support multi-source topologies
function r = check_dimensionality(fw)
    r = struct('item', 'dimensionality', 'passed', true, 'confidence', 0.85, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'No subsystems to check dimensionality';
        return;
    end
    % If signalFlow exists and has valid entries, aggregate per destination
    % [v11.8.3 Bug#9 FIX] Use sl_safe_index for cell/struct array compatibility
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        n_s = length(fw.subsystems);
        subsysNames = cell(1, n_s);
        for i_s = 1:n_s
            s = sl_safe_index(fw.subsystems, i_s);
            subsysNames{i_s} = s.name;
        end
        % Phase 1: Aggregate signal counts per destination from signalFlow entries
        % [v11.8.3 Bug#13 FIX] Count signals per signalFlow entry (signalName), not all source outputs.
        % Previous code counted ALL outputs of the source subsystem for each entry,
        % causing massive over-counting (e.g., 13 vs 4 for ADRC_Rate_Controller).
        dstAggregated = containers.Map('KeyType', 'char', 'ValueType', 'double');
        for i = 1:length(fw.signalFlow)
            if iscell(fw.signalFlow)
                sf = fw.signalFlow{i};
            else
                sf = fw.signalFlow(i);
            end
            dstName = sf.dstSubsystem;
            % Count signals in this specific signalFlow entry (comma-separated or single)
            if isfield(sf, 'signalName') && ~isempty(sf.signalName)
                nSignals = count_signals(sf.signalName);
            else
                nSignals = 1;
            end
            if isKey(dstAggregated, dstName)
                dstAggregated(dstName) = dstAggregated(dstName) + nSignals;
            else
                dstAggregated(dstName) = nSignals;
            end
        end
        % Phase 2: Compare aggregated source count vs destination input count
        dstKeys = keys(dstAggregated);
        for k = 1:length(dstKeys)
            dstName = dstKeys{k};
            dstIdx = find(strcmp(subsysNames, dstName), 1);
            if ~isempty(dstIdx) && dstIdx > 0
                totalSrcOut = dstAggregated(dstName);
                nDstIn = count_signals(sl_safe_index(fw.subsystems, dstIdx).inputs);
                if totalSrcOut ~= nDstIn
                    r.passed = false;
                    r.confidence = 0.5;
                    r.issue = sprintf('Signal mismatch: %d signals from all sources -> %s(%d in)', ...
                        totalSrcOut, dstName, nDstIn);
                    r.suggestion = 'Total signal count from all source subsystems must match destination input count.';
                    return;
                end
            end
        end
    else
        nSubs = length(fw.subsystems);
        for i = 1:(nSubs-1)
            curr = sl_safe_index(fw.subsystems, i);
            next = sl_safe_index(fw.subsystems, i+1);
            nCurrOut = count_signals(curr.outputs);
            nNextIn = count_signals(next.inputs);
            if nCurrOut ~= nNextIn
                r.passed = false;
                r.confidence = 0.6;
                r.issue = sprintf('Signal mismatch: %s(%d out) -> %s(%d in)', ...
                    curr.name, nCurrOut, ...
                    next.name, nNextIn);
                r.suggestion = 'Ensure output signal count matches next subsystem input count';
                return;
            end
        end
    end
end

% ===== [v11.8 NEW] Check 13: Single Block Subsystems =====
function r = check_single_block_subsystems(fw)
    r = struct('item', 'singleBlockSubsystems', 'passed', true, 'confidence', 0.85, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        return;
    end
    single_block_subs = {};
    find_single_block_in_tree(fw.subsystems, '', single_block_subs);
    if ~isempty(single_block_subs)
        r.passed = false;
        r.confidence = 0.4;
        subs_list = '';
        for idx = 1:length(single_block_subs)
            if idx == 1
                subs_list = single_block_subs{idx};
            else
                subs_list = [subs_list ', ' single_block_subs{idx}]; %#ok<AGROW>
            end
        end
        r.issue = sprintf('%d subsystem(s) appear to have minimal internal structure: %s', ...
            length(single_block_subs), subs_list);
        r.suggestion = 'Remove single-block subsystems (MAAB db_0037) or add internal blocks.';
    end
end

function find_single_block_in_tree(subsystems, parent_path, results)
    if isempty(subsystems), return; end
    for i = 1:length(subsystems)
        sub = sl_safe_index(subsystems, i);  % [v11.8.2 Bug#3 FIX] 统一 cell/struct 索引
        path = sub.name;
        if ~isempty(parent_path)
            path = [parent_path '/' sub.name]; %#ok<AGROW>
        end
        has_children = isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems);
        if ~has_children
            results{end+1} = path; %#ok<AGROW>
        else
            find_single_block_in_tree(sub.childSubsystems, path, results);
        end
    end
end

% ===== [v11.8 NEW] Check 14: Subsystem Cohesion =====
function r = check_subsystem_cohesion(fw)
    r = struct('item', 'subsystemCohesion', 'passed', true, 'confidence', 0.8, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        return;
    end
    issues = {};
    check_cohesion_recursive(fw.subsystems, '', issues);
    if ~isempty(issues)
        r.passed = false;
        r.confidence = 0.5;
        iss_str = '';
        for idx = 1:length(issues)
            if idx == 1, iss_str = issues{idx};
            else, iss_str = [iss_str '; ' issues{idx}]; %#ok<AGROW>
            end
        end
        r.issue = sprintf('Cohesion issues: %s', iss_str);
        r.suggestion = 'Each subsystem should have a single, well-defined function (MAAB db_0038).';
    end
end

function check_cohesion_recursive(subsystems, parent_path, issues)
    for i = 1:length(subsystems)
        sub = sl_safe_index(subsystems, i);  % [v11.8.2 Bug#3 FIX] 统一 cell/struct 索引
        path = sub.name;
        if ~isempty(parent_path)
            path = [parent_path '/' sub.name]; %#ok<AGROW>
        end
        has_children = isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems);
        if has_children && (~isfield(sub, 'role') || isempty(sub.role))
            issues{end+1} = sprintf('%s has child subsystems but no role defined', path);
        end
        if has_children && length(sub.childSubsystems) > 5
            issues{end+1} = sprintf('%s has %d children (may indicate weak cohesion)', ...
                path, length(sub.childSubsystems));
        end
        if has_children
            check_cohesion_recursive(sub.childSubsystems, path, issues);
        end
    end
end

% ===== [v11.8 NEW] Check 15: Cross-Level Interface =====
function r = check_cross_level_interface(fw)
    r = struct('item', 'crossLevelInterface', 'passed', true, 'confidence', 0.85, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        return;
    end
    issues = {};
    check_interface_recursive(fw.subsystems, '', issues);
    if ~isempty(issues)
        r.passed = false;
        r.confidence = 0.5;
        iss_str = '';
        for idx = 1:length(issues)
            if idx == 1, iss_str = issues{idx};
            else, iss_str = [iss_str '; ' issues{idx}]; %#ok<AGROW>
            end
        end
        r.issue = sprintf('Interface issues: %s', iss_str);
        r.suggestion = 'Children I/O must be compatible with parent interface.';
    end
end

function check_interface_recursive(subsystems, parent_path, issues)
    for i = 1:length(subsystems)
        sub = sl_safe_index(subsystems, i);  % [v11.8.2 Bug#3 FIX] 统一 cell/struct 索引
        path = sub.name;
        if ~isempty(parent_path)
            path = [parent_path '/' sub.name]; %#ok<AGROW>
        end
        if isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems)
            % Count child outputs without arrayfun (R2016a compat)
            total_child_outputs = 0;
            for cj = 1:length(sub.childSubsystems)
                if iscell(sub.childSubsystems)
                    child = sub.childSubsystems{cj};
                else
                    child = sub.childSubsystems(cj);
                end
                if isfield(child, 'outputs') && iscell(child.outputs)
                    total_child_outputs = total_child_outputs + length(child.outputs);
                end
            end
            parent_outputs = 0;
            if isfield(sub, 'outputs') && iscell(sub.outputs)
                parent_outputs = length(sub.outputs);
            end
            if total_child_outputs < parent_outputs
                issues{end+1} = sprintf('%s: %d parent outputs but children only produce %d', ...
                    path, parent_outputs, total_child_outputs);
            end
            check_interface_recursive(sub.childSubsystems, path, issues);
        end
    end
end

% ===== [v11.8 NEW] Check 16: Tree Completeness =====
function r = check_tree_completeness(fw)
    r = struct('item', 'treeCompleteness', 'passed', true, 'confidence', 0.9, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        return;
    end
    all_paths = {};
    collect_paths(fw.subsystems, '', all_paths);
    if length(all_paths) < 2, return; end
    for i = 1:length(all_paths)
        for j = i+1:length(all_paths)
            if strcmp(all_paths{i}, all_paths{j})
                r.passed = false;
                r.confidence = 0.3;
                r.issue = sprintf('Duplicate subsystem path: %s', all_paths{i});
                r.suggestion = 'Each subsystem must have a unique path in the hierarchy.';
                return;
            end
        end
    end
end

function collect_paths(subsystems, parent_path, results)
    if isempty(subsystems), return; end
    for i = 1:length(subsystems)
        sub = sl_safe_index(subsystems, i);  % [v11.8.2 Bug#3 FIX] 统一 cell/struct 索引
        path = sub.name;
        if ~isempty(parent_path)
            path = [parent_path '/' sub.name]; %#ok<AGROW>
        end
        results{end+1} = path;
        if isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems)
            collect_paths(sub.childSubsystems, path, results);
        end
    end
end

% ===== [v11.8 NEW] Check 17: Leaf Subsystems =====
function r = check_leaf_subsystems(fw)
    r = struct('item', 'leafSubsystems', 'passed', true, 'confidence', 0.85, ...
               'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        return;
    end
    empty_leaves = {};
    find_empty_leaves(fw.subsystems, '', empty_leaves);
    if ~isempty(empty_leaves)
        r.passed = false;
        r.confidence = 0.4;
        el_str = '';
        for idx = 1:length(empty_leaves)
            if idx == 1, el_str = empty_leaves{idx};
            else, el_str = [el_str ', ' empty_leaves{idx}]; %#ok<AGROW>
            end
        end
        r.issue = sprintf('%d leaf subsystem(s) have no defined internal blocks or interfaces: %s', ...
            length(empty_leaves), el_str);
        r.suggestion = 'Each leaf subsystem should have at least physics equations or block plan.';
    end
end

function find_empty_leaves(subsystems, parent_path, results)
    if isempty(subsystems), return; end
    for i = 1:length(subsystems)
        sub = sl_safe_index(subsystems, i);  % [v11.8.2 Bug#3 FIX] 统一 cell/struct 索引
        path = sub.name;
        if ~isempty(parent_path)
            path = [parent_path '/' sub.name]; %#ok<AGROW>
        end
        has_children = isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems);
        if ~has_children
            has_inputs = isfield(sub, 'inputs') && ~isempty(sub.inputs);
            has_outputs = isfield(sub, 'outputs') && ~isempty(sub.outputs);
            if ~has_inputs && ~has_outputs
                results{end+1} = path;
            end
        else
            find_empty_leaves(sub.childSubsystems, path, results);
        end
    end
end

function n = count_signals(sigStr)
% Count signals in a string or cell array
    if isempty(sigStr)
        n = 0;
    elseif iscell(sigStr)
        n = length(sigStr);
    elseif ischar(sigStr) || isstring(sigStr)
        n = length(strfind(sigStr, ',')) + 1;
    else
        n = 1;
    end
end  % [v11.8.2 Bug#4 FIX] count_signals end for all-functions consistency

% [v11.8.1 NEW] [v11.8.2 DEPRECATED] has_valid_signalflow
% This function has been inlined into check_subsystem() due to scope issues (Bug#4).
% Retained for reference; not called anywhere in current code.
function tf = has_valid_signalflow(sf)  %#ok<DEFNU>
    tf = false;
    if ~iscell(sf) && ~isstruct(sf), return; end
    if isstruct(sf), tf = true; return; end
    for i = 1:numel(sf)
        if isstruct(sf{i}), tf = true; return; end
    end
end  % [v11.8.2 Bug#4 FIX] has_valid_signalflow end for all-functions consistency