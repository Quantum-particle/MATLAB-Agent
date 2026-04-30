function result = sl_micro_review(subsystemName, varargin)
% SL_MICRO_REVIEW Micro Framework Self-Review
%   result = sl_micro_review(subsystemName, 'microFramework', mf)
%   result = sl_micro_review(subsystemName, 'microFramework', mf, 'checkItems', {'physics'})
%
% v11.1: subsystemName is positional; rest via Name-Value pairs

    p = struct();
    p.microFramework = struct();
    p.checkItems = {'physics', 'blockPlan', 'signalDimensions', 'integrators'};
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
                        eq_struct = eqs{j};
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
                        b = mf.blockPlan{j};
                        tot = tot + b.count;
                        if strcmp(b.type, 'Integrator'), hasInt = true; end
                    end
                    if ~hasInt && isfield(mf, 'signalDimensions') && mf.signalDimensions.states > 0
                        r.passed = false; r.confidence = 0.5;
                        r.issue = 'No Integrator for state variables';
                    end
                end
                checks{ci} = r; ci = ci + 1;

            case 'signalDimensions'
                r = struct('item', 'signalDimensions', 'passed', true, 'confidence', 0.85, 'issue', '', 'suggestion', '');
                if ~isfield(mf, 'signalDimensions') || isempty(mf.signalDimensions)
                    r.passed = false; r.confidence = 0.3; r.issue = 'No signal dimensions';
                elseif mf.signalDimensions.input < 1 || mf.signalDimensions.output < 1
                    r.passed = false; r.confidence = 0.4; r.issue = 'Invalid dimension';
                end
                checks{ci} = r; ci = ci + 1;

            case 'integrators'
                r = struct('item', 'integrators', 'passed', true, 'confidence', 0.9, 'issue', '', 'suggestion', '');
                nInt = 0;
                if isfield(mf, 'blockPlan') && ~isempty(mf.blockPlan)
                    for j = 1:length(mf.blockPlan)
                        if strcmp(mf.blockPlan{j}.type, 'Integrator')
                            nInt = nInt + mf.blockPlan{j}.count;
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
        end
    end

    n = length(checks);
    pArr = false(n, 1); cArr = zeros(n, 1);
    for k = 1:n, pArr(k) = checks{k}.passed; cArr(k) = checks{k}.confidence; end
    reviewResult = struct();
    reviewResult.passed = all(pArr);
    reviewResult.checks = checks;
    reviewResult.overallConfidence = mean(cArr);
    reviewResult.issues = {};
    reviewResult.suggestions = {};
    result = struct('status', 'ok', ...
        'reviewResult', reviewResult, ...
        'subsystemName', subsystemName);
end