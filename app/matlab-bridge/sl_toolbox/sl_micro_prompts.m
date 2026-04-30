function result = sl_micro_prompts(action, varargin)
% SL_MICRO_PROMPTS v11.2 Prompt Template Library for Micro Framework Design
%   result = sl_micro_prompts('system_prompt', subsystemName, taskDescription, parentContext)
%   result = sl_micro_prompts('output_schema')
%   result = sl_micro_prompts('review_checklist')
%   result = sl_micro_prompts('block_mapping_guide')
%
% v11.2: Enhanced anti-template constraints
%   - System prompt emphasizes AI must derive equations from domain knowledge
%   - Added parentContext handling for macro framework awareness
%   - Block mapping guide now explicitly states AI must decide blocks from ITS equations
%   - Added 'reasoning' field to output schema
%
% v11.1: Initial Prompt-Driven AI template library

    switch lower(action)
        case 'system_prompt'
            result = get_system_prompt(varargin{:});
        case 'output_schema'
            result = get_output_schema();
        case 'review_checklist'
            result = get_review_checklist();
        case 'block_mapping_guide'
            result = get_block_mapping_guide();
        otherwise
            result = struct('status', 'error', ...
                'message', sprintf('Unknown action: %s. Use: system_prompt, output_schema, review_checklist, block_mapping_guide', action));
    end
end

% ===== System Prompt: Guides AI to design subsystem internals =====
function prompt = get_system_prompt(subsystemName, taskDescription, parentContext)
    if nargin < 1 || isempty(subsystemName)
        subsystemName = '%SUBSYSTEM_NAME%';
    end
    if nargin < 2 || isempty(taskDescription)
        taskDescription = '%TASK_DESCRIPTION%';
    end
    if nargin < 3
        parentContext = '';
    end

    % Build parent context description
    parentInfo = '';
    if isstruct(parentContext) && ~isempty(fieldnames(parentContext))
        parentInfo = 'PARENT MACRO FRAMEWORK CONTEXT: ';
        if isfield(parentContext, 'subsystems')
            subs = parentContext.subsystems;
            for i = 1:length(subs)
                if isfield(subs, 'name') && isfield(subs, 'type')
                    parentInfo = [parentInfo, subs(i).name, '(', subs(i).type, ') '];
                end
            end
        end
        if isfield(parentContext, 'domain')
            parentInfo = [parentInfo, '| Domain: ', parentContext.domain];
        end
    end

    prompt = {[...
        'You are an expert in physics and control systems with deep domain knowledge.', ...
        'For the following subsystem, design its internal implementation.', ...
        '', ...
        'Subsystem: ', subsystemName, ...
        'Task: ', taskDescription, ...
        '', ...
        parentInfo, ...
        '', ...
        'CRITICAL INSTRUCTION:', ...
        'You have COMPLETE FREEDOM to design this subsystem. ', ...
        'There is NO predefined internal structure or block count. ', ...
        'The design MUST be specific to THIS subsystem and THIS task.', ...
        '', ...
        'YOUR TASK:', ...
        '1. Derive the physics equations that govern this subsystem behavior', ...
        '   from FIRST PRINCIPLES using your domain expertise. ', ...
        '   DO NOT use generic templates like dx/dt = f(x,u).', ...
        '   Use: Newton-Euler, Lagrangian, Kirchhoff, thermodynamics, etc.', ...
        '2. Determine what Simulink blocks are needed based on YOUR equations.', ...
        '   The block mapping guide below is for REFERENCE only.', ...
        '   You decide which blocks and how many -- do not use formulaic counts.', ...
        '3. Specify input/output dimensions and state variables.', ...
        '4. Consider nonlinearities, saturations, coupling, or other important dynamics.', ...
        '5. If the parent macro framework provides context about signal interfaces,', ...
        '   ensure your design is consistent with those interfaces.', ...
        '', ...
        'OUTPUT FORMAT (JSON):', ...
        '  physicsEquations: [{equation, description, variables[], assumptions[]}, ...]', ...
        '  blockPlan: [{blockType, count, reason}, ...]', ...
        '  signalDimensions: {input: n, output: m, states: k}', ...
        '  initialConditions: [{variable, value}, ...] (optional)', ...
        '  confidence: 0.0-1.0', ...
        '  reasoning: <explain why you chose these equations and blocks>', ...
        '  warnings: [string, ...]', ...
        '', ...
        'REMEMBER: You are the domain expert. Design from first principles.', ...
        'A 6-DOF aerospace plant should have different internals than a simple pendulum.', ...
    ]};
end

% ===== Output Schema =====
function schema = get_output_schema()
    schema = struct();
    schema.subsystem = 'string';
    schema.physicsEquations = struct('equation', 'string', 'description', 'string', ...
        'variables', 'cell of strings', 'assumptions', 'cell of strings');
    schema.blockPlan = struct('blockType', 'string', 'count', 'double', 'reason', 'string');
    schema.signalDimensions = struct('input', 'double', 'output', 'double', 'states', 'double');
    schema.initialConditions = struct('variable', 'string', 'value', 'double');
    schema.confidence = '0.0 to 1.0';
    schema.reasoning = 'string: explain your design decisions';
    schema.warnings = 'cell of strings';
end

% ===== Review Checklist =====
function checklist = get_review_checklist()
    checklist = {};
    checklist{1} = 'Are physics equations derived from first principles (not generic templates)?';
    checklist{2} = 'Are all state variables covered by Integrator blocks?';
    checklist{3} = 'Do block types match the mathematical operations in YOUR equations?';
    checklist{4} = 'Are signal dimensions consistent with the equations?';
    checklist{5} = 'Are nonlinearities accounted for (sin, cos, saturation, products, etc.)?';
    checklist{6} = 'Are initial conditions specified or defaulted?';
    checklist{7} = 'Are there any algebraic loops within the subsystem?';
    checklist{8} = 'Is the block count justified by the complexity, not formulaic?';
    checklist{9} = 'Is the design specific to this subsystem (not a generic template)?';
end

% ===== Block Mapping Guide: Maps math operations to Simulink blocks =====
function guide = get_block_mapping_guide()
    guide = {};
    guide{1} = 'derivative (dx/dt, dot, d/dt) => Integrator block (initial condition IC=0 by default)';
    guide{2} = 'constant coefficient (K, m, L, R, C, J, I_x, I_y, I_z) => Gain block';
    guide{3} = 'summation (x+y, x-y) => Add or Sum block (configure input signs with +|-)';
    guide{4} = 'multiplication (x*y, x.*y, element-wise product) => Product block';
    guide{5} = 'trigonometric (sin, cos, tan, asin, acos, atan) => Trigonometric Function block';
    guide{6} = 'saturation/limits/clamp => Saturation block';
    guide{7} = 'dead zone/friction => Dead Zone or Coulomb & Viscous Friction block';
    guide{8} = 'lookup table => Lookup Table (1D or 2D) block';
    guide{9} = 'switching/logic => Switch or Multiport Switch block';
    guide{10} = 'time delay => Transport Delay block';
    guide{11} = 'state-space (A,B,C,D) => State-Space block';
    guide{12} = 'transfer function (num/den) => Transfer Fcn block';
    guide{13} = 'PID control => PID Controller block (Simulink Continuous library)';
    guide{14} = 'signal generation => Step, Sine Wave, Signal Generator, Constant';
    guide{15} = 'data export => To Workspace, Outport, or Signal Logging';
    guide{16} = 'IMPORTANT: You decide blocks based on YOUR derived equations. This guide is reference only.';
end
