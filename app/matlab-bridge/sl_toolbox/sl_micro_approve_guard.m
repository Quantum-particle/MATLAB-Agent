function result = sl_micro_approve_guard(subsystemName, microFramework, reviewResult)
% SL_MICRO_APPROVE_GUARD Pre-approve validation guard
%   result = sl_micro_approve_guard(subsystemName, microFramework, reviewResult)
%
% [v12.0] Gate_APPROVE_NO_REVIEW + Gate_CONTENT_DEPTH
% Executed before sl_micro_approve to ensure:
%   1. sl_micro_review was called and passed (Gate_APPROVE_NO_REVIEW -- HC-07 FIX)
%   2. Rigor Score >= 0.65 (Gate_CONTENT_DEPTH -- HC-04 FIX)
%
% Input:
%   subsystemName  -- subsystem identifier string
%   microFramework -- micro framework struct from sl_micro_design
%   reviewResult   -- review result struct from sl_micro_review
%
% Output:
%   result.passed  -- true if all guards pass
%   result.checks  -- struct array of guard check results
%   result.message -- human-readable status
%
% R2016a+ compatible.

    result = struct('passed', false, 'checks', {{}}, 'message', '', ...
        'subsystemName', subsystemName);

    checks = {};
    ci = 1;

    % ===== Guard 1: Review must have been called and passed =====
    r1 = struct('guard', 'APPROVE_NO_REVIEW', 'passed', false, ...
        'issue', '', 'confidence', 0.0);

    if nargin < 3 || isempty(reviewResult)
        r1.passed = false;
        r1.issue = 'sl_micro_review has not been called for this subsystem';
        r1.confidence = 0.0;
    elseif isstruct(reviewResult)
        if ~isfield(reviewResult, 'passed')
            r1.passed = false;
            r1.issue = 'reviewResult missing passed field';
            r1.confidence = 0.1;
        elseif ~reviewResult.passed
            r1.passed = false;
            r1.issue = sprintf('Micro review failed (confidence: %.2f)', ...
                reviewResult.overallConfidence);
            r1.confidence = 0.2;
        else
            r1.passed = true;
            r1.confidence = 0.9;
        end
    else
        r1.passed = false;
        r1.issue = 'reviewResult is not a valid struct';
        r1.confidence = 0.0;
    end
    checks{ci} = r1; ci = ci + 1;

    % ===== Guard 2: Rigor Score >= threshold =====
    r2 = struct('guard', 'CONTENT_DEPTH', 'passed', false, ...
        'issue', '', 'confidence', 0.0, ...
        'rigorScore', 0.0, 'rigorThreshold', 0.65, ...
        'breakdown', struct(), 'weakest', '', 'fixHints', {{}});

    if nargin < 2 || isempty(microFramework) || ...
       (~isstruct(microFramework) && isempty(fieldnames(microFramework)))
        r2.passed = false;
        r2.issue = 'No microFramework provided -- cannot compute rigor score';
        r2.confidence = 0.0;
    else
        try
            rigor = sl_rigor_score(microFramework);
            r2.rigorScore = rigor.score;
            r2.rigorThreshold = rigor.threshold;
            r2.breakdown = rigor.breakdown;
            r2.weakest = rigor.weakest;
            r2.fixHints = rigor.fixHints;

            if rigor.score >= rigor.threshold
                r2.passed = true;
                r2.confidence = min(0.95, rigor.score);
            else
                r2.passed = false;
                r2.confidence = max(0.1, rigor.score / 2);
                r2.issue = sprintf('Rigor score %.2f < %.2f. Weakest: %s (%.2f)', ...
                    rigor.score, rigor.threshold, rigor.weakest, rigor.weakestScore);
            end
        catch ME
            r2.passed = false;
            r2.issue = sprintf('Rigor score computation failed: %s', ME.message);
            r2.confidence = 0.0;
        end
    end
    checks{ci} = r2;

    % ===== Assemble result =====
    allPassed = true;
    for i = 1:length(checks)
        if ~checks{i}.passed
            allPassed = false;
        end
    end

    result.passed = allPassed;
    result.checks = checks;

    if allPassed
        result.message = sprintf('[OK] All approve guards passed for %s', subsystemName);
    else
        failedGuards = {};
        for i = 1:length(checks)
            if ~checks{i}.passed
                failedGuards{end+1} = checks{i}.guard;
            end
        end
        result.message = sprintf('[BLOCKED] Guards failed: %s', ...
            sl_framework_utils('strjoin_safe', failedGuards, ', '));
    end
end
