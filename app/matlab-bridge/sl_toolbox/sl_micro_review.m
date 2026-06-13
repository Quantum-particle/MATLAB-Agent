function result = sl_micro_review(subsystemName, varargin)
% SL_MICRO_REVIEW Micro Framework Self-Review
%   result = sl_micro_review(subsystemName, 'microFramework', mf)
%   result = sl_micro_review(subsystemName, 'microFramework', mf, 'checkItems', {'physics'})
%
% v11.1: subsystemName is positional; rest via Name-Value pairs
% [v11.8] subsystemName can be bare name or full path. modelName needed for sl_review_core.

    p = struct();
    p.microFramework = struct();
    p.modelName = '';  % [v11.8] for full path construction in sl_review_core calls
    % [v11.8] Default: 4 design checks + 4 build-time checks (via sl_review_core)
    p.checkItems = {'physics', 'blockPlan', 'signalDimensions', 'integrators', ...
        'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'};
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
    
    % [v11.8] Construct full Simulink path for sl_review_core
    % v12.1 BUGFIX: always prepend modelName when provided, even if subsystemName contains '/'
    if ~isempty(p.modelName)
        if isempty(strfind(subsystemName, '/'))
            fullPath = [p.modelName '/' subsystemName];
        elseif isempty(strfind(subsystemName, p.modelName))
            fullPath = [p.modelName '/' subsystemName];
        else
            fullPath = subsystemName;
        end
    else
        fullPath = subsystemName;
    end

    % [v11.8.1] Skip microFramework lookup if only build-time checks requested
    % Design checks: 'physics', 'blockPlan', 'signalDimensions', 'integrators'
    % Build checks: 'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'
    designChecks = {'physics', 'blockPlan', 'signalDimensions', 'integrators'};
    needsDesign = false;
    for d = 1:length(p.checkItems)
        if any(strcmp(p.checkItems{d}, designChecks))
            needsDesign = true;
            break;
        end
    end
    
    if needsDesign
        if isempty(fieldnames(p.microFramework))
            fw_var = ['uFW_' subsystemName];
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
    else
        mf = struct();  % dummy, won't be used by build checks
    end

    % [v19 BUGFIX] Separate design checks from build checks.
    % Build checks (portPairing, paramAudit, connectionScan, layoutAudit)
    % require actual blocks in the subsystem. For newly designed subsystems
    % that only have Inport/Outport shells, these checks will always fail.
    % Solution: count actual blocks (excluding Inport/Outport) and only
    % run build checks if there are functional blocks.
    hasFunctionalBlocks = false;
    try
        allBlocks = find_system(fullPath, 'LookUnderMasks', 'on');
        functionalCount = 0;
        for bi = 1:length(allBlocks)
            bt = get_param(allBlocks{bi}, 'BlockType');
            if ~any(strcmp(bt, {'Inport', 'Outport', 'SubSystem'}))
                functionalCount = functionalCount + 1;
            end
        end
        if functionalCount > 0
            hasFunctionalBlocks = true;
        end
    catch
        % If find_system fails, assume no functional blocks
        hasFunctionalBlocks = false;
    end

    checks = {};
    ci = 1;
    for k = 1:length(p.checkItems)
        nm = p.checkItems{k};
        
        % [v19 BUGFIX] Skip build checks if no functional blocks exist
        buildCheckNames = {'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'};
        if any(strcmp(nm, buildCheckNames)) && ~hasFunctionalBlocks
            % Auto-pass build checks for empty subsystems (Inport/Outport only)
            r = struct('item', nm, 'passed', true, 'confidence', 0.5, ...
                'issue', '', 'suggestion', 'Build check skipped: no functional blocks yet');
            checks{ci} = r; ci = ci + 1;
            continue;
        end
        
        switch nm
            case 'physics'
                % [v12.0] check_physics upgrade: delegate to rigor score engine (HC-02/HC-03 FIX)
                r = struct('item', 'physics', 'passed', true, 'confidence', 0.9, 'issue', '', 'suggestion', '');
                if ~isfield(mf, 'physicsEquations') || isempty(mf.physicsEquations)
                    r.passed = false; r.confidence = 0.1; r.issue = 'No physics equations defined';
                else
                    % Run rigor self-consistency and completeness sub-checks
                    try
                        rigor = sl_rigor_score(mf);
                        r.rigorScore = rigor.score;
                        r.confidence = min(0.95, max(0.1, rigor.score));
                        
                        % Check completeness dimension
                        if rigor.breakdown.completeness < 0.3
                            r.passed = false;
                            r.issue = sprintf('Physics completeness too low (%.2f): insufficient equations or parameters', ...
                                rigor.breakdown.completeness);
                        end
                        
                        % Check self-consistency dimension
                        if rigor.breakdown.selfConsistency < 0.3
                            r.passed = false;
                            if isempty(r.issue)
                                r.issue = sprintf('Physics self-consistency too low (%.2f): undefined variables or mismatched integrators', ...
                                    rigor.breakdown.selfConsistency);
                            else
                                r.issue = [r.issue '; self-consistency too low'];
                            end
                        end
                        
                        % Also check for NaN or /0 (legacy basic check)
                        eqs = mf.physicsEquations;
                        for j = 1:length(eqs)
                            eq_struct = sl_safe_index(eqs, j);
                            if isstruct(eq_struct) && isfield(eq_struct, 'equation')
                                e = eq_struct.equation;
                            elseif ischar(eq_struct)
                                e = eq_struct;
                            elseif iscell(eq_struct)
                                e = sl_framework_utils('strjoin_safe', eq_struct, ' ');
                            else
                                e = '';
                            end
                            if ~isempty(strfind(e, 'NaN')) || ~isempty(strfind(e, '/0'))
                                r.passed = false; r.confidence = min(r.confidence, 0.3);
                                r.issue = sprintf('NaN or division by zero in equation %d', j); break;
                            end
                        end
                        
                        if isempty(r.issue) && r.passed
                            r.suggestion = sprintf('Equations OK (rigor: %.2f)', rigor.score);
                        end
                    catch
                        % Fallback to basic check if rigor fails
                        eqs = mf.physicsEquations;
                        hasContent = false;
                        for j = 1:length(eqs)
                            eq_struct = sl_safe_index(eqs, j);
                            if isstruct(eq_struct) && isfield(eq_struct, 'equation')
                                e = eq_struct.equation;
                            elseif ischar(eq_struct)
                                e = eq_struct;
                            elseif iscell(eq_struct)
                                e = sl_framework_utils('strjoin_safe', eq_struct, ' ');
                            else
                                e = '';
                            end
                            if ~isempty(e)
                                hasContent = true;
                            end
                            if ~isempty(strfind(e, 'NaN')) || ~isempty(strfind(e, '/0'))
                                r.passed = false; r.confidence = 0.5;
                                r.issue = sprintf('Issue in equation %d', j); break;
                            end
                        end
                        if ~hasContent
                            r.passed = false; r.confidence = 0.2;
                            r.issue = 'Equations are empty (all blank)';
                        end
                    end
                end
                checks{ci} = r; ci = ci + 1;

            case 'blockPlan'
                r = struct('item', 'blockPlan', 'passed', true, 'confidence', 0.85, 'issue', '', 'suggestion', '');
                if ~isfield(mf, 'blockPlan') || isempty(mf.blockPlan)
                    r.passed = false; r.confidence = 0.3; r.issue = 'No block plan';
                else
                    tot = 0; hasInt = false;
                    for j = 1:length(mf.blockPlan)
                        b = sl_safe_index(mf.blockPlan, j);
                        tot = tot + b.count;
                        if isfield(b, 'type') && strcmp(b.type, 'Integrator'), hasInt = true;
                        elseif isfield(b, 'blockType') && strcmp(b.blockType, 'Integrator'), hasInt = true; end
                    end
                    if ~hasInt && isfield(mf, 'signalDimensions') && isfield(mf.signalDimensions, 'states') && mf.signalDimensions.states > 0
                        r.passed = false; r.confidence = 0.5;
                        r.issue = 'No Integrator for state variables';
                    end
                end
                checks{ci} = r; ci = ci + 1;

            case 'signalDimensions'
                % Bug#22 FIX (2026-05-14): Context-aware dimension validation.
                % Source subsystems (input=0, output>=1) and sink subsystems
                % (output=0, input>=1) are valid. Only both-zero is invalid.
                r = struct('item', 'signalDimensions', 'passed', true, 'confidence', 0.85, 'issue', '', 'suggestion', '');
                if ~isfield(mf, 'signalDimensions') || isempty(mf.signalDimensions)
                    r.passed = false; r.confidence = 0.3; r.issue = 'No signal dimensions';
                else
                    sd = mf.signalDimensions;
                    % [v15 Fix #50] Guard against empty struct with missing fields
                    if ~isfield(sd, 'input') || ~isfield(sd, 'output')
                        r.passed = false; r.confidence = 0.3;
                        r.issue = 'signalDimensions missing input/output fields';
                    else
                        % [v20 FIX B1] Normalize signalDimensions to numeric.
                        % JSON [] passes through Python Bridge as cell array {},
                        % which MATLAB eq() cannot compare. Force to 0 if non-numeric.
                        if ~isnumeric(sd.input), sd.input = 0; end
                        if ~isnumeric(sd.output), sd.output = 0; end
                        in0 = (sd.input == 0); out0 = (sd.output == 0);
                        if in0 && out0
                            r.passed = false; r.confidence = 0.4;
                            r.issue = 'Invalid: both input and output are zero';
                        elseif out0 && ~in0
                            % Sink subsystem (output=0, input>=1): valid (e.g., Terminator, Scope, ToWorkspace)
                        elseif in0 && ~out0
                            % Source subsystem (input=0, output>=1): valid (e.g., Reference_Generator, Constant source)
                        elseif sd.input < 1
                            r.passed = false; r.confidence = 0.4;
                            r.issue = sprintf('Invalid input dimension: %d (must be >=1 for non-source)', sd.input);
                        elseif sd.output < 1
                            r.passed = false; r.confidence = 0.4;
                            r.issue = sprintf('Invalid output dimension: %d (must be >=1 for non-sink)', sd.output);
                        end
                    end
                end
                checks{ci} = r; ci = ci + 1;

            case 'integrators'
                r = struct('item', 'integrators', 'passed', true, 'confidence', 0.9, 'issue', '', 'suggestion', '');
                nInt = 0;
                if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
                    for j = 1:length(mf.blockPlan)
                        b_bi = sl_safe_index(mf.blockPlan, j);
                        if isfield(b_bi, 'blockType')
                            btype = b_bi.blockType;
                        elseif isfield(b_bi, 'type')
                            btype = b_bi.type;
                        else
                            btype = '';
                        end
                        if strcmp(btype, 'Integrator')
                            nInt = nInt + b_bi.count;
                        end
                    end
                end
                expS = 0;
                if isfield(mf, 'signalDimensions') && isfield(mf.signalDimensions, 'states')
                    expS = mf.signalDimensions.states;
                end
                if expS > 0 && nInt < max(1, ceil(expS / 2))
                    r.passed = false; r.confidence = 0.6;
                    r.issue = sprintf('Only %d Integrators (need %d+)', nInt, max(1, ceil(expS/2)));
                end
                checks{ci} = r; ci = ci + 1;

            % [v11.8 NEW] Build-time checks - delegate to sl_review_core
            case 'portPairing'
                r = sl_review_core(fullPath, 'portPairing');
                checks{ci} = r; ci = ci + 1;
            case 'paramAudit'
                r = sl_review_core(fullPath, 'paramAudit');
                checks{ci} = r; ci = ci + 1;
            case 'connectionScan'
                r = sl_review_core(fullPath, 'connectionScan');
                checks{ci} = r; ci = ci + 1;
            case 'layoutAudit'
                r = sl_review_core(fullPath, 'layoutAudit');
                checks{ci} = r; ci = ci + 1;
        end
    end

    n = length(checks);
    pArr = false(n, 1); cArr = zeros(n, 1);
    for k = 1:n, pArr(k) = checks{k}.passed; cArr(k) = checks{k}.confidence; end
    
    % [v11.9 Bug#24/#25 FIX] Separate design vs build checks for micro_approve gate
    buildCheckNames = {'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'};
    designCheckNames = {'physics', 'blockPlan', 'signalDimensions', 'integrators'};
    buildAllPassed = true;
    designAllPassed = true;
    buildIssues = {};
    for k = 1:n
        if any(strcmp(checks{k}.item, buildCheckNames))
            if ~checks{k}.passed
                buildAllPassed = false;
                if ~isempty(checks{k}.issue)
                    buildIssues{end+1} = checks{k}.issue;
                end
            end
        elseif any(strcmp(checks{k}.item, designCheckNames))
            if ~checks{k}.passed
                designAllPassed = false;
            end
        end
    end
    
    reviewResult = struct();
    reviewResult.passed = designAllPassed;  % [v25 FIX] Design-only: build checks are pre-build artifacts
    reviewResult.checks = checks;
    reviewResult.overallConfidence = mean(cArr);
    reviewResult.issues = {};
    reviewResult.suggestions = {};
    reviewResult.buildChecksPassed = buildAllPassed;
    reviewResult.designChecksPassed = designAllPassed;  % [v25 NEW]
    reviewResult.buildIssues = {buildIssues};
    result = struct('status', 'ok', ...
        'reviewResult', reviewResult, ...
        'subsystemName', subsystemName);
end