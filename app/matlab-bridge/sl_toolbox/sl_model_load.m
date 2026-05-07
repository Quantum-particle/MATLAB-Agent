function result = sl_model_load(modelName)
% SL_MODEL_LOAD Load and validate an existing Simulink model for Scene 2 workflow.
%
% Gate_S2_LOAD: Validates model file exists, can be loaded, and is non-empty.
% Sets mS2ModelLoaded_<modelName> flag in MATLAB base workspace.
%
% Returns:
%   result.status       - 'ok' or 'error'
%   result.modelName    - validated model name
%   result.modelPath    - absolute path to .slx/.mdl file
%   result.modelVersion - Simulink version used to create the model
%   result.blockCount   - number of top-level blocks
%   result.topLevelBlocks - cell array of top-level block full path names
%   result.loadedAt     - timestamp of load

result = struct();
result.status = 'ok';
result.modelName = modelName;

% 1. Check if model file exists
slx_path = which([modelName '.slx']);
mdl_path = which([modelName '.mdl']);
model_path = '';
if ~isempty(slx_path)
    model_path = slx_path;
elseif ~isempty(mdl_path)
    model_path = mdl_path;
end

if isempty(model_path)
    result.status = 'error';
    result.error = sprintf('Model "%s" not found on MATLAB path.', modelName);
    result.hint = 'Ensure the model is in the current working directory or on MATLAB path.';
    return;
end

% 2. Try loading the model
try
    load_system(modelName);
catch ex
    result.status = 'error';
    result.error = sprintf('Failed to load model: %s', ex.message);
    return;
end

% 3. Check model is non-empty (has at least one block)
blocks = find_system(modelName, 'SearchDepth', 1, 'Type', 'Block');
if isempty(blocks)
    result.status = 'error';
    result.error = sprintf('Model "%s" is empty (no blocks found). Use Scene 1 to build from scratch.', modelName);
    close_system(modelName, 0);
    return;
end

% 4. Set load flag in base workspace
load_flag_var = ['mS2ModelLoaded_' strrep(strrep(modelName, '/', '__'), ' ', '_')];
assignin('base', load_flag_var, true);

% 5. Return model metadata
try
    info = Simulink.MDLInfo(model_path);
    result.modelVersion = info.SimulinkVersion;
catch
    result.modelVersion = 'unknown (Simulink.MDLInfo not available)';
end
result.modelPath = model_path;
result.blockCount = length(blocks);
result.topLevelBlocks = blocks;
result.loadedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
result.message = sprintf('Model "%s" loaded successfully. %d top-level blocks.', ...
    modelName, result.blockCount);
