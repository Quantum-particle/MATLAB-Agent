function result = sl_model_create(modelName, varargin)
% SL_MODEL_CREATE Create a new Simulink model for Scene 1 (build from scratch).
%
% Part of the standard Simulink modeling workflow. Creates an empty model
% ready for subsystem creation and block placement via sl_* API.
%
% Parameters:
%   modelName - char, name of the new model (without .slx extension)
%   varargin  - optional Name-Value pairs:
%       'saveTo'  - char, directory to save the .slx file (default: pwd)
%       'overwrite' - logical, overwrite if model already exists (default: false)
%
% Returns:
%   result.status       - 'ok' or 'error'
%   result.modelName    - created model name
%   result.modelPath    - absolute path to the saved .slx file
%   result.isNew        - true if model was newly created
%
% Example:
%   result = sl_model_create('Quadrotor_ADRC')
%   result = sl_model_create('MyModel', 'saveTo', 'C:\work', 'overwrite', true)

result = struct();
result.status = 'ok';
result.modelName = modelName;

% Parse optional parameters
p = inputParser;
addParameter(p, 'saveTo', '', @ischar);
addParameter(p, 'overwrite', false, @islogical);
parse(p, varargin{:});
save_dir = p.Results.saveTo;
overwrite = p.Results.overwrite;

% 1. Check if model already exists on path
slx_path = which([modelName '.slx']);
mdl_path = which([modelName '.mdl']);
existing_path = '';
if ~isempty(slx_path)
    existing_path = slx_path;
elseif ~isempty(mdl_path)
    existing_path = mdl_path;
end

if ~isempty(existing_path) && ~overwrite
    % Model exists but overwrite not requested → try to load it
    try
        load_system(modelName);
        result.status = 'ok';
        result.modelPath = existing_path;
        result.isNew = false;
        result.message = sprintf('Model "%s" already exists. Loaded from: %s', modelName, existing_path);
        result.hint = 'Model was loaded. Use overwrite=true to create a fresh copy.';
        return;
    catch ex
        result.status = 'error';
        result.error = sprintf('Model "%s" exists but failed to load: %s', modelName, ex.message);
        return;
    end
end

% 2. If overwrite requested and model is open, close it
if overwrite && bdIsLoaded(modelName)
    close_system(modelName, 0);
end

% 3. Create new model
try
    new_system(modelName, 'Model');
catch ex
    result.status = 'error';
    result.error = sprintf('Failed to create model "%s": %s', modelName, ex.message);
    return;
end

% 4. Open the model
try
    open_system(modelName);
catch ex
    result.status = 'error';
    result.error = sprintf('Model created but failed to open: %s', ex.message);
    result.hint = 'Try opening the model manually in Simulink.';
    return;
end

% 5. Save the model
try
    if ~isempty(save_dir)
        % Ensure save directory exists
        if ~exist(save_dir, 'dir')
            mkdir(save_dir);
        end
        save_path = fullfile(save_dir, [modelName '.slx']);
        save_system(modelName, save_path);
        result.modelPath = save_path;
    else
        save_system(modelName);
        result.modelPath = which([modelName '.slx']);
    end
catch ex
    result.status = 'error';
    result.error = sprintf('Failed to save model: %s', ex.message);
    return;
end

% 6. Success
result.isNew = true;
result.message = sprintf('Model "%s" created and saved to: %s', modelName, result.modelPath);
end
