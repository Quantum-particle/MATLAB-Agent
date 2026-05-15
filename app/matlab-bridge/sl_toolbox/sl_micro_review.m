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
    if isempty(strfind(subsystemName, '/')) && ~isempty(p.modelName)
        fullPath = [p.modelName '/' subsystemName];
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

    checks = {};
    ci = 1;
    for k = 1:length(p.checkItems)
        nm = p.checkItems{k};
        switch nm
            case 'physics'
                r = struct('item', 'physics', 'passed', true, 'confidence', 0.9, 'issue', '', 'suggestion', '');
                if ~isfield(mf, 'physicsEquations') || isempty(mf.physicsEquations)
                    r.passed = false; r.confidence = 0.3; r.issue = 'No physics equations';
                else
                    eqs = mf.physicsEquations;
                    for j = 1:length(eqs)
                        eq_struct = sl_safe_index(eqs, j);
                        % Extract equation string from struct
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
                            r.passed = false; r.confidence = 0.5;
                            r.issue = sprintf('Issue in equation %d', j); break;
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
                    if ~hasInt && isfield(mf, 'signalDimensions') && mf.signalDimensions.states > 0
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

            % [v11.8 NEW] Build-time checks — delegate to sl_review_core
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
    buildAllPassed = true;
    buildIssues = {};
    for k = 1:n
        if any(strcmp(checks{k}.item, buildCheckNames))
            if ~checks{k}.passed
                buildAllPassed = false;
                if ~isempty(checks{k}.issue)
                    buildIssues{end+1} = checks{k}.issue;
                end
            end
        end
    end
    
    reviewResult = struct();
    reviewResult.passed = all(pArr);
    reviewResult.checks = checks;
    reviewResult.overallConfidence = mean(cArr);
    reviewResult.issues = {};
    reviewResult.suggestions = {};
    reviewResult.buildChecksPassed = buildAllPassed;
    reviewResult.buildIssues = {buildIssues};
    result = struct('status', 'ok', ...
        'reviewResult', reviewResult, ...
        'subsystemName', subsystemName);
end