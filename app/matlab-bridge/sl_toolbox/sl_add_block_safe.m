function result = sl_add_block_safe(modelName, sourceBlock, varargin)
% SL_ADD_BLOCK_SAFE 安全添加模块 — 含名称冲突检测+注册表解析+反模式防护+自动验证
%   result = sl_add_block_safe(modelName, sourceBlock)
%   result = sl_add_block_safe(modelName, sourceBlock, 'destPath', 'MyModel/Gain1', ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   v5.0 反模式防护:
%     #1 Sum 块 warning → 建议使用 Add 或 Subtract
%     #2 To Workspace warning → 建议使用 Signal Logging
%
%   输入:
%     modelName     - 模型名称（必选）
%     sourceBlock   - 源模块路径，如 'simulink/Math Operations/Gain'
%                     或简称如 'Gain'（自动查 sl_block_registry）
%     'destPath'    - 目标路径，默认自动命名（如 'MyModel/Gain'）
%     'position'    - 位置 [left,bottom,right,top]，默认自动
%     'makeNameUnique' - 名称冲突时自动重命名，默认 true
%     'params'      - struct，添加后立即设置的参数
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%     'skipAntiPatternCheck' - 跳过反模式检查，默认 false
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .block        - 模块信息 struct
%     .verification - 验证结果 struct
%     .antiPatternWarnings - 反模式警告列表（如有）
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'destPath', '', ...
        'position', [], ...
        'makeNameUnique', true, ...
        'params', struct(), ...
        'loadModelIfNot', true, ...
        'skipAntiPatternCheck', false);
    
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
    
    % ===== 提取真正的模型名（处理子系统路径如 'model/Subsystem'）=====
    slashIdx = find(modelName == '/', 1);
    if ~isempty(slashIdx)
        actualModelName = modelName(1:slashIdx-1);
    else
        actualModelName = modelName;
    end
    
    % ===== 确保模型已加载 =====
    if opts.loadModelIfNot
        try
            if ~bdIsLoaded(actualModelName)
                load_system(actualModelName);
            end
        catch ME
            result = struct('status', 'error', 'error', ...
                ['Model not loaded and cannot be loaded: ' ME.message]);
            return;
        end
    else
        if ~bdIsLoaded(actualModelName)
            result = struct('status', 'error', 'error', ...
                'Model not loaded. Set loadModelIfNot=true to auto-load.');
            return;
        end
    end
    
    % ===== 解析源模块路径 =====
    srcBlock = sourceBlock;
    % 如果不含 '/'，认为是简称，查注册表
    if isempty(strfind(srcBlock, '/'))
        srcBlock = sl_block_registry(sourceBlock);
    end
    
    % ===== v5.0 反模式检测 =====
    antiPatternWarnings = {};
    if ~opts.skipAntiPatternCheck
        antiPatternWarnings = check_anti_patterns(srcBlock);
    end
    
    % ===== 构造目标路径 =====
    destPath = opts.destPath;
    if isempty(destPath)
        % 从源模块提取类型名
        [~, typeName, ~] = fileparts(srcBlock);
        % 取最后一段（如 'simulink/Math Operations/Gain' → 'Gain'）
        parts = strsplit(typeName, '/');
        if ~isempty(parts)
            typeName = parts{end};
        end
        destPath = [modelName '/' typeName];
    end
    
    % ===== 检查名称冲突 =====
    try
        existingType = get_param(destPath, 'BlockType');
        % 如果已存在同名模块
        if opts.makeNameUnique
            % 让 add_block 的 MakeNameUnique 处理
        else
            result = struct('status', 'error', 'error', ...
                ['Block already exists at: ' destPath '. Set makeNameUnique=true to auto-rename.']);
            return;
        end
    catch
        % 不存在同名模块，OK
    end
    
    % ===== 执行 add_block =====
    actualPath = '';
    try
        if ~isempty(opts.position)
            add_block(srcBlock, destPath, 'Position', opts.position, ...
                'MakeNameUnique', 'on');
        else
            add_block(srcBlock, destPath, 'MakeNameUnique', 'on');
        end
        
        % MakeNameUnique 可能修改了名称，需要重新查找
        actualPath = destPath;
        try
            % 检查 destPath 是否有效
            get_param(destPath, 'BlockType');
            actualPath = destPath;
        catch
            % 名称被修改了，在模型中搜索刚添加的模块
            try
                allBlocks = find_system(modelName, 'SearchDepth', 1);
                % 找最近添加的匹配源模块类型的块
                [~, srcName, ~] = fileparts(srcBlock);
                for bi = length(allBlocks):-1:2  % 倒序，最新的在后面
                    try
                        sb = get_param(allBlocks{bi}, 'SourceBlock');
                        if strcmpi(sb, srcBlock)
                            actualPath = allBlocks{bi};
                            break;
                        end
                    catch
                    end
                end
            catch
            end
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['add_block failed: ' ME.message], ...
            'sourceBlock', srcBlock, 'destPath', destPath);
        return;
    end
    
    % ===== 设置参数 =====
    paramErrors = {};
    if ~isempty(fieldnames(opts.params))
        paramNames = fieldnames(opts.params);
        for i = 1:length(paramNames)
            try
                val = opts.params.(paramNames{i});
                if isnumeric(val)
                    set_param(actualPath, paramNames{i}, num2str(val));
                elseif islogical(val)
                    if val
                        set_param(actualPath, paramNames{i}, 'on');
                    else
                        set_param(actualPath, paramNames{i}, 'off');
                    end
                else
                    set_param(actualPath, paramNames{i}, val);
                end
            catch ME
                paramErrors{end+1} = [paramNames{i} ': ' ME.message]; %#ok<AGROW>
            end
        end
    end
    
    % ===== 验证 =====
    verification = struct();
    try
        verifyType = get_param(actualPath, 'BlockType');
        verification.blockExists = true;
        verification.actualType = verifyType;
    catch
        verification.blockExists = false;
    end
    
    % 验证参数是否正确设置
    verification.allParamsCorrect = isempty(paramErrors);
    if ~isempty(paramErrors)
        verification.incorrectParams = paramErrors;
    else
        verification.incorrectParams = {};
    end
    
    % ===== 收集返回的模块信息 =====
    blockInfo = struct();
    blockInfo.path = actualPath;
    try blockInfo.type = get_param(actualPath, 'BlockType'); catch blockInfo.type = ''; end
    try blockInfo.sourceBlock = get_param(actualPath, 'SourceBlock'); catch blockInfo.sourceBlock = srcBlock; end
    try blockInfo.position = get_param(actualPath, 'Position'); catch blockInfo.position = []; end
    
    % 获取实际参数值
    if ~isempty(fieldnames(opts.params))
        blockInfo.params = struct();
        paramNames = fieldnames(opts.params);
        for i = 1:length(paramNames)
            try
                blockInfo.params.(paramNames{i}) = get_param(actualPath, paramNames{i});
            catch
            end
        end
    end
    
    % ===== 组装返回 =====
    result = struct('status', 'ok', 'block', blockInfo, 'verification', verification);
    if ~isempty(antiPatternWarnings)
        result.antiPatternWarnings = antiPatternWarnings;
    end
end

% ===== v5.0 辅助函数: 反模式检测 =====
function warnings = check_anti_patterns(srcBlock)
% 检测用户请求的模块是否属于已知的反模式
% 基于 simulink/skills 项目的 8 大禁止做法
    warnings = {};
    
    % 提取模块类型名（最后一段）
    parts = strsplit(srcBlock, '/');
    typeName = parts{end};
    
    % 反模式 #1: Sum 块 — 推荐使用 Add 或 Subtract
    if strcmpi(typeName, 'Sum')
        warnings{end+1} = struct( ...
            'rule', '#1', ...
            'level', 'warning', ...
            'message', 'Sum block is discouraged in modern Simulink', ...
            'suggestion', 'Use Add block for addition, Subtract block for subtraction', ...
            'alternatives', {{'Add', 'Subtract'}}); %#ok<AGROW>
    end
    
    % 反模式 #2: To Workspace 块 — 推荐使用 Signal Logging
    if ~isempty(strfind(lower(typeName), 'to workspace')) || strcmpi(typeName, 'To Workspace')
        warnings{end+1} = struct( ...
            'rule', '#2', ...
            'level', 'warning', ...
            'message', 'To Workspace block is discouraged for signal recording', ...
            'suggestion', 'Use Signal Logging via sl_signal_logging instead', ...
            'alternativeCommand', 'sl_signal_logging'); %#ok<AGROW>
    end
end
