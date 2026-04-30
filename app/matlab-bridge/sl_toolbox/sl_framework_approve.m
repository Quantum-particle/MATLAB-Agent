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
    fw_var = ['mFW_' modelName];
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
    snapshot_var = ['mFWSnap_' modelName];
    assignin('base', snapshot_var, fw);

    % [P1-1 FIX] 审批后同时写入框架数据到 workspace
    % 确保 Bridge _get_workflow_state 和后续 sl_micro_design 能读取
    assignin('base', fw_var, fw);

    % ===== 写入锁定标记 =====
    lock_var = ['mFWLock_' modelName];  % [P1-4 FIX] 统一命名: framework_locked_ → mFWLock_
    assignin('base', lock_var, p.locked);

    % ===== 记录审批时间 =====
    approve_time_var = ['mFWApprovedAt_' modelName];  % [P1-4 FIX] 统一命名: fwApprovedAt_ → mFWApprovedAt_
    assignin('base', approve_time_var, sl_framework_utils('format_timestamp'));

    % ===== 返回结果 =====
    fwApprovedTs = sl_framework_utils('format_timestamp');
    result = struct('status', 'ok', ...
        'message', sprintf('Macro framework approved and locked for model: %s', modelName), ...
        'lockedAt', fwApprovedTs, ...
        'frameworkSnapshot', fw, ...
        'modelName', modelName, ...
        'locked', p.locked);

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
end