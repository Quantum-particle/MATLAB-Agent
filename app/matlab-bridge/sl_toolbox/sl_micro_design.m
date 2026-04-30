function result = sl_micro_design(subsystemName, taskDescription, varargin)
% SL_MICRO_DESIGN v11.2 Pure Prompt Assembler for AI-guided Subsystem Design
%   result = sl_micro_design(subsystemName, taskDescription)
%   result = sl_micro_design('Controller', 'PID controller for quadrotor attitude')
%   result = sl_micro_design('Plant', '6-DOF aircraft dynamics', 'parentContext', macroFramework)
%
% v11.2 Architecture Flip: "Thin Wrapper" design pattern
%   - Returns a structured design PROMPT, NOT a pre-computed design
%   - AI agent combines prompt with its own domain knowledge
%   - NO hardcoded physics equations. NO hardcoded block planning.
%   - parentContext provides macro framework context for the AI
%
% v11.1: [DEPRECATED] Prompt-Driven AI with hardcoded fallback
%   - Had ~450 lines of hardcoded keyword matching for block planning
%   - Physics equations derived from 5 hardcoded branches, not AI reasoning
%   - sl_micro_prompts loaded but never used for actual AI design
%
% Output:
%   result.status: 'ok' or 'error'
%   result.subsystemName: name of the subsystem being designed
%   result.designPrompt: cell array of prompt strings for AI
%   result.blockMappingGuide: cell array of math->block mapping rules
%   result.outputSchema: struct defining expected AI output format
%   result.parentContext: struct with macro framework context
%   result.nextExpectedAction: 'AI_AGENT_DESIGN_MICRO'

    % ===== Input Validation =====
    if nargin < 1 || isempty(subsystemName)
        result = struct('status', 'error', ...
            'message', 'sl_micro_design: subsystemName is required');
        return;
    end
    if ~ischar(subsystemName) && ~isstring(subsystemName)
        subsystemName = num2str(subsystemName); %#ok<ST2NM>
    end
    subsystemName = char(subsystemName);
    % Sanitize subsystem name: only alphanumeric and underscore
    if ~isempty(sl_framework_utils('regexp_once_safe', subsystemName, '[^a-zA-Z0-9_]'))
        result = struct('status', 'error', ...
            'message', sprintf('sl_micro_design: subsystemName "%s" contains invalid characters. Use only alphanumeric and underscore.', subsystemName));
        return;
    end
    if nargin < 2 || isempty(taskDescription)
        taskDescription = subsystemName;
    end
    if ~ischar(taskDescription) && ~isstring(taskDescription)
        taskDescription = num2str(taskDescription); %#ok<ST2NM>
    end
    taskDescription = char(taskDescription);

    try
    % ===== Parameter Parsing =====
    p = struct();
    p.parentContext = struct();
    p.detailLevel = 'standard';
    p.modelName = '';

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if strcmp(key, 'parentContext') && isstruct(val)
                p.parentContext = val;
            elseif strcmp(key, 'detailLevel') && (ischar(val) || isstring(val))
                p.detailLevel = char(val);
            elseif strcmp(key, 'modelName') && (ischar(val) || isstring(val))
                p.modelName = char(val);
            end
            idx = idx + 2;
        else
            idx = idx + 1;
        end
    end

    % ===== Step 1: Load prompt templates from sl_micro_prompts =====
    designPrompt = sl_micro_prompts('system_prompt', subsystemName, taskDescription, p.parentContext);
    blockMappingGuide = sl_micro_prompts('block_mapping_guide');
    outputSchema = sl_micro_prompts('output_schema');

    % ===== Step 2: Assemble parent context summary =====
    parentSummary = '';
    if ~isempty(fieldnames(p.parentContext))
        % Extract key context info for the AI
        if isfield(p.parentContext, 'subsystems')
            subs = p.parentContext.subsystems;
            parentSummary = [parentSummary, 'Macro framework has ', num2str(length(subs)), ' subsystem(s). '];
        end
        if isfield(p.parentContext, 'domain')
            parentSummary = [parentSummary, 'Domain: ', p.parentContext.domain, '. '];
        end
        if isfield(p.parentContext, 'signalFlow')
            parentSummary = [parentSummary, 'Signal flow topology available. '];
        end
    end

    % ===== Step 3: Return assembled prompt (NOT pre-computed design!) =====
    result = struct();
    result.status = 'ok';
    result.subsystemName = subsystemName;
    result.designPrompt = {designPrompt};
    result.blockMappingGuide = {blockMappingGuide};
    result.outputSchema = outputSchema;
    result.parentContext = p.parentContext;
    result.parentSummary = parentSummary;
    result.nextExpectedAction = 'AI_AGENT_DESIGN_MICRO';
    result.version = 'v11.2';

    % Write to workspace for review/approve chain compatibility
    try
        uFW_var = ['uFW_' subsystemName];
        assignin('base', uFW_var, result);
    catch
        % non-critical: workspace write is best-effort
    end

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_micro_design failed: %s', ME.message), ...
            'identifier', ME.identifier);
    end
end
