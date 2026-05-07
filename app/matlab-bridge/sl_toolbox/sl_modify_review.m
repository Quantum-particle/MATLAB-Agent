function result = sl_modify_review(modifyPlan)
% SL_MODIFY_REVIEW Self-check for Scene 2 modify plan.
%
% Checks:
%   1. Sandbox subsystem design completeness
%   2. Connection point validity (inputs/outputs defined)
%   3. Existing modification risk assessment

result = struct();
result.status = 'ok';
result.passed = true;
result.checks = {};
result.issues = {};

% Validate input is a struct
if ~isstruct(modifyPlan)
    result.status = 'error';
    result.passed = false;
    result.error = 'modifyPlan must be a struct with sandboxSubsystem field.';
    return;
end

% Check 1: Sandbox design exists
if ~isfield(modifyPlan, 'sandboxSubsystem') || isempty(modifyPlan.sandboxSubsystem)
    result.passed = false;
    result.issues{end+1} = 'Missing sandboxSubsystem design. All new functionality must be in a sandbox.';
end

% Check 2: Sandbox has inputs
if isfield(modifyPlan, 'sandboxSubsystem') && isfield(modifyPlan.sandboxSubsystem, 'inports')
    if isempty(modifyPlan.sandboxSubsystem.inports)
        result.issues{end+1} = 'No inports defined for sandbox. How does it receive input?';
    end
end

% Check 3: Sandbox has outputs
if isfield(modifyPlan, 'sandboxSubsystem') && isfield(modifyPlan.sandboxSubsystem, 'outports')
    if isempty(modifyPlan.sandboxSubsystem.outports)
        result.issues{end+1} = 'No outports defined for sandbox. How does it send output?';
    end
end

% Check 4: Existing modifications risk
if isfield(modifyPlan, 'existingModifications') && ...
   isfield(modifyPlan.existingModifications, 'required') && ...
   modifyPlan.existingModifications.required
    if ~isfield(modifyPlan.existingModifications, 'changes') || ...
       isempty(modifyPlan.existingModifications.changes)
        result.passed = false;
        result.issues{end+1} = 'existingModifications.required=true but no changes listed.';
    end
end

% [P1-12 FIX] Extract model name from modifyPlan or sandbox inport connectTo paths
% instead of relying on bdroot which may point to a different loaded model.
modelName = '';
if isfield(modifyPlan, 'modelName') && ~isempty(modifyPlan.modelName)
    modelName = modifyPlan.modelName;
elseif isfield(modifyPlan, 'sandboxSubsystem') && isfield(modifyPlan.sandboxSubsystem, 'inports')
    % Try to infer model name from the first inport's connectTo path
    inports_infer = modifyPlan.sandboxSubsystem.inports;
    for i_infer = 1:numel(inports_infer)
        inp_infer = inports_infer{i_infer};
        if isstruct(inp_infer) && isfield(inp_infer, 'connectTo') && ~isempty(inp_infer.connectTo)
            ct_infer = inp_infer.connectTo;
            slash_pos = strfind(ct_infer, '/');
            if ~isempty(slash_pos)
                modelName = ct_infer(1:slash_pos(1)-1);
                break;
            end
        end
    end
end
% Fallback to bdroot only if no model name could be inferred
if isempty(modelName)
    modelName = bdroot;
    result.modelNameWarning = 'Using bdroot as fallback — multi-model scenarios may have incorrect validation.';
end

% Check 5 [v11.6 P0-11]: Sandbox inport connectTo must be valid
if isfield(modifyPlan, 'sandboxSubsystem') && isfield(modifyPlan.sandboxSubsystem, 'inports')
    inports = modifyPlan.sandboxSubsystem.inports;
    for i = 1:numel(inports)
        inp = inports{i};
        if ~isstruct(inp), continue; end
        ct = '';
        if isfield(inp, 'connectTo'), ct = inp.connectTo; end
        if isempty(ct)
            result.passed = false;
            result.issues{end+1} = sprintf('Inport "%s" has empty connectTo. Must specify a valid source block.', inp.name);
        else
            % Verify connectTo target exists in the model
            % [v11.6.1 FIX] Prepend model name if relative path
            if isempty(strfind(ct, '/'))
                % Top-level block: prepend current model
                try
                    ct_full = [modelName '/' ct];  % [P1-12 FIX] Use modelName instead of bdroot
                    get_param(ct_full, 'BlockType');
                catch
                    result.passed = false;
                    result.issues{end+1} = sprintf('Inport "%s" connectTo target "%s" not found in model "%s".', inp.name, ct, modelName);
                end
            else
                % Already has path: try relative then full
                try
                    get_param(ct, 'BlockType');
                catch
                    try
                        ct_full = [modelName '/' ct];  % [P1-12 FIX] Use modelName instead of bdroot
                        get_param(ct_full, 'BlockType');
                    catch
                        result.passed = false;
                        result.issues{end+1} = sprintf('Inport "%s" connectTo target "%s" not found in model "%s".', inp.name, ct, modelName);
                    end
                end
            end
        end
    end
end

% Check 6 [v11.6 P0-11]: Sandbox outport connectTo must be valid
if isfield(modifyPlan, 'sandboxSubsystem') && isfield(modifyPlan.sandboxSubsystem, 'outports')
    outports = modifyPlan.sandboxSubsystem.outports;
    for i = 1:numel(outports)
        outp = outports{i};
        if ~isstruct(outp), continue; end
        ct = '';
        if isfield(outp, 'connectTo'), ct = outp.connectTo; end
        if isempty(ct)
            result.passed = false;
            result.issues{end+1} = sprintf('Outport "%s" has empty connectTo. Must specify a valid destination block.', outp.name);
        else
            % Verify connectTo target exists in the model
            % [v11.6.1 FIX] Prepend model name if relative path
            if isempty(strfind(ct, '/'))
                try
                    ct_full = [modelName '/' ct];  % [P1-12 FIX] Use modelName instead of bdroot
                    get_param(ct_full, 'BlockType');
                catch
                    result.passed = false;
                    result.issues{end+1} = sprintf('Outport "%s" connectTo target "%s" not found in model "%s".', outp.name, ct, modelName);
                end
            else
                try
                    get_param(ct, 'BlockType');
                catch
                    try
                        ct_full = [modelName '/' ct];  % [P1-12 FIX] Use modelName instead of bdroot
                        get_param(ct_full, 'BlockType');
                    catch
                        result.passed = false;
                        result.issues{end+1} = sprintf('Outport "%s" connectTo target "%s" not found in model "%s".', outp.name, ct, modelName);
                    end
                end
            end
        end
    end
end

if ~result.passed
    result.message = sprintf('Modify plan review FAILED: %d issues found.', length(result.issues));
else
    result.message = 'Modify plan review PASSED. Ready for approval.';
end
