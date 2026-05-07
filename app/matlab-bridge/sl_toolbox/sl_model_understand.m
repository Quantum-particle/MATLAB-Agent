function result = sl_model_understand(modelName)
% SL_MODEL_UNDERSTAND Automatically analyze an existing Simulink model.
%
% Gate_S2_LOAD must be passed (sl_model_load) before calling.
%
% Returns comprehensive analysis:
%   - modelTree: hierarchical block structure
%   - signalFlow: signal connectivity summary
%   - ioInterface: all Inport/Outport/Goto/From (sandbox connection points)
%   - keyParams: critical parameter values
%   - config: solver + simulation settings
%   - issues: pre-existing warnings/errors

result = struct();
result.status = 'ok';
result.modelName = modelName;

% Check Gate_S2_LOAD has been passed
% [P1-3 FIX] Add try-catch for evalin robustness
try
    loaded_flag = evalin('base', ...
        ['exist(''mS2ModelLoaded_' strrep(strrep(modelName, '/', '__'), ' ', '_') ''', ''var'')']);
catch
    loaded_flag = 0;
end
if loaded_flag ~= 1
    result.status = 'error';
    result.error = sprintf('Model "%s" not loaded. Use sl_model_load first.', modelName);
    return;
end

% 1. Model tree (hierarchical block structure)
all_blocks = find_system(modelName, 'Type', 'Block');
subsystems = find_system(modelName, 'BlockType', 'SubSystem');

result.modelTree = struct();
result.modelTree.totalBlocks = length(all_blocks);
result.modelTree.subsystemCount = length(subsystems);
top_subs = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'SubSystem');
top_other = find_system(modelName, 'SearchDepth', 1, 'Type', 'Block');
result.modelTree.topLevelBlocks = setdiff(top_other, top_subs);

% 2. Signal flow topology (lines between top-level blocks)
lines = find_system(modelName, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'Line');
result.signalFlow = struct();
result.signalFlow.lineCount = length(lines);
result.signalFlow.connections = {};
for i = 1:length(lines)
    try
        src = get_param(lines(i), 'SrcBlockHandle');
        dst = get_param(lines(i), 'DstBlockHandle');
        if ~isempty(src) && src > 0 && ~isempty(dst) && dst(1) > 0
            conn = struct();
            conn.srcBlock = get_param(src, 'Name');
            conn.dstBlock = get_param(dst(1), 'Name');
            result.signalFlow.connections{end+1} = conn;
        end
    catch
        % Skip lines with virtual/non-resolvable endpoints
    end
end

% 3. I/O Interface — connection points for sandbox
inports = find_system(modelName, 'BlockType', 'Inport');
outports = find_system(modelName, 'BlockType', 'Outport');
gotos = find_system(modelName, 'BlockType', 'Goto');
froms = find_system(modelName, 'BlockType', 'From');

result.ioInterface = struct();
result.ioInterface.inports = {};
for i = 1:length(inports)
    result.ioInterface.inports{end+1} = struct(...
        'path', inports{i}, 'port', get_param(inports{i}, 'Port'));
end
result.ioInterface.outports = {};
for i = 1:length(outports)
    result.ioInterface.outports{end+1} = struct(...
        'path', outports{i}, 'port', get_param(outports{i}, 'Port'));
end
result.ioInterface.gotoTags = {};
for i = 1:length(gotos)
    result.ioInterface.gotoTags{end+1} = get_param(gotos{i}, 'GotoTag');
end
result.ioInterface.fromTags = {};
for i = 1:length(froms)
    result.ioInterface.fromTags{end+1} = get_param(froms{i}, 'GotoTag');
end

% 4. Key parameter extraction
gain_blocks = find_system(modelName, 'BlockType', 'Gain');
result.keyParams = struct();
result.keyParams.gains = {};
for i = 1:length(gain_blocks)
    g = struct();
    g.path = gain_blocks{i};
    g.value = get_param(gain_blocks{i}, 'Gain');
    result.keyParams.gains{end+1} = g;
end

% 5. Configuration
result.config = struct();
result.config.solver = get_param(modelName, 'Solver');
result.config.stopTime = get_param(modelName, 'StopTime');
result.config.solverType = get_param(modelName, 'SolverType');

% 6. Pre-existing issues
try
    result.issues = sl_get_model_issues(modelName);
catch
    result.issues = struct('status', 'warning', ...
        'message', 'sl_get_model_issues unavailable');
end

result.message = sprintf(...
    'Model "%s" analyzed: %d blocks, %d subsystems, %d lines.', ...
    modelName, result.modelTree.totalBlocks, ...
    result.modelTree.subsystemCount, result.signalFlow.lineCount);
