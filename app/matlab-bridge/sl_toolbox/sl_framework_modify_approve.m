function result = sl_framework_modify_approve(modelName, varargin)
% SL_FRAMEWORK_MODIFY_APPROVE Approve a pending macro framework modification
%   result = sl_framework_modify_approve(modelName)
%   result = sl_framework_modify_approve(modelName, 'reason', 'Approved after review')
%
% v11.0 Phase 3: Approve a pending modification stored in mFWPending_<modelName>
%   - Applies the pending modification to the macro framework
%   - Updates the workspace variable mFW_<modelName>
%   - Records the modification history
%   - Clears the pending modification

    % ===== Input Validation =====
    if nargin < 1 || isempty(modelName)
        result = struct('status', 'error', ...
            'message', 'sl_framework_modify_approve: modelName is required');
        return;
    end
    if ~ischar(modelName) && ~isstring(modelName)
        modelName = char(modelName);
    end

    % Parse Name-Value params
    p = struct('reason', '');
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
    try
        locked = evalin('base', lock_var);
    catch
        result = struct('status', 'error', ...
            'message', sprintf('Macro framework not locked for model: %s', modelName));
        return;
    end
    if ~locked
        result = struct('status', 'error', ...
            'message', sprintf('Macro framework not locked for model: %s', modelName));
        return;
    end

    % ===== Load pending modification =====
    pending_var = ['mFWPending_' modelName];
    try
        pending = evalin('base', pending_var);
    catch
        result = struct('status', 'error', ...
            'message', sprintf('No pending modification for model: %s', modelName));
        return;
    end
    % [P1-6 FIX] Check if pending is empty (cleared to [] or empty struct)
    if isempty(pending) || (isstruct(pending) && isempty(fieldnames(pending)))
        result = struct('status', 'error', ...
            'message', sprintf('No pending modification for model: %s (already cleared)', modelName));
        return;
    end

    % [P0-3 FIX] Race condition protection: verify pending.preSnapshot matches current framework
    % If framework was modified before approve, reject to avoid overwriting
    if isfield(pending, 'preSnapshot') && ~isempty(fieldnames(pending.preSnapshot))
        fw_var = ['mFW_' modelName];
        try
            currentFw = evalin('base', fw_var);
        catch
            result = struct('status', 'error', ...
                'message', sprintf('No macro framework found for model: %s', modelName));
            return;
        end
        % Compare current framework with pending snapshot
        % Simplified: check if subsystem names and count match
        if isfield(currentFw, 'subsystems') && isfield(pending.preSnapshot, 'subsystems')
            curNames = {currentFw.subsystems.name};
            snapNames = {pending.preSnapshot.subsystems.name};
            if ~isequal(sort(curNames), sort(snapNames))
                result = struct('status', 'error', ...
                    'message', sprintf('CONFLICT: Framework has been modified since the modification was requested. Current subsystems differ from snapshot. Reject this modification and re-apply.', modelName));
                return;
            end
        end
    end

    % ===== Apply modification =====
    fw_var = ['mFW_' modelName];
    try
        currentFw = evalin('base', fw_var);
    catch
        result = struct('status', 'error', ...
            'message', sprintf('No macro framework found for model: %s', modelName));
        return;
    end

    % Store pre-modification snapshot
    snap_var = ['mFWSnap_' modelName];
    assignin('base', snap_var, currentFw);

    % Apply the pending framework
    assignin('base', fw_var, pending.framework);

    % Record modification history
    history_var = ['mFWHistory_' modelName];
    try
        history = evalin('base', history_var);
    catch
        history = {};
    end
    historyEntry = struct();
    historyEntry.action = pending.action;
    historyEntry.approvedAt = sl_framework_utils('format_timestamp');
    historyEntry.summary = pending.summary;
    if ~isempty(p.reason)
        historyEntry.approvalReason = p.reason;
    end
    if isfield(pending, 'reason')
        historyEntry.requestReason = pending.reason;
    end
    history{end+1} = historyEntry; %#ok<AGROW>
    assignin('base', history_var, history);

    % Record modification timestamp
    assignin('base', ['mFWModifiedAt_' modelName], sl_framework_utils('format_timestamp'));

    % ===== Clear pending modification =====
    % [P1-6 FIX] Use empty array [] instead of empty struct() to clear pending
    % Empty struct passes evalin without error but returns non-empty, causing later ispending check to fail
    assignin('base', pending_var, []);

    % [P1-4 FIX] Set Gate 3 one-time pass
    % After approve, the next Gate 3-blocked command will be allowed (to execute the actual modeling op)
    % Pass is one-time only, Gate 3 reads and auto-clears it
    gate3_pass_var = ['mFWGate3Pass_' modelName];
    assignin('base', gate3_pass_var, true);

    result = struct('status', 'ok', ...
        'action', pending.action, ...
        'modelName', modelName, ...
        'modificationSummary', pending.summary, ...
        'approvedAt', sl_framework_utils('format_timestamp'), ...
        'reviewResult', pending.reviewResult);

    fprintf('[sl_framework_modify_approve] Approved modification "%s" for model: %s\n', ...
        pending.action, modelName);

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_modify_approve failed: %s', ME.message), ...
            'identifier', ME.identifier);
    end
end
