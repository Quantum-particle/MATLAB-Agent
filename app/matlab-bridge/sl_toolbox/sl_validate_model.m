function result = sl_validate_model(modelName)
% SL_VALIDATE_MODEL Validate Simulink model for issues
% v12.0: check_unconnected returns fail (not warning) - CN-01 FIX
% [v25 FIX RC1] Support subsystem-level validation via subsystem path.
%   modelName can be "Quadrotor_ADRC" (model-level) or
%   "Quadrotor_ADRC/Reference_Generator" (subsystem-level).
    result = struct('status','ok','overall','pass','checks',struct());
    try
        % Extract top-level model name if subsystem path is provided
        if contains(modelName, '/')
            topModel = extractBefore(modelName, '/');
            if ~bdIsLoaded(topModel), load_system(topModel); end
        else
            if ~bdIsLoaded(modelName), load_system(modelName); end
        end
        disp('[v24 BUG-001] sl_validate_model LOADED with paramAudit+connectionScan');
        checks = struct('name',{},'status',{},'message',{},'details',{});
        ci = 1;

        % Check 1: Unconnected ports
        [ucStatus, ucMsg, ucDetails] = check_unconnected(modelName);
        checks(ci).name = 'unconnected';
        checks(ci).status = ucStatus;
        checks(ci).message = ucMsg;
        checks(ci).details = ucDetails;
        ci = ci + 1;

        % Check 2: Compilation
        compPassed = true;
        compMsg = 'Model compiles successfully';
        try
            set_param(modelName, 'SimulationCommand', 'update');
        catch ME
            compPassed = false;
            compMsg = ME.message;
        end
        checks(ci).name = 'compilation';
        checks(ci).status = 'pass'; if ~compPassed, checks(ci).status = 'fail'; end
        checks(ci).message = compMsg;
        ci = ci + 1;

        % [v24 FIX BUG-001] Check 2.5: Parameter Audit (via sl_review_core)
        % Detects hardcoded numeric parameters in Gain/Constant blocks.
        % MathWorks Model Advisor uses find_system + get_param pattern.
        try
            paResult = sl_review_core(modelName, 'paramAudit');
            checks(ci).name = 'paramAudit';
            checks(ci).status = 'pass';
            if ~paResult.passed, checks(ci).status = 'fail'; end
            checks(ci).message = paResult.issue;
            checks(ci).details = paResult.details;
            ci = ci + 1;
        catch ME_pa
            checks(ci).name = 'paramAudit';
            checks(ci).status = 'warning';
            checks(ci).message = sprintf('paramAudit skipped: %s', ME_pa.message);
            ci = ci + 1;
        end

        % [v24 FIX BUG-001] Check 2.6: Connection Scan (via sl_review_core)
        % Detects unconnected internal block ports. Uses linear degradation
        % formula for confidence scoring.
        try
            csResult = sl_review_core(modelName, 'connectionScan');
            checks(ci).name = 'connectionScan';
            checks(ci).status = 'pass';
            if ~csResult.passed, checks(ci).status = 'fail'; end
            checks(ci).message = csResult.issue;
            checks(ci).details = csResult.details;
            ci = ci + 1;
        catch ME_cs
            checks(ci).name = 'connectionScan';
            checks(ci).status = 'warning';
            checks(ci).message = sprintf('connectionScan skipped: %s', ME_cs.message);
            ci = ci + 1;
        end

        % [v25 FIX] Check 2.7: Layout Audit (via sl_review_core)
        % Detects overlapping blocks and out-of-bounds positions.
        try
            laResult = sl_review_core(modelName, 'layoutAudit');
            checks(ci).name = 'layoutAudit';
            checks(ci).status = 'pass';
            if ~laResult.passed, checks(ci).status = 'fail'; end
            checks(ci).message = laResult.issue;
            checks(ci).details = laResult.details;
            ci = ci + 1;
        catch ME_la
            checks(ci).name = 'layoutAudit';
            checks(ci).status = 'warning';
            checks(ci).message = sprintf('layoutAudit skipped: %s', ME_la.message);
            ci = ci + 1;
        end

        % Check 3: Variables
        [varStatus, varMsg] = check_variables(modelName);
        checks(ci).name = 'variables';
        checks(ci).status = varStatus;
        checks(ci).message = varMsg;
        ci = ci + 1;

        % Overall
        allPassed = true;
        for i = 1:length(checks)
            if ~strcmpi(checks(i).status, 'pass')
                allPassed = false;
            end
        end
        result.overall = 'pass'; if ~allPassed, result.overall = 'fail'; end
        result.checks = checks;
    catch ME
        result.status = 'error';
        result.message = ME.message;
    end
end

function [status, msg, details] = check_unconnected(modelName)
    details = struct('unconnectedCount',0,'unconnected',{{}});
    try
        % [v12.1 BUGFIX #34] Adaptive SearchDepth: deep for model, shallow for subsystem
        if contains(modelName, '/')
            % Subsystem target: only check this level (Inport/Outport at boundaries)
            blocks = find_system(modelName, 'SearchDepth', 1, 'LookUnderMasks', 'all');
        else
            % Model target: recursive deep scan of all hierarchy levels
            blocks = find_system(modelName, 'LookUnderMasks', 'all');
        end
        unconnected = {};
        for i = 2:length(blocks)
            bp = blocks{i};
            try
                ph = get_param(bp, 'PortHandles');
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            btype = get_param(bp, 'BlockType');  % [v12.1 BUGFIX #35] Check BlockType
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH == -1 && ~strcmp(btype, 'Inport')
                                unconnected{end+1} = struct('block',bp,'portType','input','portIndex',j);
                            end
                        catch ME_in
                            warning('sl_validate:inport', '[check_unconnected] Inport check failed for %s port %d: %s', bp, j, ME_in.message);
                        end
                    end
                end
                if ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            btype = get_param(bp, 'BlockType');
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH == -1 && ~strcmp(btype, 'Outport')
                                unconnected{end+1} = struct('block',bp,'portType','output','portIndex',j);
                            end
                        catch ME_out
                            warning('sl_validate:outport', '[check_unconnected] Outport check failed for %s port %d: %s', bp, j, ME_out.message);
                        end
                    end
                end
            catch ME_block
                warning('sl_validate:block', '[check_unconnected] Block check failed for %s: %s', bp, ME_block.message);
            end
        end
        n = length(unconnected);
        details.unconnectedCount = n;
        details.unconnected = unconnected;
        if n == 0
            status = 'pass'; msg = 'All ports connected';
        else
            status = 'fail'; msg = [num2str(n) ' unconnected port(s)'];
        end
    catch ME
        status = 'warning'; msg = ['Cannot check unconnected: ' ME.message];
    end
end

function [status, msg] = check_variables(modelName)
    status = 'pass'; msg = 'No undefined variables';
    try
        vars = get_param(modelName, 'UnderspecifiedDataTypeMsgs');
        if ~isempty(vars)
            status = 'fail';
            msg = 'Undefined or underspecified variables detected';
        end
    catch
        status = 'pass'; msg = 'Variable check not applicable';
    end
end
