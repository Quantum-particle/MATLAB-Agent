function result = sl_snapshot_model(modelName, action, varargin)
% SL_SNAPSHOT_MODEL 模型快照/回滚 — 保存模型快照到临时目录 → 可回滚到任意快照
%   result = sl_snapshot_model('MyModel', 'create')
%   result = sl_snapshot_model('MyModel', 'create', 'snapshotName', 'before_pid', 'description', 'Before PID')
%   result = sl_snapshot_model('MyModel', 'rollback', 'snapshotName', 'before_pid')
%   result = sl_snapshot_model('MyModel', 'list')
%   result = sl_snapshot_model('MyModel', 'delete', 'snapshotName', 'before_pid')
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   快照存储位置: tempdir/sl_snapshots/<modelName>/
%   每个快照包含: <snapshotName>.slx + <snapshotName>_meta.txt
%
%   输入:
%     modelName        - 模型名称（必选）
%     action           - 'create'/'rollback'/'list'/'delete'（必选）
%     'snapshotName'   - 快照名称（create/delete/rollback 时可选，默认时间戳命名）
%     'description'    - 快照描述（create 时可选）
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .snapshot - struct（结构因 action 不同而异）
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'snapshotName', '', ...
        'description', '', ...
        'loadModelIfNot', true);
    
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end
    
    result = struct('status', 'ok', 'snapshot', struct(), 'error', '');
    
    % ===== 验证 action =====
    if isempty(action)
        result.status = 'error';
        result.error = 'action is required: ''create'', ''rollback'', ''list'', or ''delete''';
        return;
    end
    
    validActions = {'create', 'rollback', 'list', 'delete'};
    isValidAction = false;
    for i = 1:length(validActions)
        if strcmpi(action, validActions{i})
            isValidAction = true;
            break;
        end
    end
    if ~isValidAction
        result.status = 'error';
        result.error = ['Invalid action: ' action '. Must be create/rollback/list/delete.'];
        return;
    end
    
    % ===== 确保模型已加载（create/rollback 需要）=====
    if strcmpi(action, 'create') || strcmpi(action, 'rollback')
        if opts.loadModelIfNot
            try
                if ~bdIsLoaded(modelName)
                    load_system(modelName);
                end
            catch ME
                result.status = 'error';
                result.error = ['Model not loaded and cannot be loaded: ' ME.message];
                return;
            end
        else
            if ~bdIsLoaded(modelName)
                result.status = 'error';
                result.error = 'Model not loaded. Set loadModelIfNot=true to auto-load.';
                return;
            end
        end
    end
    
    % ===== 分发到对应 action =====
    switch lower(action)
        case 'create'
            result = action_create(modelName, opts, result);
        case 'rollback'
            result = action_rollback(modelName, opts, result);
        case 'list'
            result = action_list(modelName, opts, result);
        case 'delete'
            result = action_delete(modelName, opts, result);
    end
end


% ===== action='create': 创建快照 =====
function result = action_create(modelName, opts, result)
    % 确保快照目录存在
    snapshotDir = fullfile(tempdir, 'sl_snapshots', modelName);
    if ~exist(snapshotDir, 'dir')
        try
            mkdir(snapshotDir);
        catch ME
            result.status = 'error';
            result.error = ['Failed to create snapshot directory: ' ME.message];
            return;
        end
    end
    
    % 生成快照名称（如果未指定）
    snapshotName = opts.snapshotName;
    if isempty(snapshotName)
        snapshotName = ['snapshot_' datestr(now, 'yyyymmdd_HHMMSS')];
    end
    
    % 清理快照名称中的非法字符
    snapshotName = strrep(snapshotName, ' ', '_');
    snapshotName = strrep(snapshotName, '/', '_');
    snapshotName = strrep(snapshotName, '\', '_');
    snapshotName = strrep(snapshotName, ':', '_');
    
    % 避免快照名与已加载模型同名导致 save_system 冲突
    % 自动添加前缀
    if strcmp(snapshotName, modelName)
        snapshotName = ['sl_snap_' snapshotName];
    end
    
    % 保存模型到快照目录
    snapshotPath = fullfile(snapshotDir, [snapshotName '.slx']);
    try
        save_system(modelName, snapshotPath);
    catch ME
        % 尝试 .mdl 格式（兼容旧版）
        snapshotPath = fullfile(snapshotDir, [snapshotName '.mdl']);
        try
            save_system(modelName, snapshotPath);
        catch ME2
            result.status = 'error';
            result.error = ['Failed to save snapshot: ' ME.message ' / ' ME2.message];
            return;
        end
    end
    
    % 写入元数据文件
    metaPath = fullfile(snapshotDir, [snapshotName '_meta.txt']);
    try
        metaContent = sprintf(['snapshotName=%s' char(10) ...
            'modelName=%s' char(10) ...
            'timestamp=%s' char(10) ...
            'description=%s' char(10) ...
            'file=%s'], ...
            snapshotName, modelName, datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
            opts.description, snapshotPath);
        
        fid = fopen(metaPath, 'w');
        if fid == -1
            % 元数据写入失败不影响快照，但记录警告
            result.warnings = {'Failed to write metadata file'};
        else
            fprintf(fid, '%s', metaContent);
            fclose(fid);
        end
    catch
        result.warnings = {'Failed to write metadata file'};
    end
    
    result.snapshot = struct( ...
        'action', 'create', ...
        'snapshotName', snapshotName, ...
        'snapshotPath', snapshotPath, ...
        'modelName', modelName, ...
        'timestamp', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
        'description', opts.description);
    
    result.message = sprintf('Snapshot created: %s', snapshotName);
end


% ===== action='rollback': 回滚到快照 =====
function result = action_rollback(modelName, opts, result)
    snapshotName = opts.snapshotName;
    if isempty(snapshotName)
        result.status = 'error';
        result.error = 'snapshotName is required for action=''rollback''';
        return;
    end
    
    snapshotDir = fullfile(tempdir, 'sl_snapshots', modelName);
    
    % 查找快照文件
    snapshotPath = '';
    slxPath = fullfile(snapshotDir, [snapshotName '.slx']);
    mdlPath = fullfile(snapshotDir, [snapshotName '.mdl']);
    
    if exist(slxPath, 'file')
        snapshotPath = slxPath;
    elseif exist(mdlPath, 'file')
        snapshotPath = mdlPath;
    else
        result.status = 'error';
        result.error = ['Snapshot not found: ' snapshotName];
        return;
    end
    
    % 检查模型是否在编译状态
    try
        simStatus = get_param(modelName, 'SimulationStatus');
        if ~strcmpi(simStatus, 'stopped')
            result.status = 'error';
            result.error = ['Cannot rollback: model simulation status is ' simStatus '. Stop simulation first.'];
            return;
        end
    catch
        % 某些版本不支持 SimulationStatus，继续
    end
    
    % 记录原始模型文件路径
    originalPath = '';
    try
        originalPath = get_param(modelName, 'FileName');
    catch
        % 如果获取不到，使用模型名 + 当前目录
        originalPath = [modelName '.slx'];
    end
    
    % 关闭当前模型（不保存）
    try
        close_system(modelName, 0);
    catch ME
        result.status = 'error';
        result.error = ['Failed to close model for rollback: ' ME.message];
        return;
    end
    
    % 加载快照
    try
        load_system(snapshotPath);
    catch ME
        result.status = 'error';
        result.error = ['Failed to load snapshot: ' ME.message];
        return;
    end
    
    % 保存到原始路径（覆盖原文件）
    try
        save_system(modelName, originalPath);
    catch ME
        % 保存到原路径失败，记录但不算错误
        result.warnings = {['Failed to save to original path: ' ME.message]};
    end
    
    result.snapshot = struct( ...
        'action', 'rollback', ...
        'snapshotName', snapshotName, ...
        'snapshotPath', snapshotPath, ...
        'modelName', modelName, ...
        'originalPath', originalPath);
    
    result.message = sprintf('Rolled back to snapshot: %s', snapshotName);
end


% ===== action='list': 列出所有快照 =====
function result = action_list(modelName, opts, result)
    snapshotDir = fullfile(tempdir, 'sl_snapshots', modelName);
    
    if ~exist(snapshotDir, 'dir')
        result.snapshot = struct( ...
            'action', 'list', ...
            'modelName', modelName, ...
            'snapshots', {{}}, ...
            'count', 0);
        result.message = 'No snapshots found';
        return;
    end
    
    % 查找所有 .slx 和 .mdl 文件
    slxFiles = {};
    mdlFiles = {};
    try
        slxFiles = dir(fullfile(snapshotDir, '*.slx'));
    catch
    end
    try
        mdlFiles = dir(fullfile(snapshotDir, '*.mdl'));
    catch
    end
    
    allFiles = {};
    for i = 1:length(slxFiles)
        allFiles{end+1} = slxFiles(i).name; %#ok<AGROW>
    end
    for i = 1:length(mdlFiles)
        allFiles{end+1} = mdlFiles(i).name; %#ok<AGROW>
    end
    
    % 读取每个快照的元数据
    snapshots = {};
    for i = 1:length(allFiles)
        [~, name, ext] = fileparts(allFiles{i});
        
        snapInfo = struct();
        snapInfo.snapshotName = name;
        snapInfo.filePath = fullfile(snapshotDir, allFiles{i});
        snapInfo.fileType = ext;
        
        % 读取元数据
        metaPath = fullfile(snapshotDir, [name '_meta.txt']);
        if exist(metaPath, 'file')
            try
                fid = fopen(metaPath, 'r');
                if fid ~= -1
                    raw = fread(fid, '*char')';
                    fclose(fid);
                    
                    % 解析简单的 key=value 格式
                    snapInfo.timestamp = parse_meta_value(raw, 'timestamp');
                    snapInfo.description = parse_meta_value(raw, 'description');
                end
            catch
                snapInfo.timestamp = '';
                snapInfo.description = '';
            end
        else
            % 使用文件修改时间作为时间戳
            try
                fileInfo = dir(fullfile(snapshotDir, allFiles{i}));
                snapInfo.timestamp = datestr(fileInfo.datenum, 'yyyy-mm-dd HH:MM:SS');
            catch
                snapInfo.timestamp = '';
            end
            snapInfo.description = '';
        end
        
        snapshots{end+1} = snapInfo; %#ok<AGROW>
    end
    
    % 按时间排序（最新的在前）
    if length(snapshots) > 1
        timestamps = cell(1, length(snapshots));
        for i = 1:length(snapshots)
            if ~isempty(snapshots{i}.timestamp)
                try
                    timestamps{i} = datenum(snapshots{i}.timestamp, 'yyyy-mm-dd HH:MM:SS');
                catch
                    timestamps{i} = 0;
                end
            else
                timestamps{i} = 0;
            end
        end
        
        % 简单的冒泡排序（R2016a 兼容）
        for i = 1:length(snapshots)-1
            for j = i+1:length(snapshots)
                if timestamps{i} < timestamps{j}
                    tmp = snapshots{i};
                    snapshots{i} = snapshots{j};
                    snapshots{j} = tmp;
                    tmpT = timestamps{i};
                    timestamps{i} = timestamps{j};
                    timestamps{j} = tmpT;
                end
            end
        end
    end
    
    result.snapshot = struct( ...
        'action', 'list', ...
        'modelName', modelName, ...
        'snapshots', snapshots, ...
        'count', length(snapshots));
    
    result.message = sprintf('Found %d snapshot(s)', length(snapshots));
end


% ===== action='delete': 删除快照 =====
function result = action_delete(modelName, opts, result)
    snapshotName = opts.snapshotName;
    if isempty(snapshotName)
        result.status = 'error';
        result.error = 'snapshotName is required for action=''delete''';
        return;
    end
    
    snapshotDir = fullfile(tempdir, 'sl_snapshots', modelName);
    
    % 查找并删除快照文件
    deletedFiles = {};
    errors = {};
    
    slxPath = fullfile(snapshotDir, [snapshotName '.slx']);
    mdlPath = fullfile(snapshotDir, [snapshotName '.mdl']);
    metaPath = fullfile(snapshotDir, [snapshotName '_meta.txt']);
    
    if exist(slxPath, 'file')
        try
            delete(slxPath);
            deletedFiles{end+1} = slxPath; %#ok<AGROW>
        catch ME
            errors{end+1} = ['Failed to delete ' slxPath ': ' ME.message]; %#ok<AGROW>
        end
    end
    
    if exist(mdlPath, 'file')
        try
            delete(mdlPath);
            deletedFiles{end+1} = mdlPath; %#ok<AGROW>
        catch ME
            errors{end+1} = ['Failed to delete ' mdlPath ': ' ME.message]; %#ok<AGROW>
        end
    end
    
    if exist(metaPath, 'file')
        try
            delete(metaPath);
            deletedFiles{end+1} = metaPath; %#ok<AGROW>
        catch ME
            errors{end+1} = ['Failed to delete ' metaPath ': ' ME.message]; %#ok<AGROW>
        end
    end
    
    if isempty(deletedFiles) && isempty(errors)
        result.status = 'error';
        result.error = ['Snapshot not found: ' snapshotName];
        return;
    end
    
    result.snapshot = struct();
    result.snapshot.action = 'delete';
    result.snapshot.snapshotName = snapshotName;
    result.snapshot.deletedFiles = deletedFiles;
    result.snapshot.errors = errors;
    
    if isempty(errors)
        result.message = sprintf('Snapshot deleted: %s (%d files)', snapshotName, length(deletedFiles));
    else
        result.message = sprintf('Snapshot partially deleted: %s (%d files, %d errors)', ...
            snapshotName, length(deletedFiles), length(errors));
    end
end


% ===== 辅助函数: 解析元数据值 =====
function val = parse_meta_value(rawText, key)
% 从 key=value 格式的文本中提取指定 key 的值
% R2016a 兼容: 不使用 contains()
    val = '';
    lines = strsplit(rawText, char(10));
    for i = 1:length(lines)
        line = lines{i};
        prefix = [key '='];
        if length(line) >= length(prefix) && strcmpi(line(1:length(prefix)), prefix)
            val = line(length(prefix)+1:end);
            % 去除末尾回车
            if ~isempty(val) && val(end) == char(13)
                val = val(1:end-1);
            end
            break;
        end
    end
end
