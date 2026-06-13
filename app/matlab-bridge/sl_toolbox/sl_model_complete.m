function result = sl_model_complete(modelName, varargin)
% SL_MODEL_COMPLETE v12.1 Model completion gate (Bug #27 FIX: subsystem-scoped scan)
    isSubPath = false;
    subPath = '';
    blockPlan = {};
    if nargin > 1
        for k = 1:2:length(varargin)
            if strcmp(varargin{k}, 'isSubPath'), isSubPath = varargin{k+1}; end
            if strcmp(varargin{k}, 'subPath'), subPath = varargin{k+1}; end
            if strcmp(varargin{k}, 'blockPlan'), blockPlan = varargin{k+1}; end
        end
    end
    result = struct('status','ok','passed',false,'canProceed',false,'unconnectedCount',0,...
        'failureType','','failedChecks',{{}},'retryContext',struct());

    % [v19 FIX #NEW-9] Extract top-level model name from subsystem path
    if ~isempty(strfind(modelName, '/'))
        topModel = modelName(1:strfind(modelName, '/')-1);
    else
        topModel = modelName;
    end
    if ~bdIsLoaded(topModel)
        load_system(topModel);
    end

    % [v12.1 BUGFIX #27] Determine scan scope
    if ~isempty(subPath)
        mn_prefix = [modelName '/'];
        if strncmp(subPath, mn_prefix, length(mn_prefix))
            subPath = subPath(length(mn_prefix)+1:end);
        end
        scanTarget = [modelName '/' subPath];
        try
            get_param(scanTarget, 'BlockType');
        catch
            result.status = 'error';
            result.message = sprintf('Subsystem not found: %s', scanTarget);
            return;
        end
    else
        scanTarget = modelName;
    end

    % [v25 FIX] Force auto_layout
    try
        sl_auto_layout(scanTarget);
    catch layout_err
        result.canProceed = false;
        result.passed = false;
        result.message = sprintf('Auto-layout failed: %s', layout_err.message);
        return;
    end

    vr = sl_validate_model(scanTarget);
    if ~isstruct(vr) || ~isfield(vr,'checks')
        result.status = 'error'; result.message = 'Invalid validate result'; return;
    end
    checks = vr.checks;
    mpChecks = {'unconnected','paramAudit','connectionScan','layoutAudit'};
    if ~isSubPath, mpChecks{end+1} = 'compilation'; end
    mpPass = true; totalUC = 0;
    for i = 1:length(checks)
        c = checks(i); cn = ''; cs = '';
        if isfield(c,'name'), cn = c.name; end
        if isfield(c,'status'), cs = c.status; end
        if strcmpi(cn,'unconnected') && isfield(c,'details')
            if isfield(c.details,'unconnectedCount'), totalUC = c.details.unconnectedCount; end
        end
        if any(strcmp(mpChecks,cn))
            if ~strcmpi(cs,'pass'), mpPass = false; end
        end
    end

    if ~isempty(subPath) || isSubPath
        result.passed = mpPass && (totalUC == 0);
        result.canProceed = mpPass && (totalUC == 0);
        if totalUC > 0
            result.message = sprintf('Subsystem %s has %d unconnected port(s).', scanTarget, totalUC);
        end
    else
        result.passed = mpPass && (totalUC == 0);
        result.canProceed = mpPass && (totalUC == 0);
    end
    result.unconnectedCount = totalUC;
    result.checkResults = checks;
    result.scanTarget = scanTarget;

    % [v18] Prevent empty shells from passing complete
    if result.canProceed && ~isempty(subPath)
        allBlocks = find_system(scanTarget, 'SearchDepth', 1, 'LookUnderMasks', 'on');
        functionalCount = 0;
        for bi = 1:length(allBlocks)
            bt = get_param(allBlocks{bi}, 'BlockType');
            if ~strcmp(bt, 'Inport') && ~strcmp(bt, 'Outport') && ~strcmp(bt, 'SubSystem')
                functionalCount = functionalCount + 1;
            end
        end
        if functionalCount == 0
            result.canProceed = false;
            result.passed = false;
            result.message = sprintf('Subsystem %s has no functional blocks (shell only).', subPath);
        end

        % [v25] Duplicate block detection
        duplicateNames = {};
        for bi = 2:length(allBlocks)
            nm = get_param(allBlocks{bi}, 'Name');
            tokens = regexp(nm, '^(.+)_(\d+)$', 'tokens');
            if ~isempty(tokens)
                baseName = tokens{1}{1};
                for bj = 2:length(allBlocks)
                    if strcmp(get_param(allBlocks{bj}, 'Name'), baseName)
                        duplicateNames{end+1} = nm; break;
                    end
                end
            end
        end
        if ~isempty(duplicateNames)
            result.canProceed = false;
            result.passed = false;
            result.message = sprintf('Duplicate blocks in %s: %s', subPath, strjoin(duplicateNames, ', '));
        end

        % [v25] blockPlan consistency check
        if result.canProceed && ~isempty(blockPlan)
            actualByType = containers.Map('KeyType','char','ValueType','double');
            for bi = 2:length(allBlocks)
                bt = get_param(allBlocks{bi}, 'BlockType');
                if ~strcmp(bt, 'Inport') && ~strcmp(bt, 'Outport') && ~strcmp(bt, 'SubSystem')
                    if isKey(actualByType, bt)
                        actualByType(bt) = actualByType(bt) + 1;
                    else
                        actualByType(bt) = 1;
                    end
                end
            end
            mismatches = {};
            for pi = 1:length(blockPlan)
                bp = blockPlan{pi};
                if isstruct(bp) || (iscell(bp) && length(bp)>=2)
                    if iscell(bp), bt = bp{1}; ec = bp{2};
                    elseif isfield(bp,'blockType'), bt = bp.blockType; ec = bp.count;
                    else continue; end
                end
                ac = 0;
                if isKey(actualByType, bt), ac = actualByType(bt); end
                if ac ~= ec
                    mismatches{end+1} = sprintf('%s: expected %d, actual %d', bt, ec, ac);
                end
            end
            if ~isempty(mismatches)
                result.canProceed = false;
                result.passed = false;
                result.message = sprintf('blockPlan mismatch in %s: %s', subPath, strjoin(mismatches, '; '));
            end
        end
    end

    % [v30] failureType classification when canProceed=false
    if ~result.canProceed
        result.failureType = 'implementation_error';
        result.failedChecks = {};
        designCritical = {'paramAudit', 'blockPlan', 'compilation'};
        for i = 1:length(checks)
            c = checks(i);
            if ~isfield(c, 'name') || ~isfield(c, 'status'), continue; end
            if strcmpi(c.status, 'pass'), continue; end
            % Check if any mustPass check failed → design_suspect
            if any(strcmp(designCritical, c.name))
                result.failureType = 'design_suspect';
            end
            % Per-port details for unconnected (needed by sl_retry_plan)
            if strcmp(c.name, 'unconnected') && isfield(c, 'details')
                c = extractPortDetails(c, scanTarget);
            end
            result.failedChecks{end+1} = c; %#ok<AGROW>
        end
    end

    % Save model (non-fatal: model is already structurally verified)
    if exist('modelName', 'var') && ~isempty(modelName)
        try
            save_system(modelName);
        catch saveErr
            % Non-fatal: result status remains 'ok' with canProceed intact.
            % The model state has been verified, save failure is typically
            % a filesystem issue (permissions, disk full) not a model issue.
            result.message = sprintf('[WARN] save_system failed: %s. Model verification passed but file not saved.', saveErr.message);
        end
    end
end

% [v30] Helper: extract per-port details for sl_retry_plan
function check = extractPortDetails(check, scanTarget)
    check.ports = {};
    try
        ph = get_param(scanTarget, 'PortHandles');
        if isfield(ph, 'Outport')
            for i = 1:length(ph.Outport)
                try
                    lh = get_param(ph.Outport(i), 'Line');
                    if lh == -1
                        check.ports{end+1} = struct('blockPath', scanTarget, ...
                            'direction', 'output', 'portIndex', i); %#ok<AGROW>
                    end
                catch
                end
            end
        end
        if isfield(ph, 'Inport')
            for i = 1:length(ph.Inport)
                try
                    lh = get_param(ph.Inport(i), 'Line');
                    if lh == -1
                        check.ports{end+1} = struct('blockPath', scanTarget, ...
                            'direction', 'input', 'portIndex', i); %#ok<AGROW>
                    end
                catch
                end
            end
        end
    catch
    end
end
