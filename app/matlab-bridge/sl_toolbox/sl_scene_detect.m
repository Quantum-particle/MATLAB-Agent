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
%
% [v13 BUGFIX #47] Multi-strategy file search with fallback:
%   Strategy 1: requested workspaceDir
%   Strategy 2: MATLAB native pwd (survives Engine restart)
%   Strategy 3: normalize path separators and retry

result = struct();
result.status = 'ok';
result.scene = 1;  % default: from scratch
result.models = {};
result.reason = '';

% [v13 BUGFIX #47] Multi-strategy workspace scan
all_models = {};
scan_dirs = {};

% Strategy 1: requested workspaceDir (from REST API)
if ~isempty(workspaceDir) && exist(workspaceDir, 'dir')
    scan_dirs{end+1} = workspaceDir;
end

% Strategy 2: MATLAB current working directory (set by Bridge via cd())
try
    matlab_pwd = pwd();
    if ~isempty(matlab_pwd) && exist(matlab_pwd, 'dir')
        % Avoid duplicate
        already_added = false;
        for si = 1:length(scan_dirs)
            if strcmp(strrep(scan_dirs{si}, '\', '/'), strrep(matlab_pwd, '\', '/'))
                already_added = true;
                break;
            end
        end
        if ~already_added
            scan_dirs{end+1} = matlab_pwd;
        end
    end
catch
end

% Strategy 3: Normalize path separators and retry
% Windows: forward slashes → backslashes
if ~isempty(workspaceDir) && ispc
    normalized_dir = strrep(workspaceDir, '/', filesep);
    if ~strcmp(normalized_dir, workspaceDir)
        already_added = false;
        for si = 1:length(scan_dirs)
            if strcmp(strrep(scan_dirs{si}, '\', '/'), strrep(normalized_dir, '\', '/'))
                already_added = true;
                break;
            end
        end
        if ~already_added
            scan_dirs{end+1} = normalized_dir;
        end
    end
end

% Scan each candidate directory for model files
for di = 1:length(scan_dirs)
    d = scan_dirs{di};
    slx_files = dir(fullfile(d, '*.slx'));
    mdl_files = dir(fullfile(d, '*.mdl'));
    
    if ~isempty(slx_files)
        for i = 1:length(slx_files)
            [~, name] = fileparts(slx_files(i).name);
            all_models{end+1} = struct('name', name, 'ext', '.slx', ...
                'fullpath', fullfile(d, slx_files(i).name));
        end
    end
    if ~isempty(mdl_files)
        for i = 1:length(mdl_files)
            [~, name] = fileparts(mdl_files(i).name);
            all_models{end+1} = struct('name', name, 'ext', '.mdl', ...
                'fullpath', fullfile(d, mdl_files(i).name));
        end
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
