function result = sl_framework_utils(funcName, varargin)
% SL_FRAMEWORK_UTILS Shared utility functions for Phase 1~2~3 framework design
%   result = sl_framework_utils('make_eq', equation, variables, description)
%   result = sl_framework_utils('make_eq', equation, description, variables, assumptions)
%   result = sl_framework_utils('strjoin_safe', cellStr, delimiter)
%   result = sl_framework_utils('regexp_once_safe', str, pattern)
%   result = sl_framework_utils('format_timestamp')
%   result = sl_framework_utils('normalize_to_struct_array', data)
%
% v11.1: Shared utilities extracted from sl_framework_design.m and sl_micro_design.m
%   - make_eq: Build equation struct safely (avoid cell expansion bug #7)
%   - strjoin_safe: R2016a-compatible strjoin fallback
%   - regexp_once_safe: R2016a-compatible regexp('once') fallback
%   - format_timestamp: ISO 8601 timestamp
%   - normalize_to_struct_array: Convert cell-of-struct to struct array (P2-1)

    switch lower(funcName)
        case 'make_eq'
            result = make_eq(varargin{:});
        case 'strjoin_safe'
            result = strjoin_safe(varargin{:});
        case 'regexp_once_safe'
            result = regexp_once_safe(varargin{:});
        case 'format_timestamp'
            result = format_timestamp();
        case 'normalize_to_struct_array'
            result = normalize_to_struct_array_safe(varargin{:});
        otherwise
            result = struct('status', 'error', ...
                'message', sprintf('sl_framework_utils: unknown function "%s"', funcName));
    end
end

% ===== Build equation struct safely (avoid cell expansion bug #7) =====
function eq = make_eq(eqnStr, descStr, varCell, assumpCell)
% Build equation struct using step-by-step assignment to avoid
% MATLAB struct() cell expansion dimension mismatch (pitfall #7)
    eq = struct();
    eq.equation = eqnStr;
    eq.description = descStr;
    if nargin >= 3 && ~isempty(varCell)
        eq.variables = varCell;
    else
        eq.variables = {};
    end
    if nargin >= 4 && ~isempty(assumpCell)
        eq.assumptions = assumpCell;
    else
        eq.assumptions = {};
    end
end

% ===== R2016a-compatible strjoin =====
function result = strjoin_safe(cellStr, delim)
% R2016a-compatible strjoin: strjoin() was introduced in R2016b
% Fallback to manual loop for R2016a
    if nargin < 2 || isempty(delim)
        delim = ' ';
    end
    if exist('strjoin', 'builtin')
        result = strjoin(cellStr, delim);
    else
        if isempty(cellStr)
            result = '';
            return;
        end
        result = cellStr{1};
        for k = 2:length(cellStr)
            result = [result, delim, cellStr{k}]; %#ok<AGROW>
        end
    end
end

% ===== R2016a-compatible regexp('once') =====
function matchResult = regexp_once_safe(str, pattern)
% R2016a-compatible regexp with 'once': regexp(..., 'once') was introduced in R2016b
% Fallback: use regexp without 'once' and take first match
    if exist('regexp', 'builtin') || true
        % regexp exists in all MATLAB versions, but 'once' flag is R2016b+
        % Try with 'once' first, fall back to without
        try
            matchResult = regexp(str, pattern, 'once');
        catch
            matches = regexp(str, pattern);
            if ~isempty(matches)
                matchResult = matches(1);
            else
                matchResult = '';
            end
        end
    end
end

% ===== ISO 8601 timestamp =====
function ts = format_timestamp()
% Generate ISO 8601 timestamp compatible with R2016a+
% datestr(now, 'yyyy-mm-ddTHH:MM:SS') works in R2016a
    ts = datestr(now, 'yyyy-mm-ddTHH:MM:SS');
end

% ===== Normalize cell-of-struct to struct array =====
function sa = normalize_to_struct_array_safe(data)
% [P2-1] Extracted from sl_framework_modify.m for reuse across all framework functions
% Normalize cell-of-struct or struct-array to a proper struct array
% This handles the case where Python Engine assignment converts struct arrays
% to cell arrays of scalar structs (which breaks .field access patterns)
%
% [CRITICAL] Uses sa(1)=data{1}; sa(2)=data{2}; ... pattern instead of
% struct() constructor to avoid struct array expansion issues with cell fields

    if isempty(data)
        sa = data;
        return;
    end

    if isstruct(data) && ~iscell(data)
        % Already a struct array
        sa = data;
        return;
    end

    if iscell(data)
        % Cell array - check if all elements are structs
        if ~all(cellfun(@isstruct, data))
            % Not all structs - return as-is (e.g., cell of strings)
            sa = data;
            return;
        end
        if isempty(data)
            sa = data;
            return;
        end
        % Build struct array from cell of structs
        % Use first-element-init + sequential assignment pattern
        % This is the safest way to create struct arrays from cells
        % because struct() constructor can incorrectly expand cell field values
        nElem = length(data);
        sa = data{1};
        for i = 2:nElem
            sa(i) = data{i};
        end
        return;
    end

    % Fallback: return as-is
    sa = data;
end
