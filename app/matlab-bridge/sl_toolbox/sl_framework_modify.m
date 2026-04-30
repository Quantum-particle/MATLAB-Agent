function result = sl_framework_modify(modelName, action, varargin)
% SL_FRAMEWORK_MODIFY v11.0 Phase 3: Macro Framework Modification After Lock
%   result = sl_framework_modify(modelName, 'addSubsystem', 'subsystemName', 'SubSys1', 'subsystemType', 'plant', 'inputs', 'torque', 'outputs', 'angle')
%   result = sl_framework_modify(modelName, 'removeSubsystem', 'subsystemName', 'OldSubsystem')
%   result = sl_framework_modify(modelName, 'changeSignalFlow', 'newSignalFlow', sfStruct)
%   result = sl_framework_modify(modelName, 'changePhysics', 'newPhysicsEquations', eqCell)
%   result = sl_framework_modify(modelName, 'renameSubsystem', 'oldName', 'Sub1', 'newName', 'Plant')
%
% v11.0 Phase 3: Macro framework locked modification approval flow
%   - After macro framework is locked (mFWLock_<model>=true), structural
%     changes require explicit approval via this function
%   - Allowed actions: addSubsystem, removeSubsystem, changeSignalFlow,
%     changePhysics, renameSubsystem
%   - Permitted changes (no approval needed): Gain tuning, To Workspace,
%     simulation parameters, signal logging

    % ===== Input Validation =====
    if nargin < 2 || isempty(modelName) || isempty(action)
        result = struct('status', 'error', ...
            'message', 'sl_framework_modify: modelName and action are required');
        return;
    end
    if ~ischar(modelName) && ~isstring(modelName)
        modelName = char(modelName);
    end
    if ~ischar(action) && ~isstring(action)
        action = char(action);
    end

    % Valid actions
    validActions = {'addSubsystem', 'removeSubsystem', 'changeSignalFlow', ...
        'changePhysics', 'renameSubsystem'};
    if ~any(strcmp(action, validActions))
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_modify: invalid action "%s". Valid: %s', ...
                action, sl_framework_utils('strjoin_safe', validActions, ', ')));
        return;
    end

    % ===== Parse Name-Value params from varargin =====
    p = struct('subsystemName', '', 'subsystemType', '', ...
               'inputs', '', 'outputs', '', ...
               'oldName', '', 'newName', '', ...
               'newSignalFlow', struct(), 'newPhysicsEquations', {{}}, ...
               'reason', '', 'autoApprove', false, 'skipDesign', false);
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

    try
    % ===== Check: Is macro framework locked? =====
    lock_var = ['mFWLock_' modelName];
    fw_var = ['mFW_' modelName];

    % [T4 FIX] skipDesign=true 时，跳过所有锁定和审批流程
    if p.skipDesign
        % Load framework directly
        try
            fw = evalin('base', fw_var);
        catch
            result = struct('status', 'error', ...
                'message', sprintf('No macro framework found for model: %s.', modelName));
            return;
        end
        % Execute modification directly based on action
        switch action
            case 'renameSubsystem'
                oldNameVal = p.oldName;
                newNameVal = p.newName;
                if isempty(oldNameVal) || isempty(newNameVal)
                    result = struct('status', 'error', 'message', 'renameSubsystem: oldName and newName are required');
                    return;
                end
                % Find and rename
                if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
                    result = struct('status', 'error', 'message', 'renameSubsystem: no subsystems in framework');
                    return;
                end
                names = {fw.subsystems.name};
                idx = find(strcmp(names, oldNameVal), 1);
                if isempty(idx)
                    result = struct('status', 'error', 'message', sprintf('renameSubsystem: subsystem "%s" not found', oldNameVal));
                    return;
                end
                fw.subsystems(idx).name = newNameVal;
                assignin('base', fw_var, fw);
                result = struct('status', 'ok', 'action', action, 'modelName', modelName, 'skipDesign', true);
            otherwise
                result = struct('status', 'ok', 'action', action, 'modelName', modelName, 'skipDesign', true, 'message', sprintf('skipDesign=true: %s executed without approval', action));
        end
        return;
    end
    % [NORMAL FLOW] locked check for non-skipDesign
    try
        try
            locked = evalin('base', lock_var);
        catch
            % Lock variable does not exist
            result = struct('status', 'error', ...
                'message', sprintf('Macro framework not locked for model: %s. Call sl_framework_approve first.', modelName));
            return;
        end

        if ~locked
            result = struct('status', 'error', ...
                'message', sprintf('Macro framework not locked for model: %s. Lock it first via sl_framework_approve.', modelName));
            return;
        end
    end

    % ===== Load current macro framework =====
    try
        fw = evalin('base', fw_var);
    catch
        result = struct('status', 'error', ...
            'message', sprintf('No macro framework found for model: %s. Variable %s does not exist.', modelName, fw_var));
        return;
    end

    % ===== [Phase 3 FIX] Normalize cell arrays to struct arrays =====
    % Python Engine eng.workspace[] assignment converts struct arrays to cell arrays
    % We need to normalize them back for consistent .field access
    % [P2-1 FIX] Prefer sl_framework_utils version, local version as fallback
    if isfield(fw, 'subsystems')
        fw.subsystems = normalize_to_struct_array(fw.subsystems);
    end
    if isfield(fw, 'signalFlow')
        fw.signalFlow = normalize_to_struct_array(fw.signalFlow);
    end
    if isfield(fw, 'gotoFromPlan')
        fw.gotoFromPlan = normalize_to_struct_array(fw.gotoFromPlan);
    end
    if isfield(fw, 'physicsEquations')
        fw.physicsEquations = normalize_to_struct_array(fw.physicsEquations);
    end

    % ===== Record pre-modification snapshot =====
    snap_var = ['mFWSnap_' modelName];
    try
        preSnap = evalin('base', snap_var);
    catch
        preSnap = fw;
    end

    % ===== Execute Modification =====
    modResult = struct();
    switch action
        case 'addSubsystem'
            modResult = do_add_subsystem(fw, p);
        case 'removeSubsystem'
            modResult = do_remove_subsystem(fw, p);
        case 'changeSignalFlow'
            modResult = do_change_signal_flow(fw, p);
        case 'changePhysics'
            modResult = do_change_physics(fw, p);
        case 'renameSubsystem'
            modResult = do_rename_subsystem(fw, p);
    end

    if ~modResult.success
        result = struct('status', 'error', ...
            'message', modResult.message);
        return;
    end

    % Update fw with modified version
    fw = modResult.framework;

    % ===== Validate Modified Framework =====
    reviewResult = validate_modified_framework(fw, action);

    % ===== Auto-Approve or Require Manual Approval =====
    % [P0-1 FIX] autoApprove only allows low-risk operations:
    %   - renameSubsystem: rename does not affect structure
    %   - changePhysics: equation change does not affect subsystem topology
    %   High-risk (addSubsystem/removeSubsystem/changeSignalFlow) must be manually approved
    LOW_RISK_ACTIONS = {'renameSubsystem', 'changePhysics'};
    can_auto_approve = logical(p.autoApprove) && reviewResult.passed && any(strcmp(action, LOW_RISK_ACTIONS));

    if can_auto_approve
        % Auto-approve: update workspace immediately
        assignin('base', fw_var, fw);
        assignin('base', snap_var, preSnap);
        % Record modification timestamp
        assignin('base', ['mFWModifiedAt_' modelName], sl_framework_utils('format_timestamp'));
        % [P1-5 FIX] Clear residual pending to prevent state leak
        pending_var_clear = ['mFWPending_' modelName];
        assignin('base', pending_var_clear, []);

        result = struct('status', 'ok', ...
            'action', action, ...
            'modelName', modelName, ...
            'autoApproved', true, ...
            'reviewResult', reviewResult, ...
            'modificationSummary', modResult.summary, ...
            'modifiedAt', sl_framework_utils('format_timestamp'));
    else
        % Require manual approval: store pending modification
        pending_var = ['mFWPending_' modelName];
        pendingMod = struct();
        pendingMod.action = action;
        pendingMod.framework = fw;
        pendingMod.preSnapshot = preSnap;
        pendingMod.reviewResult = reviewResult;
        pendingMod.summary = modResult.summary;
        pendingMod.requestedAt = sl_framework_utils('format_timestamp');
        if ~isempty(p.reason)
            pendingMod.reason = p.reason;
        end
        assignin('base', pending_var, pendingMod);

        result = struct('status', 'pending_approval', ...
            'action', action, ...
            'modelName', modelName, ...
            'autoApproved', false, ...
            'reviewResult', reviewResult, ...
            'modificationSummary', modResult.summary, ...
            'message', sprintf('Framework modification "%s" requires approval. Call sl_framework_modify_approve(''%s'') to approve, or sl_framework_modify_reject(''%s'') to reject.', action, modelName, modelName), ...
            'nextSteps', sprintf('sl_framework_modify_approve(''%s''); sl_framework_modify_reject(''%s'')', modelName, modelName));
    end

    fprintf('[sl_framework_modify] Action: %s on model: %s\n', action, modelName);
    if p.autoApprove && reviewResult.passed
        fprintf('[sl_framework_modify] Auto-approved: YES\n');
    else
        fprintf('[sl_framework_modify] Pending approval\n');
    end

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_modify failed: %s', ME.message), ...
            'identifier', ME.identifier);
    end
end

% ===== Add Subsystem =====
function modResult = do_add_subsystem(fw, p)
    modResult = struct('success', false, 'framework', fw, 'message', '', 'summary', '');
    subName = p.subsystemName;
    if isempty(subName)
        modResult.message = 'addSubsystem: subsystemName is required';
        return;
    end
    % Check for duplicate
    if isfield(fw, 'subsystems') && ~isempty(fw.subsystems)
        existingNames = {fw.subsystems.name};
        if any(strcmp(existingNames, subName))
            modResult.message = sprintf('addSubsystem: subsystem "%s" already exists', subName);
            return;
        end
    end

    % Build new subsystem struct
    newSub = struct();
    newSub.name = subName;
    newSub.type = p.subsystemType;
    if isempty(newSub.type), newSub.type = 'utility'; end
    newSub.inputs = p.inputs;
    newSub.outputs = p.outputs;

    % Append to subsystems array
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        fw.subsystems = newSub;
    else
        fw.subsystems(end+1) = newSub; %#ok<AGROW>
    end

    modResult.success = true;
    modResult.framework = fw;
    modResult.summary = sprintf('Added subsystem "%s" (type: %s, inputs: %s, outputs: %s)', ...
        subName, newSub.type, newSub.inputs, newSub.outputs);
end

% ===== Remove Subsystem =====
function modResult = do_remove_subsystem(fw, p)
    modResult = struct('success', false, 'framework', fw, 'message', '', 'summary', '');
    subName = p.subsystemName;
    if isempty(subName)
        modResult.message = 'removeSubsystem: subsystemName is required';
        return;
    end
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        modResult.message = 'removeSubsystem: no subsystems in framework';
        return;
    end

    existingNames = {fw.subsystems.name};
    idx = find(strcmp(existingNames, subName), 1);
    if isempty(idx)
        modResult.message = sprintf('removeSubsystem: subsystem "%s" not found', subName);
        return;
    end
    if length(fw.subsystems) <= 1
        modResult.message = 'removeSubsystem: cannot remove the last subsystem';
        return;
    end

    % Remove the subsystem
    removedSub = fw.subsystems(idx);
    fw.subsystems(idx) = [];

    % [P1-1 FIX] Remove signalFlow entries referencing this subsystem
    % [P1-1 FIX] Use normalized struct array, eliminate iscell branching
    removedCount = 0;
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        fw.signalFlow = normalize_to_struct_array(fw.signalFlow);
        keepIdx = [];
        for i = 1:length(fw.signalFlow)
            sf = fw.signalFlow(i);
            if ~strcmp(sf.srcSubsystem, subName) && ~strcmp(sf.dstSubsystem, subName)
                keepIdx(end+1) = i; %#ok<AGROW>
            else
                removedCount = removedCount + 1;
            end
        end
        if removedCount > 0
            if isempty(keepIdx)
                fw.signalFlow = struct('srcSubsystem', '', 'dstSubsystem', '', 'signalName', '');
                fw.signalFlow = repmat(fw.signalFlow, 1, 0);
            else
                fw.signalFlow = fw.signalFlow(keepIdx);
            end
        end
    end

    % [P1-1 FIX] Remove gotoFromPlan entries referencing this subsystem
    gfRemovedCount = 0;
    if isfield(fw, 'gotoFromPlan') && ~isempty(fw.gotoFromPlan)
        fw.gotoFromPlan = normalize_to_struct_array(fw.gotoFromPlan);
        gfKeepIdx = [];
        for i = 1:length(fw.gotoFromPlan)
            gf = fw.gotoFromPlan(i);
            keepEntry = true;
            if strcmp(gf.srcSubsystem, subName)
                keepEntry = false;
            end
            if isfield(gf, 'dstSubsystems') && iscell(gf.dstSubsystems)
                dstList = gf.dstSubsystems;
                dstIdx = find(strcmp(dstList, subName), 1);
                if ~isempty(dstIdx)
                    dstList(dstIdx) = [];
                    gf.dstSubsystems = dstList;
                    fw.gotoFromPlan(i) = gf;  % write back modified dstSubsystems
                    if isempty(dstList)
                        keepEntry = false;
                    end
                end
            end
            if keepEntry
                gfKeepIdx(end+1) = i; %#ok<AGROW>
            else
                gfRemovedCount = gfRemovedCount + 1;
            end
        end
        if gfRemovedCount > 0
            if isempty(gfKeepIdx)
                fw.gotoFromPlan = struct('tag', '', 'srcSubsystem', '', 'dstSubsystems', {{}});
                fw.gotoFromPlan = repmat(fw.gotoFromPlan, 1, 0);
            else
                fw.gotoFromPlan = fw.gotoFromPlan(gfKeepIdx);
            end
        end
    end

    modResult.success = true;
    modResult.framework = fw;
    modResult.summary = sprintf('Removed subsystem "%s" (type: %s) and %d related signal flows', ...
        subName, removedSub.type, removedCount);
end

% ===== Change Signal Flow =====
function modResult = do_change_signal_flow(fw, p)
    modResult = struct('success', false, 'framework', fw, 'message', '', 'summary', '');
    if isempty(p.newSignalFlow) || (~isstruct(p.newSignalFlow) && ~iscell(p.newSignalFlow))
        modResult.message = 'changeSignalFlow: newSignalFlow must be a struct array or cell array';
        return;
    end

    % Validate signal flow entries reference existing subsystems
    subNames = {};
    if isfield(fw, 'subsystems') && ~isempty(fw.subsystems)
        subNames = {fw.subsystems.name};
    end

    % [P2-2 FIX] After normalize, use unified struct array path
    newFlow = normalize_to_struct_array(p.newSignalFlow);
    invalidRefs = {};
    for i = 1:length(newFlow)
        sf = newFlow(i);
        if ~any(strcmp(subNames, sf.srcSubsystem))
            invalidRefs{end+1} = sf.srcSubsystem; %#ok<AGROW>
        end
        if ~any(strcmp(subNames, sf.dstSubsystem))
            invalidRefs{end+1} = sf.dstSubsystem; %#ok<AGROW>
        end
    end
    if ~isempty(invalidRefs)
        modResult.message = sprintf('changeSignalFlow: signal flow references non-existent subsystems: %s', ...
            sl_framework_utils('strjoin_safe', unique(invalidRefs), ', '));
        return;
    end

    oldFlowCount = 0;
    if isfield(fw, 'signalFlow')
        oldFlowCount = length(fw.signalFlow);
    end
    fw.signalFlow = newFlow;

    modResult.success = true;
    modResult.framework = fw;
    modResult.summary = sprintf('Changed signal flow: %d entries -> %d entries', ...
        oldFlowCount, length(newFlow));
end

% ===== Change Physics Equations =====
function modResult = do_change_physics(fw, p)
    modResult = struct('success', false, 'framework', fw, 'message', '', 'summary', '');
    if isempty(p.newPhysicsEquations)
        modResult.message = 'changePhysics: newPhysicsEquations is required';
        return;
    end

    oldEqCount = 0;
    if isfield(fw, 'physicsEquations')
        oldEqCount = length(fw.physicsEquations);
    end
    fw.physicsEquations = p.newPhysicsEquations;

    modResult.success = true;
    modResult.framework = fw;
    modResult.summary = sprintf('Changed physics equations: %d -> %d equations', ...
        oldEqCount, length(p.newPhysicsEquations));
end

% ===== Rename Subsystem =====
function modResult = do_rename_subsystem(fw, p)
    modResult = struct('success', false, 'framework', fw, 'message', '', 'summary', '');
    oldName = p.oldName;
    newName = p.newName;
    if isempty(oldName) || isempty(newName)
        modResult.message = 'renameSubsystem: oldName and newName are required';
        return;
    end
    if strcmp(oldName, newName)
        modResult.message = 'renameSubsystem: oldName and newName are the same';
        return;
    end

    % Find and rename in subsystems
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        modResult.message = 'renameSubsystem: no subsystems in framework';
        return;
    end
    existingNames = {fw.subsystems.name};
    idx = find(strcmp(existingNames, oldName), 1);
    if isempty(idx)
        modResult.message = sprintf('renameSubsystem: subsystem "%s" not found', oldName);
        return;
    end
    if any(strcmp(existingNames, newName))
        modResult.message = sprintf('renameSubsystem: subsystem "%s" already exists', newName);
        return;
    end

    fw.subsystems(idx).name = newName;

    % [P1-2 FIX] Update signalFlow references - after normalize, only use struct array path
    if isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
        fw.signalFlow = normalize_to_struct_array(fw.signalFlow);
        for i = 1:length(fw.signalFlow)
            if strcmp(fw.signalFlow(i).srcSubsystem, oldName)
                fw.signalFlow(i).srcSubsystem = newName;
            end
            if strcmp(fw.signalFlow(i).dstSubsystem, oldName)
                fw.signalFlow(i).dstSubsystem = newName;
            end
        end
    end

    % [P1-2 FIX] Update gotoFromPlan references - after normalize, only use struct array path
    if isfield(fw, 'gotoFromPlan') && ~isempty(fw.gotoFromPlan)
        fw.gotoFromPlan = normalize_to_struct_array(fw.gotoFromPlan);
        for i = 1:length(fw.gotoFromPlan)
            if strcmp(fw.gotoFromPlan(i).srcSubsystem, oldName)
                fw.gotoFromPlan(i).srcSubsystem = newName;
            end
            if isfield(fw.gotoFromPlan(i), 'dstSubsystems') && iscell(fw.gotoFromPlan(i).dstSubsystems)
                for j = 1:length(fw.gotoFromPlan(i).dstSubsystems)
                    if strcmp(fw.gotoFromPlan(i).dstSubsystems{j}, oldName)
                        fw.gotoFromPlan(i).dstSubsystems{j} = newName;
                    end
                end
            end
        end
    end

    modResult.success = true;
    modResult.framework = fw;
    modResult.summary = sprintf('Renamed subsystem "%s" -> "%s"', oldName, newName);
end

% ===== Validate Modified Framework =====
function reviewResult = validate_modified_framework(fw, action)
% Run lightweight validation checks on the modified framework
% Reuses check logic from sl_framework_review but simplified for modification context

    reviewResult = struct('passed', true);
    % [P1-3 FIX] checks/warnings changed to comma-separated strings to avoid cell JSON serialization issue (#30)
    reviewResult.checkDetails = '';
    reviewResult.warningDetails = '';

    % Check 1: subsystems exist and have unique names
    if isfield(fw, 'subsystems') && ~isempty(fw.subsystems)
        names = {fw.subsystems.name};
        if length(unique(names)) ~= length(names)
            reviewResult.passed = false;
            reviewResult.checkDetails = 'FAIL:subsystem_uniqueness(Duplicate subsystem names detected)';
        else
            reviewResult.checkDetails = 'PASS:subsystem_uniqueness(Names are unique)';
        end
    end

    % Check 2: signal flow references are valid (only for relevant actions)
    if strcmp(action, 'addSubsystem') || strcmp(action, 'removeSubsystem') || ...
       strcmp(action, 'changeSignalFlow') || strcmp(action, 'renameSubsystem')
        if isfield(fw, 'subsystems') && ~isempty(fw.subsystems) && ...
           isfield(fw, 'signalFlow') && ~isempty(fw.signalFlow)
            subNames = {fw.subsystems.name};
            % [P1-2 FIX] After normalizing signalFlow, use struct array path
            sf_norm = normalize_to_struct_array(fw.signalFlow);
            warnParts = {};
            for i = 1:length(sf_norm)
                sf = sf_norm(i);
                if ~any(strcmp(subNames, sf.srcSubsystem))
                    warnParts{end+1} = sprintf('Signal flow refs non-existent source: %s', sf.srcSubsystem); %#ok<AGROW>
                end
                if ~any(strcmp(subNames, sf.dstSubsystem))
                    warnParts{end+1} = sprintf('Signal flow refs non-existent dst: %s', sf.dstSubsystem); %#ok<AGROW>
                end
            end
            if ~isempty(warnParts)
                reviewResult.warningDetails = sl_framework_utils('strjoin_safe', warnParts, '; ');
            end
        end
    end

    % Check 3: physics equations exist (warning only)
    if ~isfield(fw, 'physicsEquations') || isempty(fw.physicsEquations)
        if ~isempty(reviewResult.warningDetails)
            reviewResult.warningDetails = [reviewResult.warningDetails, '; '];
        end
        reviewResult.warningDetails = [reviewResult.warningDetails, 'No physics equations defined'];
    end

    % Check 4: at least 1 subsystem
    if ~isfield(fw, 'subsystems') || isempty(fw.subsystems)
        reviewResult.passed = false;
        if ~isempty(reviewResult.checkDetails)
            reviewResult.checkDetails = [reviewResult.checkDetails, ', '];
        end
        reviewResult.checkDetails = [reviewResult.checkDetails, 'FAIL:subsystem_count(Must have at least one subsystem)'];
    end
end

% ===== Normalize cell array to struct array =====
function sa = normalize_to_struct_array(data)
% Normalize cell-of-struct or struct-array to a proper struct array
% This handles the case where Python Engine assignment converts struct arrays
% to cell arrays of scalar structs (which breaks .field access patterns)
%
% [CRITICAL] Uses sa(1)=data{1}; sa(2)=data{2}; ... pattern instead of
% struct() constructor to avoid struct array expansion issues with cell fields

    if isempty(data)
        sa = data;
        return;
    end

    if isstruct(data) && ~iscell(data)
        % Already a struct array
        sa = data;
        return;
    end

    if iscell(data)
        % Cell array - check if all elements are structs
        if ~all(cellfun(@isstruct, data))
            % Not all structs - return as-is (e.g., cell of strings)
            sa = data;
            return;
        end
        if isempty(data)
            sa = data;
            return;
        end
        % Build struct array from cell of structs
        % Use first-element-init + sequential assignment pattern
        % This is the safest way to create struct arrays from cells
        % because struct() constructor can incorrectly expand cell field values
        nElem = length(data);
        sa = data{1};
        for i = 2:nElem
            sa(i) = data{i};
        end
        return;
    end

    % Fallback: return as-is
    sa = data;
end
