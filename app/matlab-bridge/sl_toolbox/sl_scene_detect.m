function result = sl_scene_detect(workspaceDir)
% SL_SCENE_DETECT Auto-detect Scene 1 (new model) vs Scene 2 (existing model)
%
% Scans the workspace directory for .slx/.mdl files and determines:
%   scene=1: No .slx/.mdl files found -> new model from scratch
%   scene=2: .slx/.mdl files found -> existing model modification
%
% Returns scene recommendation + list of found models for user review.
%
% This is Gate_S0: the first gate all Simulink operations must pass through.

result = struct();
result.status = 'ok';
result.scene = 1;  % default: from scratch
result.models = {};
result.reason = '';

% Scan workspace for Simulink model files
slx_files = dir(fullfile(workspaceDir, '*.slx'));
mdl_files = dir(fullfile(workspaceDir, '*.mdl'));

all_models = {};
if ~isempty(slx_files)
    for i = 1:length(slx_files)
        [~, name] = fileparts(slx_files(i).name);
        all_models{end+1} = struct('name', name, 'ext', '.slx', ...
            'fullpath', fullfile(workspaceDir, slx_files(i).name));
    end
end
if ~isempty(mdl_files)
    for i = 1:length(mdl_files)
        [~, name] = fileparts(mdl_files(i).name);
        all_models{end+1} = struct('name', name, 'ext', '.mdl', ...
            'fullpath', fullfile(workspaceDir, mdl_files(i).name));
    end
end

if isempty(all_models)
    result.scene = 1;
    result.reason = 'No .slx or .mdl files found in workspace -- Scene 1 (build from scratch)';
else
    result.scene = 2;
    result.models = all_models;
    result.reason = sprintf('Found %d model file(s) in workspace -- Scene 2 (modify existing)', ...
        length(all_models));
end
