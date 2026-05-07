function result = sl_modify_approve(modelName, modifyPlan)
% SL_MODIFY_APPROVE Approve Scene 2 modify plan + set approval flags.
%
% Checks:
%   1. Sandbox name doesn't conflict with existing subsystems
%   2. Sets mS2Approved_<modelName> flag — existing model read-only
%   3. Sets mS2SandboxName_<modelName> — sandbox subsystem name
%
% After approval, Gate_S2_MODIFY protects existing model parts from writes.

result = struct();
result.status = 'ok';

% Validate sandbox plan
if ~isstruct(modifyPlan)
    result.status = 'error';
    result.error = 'modifyPlan must be a struct with sandboxSubsystem.name.';
    return;
end

if ~isfield(modifyPlan, 'sandboxSubsystem') || ~isfield(modifyPlan.sandboxSubsystem, 'name')
    result.status = 'error';
    result.error = 'modifyPlan.sandboxSubsystem.name is required for approval.';
    return;
end

sandbox_name = modifyPlan.sandboxSubsystem.name;

% Check sandbox name uniqueness
existing = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'SubSystem', 'Name', sandbox_name);
if ~isempty(existing)
    result.status = 'error';
    result.error = sprintf('Sandbox name "%s" already exists in model.', sandbox_name);
    return;
end

% Set MATLAB base workspace approval flags
model_safe = strrep(strrep(modelName, '/', '__'), ' ', '_');
sandbox_safe = strrep(sandbox_name, ' ', '_');
assignin('base', ['mS2Approved_' model_safe], true);
assignin('base', ['mS2SandboxName_' model_safe], sandbox_name);

result.message = sprintf('Modify plan approved for model "%s". Sandbox: "%s".', ...
    modelName, sandbox_name);
result.sandboxName = sandbox_name;
result.approved = true;
