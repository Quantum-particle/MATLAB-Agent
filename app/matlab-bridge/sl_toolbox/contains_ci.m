function found = contains_ci(str, pattern)
%CONTAINS_CI Case-insensitive string search
%   found = contains_ci(str, pattern)
%   R2016a compatible (no contains() function)

if ~ischar(str) || ~ischar(pattern)
    error('contains_ci:invalidInput', 'Both inputs must be character arrays');
end

found = ~isempty(strfind(lower(str), lower(pattern)));
end
