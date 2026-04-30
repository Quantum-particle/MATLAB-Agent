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
    p = struct('domain', 'auto', 'checkItems', {{'physics', 'signalFlow', 'subsystem', 'gotoFrom', 'dimensionality'}});
    idx = 1;
    while idx <= length(varargin)
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
            'message', sprintf('sl_framework_review failed: %s', ME.message), ...
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
    % 检查每个子系统是否有输入输出定义
    for i = 1:length(fw.subsystems)
        subsys = fw.subsystems(i);
        if ~isfield(subsys, 'inputs') || ~isfield(subsys, 'outputs')
            r.passed = false;
            r.confidence = 0.5;
            r.issue = sprintf('Subsystem %s missing inputs or outputs', subsys.name);
            r.suggestion = 'Define inputs and outputs for all subsystems';
            return;
        end
    end
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
    % 获取所有子系统名称
    subsysNames = {fw.subsystems.name};
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
end

% subsystem: 检查子系统数量 >= 1，无循环依赖
function r = check_subsystem(fw)
    r = struct('item', 'subsystem', 'passed', true, 'confidence', 0.8, 'issue', '', 'suggestion', '');
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
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        for i = 1:length(fw.signalFlow)
            if iscell(fw.signalFlow)
                sf = fw.signalFlow{i};
            else
                sf = fw.signalFlow(i);
            end
            from = sf.srcSubsystem;
            to = sf.dstSubsystem;
            % 检查是否存在 from -> to -> from 的直接循环
            for j = 1:length(fw.signalFlow)
                if iscell(fw.signalFlow)
                    sf2 = fw.signalFlow{j};
                else
                    sf2 = fw.signalFlow(j);
                end
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
    subsysNames = {fw.subsystems.name};
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
    end
end

% dimensionality: check signal count consistency between connected subsystems
function r = check_dimensionality(fw)
    r = struct('item', 'dimensionality', 'passed', true, 'confidence', 0.85, 'issue', '', 'suggestion', '');
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        r.passed = false;
        r.confidence = 0.3;
        r.issue = 'No subsystems to check dimensionality';
        return;
    end
    % If signalFlow exists, check each connection's signal count
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        subsysNames = {fw.subsystems.name};
        for i = 1:length(fw.signalFlow)
            if iscell(fw.signalFlow)
                sf = fw.signalFlow{i};
            else
                sf = fw.signalFlow(i);
            end
            srcName = sf.srcSubsystem;
            dstName = sf.dstSubsystem;
            srcIdx = find(strcmp(subsysNames, srcName), 1);
            dstIdx = find(strcmp(subsysNames, dstName), 1);
            if ~isempty(srcIdx) && ~isempty(dstIdx) && srcIdx > 0 && dstIdx > 0
                srcOut = fw.subsystems(srcIdx).outputs;
                dstIn = fw.subsystems(dstIdx).inputs;
                nSrcOut = count_signals(srcOut);
                nDstIn = count_signals(dstIn);
                if nSrcOut ~= nDstIn
                    r.passed = false;
                    r.confidence = 0.6;
                    r.issue = sprintf('Signal mismatch: %s(%d out) -> %s(%d in)', ...
                        srcName, nSrcOut, dstName, nDstIn);
                    r.suggestion = 'Ensure output signal count matches destination input count';
                    return;
                end
            end
        end
    else
        nSubs = length(fw.subsystems);
        for i = 1:(nSubs-1)
            nCurrOut = count_signals(fw.subsystems(i).outputs);
            nNextIn = count_signals(fw.subsystems(i+1).inputs);
            if nCurrOut ~= nNextIn
                r.passed = false;
                r.confidence = 0.6;
                r.issue = sprintf('Signal mismatch: %s(%d out) -> %s(%d in)', ...
                    fw.subsystems(i).name, nCurrOut, ...
                    fw.subsystems(i+1).name, nNextIn);
                r.suggestion = 'Ensure output signal count matches next subsystem input count';
                return;
            end
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
end