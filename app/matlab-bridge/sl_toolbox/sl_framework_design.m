function result = sl_framework_design(taskDescription, varargin)
% SL_FRAMEWORK_DESIGN v11.2 Pure Prompt Assembler for AI-guided Framework Design
%   result = sl_framework_design(taskDescription)
%   result = sl_framework_design('6-DOF aircraft attitude control with Euler angles')
%   result = sl_framework_design(taskDescription, 'modelName', 'myModel')
%   result = sl_framework_design(taskDescription, 'existingFramework', existingFw)
%
% v11.2 Architecture Flip: "Thin Wrapper" design pattern
%   - Returns a structured design PROMPT, NOT a pre-computed design
%   - AI agent combines prompt with its own domain knowledge
%   - NO hardcoded subsystem selection. NO hardcoded physics equations.
%   - All design decisions are made by the AI, guided by the prompt.
%
% v11.1: [DEPRECATED] Prompt-Driven AI with hardcoded fallback
%   - Had ~600 lines of hardcoded keyword matching and template equations
%   - sl_framework_prompts loaded but never used for actual AI design
%
% Output:
%   result.status: 'ok' or 'error'
%   result.designPrompt: cell array of prompt strings for AI
%   result.taskGuide: cell array of task analysis steps
%   result.flowPatterns: cell array of signal flow topology patterns
%   result.outputSchema: struct defining expected AI output format
%   result.context: struct with existingFramework (if any)
%   result.nextExpectedAction: 'AI_AGENT_DESIGN'

    % ===== Input Validation =====
    if nargin < 1 || isempty(taskDescription)
        result = struct('status', 'error', ...
            'message', 'sl_framework_design: taskDescription is required');
        return;
    end
    if ~ischar(taskDescription) && ~isstring(taskDescription)
        taskDescription = num2str(taskDescription); %#ok<ST2NM>
    end
    taskDescription = char(taskDescription);
    if isempty(strtrim(taskDescription))
        result = struct('status', 'error', ...
            'message', 'sl_framework_design: taskDescription cannot be empty');
        return;
    end
    if length(taskDescription) > 10000
        taskDescription = taskDescription(1:10000);
    end

    try
    % ===== Parameter Parsing =====
    p = struct();
    p.modelName = '';
    p.existingFramework = struct();
    p.detailLevel = 'standard';
    
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if strcmp(key, 'modelName') && (ischar(val) || isstring(val))
                p.modelName = char(val);
            elseif strcmp(key, 'existingFramework') && isstruct(val)
                p.existingFramework = val;
            elseif strcmp(key, 'detailLevel') && (ischar(val) || isstring(val))
                p.detailLevel = char(val);
            end
            idx = idx + 2;
        else
            idx = idx + 1;
        end
    end

    % ===== Step 1: Load prompt templates from sl_framework_prompts =====
    designPrompt = sl_framework_prompts('system_prompt', taskDescription);
    taskGuide = sl_framework_prompts('task_analysis_guide');
    flowPatterns = sl_framework_prompts('signal_flow_patterns');
    outputSchema = sl_framework_prompts('output_schema');

    % ===== Step 2: Assemble context (existing framework if any) =====
    context = struct();
    if ~isempty(fieldnames(p.existingFramework))
        context.existingFramework = p.existingFramework;
    end
    context.detailLevel = p.detailLevel;

    % ===== Step 3: Return assembled prompt (NOT pre-computed design!) =====
    result = struct();
    result.status = 'ok';
    result.modelName = p.modelName;
    % designPrompt is cell of strings; keep as-is for AI consumption
    result.designPrompt = {designPrompt};
    result.taskGuide = {taskGuide};
    result.flowPatterns = {flowPatterns};
    result.outputSchema = outputSchema;
    result.context = context;
    result.nextExpectedAction = 'AI_AGENT_DESIGN';
    result.version = 'v11.2';

    % Write to workspace for review/approve chain compatibility
    try
        assignin('base', 'mFW_designPrompt', designPrompt);
        assignin('base', 'mFW_outputSchema_', outputSchema);
    catch
        % non-critical: workspace write is best-effort
    end

    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_framework_design failed: %s', ME.message), ...
            'identifier', ME.identifier);
    end
end
