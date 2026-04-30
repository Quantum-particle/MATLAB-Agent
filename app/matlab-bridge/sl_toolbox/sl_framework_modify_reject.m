function result = sl_framework_modify_reject(modelName, varargin)
% SL_FRAMEWORK_MODIFY_REJECT Reject a pending macro framework modification
%   result = sl_framework_modify_reject(modelName)
%   result = sl_framework_modify_reject(modelName, 'reason', 'Subsystem not needed')
%
% v11.0 Phase 3: Reject a pending modification stored in mFWPending_<modelName>
%   - Discards the pending modification
%   - The macro framework remains unchanged
%   - Records the rejection in modification history

    % ===== Input Validation =====
    if nargin < 1 || isempty(modelName)
        result = struct('status', 'error', ...
            'message', 'sl_framework_modify_reject: modelName is required');
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
    % [P0-4 FIX] Check framework is locked (consistent with approve)
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
    % [P1-6 FIX] Check if pending is empty
    if isempty(pending) || (isstruct(pending) && isempty(fieldnames(pending)))
        result = struct('status', 'error', ...
            'message', sprintf('No pending modification for model: %s (already cleared)', modelName));
        return;
    end

    % ===== Record rejection in history =====
    history_var = ['mFWHistory_' modelName];
    try
        history = evalin('base', history_var);
    catch
        history = {};
    end
    historyEntry = struct();
    historyEntry.action = pending.action;
    historyEntry.rejectedAt = sl_framework_utils('format_timestamp');
    historyEntry.summary = pending.summary;
    historyEntry.status = 'rejected';
    if ~isempty(p.reason)
        historyEntry.rejectionReason = p.reason;
    end
    history{end+1} = historyEntry; %#ok<AGROW>
    assignin('base', history_var, history);

    % ===== Clear pending modification =====
    % [P1-6 FIX] Use empty array [] instead of empty struct() to clear pending
    assignin('base', pending_var, []);

    result = struct('status', 'ok', ...
        'action', pending.action, ...
        'modelName', modelName, ...
        'modificationSummary', pending.summary, ...
        'rejectedAt', sl_framework_utils('format_timestamp'), ...
        'message', sprintf('Modification "%s" rejected. Macro framework unchanged.', pending.action));

    fprintf('[sl_framework_modify_reject] Rejected modification "%s" for model: %s\n', ...
        pending.action, modelName);

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_modify_reject failed: %s', ME.message), ...
            'identifier', ME.identifier);
    end
end
