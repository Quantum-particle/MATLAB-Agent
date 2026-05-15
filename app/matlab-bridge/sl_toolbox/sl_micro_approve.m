function result = sl_micro_approve(subsystemName, varargin)
% SL_MICRO_APPROVE Micro Framework Approval
%   result = sl_micro_approve(subsystemName, 'microFramework', mf, 'locked', true, 'modelName', modelName)
%
% v11.1: subsystemName is positional; microFramework/locked/modelName via Name-Value

    % parse Name-Value params from varargin
    p = struct('microFramework', struct(), 'locked', true, 'modelName', '');
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            k = varargin{idx};
            v = varargin{idx+1};
            if isfield(p, k)
                p.(k) = v;
            end
            idx = idx + 2;
        else
            idx = idx + 1;
        end
    end

    % get microFramework (from param or workspace)
    if isempty(fieldnames(p.microFramework))
        ss_safe = strrep(strrep(subsystemName, '/', '__'), ' ', '_');
        fw_var = ['uFW_' ss_safe];
        try
            mf = evalin('base', fw_var);
        catch
            result = struct('status', 'error', 'message', ...
                sprintf('No micro framework for subsystem: %s. Run sl_micro_design first.', subsystemName));
            return;
        end
    else
        mf = p.microFramework;
    end

    % [P1-4 FIX] 统一命名: mfSnap_ → uFWSnap_, mfLock_ → uFWLock_, mfApprove_ → uFWApprovedAt_, mfModel_ → uFWModel_
    % [Bug #20 FIX] Sanitize subsystemName: replace / and spaces with __ and _
    ss_safe = strrep(strrep(subsystemName, '/', '__'), ' ', '_');
    assignin('base', ['uFWSnap_' ss_safe], mf);
    if p.locked
        assignin('base', ['uFWLock_' ss_safe], p.locked);
    end
    assignin('base', ['uFWApprovedAt_' ss_safe], sl_framework_utils('format_timestamp'));
    if ~isempty(p.modelName)
        assignin('base', ['uFWModel_' ss_safe], p.modelName);
    end

    result = struct('status', 'ok', 'subsystemName', subsystemName, ...
        'modelName', p.modelName, 'locked', p.locked, ...
        'approvedAt', sl_framework_utils('format_timestamp'));
end