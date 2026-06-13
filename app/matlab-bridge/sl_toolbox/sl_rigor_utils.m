function result = sl_rigor_utils(action, varargin)
% SL_RIGOR_UTILS Domain-agnostic symbolic analysis helpers for Rigor Score
%   result = sl_rigor_utils(action, data, ...)
%
% Actions:
%   'extract_variables'          Extract variable names from equation strings
%   'count_derivative_operators' Count d/dt (or dx/dt) operators in equations
%   'count_integrators'          Count Integrator blocks in blockPlan
%   'check_operation_coverage'   Check equation operators -> block type mapping
%   'check_parameter_usage'      Check parameter reference graph
%   'check_no_orphan_blocks'     Detect blocks with no corresponding equation
%   'get_defined_variables'      Collect all defined variables from microFramework
%   'split_equation'             Split equation into LHS/RHS/operators
%   'extract_operators'          Extract mathematical operators from equation text
%
% v12.0: New module for Rigor Score engine. Pure formal logic, zero domain knowledge.
% R2016a+ compatible (no string type, no contains(), no startsWith/endsWith).

    if nargin < 1
        result = struct('status', 'error', 'message', 'sl_rigor_utils: action required');
        return;
    end

    switch lower(action)
        case 'extract_variables'
            data = extract_variables(varargin{:});
            result = struct('status', 'ok', 'action', 'extract_variables', 'data', {data});
        case 'count_derivative_operators'
            data = count_derivative_operators(varargin{:});
            result = struct('status', 'ok', 'action', 'count_derivative_operators', 'data', data);
        case 'count_integrators'
            data = count_integrators(varargin{:});
            result = struct('status', 'ok', 'action', 'count_integrators', 'data', data);
        case 'check_operation_coverage'
            result = check_operation_coverage(varargin{:});
            result.status = 'ok';
            result.action = 'check_operation_coverage';
        case 'check_parameter_usage'
            result = check_parameter_usage(varargin{:});
            result.status = 'ok';
            result.action = 'check_parameter_usage';
        case 'check_no_orphan_blocks'
            result = check_no_orphan_blocks(varargin{:});
            result.status = 'ok';
            result.action = 'check_no_orphan_blocks';
        case 'get_defined_variables'
            data = get_defined_variables(varargin{:});
            result = struct('status', 'ok', 'action', 'get_defined_variables', 'data', {data});
        case 'compute_operator_complexity'  % v22 FIX D3
            data = compute_operator_complexity(varargin{:});
            result = struct('status', 'ok', 'action', 'compute_operator_complexity', 'data', data);
        case 'split_equation'
            result = split_equation(varargin{:});
            result.status = 'ok';
            result.action = 'split_equation';
        case 'extract_operators'
            data = extract_operators(varargin{:});
            result = struct('status', 'ok', 'action', 'extract_operators', 'data', {data});
        otherwise
            result = struct('status', 'error', ...
                'message', sprintf('sl_rigor_utils: unknown action "%s"', action));
    end
end

% =========================================================================
% extract_variables -- Extract variable names from equation strings
%   vars = sl_rigor_utils('extract_variables', equations)
%
% Recognizes identifiers: [a-zA-Z][a-zA-Z0-9_]*
% Filters out: math constants, operators, function names, numbers
% Returns: unique sorted cell array of variable name strings
% =========================================================================
function varList = extract_variables(equations)
    if isempty(equations)
        varList = {};
        return;
    end

    % Normalize to cell array of equation strings
    eqStrs = {};
    if iscell(equations)
        for i = 1:length(equations)
            eqStrs{end+1} = eq_to_string(equations{i});
        end
    elseif isstruct(equations)
        for i = 1:length(equations)
            eqStrs{end+1} = eq_to_string(equations(i));
        end
    else
        varList = {};
        return;
    end

    % Reserved words to filter out (math functions, constants, operators)
    reserved = {'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', ...
                'sinh', 'cosh', 'tanh', 'exp', 'log', 'log10', 'sqrt', ...
                'abs', 'sign', 'mod', 'rem', 'min', 'max', 'floor', 'ceil', ...
                'round', 'pi', 'inf', 'nan', 'eps', 'realmax', 'realmin', ...
                'i', 'j', 'e', 'd', 'dt', 'dx', 'dy', 'dz', 'ddt', ...
                'sum', 'prod', 'diff', 'int', 'integral', ...
                'true', 'false', 'zeros', 'ones', 'eye', 'NaN', 'Inf'};

    allVars = {};
    for i = 1:length(eqStrs)
        s = eqStrs{i};
        if isempty(s)
            continue;
        end
        % Find all identifiers: [a-zA-Z][a-zA-Z0-9_]*
        [starts, ends] = regexp(s, '[a-zA-Z][a-zA-Z0-9_]*');
        if isempty(starts)
            continue;
        end
        for j = 1:length(starts)
            token = s(starts(j):ends(j));
            % Skip reserved words
            if ~any(strcmpi(token, reserved))
                allVars{end+1} = token;
            end
        end
    end

    if isempty(allVars)
        varList = {};
        return;
    end
    varList = unique(allVars);
end

% =========================================================================
% count_derivative_operators -- Count d/dt, dx/dt, d2x/dt2, etc.
%   n = sl_rigor_utils('count_derivative_operators', equations)
%
% Patterns: d/dt, dx/dt, d2x/dt2, d(x)/dt, dot{x}, x_dot, x', x'' 
% =========================================================================
function nDeriv = count_derivative_operators(equations)
    nDeriv = 0;
    if isempty(equations)
        return;
    end

    % Normalize
    eqStrs = {};
    if iscell(equations)
        for i = 1:length(equations)
            eqStrs{end+1} = eq_to_string(equations{i});
        end
    elseif isstruct(equations)
        for i = 1:length(equations)
            eqStrs{end+1} = eq_to_string(equations(i));
        end
    else
        return;
    end

    % Pattern: d[x]/dt, d2[x]/dt2, or simpler forms
    for i = 1:length(eqStrs)
        s = eqStrs{i};
        if isempty(s)
            continue;
        end
        % Count d.../dt patterns (MATLAB regexp)
        [matches] = regexp(s, 'd\d*\w*/dt\d*', 'match');
        if ~isempty(matches)
            nDeriv = nDeriv + length(matches);
        end
        % Count x_dot patterns (commonly used in control literature)
        [matches] = regexp(s, '\w+_dot\b', 'match');
        if ~isempty(matches)
            nDeriv = nDeriv + length(matches);
        end
        % Count \dot{x} LaTeX patterns
        [matches] = regexp(s, '\\dot\{\w+\}', 'match');
        if ~isempty(matches)
            nDeriv = nDeriv + length(matches);
        end
    end
end

% =========================================================================
% count_integrators -- Count Integrator blocks in blockPlan
%   n = sl_rigor_utils('count_integrators', blockPlan)
% =========================================================================
function nInt = count_integrators(blockPlan)
    nInt = 0;
    if isempty(blockPlan)
        return;
    end

    for i = 1:length(blockPlan)
        b = sl_safe_index(blockPlan, i);
        btype = '';
        if isfield(b, 'blockType')
            btype = b.blockType;
        elseif isfield(b, 'type')
            btype = b.type;
        end
        if ~isempty(strfind(lower(btype), 'integrator'))
            cnt = 1;
            if isfield(b, 'count')
                cnt = b.count;
            end
            nInt = nInt + cnt;
        end
    end
end

% =========================================================================
% check_operation_coverage -- Check if every equation operator has a block
%   coverage = sl_rigor_utils('check_operation_coverage', microFramework)
%
% Maps: d/dt->Integrator, *->Gain/Product, +/-->Sum, sin/cos->Trig,
%        sqrt->Sqrt, 1/s->Integrator, /->Divide, ^->Math Function
% Returns: struct(ratio, missingOps, coveredOps)
% =========================================================================
function result = check_operation_coverage(microFramework)
    result = struct('ratio', 0.0, 'missingOps', {{}}, 'coveredOps', {{}});

    if ~isfield(microFramework, 'physicsEquations') || isempty(microFramework.physicsEquations)
        return;
    end
    if ~isfield(microFramework, 'blockPlan') || isempty(microFramework.blockPlan)
        return;
    end

    eqs = microFramework.physicsEquations;
    bp = microFramework.blockPlan;

    % Extract all operators from equations
    allOps = {};
    if iscell(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs{i});
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                allOps = [allOps, ops];
            end
        end
    elseif isstruct(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs(i));
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                allOps = [allOps, ops];
            end
        end
    end

    if isempty(allOps)
        result.ratio = 1.0;
        return;
    end
    allOps = unique(allOps);

    % Get covered block types
    coveredTypes = {};
    for i = 1:length(bp)
        b = sl_safe_index(bp, i);
        btype = '';
        if isfield(b, 'blockType')
            btype = b.blockType;
        elseif isfield(b, 'type')
            btype = b.type;
        end
        coveredTypes{end+1} = lower(btype);
    end

    % Map operators to required block types
    opToBlock = struct();
    opToBlock.ddt = {'integrator'};
    opToBlock.mult = {'gain', 'product'};
    opToBlock.div = {'divide', 'gain', 'product'};
    opToBlock.add = {'sum'};
    opToBlock.sub = {'sum'};
    opToBlock.sin = {'trigonometric function'};
    opToBlock.cos = {'trigonometric function'};
    opToBlock.tan = {'trigonometric function'};
    opToBlock.sqrt = {'sqrt'};
    opToBlock.pow = {'math function'};
    opToBlock.abs = {'abs'};
    opToBlock.exp = {'math function'};
    opToBlock.log = {'math function'};
    opToBlock.integral = {'integrator'};

    covered = 0;
    missing = {};
    coveredList = {};

    for i = 1:length(allOps)
        op = allOps{i};
        if isfield(opToBlock, op)
            required = opToBlock.(op);
            found = false;
            for r = 1:length(required)
                if any(strncmp(coveredTypes, required{r}, min(length(required{r}), 5)))
                    found = true;
                    break;
                end
            end
            if found
                covered = covered + 1;
                coveredList{end+1} = op;
            else
                missing{end+1} = op;
            end
        else
            % Unknown operator -- skip (domain-agnostic)
            covered = covered + 1;
        end
    end

    result.ratio = covered / max(length(allOps), 1);
    result.missingOps = missing;
    result.coveredOps = coveredList;
end

% =========================================================================
% check_parameter_usage -- Check if all parameters are referenced in equations
%   usage = sl_rigor_utils('check_parameter_usage', microFramework)
%
% Returns: struct(ratio, unusedParams, usedParams)
% =========================================================================
function result = check_parameter_usage(microFramework)
    result = struct('ratio', 0.0, 'unusedParams', {{}}, 'usedParams', {{}});

    if ~isfield(microFramework, 'parameters') || isempty(microFramework.parameters)
        result.ratio = 1.0;
        return;
    end
    if ~isfield(microFramework, 'physicsEquations') || isempty(microFramework.physicsEquations)
        return;
    end

    params = microFramework.parameters;
    eqs = microFramework.physicsEquations;

    % Collect all equation text
    allEqText = '';
    if iscell(eqs)
        for i = 1:length(eqs)
            allEqText = [allEqText ' ' eq_to_string(eqs{i})];
        end
    elseif isstruct(eqs)
        for i = 1:length(eqs)
            allEqText = [allEqText ' ' eq_to_string(eqs(i))];
        end
    end

    paramNames = {};
    for i = 1:length(params)
        p = sl_safe_index(params, i);
        pname = '';
        if isfield(p, 'name')
            pname = p.name;
        elseif isfield(p, 'symbol')
            pname = p.symbol;
        end
        if isempty(pname) && ischar(p)
            pname = p;
        end
        paramNames{end+1} = pname;
    end

    used = {};
    unused = {};
    for i = 1:length(paramNames)
        if ~isempty(paramNames{i}) && ~isempty(strfind(allEqText, paramNames{i}))
            used{end+1} = paramNames{i};
        else
            unused{end+1} = paramNames{i};
        end
    end

    result.ratio = length(used) / max(length(paramNames), 1);
    result.unusedParams = unused;
    result.usedParams = used;
end

% =========================================================================
% check_no_orphan_blocks -- Detect blocks in blockPlan with no equation mapping
%   orphan = sl_rigor_utils('check_no_orphan_blocks', microFramework)
%
% Returns: struct(ratio, orphanBlocks [names], mappedBlocks [names])
% =========================================================================
function result = check_no_orphan_blocks(microFramework)
    result = struct('ratio', 1.0, 'orphanBlocks', {{}}, 'mappedBlocks', {{}});

    if ~isfield(microFramework, 'blockPlan') || isempty(microFramework.blockPlan)
        return;
    end
    if ~isfield(microFramework, 'physicsEquations') || isempty(microFramework.physicsEquations)
        result.ratio = 0.0;
        for i = 1:length(microFramework.blockPlan)
            b = sl_safe_index(microFramework.blockPlan, i);
            bname = '';
            if isfield(b, 'blockType'), bname = b.blockType; end
            result.orphanBlocks{end+1} = bname;
        end
        return;
    end

    bp = microFramework.blockPlan;
    eqs = microFramework.physicsEquations;

    % Extract all operators from equations
    allOps = {};
    if iscell(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs{i});
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                allOps = [allOps, ops];
            end
        end
    elseif isstruct(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs(i));
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                allOps = [allOps, ops];
            end
        end
    end
    allOps = unique(allOps);

    % Classify each block
    orphan = {};
    mapped = {};

    % Allowed structural blocks (always considered mapped)
    structural = {'inport', 'outport', 'subsystem', 'goto', 'from', 'terminator', 'ground'};

    for i = 1:length(bp)
        b = sl_safe_index(bp, i);
        btype = '';
        if isfield(b, 'blockType')
            btype = lower(b.blockType);
        elseif isfield(b, 'type')
            btype = lower(b.type);
        end

        if any(strcmp(btype, structural))
            mapped{end+1} = btype;
            continue;
        end

        % Check if block type is needed for any equation operation
        needed = false;
        if ~isempty(strfind(btype, 'integrator')) && any(strcmp(allOps, 'ddt'))
            needed = true;
        elseif (~isempty(strfind(btype, 'gain')) || ~isempty(strfind(btype, 'product'))) && ...
               (any(strcmp(allOps, 'mult')) || any(strcmp(allOps, 'div')))
            needed = true;
        elseif ~isempty(strfind(btype, 'sum')) && ...
               (any(strcmp(allOps, 'add')) || any(strcmp(allOps, 'sub')))
            needed = true;
        elseif ~isempty(strfind(btype, 'trigonometric')) && ...
               (any(strcmp(allOps, 'sin')) || any(strcmp(allOps, 'cos')) || any(strcmp(allOps, 'tan')))
            needed = true;
        elseif ~isempty(strfind(btype, 'sqrt')) && any(strcmp(allOps, 'sqrt'))
            needed = true;
        elseif ~isempty(strfind(btype, 'math function')) && ...
               (any(strcmp(allOps, 'pow')) || any(strcmp(allOps, 'exp')))
            needed = true;
        elseif ~isempty(strfind(btype, 'abs')) && any(strcmp(allOps, 'abs'))
            needed = true;
        else
            % Unknown mapping -- could be Constant, BusCreator, etc.
            % Give benefit of doubt but track
            needed = true;
        end

        if needed
            mapped{end+1} = btype;
        else
            orphan{end+1} = btype;
        end
    end

    nTotal = max(length(bp), 1);
    result.ratio = length(mapped) / nTotal;
    result.orphanBlocks = orphan;
    result.mappedBlocks = mapped;
end

% =========================================================================
% get_defined_variables -- Collect all defined variables from microFramework
%   vars = sl_rigor_utils('get_defined_variables', microFramework)
%
% Sources: parameters[].name, signalDimensions.states list, inputs/outputs
% =========================================================================
function varList = get_defined_variables(microFramework)
    varList = {};

    % From parameters
    if isfield(microFramework, 'parameters') && ~isempty(microFramework.parameters)
        for i = 1:length(microFramework.parameters)
            p = sl_safe_index(microFramework.parameters, i);
            if isfield(p, 'name') && ~isempty(p.name)
                varList{end+1} = p.name;
            elseif isfield(p, 'symbol') && ~isempty(p.symbol)
                varList{end+1} = p.symbol;
            end
        end
    end

    % From state variables (if listed)
    if isfield(microFramework, 'stateVariables') && ~isempty(microFramework.stateVariables)
        sv = microFramework.stateVariables;
        if iscell(sv)
            varList = [varList, sv];
        elseif isstruct(sv)
            for i = 1:length(sv)
                s = sv(i);
                if isfield(s, 'name')
                    varList{end+1} = s.name;
                elseif isfield(s, 'symbol')
                    varList{end+1} = s.symbol;
                end
            end
        end
    end

    % From blockPlan (Signal Generator, Constant names, etc.)
    if isfield(microFramework, 'blockPlan') && ~isempty(microFramework.blockPlan)
        for i = 1:length(microFramework.blockPlan)
            b = sl_safe_index(microFramework.blockPlan, i);
            if isfield(b, 'name') && ~isempty(b.name)
                varList{end+1} = b.name;
            elseif isfield(b, 'label') && ~isempty(b.label)
                varList{end+1} = b.label;
            end
        end
    end

    % Deduplicate
    if ~isempty(varList)
        varList = unique(varList);
    end
end

% =========================================================================
% split_equation -- Split equation string into LHS, RHS, and operators
%   parts = sl_rigor_utils('split_equation', eqStr)
%
% Returns: struct(lhs, rhs, operators)
% =========================================================================
function parts = split_equation(eqStr)
    parts = struct('lhs', '', 'rhs', '', 'operators', {{}});

    if isempty(eqStr)
        return;
    end

    e = eqStr;
    % Find = sign
    eqPos = strfind(e, '=');
    if isempty(eqPos)
        % No equals sign -- treat whole string as expression
        parts.lhs = '';
        parts.rhs = strtrim(e);
    else
        parts.lhs = strtrim(e(1:eqPos(1)-1));
        parts.rhs = strtrim(e(eqPos(1)+1:end));
    end

    % Extract operators from RHS (primary)
    parts.operators = extract_operators_from_str(parts.rhs);
end

% =========================================================================
% extract_operators -- Extract mathematical operators from equation text
%   ops = sl_rigor_utils('extract_operators', eqStr)
%
% Returns: cell array of operator names (ddt, mult, div, add, sub, etc.)
% =========================================================================
function ops = extract_operators(eqStr)
    ops = extract_operators_from_str(eqStr);
end

% =========================================================================
% Internal: extract operators from a string
% =========================================================================
function ops = extract_operators_from_str(s)
    ops = {};
    if isempty(s)
        return;
    end

    % d/dt derivatives
    if ~isempty(regexp(s, 'd\w*/dt', 'once'))
        ops{end+1} = 'ddt';
    end
    if ~isempty(regexp(s, '\w+_dot\b', 'once'))
        ops{end+1} = 'ddt';
    end
    if ~isempty(strfind(s, '\dot{'))
        ops{end+1} = 'ddt';
    end

    % Integral (1/s) operator
    if ~isempty(strfind(s, '1/s')) || ~isempty(strfind(s, 'integral'))
        ops{end+1} = 'integral';
    end

    % Multiplication
    if ~isempty(strfind(s, '*')) || ~isempty(strfind(s, '.*'))
        ops{end+1} = 'mult';
    end

    % Division
    if ~isempty(strfind(s, '/')) || ~isempty(strfind(s, './'))
        ops{end+1} = 'div';
    end

    % Addition
    if ~isempty(strfind(s, '+'))
        ops{end+1} = 'add';
    end

    % Subtraction
    if ~isempty(strfind(s, '-'))
        ops{end+1} = 'sub';
    end

    % Trigonometric
    if ~isempty(regexp(s, '\bsin\b', 'once'))
        ops{end+1} = 'sin';
    end
    if ~isempty(regexp(s, '\bcos\b', 'once'))
        ops{end+1} = 'cos';
    end
    if ~isempty(regexp(s, '\btan\b', 'once'))
        ops{end+1} = 'tan';
    end

    % sqrt
    if ~isempty(regexp(s, '\bsqrt\b', 'once'))
        ops{end+1} = 'sqrt';
    end

    % Power
    if ~isempty(strfind(s, '^')) || ~isempty(strfind(s, '.^'))
        ops{end+1} = 'pow';
    end

    % Exponential
    if ~isempty(regexp(s, '\bexp\b', 'once'))
        ops{end+1} = 'exp';
    end

    % Logarithm
    if ~isempty(regexp(s, '\blog\b', 'once'))
        ops{end+1} = 'log';
    end

    % Abs
    if ~isempty(regexp(s, '\babs\b', 'once'))
        ops{end+1} = 'abs';
    end

    if isempty(ops)
        ops = {};
    end
end

% =========================================================================
% Internal: convert equation element (struct or string) to string
% =========================================================================
function s = eq_to_string(eq)
    if ischar(eq)
        s = eq;
    elseif isstruct(eq) && isfield(eq, 'equation')
        s = eq.equation;
    elseif iscell(eq)
        s = sl_framework_utils('strjoin_safe', eq, ' ');
    else
        s = '';
    end
end

% =========================================================================
% compute_operator_complexity -- Domain-agnostic operator complexity score
%   complexity = compute_operator_complexity(microFramework)
%
% [v22 FIX D3] Addresses the missing mathematical complexity dimension in
% Rigor Score. Operators are weighted purely by formal complexity tier:
%   Dynamics:  ddt=3, integral=3
%   Nonlinear: sin/cos/tan/exp/log/pow=2
%   Algebraic: mult/div/sqrt/abs=1
%   Linear:    add/sub=0.5
%
% Normalized: score = sum(weights) / (nEq * maxPerEq), capped at 1.0
% maxPerEq = 3.0 (max achievable per-equation complexity)
%
% Domain-agnostic: zero physics knowledge, purely formal operator counting.
% R2016a+ compatible.
% =========================================================================
function complexity = compute_operator_complexity(microFramework)
    complexity = 0.0;

    if ~isfield(microFramework, 'physicsEquations') || isempty(microFramework.physicsEquations)
        return;
    end
    if ~isfield(microFramework, 'blockPlan') || isempty(microFramework.blockPlan)
        return;
    end

    eqs = microFramework.physicsEquations;

    % Collect all operators from all equations
    allOps = {};
    if iscell(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs{i});
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                if ~isempty(ops)
                    allOps = [allOps, ops];
                end
            end
        end
    elseif isstruct(eqs)
        for i = 1:length(eqs)
            e = eq_to_string(eqs(i));
            if ~isempty(e)
                ops = extract_operators_from_str(e);
                if ~isempty(ops)
                    allOps = [allOps, ops];
                end
            end
        end
    end

    if isempty(allOps)
        complexity = 0.0;
        return;
    end

    % Domain-agnostic operator weight map (purely formal, no physics)
    % [v22 FIX D3] Adjusted: lowered linear operator weights to increase
    % separation between trivial (step functions) and non-trivial (nonlinear ODEs)
    weights = struct();
    weights.ddt = 3.0;      weights.integral = 3.0;
    weights.sin = 2.0;      weights.cos = 2.0;
    weights.tan = 2.0;      weights.exp = 2.0;
    weights.log = 2.0;      weights.pow = 2.0;
    weights.mult = 1.0;     weights.div = 1.0;
    weights.sqrt = 1.0;     weights.abs = 1.0;
    weights.add = 0.3;      weights.sub = 0.3;   % [v22 FIX D3] reduced from 0.5

    totalWeight = 0.0;
    for i = 1:length(allOps)
        op = allOps{i};
        if isfield(weights, op)
            totalWeight = totalWeight + weights.(op);
        end
    end

    nEq = max(length(eqs), 1);
    maxPerEq = 5.0;  % [v22 FIX D3] increased from 3.0 — tighter normalization
    complexity = min(totalWeight / (nEq * maxPerEq), 1.0);
end
