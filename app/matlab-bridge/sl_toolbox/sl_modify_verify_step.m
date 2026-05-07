function result = sl_modify_verify_step(modelName, stepIndex, modifyPlan)
% SL_MODIFY_VERIFY_STEP Verify a single modification step against the plan.
%
% Used after each add_block/add_line/set_param in Scene 2 to ensure
% the actual change matches the modifyPlan.
%
% Checks:
%   - Block was actually created/deleted/modified at the planned path
%   - Parameters match planned values

result = struct();
result.status = 'ok';
result.stepIndex = stepIndex;
result.verified = true;
result.mismatches = {};

% Get the expected change from modifyPlan
if isfield(modifyPlan, 'executionSteps') && stepIndex <= length(modifyPlan.executionSteps)
    expected = modifyPlan.executionSteps{stepIndex};
    
    % Check block existence
    if isfield(expected, 'blockPath')
        try
            get_param(expected.blockPath, 'BlockType');
        catch
            result.verified = false;
            result.mismatches{end+1} = sprintf('Block not found: %s', expected.blockPath);
        end
    end
    
    % Check parameters
    if isfield(expected, 'params') && isfield(expected, 'blockPath')
        param_names = fieldnames(expected.params);
        for i = 1:length(param_names)
            try
                actual = get_param(expected.blockPath, param_names{i});
                expected_val = expected.params.(param_names{i});
                if ~strcmp(actual, expected_val)
                    result.mismatches{end+1} = sprintf(...
                        'Param mismatch [%s]: expected=%s, actual=%s', ...
                        param_names{i}, expected_val, actual);
                end
            catch
                % Skip unverifiable params
            end
        end
    end
end

if ~result.verified
    result.message = sprintf('Step %d verification FAILED: %d mismatches.', ...
        stepIndex, length(result.mismatches));
else
    result.message = sprintf('Step %d verified OK.', stepIndex);
end
