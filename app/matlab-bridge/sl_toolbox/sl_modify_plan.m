function result = sl_modify_plan(modelName, taskDescription, modelUnderstanding)
% SL_MODIFY_PLAN Modify intent Prompt assembler for Scene 2.
%
% Takes the existing model understanding and the user's modification task,
% generates a structured design prompt for the AI + an output schema.
%
% Pure Prompt assembler — AI has complete design freedom.
% No predefined templates, no forced subsystem divisions.
%
% The modify plan guides AI to produce:
%   - sandboxSubsystem: new subsystem design (additive changes)
%   - existingModifications: changes to existing parts (optional, needs user confirm)
%   - connectionPoints: Goto/From or Inport/Outport for sandbox ↔ existing

result = struct();
result.status = 'ok';

% [v11.7.1 B3 FIX] Validate modelUnderstanding is a struct with clear error guidance
if ~isstruct(modelUnderstanding)
    result.status = 'error';
    result.error = 'modelUnderstanding must be a struct. Use sl_model_understand() or pass a dict with modelTree/signalFlow/ioInterface fields.';
    result.help = 'Example: struct(''modelTree'', struct(''totalBlocks'', 13), ''signalFlow'', struct(''lineCount'', 36), ''ioInterface'', struct(''inports'', [], ''outports'', []))';
    return;
end

% Extract key metrics for the prompt
totalBlocks = 0;
subsystemCount = 0;
lineCount = 0;
inportCount = 0;
outportCount = 0;
gotoCount = 0;
fromCount = 0;

if isfield(modelUnderstanding, 'modelTree')
    mt = modelUnderstanding.modelTree;
    if isfield(mt, 'totalBlocks'), totalBlocks = mt.totalBlocks; end
    if isfield(mt, 'subsystemCount'), subsystemCount = mt.subsystemCount; end
end
if isfield(modelUnderstanding, 'signalFlow')
    sf = modelUnderstanding.signalFlow;
    if isfield(sf, 'lineCount'), lineCount = sf.lineCount; end
end
if isfield(modelUnderstanding, 'ioInterface')
    io = modelUnderstanding.ioInterface;
    if isfield(io, 'inports'), inportCount = length(io.inports); end
    if isfield(io, 'outports'), outportCount = length(io.outports); end
    if isfield(io, 'gotoTags'), gotoCount = length(io.gotoTags); end
    if isfield(io, 'fromTags'), fromCount = length(io.fromTags); end
end

% Generate the modify prompt
lines = {};
lines{end+1} = sprintf('You are analyzing an existing Simulink model "%s" for modification.', modelName);
lines{end+1} = '';
lines{end+1} = '## Existing Model Understanding';
lines{end+1} = 'The model has been automatically analyzed. Here is what we know:';
lines{end+1} = sprintf('- Total blocks: %d', totalBlocks);
lines{end+1} = sprintf('- Subsystems: %d', subsystemCount);
lines{end+1} = sprintf('- Signal lines: %d', lineCount);
lines{end+1} = '- Available I/O connection points:';
lines{end+1} = sprintf('  - Inports: %d', inportCount);
lines{end+1} = sprintf('  - Outports: %d', outportCount);
lines{end+1} = sprintf('  - Goto tags: %d', gotoCount);
lines{end+1} = sprintf('  - From tags: %d', fromCount);
lines{end+1} = '';
lines{end+1} = '## Modification Task';
lines{end+1} = taskDescription;
lines{end+1} = '';
lines{end+1} = '## Design Requirements';
lines{end+1} = '1. **Sandbox Isolation**: All NEW functionality MUST be placed inside a new ';
lines{end+1} = 'top-level Subsystem called "<ModelName>_Mod". This isolates new changes ';
lines{end+1} = 'from existing model parts.';
lines{end+1} = '2. **Connection Points**: Define how the sandbox connects to the existing model ';
lines{end+1} = 'using Goto/From tags or additional Inport/Outport blocks.';
lines{end+1} = '3. **Existing Modifications (OPTIONAL)**: If the task requires modifying existing ';
lines{end+1} = 'blocks, list each modification explicitly with the target path and reason.';
lines{end+1} = '   WARNING: Existing modifications require USER CONFIRMATION and cannot be automated.';
lines{end+1} = '4. **Sandbox Internal Design**: Use full Scene 1 workflow inside the sandbox -- ';
lines{end+1} = 'design the subsystem architecture from first principles.';
lines{end+1} = '';
lines{end+1} = '## COMPLETE FREEDOM';
lines{end+1} = 'There is NO predefined template for the sandbox architecture. ';
lines{end+1} = 'You have complete freedom to design the subsystem structure, signal flow, ';
lines{end+1} = 'and internal block arrangement based on your domain expertise.';
lines{end+1} = '';
lines{end+1} = 'Use web search, knowledge bases, and your expertise to design the optimal architecture.';

result.modifyPrompt = strjoin(lines, char(10));

% Output schema for validating AI's response
result.outputSchema = struct();
result.outputSchema.sandboxSubsystem = struct(...
    'name', 'char (subsystem name, e.g. "ModelName_Mod")', ...
    'inports', 'cell array of {name, connectTo} pairs', ...
    'outports', 'cell array of {name, connectTo} pairs', ...
    'gotoFrom', 'cell array of {tag, connectFrom, connectTo} triples', ...
    'internalDesign', 'macroFramework (same format as Scene 1 framework_design output)');
result.outputSchema.existingModifications = struct(...
    'required', 'logical (true if task requires modifying existing parts)', ...
    'changes', 'cell array of {targetPath, operation, reason} triples');
% [P2-2 FIX] Add executionSteps for per-step verification
result.outputSchema.executionSteps = struct(...
    'stepIndex', 'integer', ...
    'operation', 'char (add_block|add_line|set_param|delete)', ...
    'blockPath', 'char (target block path)', ...
    'params', 'struct (expected parameters, optional)');
result.outputSchema.reasoning = 'char (explain design decisions and domain methodology)';
