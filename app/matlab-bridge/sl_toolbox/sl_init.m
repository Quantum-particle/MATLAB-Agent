function result = sl_init()
% SL_INIT 初始化 sl_toolbox 工具箱
%   result = sl_init() — 自动定位 sl_toolbox 目录并添加到 MATLAB path
%
%   返回 struct:
%     .status       — 'ok' 或 'error'
%     .toolbox_path — sl_toolbox 目录的完整路径
%     .file_count   — 工具箱中可用的 .m 文件数量
%     .files        — 工具箱中可用的 .m 文件列表 (cell array)
%     .message      — 状态信息
%
%   设计原则（v6.0 中文路径安全）:
%     1. 优先使用 mfilename('fullpath') 自定位（不依赖外部路径传参）
%     2. R2022b+ 高版本优先，R2016a 兼容回退
%     3. 幂等操作：重复调用不会重复添加路径
%     4. 中文路径安全：不通过函数参数传递路径，全靠自定位
%     5. 通用设计：不依赖任何特定目录结构，任何用户安装后都能工作

    result = struct('status', 'ok', 'toolbox_path', '', 'file_count', 0, 'files', {{}}, 'message', '');

    % === 1. 自定位 sl_toolbox 目录 ===
    % mfilename('fullpath') 返回本函数的完整路径（如 C:\Users\泰坦\...\sl_toolbox\sl_init.m）
    % 即使路径含中文，MATLAB 内部也能正确识别（因为是 OS 层面的文件系统操作）
    thisFile = mfilename('fullpath');
    [thisDir, ~, ~] = fileparts(thisFile);

    % 验证目录中确实有 sl_toolbox 的核心文件
    coreFile = fullfile(thisDir, 'sl_jsonencode.m');
    if ~exist(coreFile, 'file')
        result.status = 'error';
        result.message = ['sl_toolbox directory not found at: ' thisDir];
        return;
    end

    result.toolbox_path = thisDir;

    % === 2. 添加到 MATLAB path（幂等） ===
    % 用 strfind 检查是否已在 path 中（R2016a 兼容，不用 contains）
    currentPaths = path();
    if isempty(strfind(currentPaths, thisDir))
        addpath(thisDir, '-end');
        result.message = ['Added to path: ' thisDir];
    else
        result.message = ['Already in path: ' thisDir];
    end

    % === 3. 列出可用工具函数 ===
    mFiles = dir(fullfile(thisDir, 'sl_*.m'));
    n = length(mFiles);
    fileNames = cell(1, n);
    for i = 1:n
        [~, name, ~] = fileparts(mFiles(i).name);
        fileNames{i} = name;
    end
    result.files = fileNames;
    result.file_count = n;
end
