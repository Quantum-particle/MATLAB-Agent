function result = sl_framework_approve(modelName, varargin)
% SL_FRAMEWORK_APPROVE Macro Framework Approval and Lock
%   result = sl_framework_approve(modelName)
%   result = sl_framework_approve(modelName, 'locked', true)
%   result = sl_framework_approve(modelName, 'macroFramework', fw)
%
% v11.0: 审批并锁定大框架，之后修改需要额外审批
%   - 将大框架写入 MATLAB workspace 变量 _macro_framework_<modelName>
%   - 设置锁定标记 framework_locked_<modelName> = true
%   - Bridge 层读取该标记，后续拦截对顶层架构的修改

    % ===== 参数解析 =====
    p = struct('locked', true, 'macroFramework', struct());
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

    % ===== 获取大框架（优先从参数，其次从 MATLAB workspace）=====
    model_safe = strrep(modelName, '/', '__');
    fw_var = ['mFW_' model_safe];
    if isempty(fieldnames(p.macroFramework))
        % 参数没有传入，尝试从 workspace 获取
        try
            fw = evalin('base', fw_var);
        catch
            result = struct('status', 'error', ...
                'message', sprintf('No macro framework found for model: %s. Call sl_framework_design first.', modelName));
            return;
        end
    else
        fw = p.macroFramework;
    end

    % ===== 写入大框架快照 =====
    snapshot_var = ['mFWSnap_' model_safe];
    assignin('base', snapshot_var, fw);

    % [P1-1 FIX] 审批后同时写入框架数据到 workspace
    assignin('base', fw_var, fw);

    % ===== [v11.8 NEW] Multi-level Hierarchy Validation =====
    if isfield(fw, 'subsystems')
        hierarchy_result = validate_hierarchy(modelName, fw.subsystems);
        if ~hierarchy_result.passed
            result = struct('status', 'error', ...
                'message', 'Hierarchy validation failed. Framework approval REJECTED.', ...
                'hierarchyIssues', {hierarchy_result.issues});
            return;
        end
        
        % Write hierarchy workspace variables
        hier_appr_var = ['mHierarchyApproved_' model_safe];
        assignin('base', hier_appr_var, true);
        
        max_depth = hierarchy_result.maxDepth;
        hier_depth_var = ['mHierarchyDepth_' model_safe];
        assignin('base', hier_depth_var, max_depth);
        
        total_nodes = hierarchy_result.totalNodes;
        hier_nodes_var = ['mHierarchyNodes_' model_safe];
        assignin('base', hier_nodes_var, total_nodes);
        
        % Store tree structure for Bridge persistence
        if isfield(fw, 'subsystems')
            hier_tree_var = ['mHierarchyTree_' model_safe];
            assignin('base', hier_tree_var, fw.subsystems);
        end
    end

    % ===== 写入锁定标记 =====
    lock_var = ['mFWLock_' model_safe];  % [P1-4 FIX] 统一命名: framework_locked_ → mFWLock_
    assignin('base', lock_var, p.locked);

    % ===== 记录审批时间 =====
    approve_time_var = ['mFWApprovedAt_' model_safe];  % [P1-4 FIX] 统一命名: fwApprovedAt_ → mFWApprovedAt_
    assignin('base', approve_time_var, sl_framework_utils('format_timestamp'));

    % ===== 返回结果 =====
    fwApprovedTs = sl_framework_utils('format_timestamp');
    result = struct('status', 'ok', ...
        'message', sprintf('Macro framework approved and locked for model: %s', modelName), ...
        'lockedAt', fwApprovedTs, ...
        'frameworkSnapshot', fw, ...
        'modelName', modelName, ...
        'locked', p.locked);
    
    % [v11.8] Add hierarchy info to result if available
    if exist('hierarchy_result', 'var')
        result.hierarchyApproved = true;
        result.maxDepth = hierarchy_result.maxDepth;
        result.totalNodes = hierarchy_result.totalNodes;
    end

    % ===== 打印确认信息 =====
    fprintf('[sl_framework_approve] Framework approved for model: %s\n', modelName);
    fprintf('[sl_framework_approve] Locked: %d\n', p.locked);
    fprintf('[sl_framework_approve] Subsystems: %d\n', length(fw.subsystems));
    if isfield(fw, 'signalFlow')
        fprintf('[sl_framework_approve] Signal flows: %d\n', length(fw.signalFlow));
    end
    if isfield(fw, 'gotoFromPlan') && ~isempty(fw.gotoFromPlan)
        fprintf('[sl_framework_approve] Goto/From plans: %d\n', length(fw.gotoFromPlan));
    end
    % [v11.8] Hierarchy info
    if exist('hierarchy_result', 'var')
        fprintf('[sl_framework_approve] Hierarchy depth: %d, Total nodes: %d\n', ...
            hierarchy_result.maxDepth, hierarchy_result.totalNodes);
    end
end

% ===== [v11.8 NEW] Multi-level Gate_5: Hierarchy Validation =====
function result = validate_hierarchy(modelName, subsystems)
    % Walk the entire subsystem tree and validate at EVERY level
    issues = {};
    
    [issues_out, max_depth, total_nodes] = validate_level(subsystems, modelName, issues, 0, 0, 1);
    
    passed = isempty(issues_out);
    result = struct('passed', passed, 'issues', {issues_out}, ...
        'maxDepth', max_depth, 'totalNodes', total_nodes);
end

function [issues, max_depth, total_nodes] = validate_level(subsystems, parent_path, issues, max_depth, total_nodes, depth)
    % Anti-recursion explosion safeguard
    if depth > 10
        issues{end+1} = sprintf('RECURSION LIMIT EXCEEDED at depth %d under %s', depth, parent_path);
        return;
    end
    
    % [RED] HARD DEPTH LIMIT: depth > 5
    if depth > 5
        issues{end+1} = sprintf('[RED] DEPTH EXCEEDED at %s: depth=%d, max=5. Framework APPROVAL REJECTED.', ...
            parent_path, depth);
        return;
    end
    
    if isempty(subsystems)
        return;
    end
    
    total_nodes = total_nodes + length(subsystems);
    if depth > max_depth
        max_depth = depth;
    end
    
    for i = 1:length(subsystems)
        if iscell(subsystems)
            sub = subsystems{i};
        else
            sub = subsystems(i);
        end
        level_path = [parent_path '/' sub.name];
        
        % [RED] Check: absolute depth limit before any other validation
        child_subs = [];
        if isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems)
            child_subs = sub.childSubsystems;
        end
        if ~isempty(child_subs) && depth + 1 > 5
            issues{end+1} = sprintf('[RED] DEPTH VIOLATION at %s: has children at depth %d (max 5). Approve BLOCKED.', ...
                level_path, depth + 1);
            return;
        end
        
        % Check port completeness at this level
        port_check = sl_check_port_completeness(sub);
        if ~port_check.passed
            issues{end+1} = sprintf('Port completeness failed at %s: %s', ...
                level_path, port_check.issue);
        end
        
        % Check signal closure at this level
        sig_check = sl_check_signal_closure(sub);
        if ~sig_check.passed
            issues{end+1} = sprintf('Signal closure failed at %s: %s', ...
                level_path, sig_check.issue);
        end
        
        % Recurse into children
        if ~isempty(child_subs)
            [issues, max_depth, total_nodes] = validate_level(child_subs, level_path, issues, max_depth, total_nodes, depth + 1);
        end
    end
end