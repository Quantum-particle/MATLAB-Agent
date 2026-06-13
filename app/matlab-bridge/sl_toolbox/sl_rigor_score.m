function result = sl_rigor_score(microFramework)
% SL_RIGOR_SCORE Domain-agnostic engineering rigor scoring engine
%   result = sl_rigor_score(microFramework)
%
% v12.0: Core engine for Gate_CONTENT_DEPTH. Pure formal logic, zero domain knowledge.
% R2016a+ compatible.

    if nargin < 1 || isempty(fieldnames(microFramework))
        result = struct('score', 0.0, ...
            'breakdown', struct('completeness', 0.0, 'selfConsistency', 0.0, ...
                'traceability', 0.0, 'justifiability', 0.0), ...
            'weakest', 'completeness', 'weakestScore', 0.0, ...
            'fixHints', {{'No microFramework provided. Call sl_micro_design first.'}}, ...
            'passed', false, 'threshold', 0.65);
        return;
    end

    mf = microFramework;
    
    % [v26 FIX R1] Check if zero-dynamic subsystem (no states, no integrators).
    % For purely algebraic/parametric subsystems (signal generators, constants, 
    % simple arithmetic), use a different scoring model based on parameter quality.
    isZeroDynamic = false;
    if isfield(mf, 'signalDimensions') && isstruct(mf.signalDimensions)
        if isfield(mf.signalDimensions, 'states')
            isZeroDynamic = (mf.signalDimensions.states == 0);
        end
    end
    if ~isZeroDynamic
        % Also check blockPlan for integrators
        if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
            nInt = sl_rigor_utils('count_integrators', mf.blockPlan);
            if isstruct(nInt) && isfield(nInt, 'data'), nInt = nInt.data; end
            if nInt == 0
                % Still has physics equations with derivatives? Check.
                if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
                    nDeriv = sl_rigor_utils('count_derivative_operators', mf.physicsEquations);
                    if isstruct(nDeriv) && isfield(nDeriv, 'data'), nDeriv = nDeriv.data; end
                    if nDeriv == 0
                        isZeroDynamic = true;
                    end
                end
            end
        end
    end
    
    c = compute_completeness(mf);
    s = compute_self_consistency(mf);
    t = compute_traceability(mf);
    j = compute_justifiability(mf);

    % [v26 FIX R1] Zero-dynamic subsystem: recalculate with parametric model
    if isZeroDynamic
        % Parametric completeness: score based on parameter definition quality
        paramScore = 1.0;
        if isfield(mf, 'parameters') && ~isempty(mf.parameters)
            params = mf.parameters;
            if iscell(params), nParams = length(params);
            elseif isstruct(params), nParams = length(params);
            else nParams = 0; end
            if nParams >= 5
                paramScore = 1.0;
            elseif nParams >= 3
                paramScore = 0.90;
            elseif nParams >= 2
                paramScore = 0.75;
            elseif nParams >= 1
                paramScore = 0.55;
            else
                paramScore = 0.30;
            end
        end
        % Justifiability: use confidence directly
        conf = 0.7;
        if isfield(mf, 'confidence'), conf = max(0.0, min(1.0, mf.confidence)); end
        % Traceability: high when blockPlan maps to outputs
        blockScore = 0.8;
        if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
            bp = mf.blockPlan;
            if iscell(bp), nBlocks = length(bp);
            elseif isstruct(bp), nBlocks = length(bp);
            else nBlocks = 0; end
            if nBlocks >= 3, blockScore = 1.0;
            elseif nBlocks >= 2, blockScore = 0.90;
            elseif nBlocks >= 1, blockScore = 0.70;
            else blockScore = 0.30; end
        end
        % New weights for zero-dynamic: parameter quality driven
        c = paramScore;
        s = paramScore * 0.8;  % self-consistency from parameter consistency
        t = blockScore;
        j = conf;
    end
    
    score = c * 0.30 + s * 0.35 + t * 0.20 + j * 0.15;
    dimScores = [c, s, t, j];
    dimNames = {'completeness', 'selfConsistency', 'traceability', 'justifiability'};
    [weakestScore, weakestIdx] = min(dimScores);
    weakest = dimNames{weakestIdx};
    fixHints = generate_fix_hints(weakest, mf, weakestScore);
    RIGOR_THRESHOLD = 0.65;  % [v25 FIX RC2] Restored. Design review now independent of build state.

    result = struct('score', score, ...
        'breakdown', struct('completeness', c, 'selfConsistency', s, ...
            'traceability', t, 'justifiability', j), ...
        'weakest', weakest, 'weakestScore', weakestScore, ...
        'fixHints', {fixHints}, 'passed', score >= RIGOR_THRESHOLD, ...
        'threshold', RIGOR_THRESHOLD);
end

function score = compute_completeness(mf)
    nEq = 0; nStates = 0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        nEq = count_nonempty_equations(mf.physicsEquations);
    end
    if isfield(mf, 'signalDimensions') && ~isempty(mf.signalDimensions)
        sd = mf.signalDimensions;
        if isfield(sd, 'states'), nStates = sd.states; end
    end
    if nStates > 0
        eqRatio = min(nEq / nStates, 1.0);
    else
        % [v22 FIX D1] Zero-state subsystems: use blockPlan size as complexity proxy.
        % Previous: max(nStates,1) = 1 for nStates=0, giving full eqRatio credit
        % for ANY >=1 equation — making trivial signal generators score as high
        % as multi-state dynamic systems. Now: nBlocks acts as expected-equation-count.
        % A 4-block signal generator needs >=4 equations for full completeness.
        nBlocks = 1;
        if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
            nBlocks = max(length(mf.blockPlan), 1);
        end
        eqRatio = min(nEq / nBlocks, 1.0);
        % [v22 FIX D3] Blend: 50% equation coverage + 50% operator complexity.
        % Pure signal generators (Step/Constant) get penalty from low operator density.
        oc_raw = sl_rigor_utils('compute_operator_complexity', mf);
        if isstruct(oc_raw) && isfield(oc_raw, 'data')
            opDensity = oc_raw.data;
            eqRatio = eqRatio * (0.5 + 0.5 * opDensity);
        end
    end

    paramCoverage = 0.0;
    if isfield(mf, 'parameters') && ~isempty(mf.parameters)
        params = mf.parameters; nParams = length(params); nComplete = 0;
        for i = 1:nParams
            p = sl_safe_index(params, i);
            hasValue = isfield(p, 'value') && ~isempty(p.value);
            hasUnit = isfield(p, 'unit') && ~isempty(p.unit);
            if hasValue && hasUnit, nComplete = nComplete + 1; end
        end
        paramCoverage = nComplete / max(nParams, 1);
    end

    % [v22 FIX D2] Weight paramCoverage by actual parameter usage in equations.
    % Parameters that are documented (value+unit) but never appear in equations
    % get discounted. Uses existing check_parameter_usage() from sl_rigor_utils.
    % Blend: 50% from documentation quality, 50% from actual usage ratio.
    % Usage ratio=1.0 → no discount; ratio=0.5 → discounted to 75% of original.
    if paramCoverage > 0 && isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        usage = sl_rigor_utils('check_parameter_usage', mf);
        if isstruct(usage) && isfield(usage, 'ratio')
            paramCoverage = paramCoverage * (0.5 + 0.5 * usage.ratio);
        end
    end

    hasBlockPlan = 0.0;
    if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
        if length(mf.blockPlan) > 0, hasBlockPlan = 1.0; end
    end

    icCoverage = 0.0;
    if nStates > 0 && isfield(mf, 'initialConditions') && ~isempty(mf.initialConditions)
        ic = mf.initialConditions;
        if iscell(ic) || isstruct(ic), icCoverage = min(length(ic) / nStates, 1.0); end
    end

    score = eqRatio * 0.4 + paramCoverage * 0.3 + hasBlockPlan * 0.2 + icCoverage * 0.1;
    
    % [v24 FIX BUG-004] Container subsystem exemption:
    % Subsystems with childSubsystems but no internal dynamics (e.g.,
    % ADRC_Controller routing hub) should not be penalized for lacking
    % differential equations. MAAB db_0038 only requires single clear function.
    is_container = false;
    if isfield(mf, 'childSubsystems') && ~isempty(mf.childSubsystems)
        is_container = true;
    elseif isfield(mf, 'children') && ~isempty(mf.children)
        is_container = true;
    elseif isfield(mf, 'type')
        is_container = any(strcmpi(mf.type, {'controller_hub', 'container', 'routing'}));
    end
    if is_container && nStates == 0
        score = min(1.0, score * 1.5);
    end
end

function score = compute_self_consistency(mf)
    varCoverage = 1.0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        allVars_raw = sl_rigor_utils('extract_variables', mf.physicsEquations);
        allVars = extract_data(allVars_raw);
        definedVars_raw = sl_rigor_utils('get_defined_variables', mf);
        definedVars = extract_data(definedVars_raw);
        if ~isempty(allVars)
            % [v19 FIX #NEW-7] Fuzzy variable matching: equation variables may use
            % shortened names vs parameter definitions (e.g. 'A' → 'A_Reference_Generator').
            % Match strategy (ordered by strictness):
            %   1. Exact match
            %   2. Equation variable is prefix of defined variable + '_' (A → A_xxx)
            %   3. Case-insensitive match (robustness)
            nMissing = 0;
            for i = 1:length(allVars)
                evar = allVars{i};
                isDefined = false;
                for j = 1:length(definedVars)
                    dvar = definedVars{j};
                    % Exact match
                    if strcmp(evar, dvar)
                        isDefined = true; break;
                    end
                    % Prefix match: evar is prefix of dvar followed by '_'
                    % R2016a compatible (no startsWith): manual length check + strcmp
                    lenE = length(evar);
                    lenD = length(dvar);
                    if lenD >= lenE + 1 && strcmp(dvar(1:lenE), evar) && dvar(lenE+1) == '_'
                        isDefined = true; break;
                    end
                    % Case-insensitive fallback
                    if strcmpi(evar, dvar)
                        isDefined = true; break;
                    end
                end
                if ~isDefined
                    nMissing = nMissing + 1;
                end
            end
            varCoverage = 1.0 - nMissing / length(allVars);
        end
    end

    integratorMatch = 1.0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        nDeriv_raw = sl_rigor_utils('count_derivative_operators', mf.physicsEquations);
        nDeriv = extract_data(nDeriv_raw);
        nInt = 0;
        if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
            nInt_raw = sl_rigor_utils('count_integrators', mf.blockPlan);
            nInt = extract_data(nInt_raw);
        end
        if nDeriv > 0 || nInt > 0
            integratorMatch = 1.0 - abs(nDeriv - nInt) / max(max(nDeriv, nInt), 1);
            integratorMatch = max(0.0, integratorMatch);
        end
    end

    opCoverage = 1.0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations) && ...
       isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
        cov = sl_rigor_utils('check_operation_coverage', mf);
        if isstruct(cov) && isfield(cov, 'ratio'), opCoverage = cov.ratio; end
    end

    % [v22 FIX D3] Introduce operator complexity as self-consistency sub-factor.
    % Previous weights: varCoverage=0.4, integratorMatch=0.3, opCoverage=0.3
    % New: takes 0.15 each from varCoverage and integratorMatch for opComplexity.
    % Operator complexity distinguishes trivial math (add/sub only) from
    % non-trivial math (ddt, sin, exp, pow) — purely formal, no domain knowledge.
    opComplexity_raw = sl_rigor_utils('compute_operator_complexity', mf);
    if isstruct(opComplexity_raw) && isfield(opComplexity_raw, 'data')
        opComplexity = opComplexity_raw.data;
    else
        opComplexity = 0.0;
    end
    score = varCoverage * 0.25 + integratorMatch * 0.15 + opCoverage * 0.30 + opComplexity * 0.30;
    
    % [v26 FIX R1] Zero-dynamic subsystem: if signalDimensions.states == 0,
    % the subsystem has no dynamical state variables. Use parameter
    % completeness score instead of dynamical self-consistency.
    nStates = 0;
    if isfield(mf, 'signalDimensions') && isstruct(mf.signalDimensions)
        if isfield(mf.signalDimensions, 'states')
            nStates = mf.signalDimensions.states;
        end
    end
    if nStates == 0
        paramCoverage = 1.0;
        if isfield(mf, 'parameters') && ~isempty(mf.parameters)
            if iscell(mf.parameters)
                nParams = length(mf.parameters);
            else
                nParams = length(mf.parameters);
            end
            if nParams >= 4
                paramCoverage = 1.0;
            elseif nParams >= 2
                paramCoverage = 0.85;
            elseif nParams >= 1
                paramCoverage = 0.70;
            else
                paramCoverage = 0.50;
            end
        else
            paramCoverage = 0.35;
        end
        score = varCoverage * 0.50 + paramCoverage * 0.50;
    end
end

function score = compute_traceability(mf)
    eqToBlock = 1.0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations) && ...
       isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
        bp = mf.blockPlan; eqs = mf.physicsEquations;
        allOps = {};
        if iscell(eqs)
            for i = 1:length(eqs)
                e = eq_to_string(eqs{i});
                if ~isempty(e)
                    ops_raw = sl_rigor_utils('extract_operators', e);
                    ops = extract_data(ops_raw);
                    allOps = [allOps, ops];
                end
            end
        elseif isstruct(eqs)
            for i = 1:length(eqs)
                e = eq_to_string(eqs(i));
                if ~isempty(e)
                    ops_raw = sl_rigor_utils('extract_operators', e);
                    ops = extract_data(ops_raw);
                    allOps = [allOps, ops];
                end
            end
        end
        if ~isempty(allOps) && ~isempty(bp)
            nMapped = 0; nTotal = length(bp);
            for i = 1:nTotal
                b = sl_safe_index(bp, i); btype = '';
                if isfield(b, 'blockType'), btype = lower(b.blockType);
                elseif isfield(b, 'type'), btype = lower(b.type); end
                if is_empty_or_mapped(btype, allOps), nMapped = nMapped + 1; end
            end
            eqToBlock = nMapped / nTotal;
        end
    end

    paramUsage = 1.0;
    if isfield(mf, 'parameters') && ~isempty(mf.parameters) && ...
       isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        usage = sl_rigor_utils('check_parameter_usage', mf);
        if isstruct(usage) && isfield(usage, 'ratio'), paramUsage = usage.ratio; end
    end

    noOrphans = 1.0;
    if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
        orphan = sl_rigor_utils('check_no_orphan_blocks', mf);
        if isstruct(orphan) && isfield(orphan, 'ratio'), noOrphans = orphan.ratio; end
    end

    score = eqToBlock * 0.4 + paramUsage * 0.3 + noOrphans * 0.3;
end

function score = compute_justifiability(mf)
    hasDerivation = 0.0;
    if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
        eqs = mf.physicsEquations; nEq = length(eqs); nWithDeriv = 0;
        for i = 1:nEq
            eq = sl_safe_index(eqs, i);
            if isstruct(eq) && isfield(eq, 'derivedFrom') && ~isempty(eq.derivedFrom)
                nWithDeriv = nWithDeriv + 1;
            end
        end
        if nEq > 0, hasDerivation = nWithDeriv / nEq; end
    end

    hasAssumptions = 0.0;
    if isfield(mf, 'assumptions') && ~isempty(mf.assumptions), hasAssumptions = 1.0; end

    hasConfidence = 0.0;
    if isfield(mf, 'confidence') && ~isempty(mf.confidence)
        if isnumeric(mf.confidence) && mf.confidence >= 0.3, hasConfidence = 1.0; end
    end

    hasReasoning = 0.0;
    if isfield(mf, 'reasoning') && ~isempty(mf.reasoning)
        if ischar(mf.reasoning) && length(mf.reasoning) > 50, hasReasoning = 1.0; end
    end

    score = hasDerivation * 0.35 + hasAssumptions * 0.25 + hasConfidence * 0.20 + hasReasoning * 0.20;
end

function hints = generate_fix_hints(weakest, mf, weakestScore)
    hints = {};
    switch weakest
        case 'completeness'
            if ~isfield(mf, 'physicsEquations') || isempty(mf.physicsEquations)
                hints{end+1} = 'Add physicsEquations field with derived equations';
            else
                nEq = count_nonempty_equations(mf.physicsEquations); nStates = 0;
                if isfield(mf, 'signalDimensions') && isfield(mf.signalDimensions, 'states')
                    nStates = mf.signalDimensions.states;
                end
                if nEq < max(nStates, 1)
                    hints{end+1} = sprintf('Only %d equations for %d states -- add missing state equations', nEq, nStates);
                end
            end
            if ~isfield(mf, 'parameters') || isempty(mf.parameters)
                hints{end+1} = 'Define parameters with name, value, and unit fields';
            end
            if ~isfield(mf, 'blockPlan') || isempty(mf.blockPlan)
                hints{end+1} = 'Create blockPlan mapping equations to Simulink blocks';
            end

        case 'selfConsistency'
            if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
                allVars = extract_data(sl_rigor_utils('extract_variables', mf.physicsEquations));
                definedVars = extract_data(sl_rigor_utils('get_defined_variables', mf));
                undefined = {};
                for i = 1:length(allVars)
                    if ~any(strcmp(allVars{i}, definedVars))
                        undefined{end+1} = allVars{i};
                    end
                end
                if ~isempty(undefined)
                    if length(undefined) <= 5
                        undefStr = sl_framework_utils('strjoin_safe', undefined, ', ');
                    else
                        undefStr = [sl_framework_utils('strjoin_safe', undefined(1:5), ', ') ...
                            sprintf(' ... and %d more', length(undefined)-5)];
                    end
                    hints{end+1} = sprintf('Undefined variables in equations: %s', undefStr);
                end
            end
            nDeriv = 0; nInt = 0;
            if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
                nDeriv = extract_data(sl_rigor_utils('count_derivative_operators', mf.physicsEquations));
            end
            if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
                nInt = extract_data(sl_rigor_utils('count_integrators', mf.blockPlan));
            end
            if nDeriv ~= nInt
                hints{end+1} = sprintf('%d derivative operators but %d Integrator blocks -- add %d more Integrator(s)', ...
                    nDeriv, nInt, abs(nDeriv-nInt));
            end

        case 'traceability'
            if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
                orphan = sl_rigor_utils('check_no_orphan_blocks', mf);
                if isstruct(orphan) && isfield(orphan, 'orphanBlocks') && ~isempty(orphan.orphanBlocks)
                    ob = orphan.orphanBlocks;
                    orphanStr = sl_framework_utils('strjoin_safe', ob(1:min(3, end)), ', ');
                    hints{end+1} = sprintf('Blocks not traceable to equations: %s', orphanStr);
                end
            end

        case 'justifiability'
            if isfield(mf, 'physicsEquations') && ~isempty(mf.physicsEquations)
                eqs = mf.physicsEquations; nMissingDeriv = 0;
                for i = 1:length(eqs)
                    eq = sl_safe_index(eqs, i);
                    if ~isstruct(eq) || ~isfield(eq, 'derivedFrom') || isempty(eq.derivedFrom)
                        nMissingDeriv = nMissingDeriv + 1;
                    end
                end
                if nMissingDeriv > 0
                    hints{end+1} = sprintf('%d equations missing derivedFrom field (cite physical law)', nMissingDeriv);
                end
            end
            if ~isfield(mf, 'assumptions') || isempty(mf.assumptions)
                hints{end+1} = 'Add assumptions field listing modeling assumptions';
            end
    end
    if isempty(hints)
        hints{1} = sprintf('Improve %s dimension (score: %.2f)', weakest, weakestScore);
    end
end

function n = count_nonempty_equations(eqs)
    n = 0;
    for i = 1:length(eqs)
        e = sl_safe_index(eqs, i); s = eq_to_string(e);
        if ~isempty(s), n = n + 1; end
    end
end

function s = eq_to_string(eq)
    if ischar(eq), s = eq;
    elseif isstruct(eq) && isfield(eq, 'equation'), s = eq.equation;
    elseif iscell(eq), s = sl_framework_utils('strjoin_safe', eq, ' ');
    else s = '';
    end
end

function d = extract_data(result)
    if isstruct(result) && isfield(result, 'data'), d = result.data;
    else d = result;
    end
end

function tf = is_empty_or_mapped(btype, allOps)
    if isempty(btype), tf = true; return; end
    structural = {'inport', 'outport', 'subsystem', 'goto', 'from', 'terminator', 'ground', ...
        'buscreator', 'busselector', 'mux', 'demux'};
    if any(strcmp(btype, structural)), tf = true; return; end
    opMap = containers.Map();
    opMap('ddt') = {{'integrator'}};
    opMap('mult') = {{'gain', 'product'}};
    opMap('div') = {{'divide', 'gain', 'product'}};
    opMap('add') = {{'sum'}}; opMap('sub') = {{'sum'}};
    opMap('sin') = {{'trigonometric function', 'trigonometricfunction'}};
    opMap('cos') = {{'trigonometric function', 'trigonometricfunction'}};
    opMap('tan') = {{'trigonometric function', 'trigonometricfunction'}};
    opMap('sqrt') = {{'sqrt'}};
    opMap('pow') = {{'math function', 'mathfunction'}};
    opMap('exp') = {{'math function', 'mathfunction'}};
    opMap('log') = {{'math function', 'mathfunction'}};
    opMap('abs') = {{'abs'}};
    opMap('integral') = {{'integrator'}};
    for i = 1:length(allOps)
        op = allOps{i};
        if isKey(opMap, op)
            candidates = opMap(op); candidates = candidates{1};
            for c = 1:length(candidates)
                if ~isempty(strfind(btype, candidates{c})), tf = true; return; end
            end
        end
    end
    tf = false;
end
