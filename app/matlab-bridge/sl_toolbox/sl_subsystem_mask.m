function result = sl_subsystem_mask(modelName, blockPath, action, varargin)
% SL_SUBSYSTEM_MASK 创建/编辑 Mask — R2017a+ 推荐 Simulink.Mask / R2016a 回退 legacy API
%   result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'create', ...)
%   result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'inspect')
%   result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'edit', ...)
%   result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'delete')
%
%   输入:
%     modelName   - 模型名称（必选）
%     blockPath   - 子系统完整路径（必选）
%     action      - 'create'/'edit'/'delete'/'inspect'（必选）
%     'parameters' - cell{struct}，每个 struct 含 .name, .prompt, .type, .defaultValue
%                    type 可选: 'edit'/'popup'/'checkbox'/'listbox'
%     'icon'       - char，Mask 图标命令，如 'disp(''PID'')'
%     'documentation' - char，Mask 文档说明
%     'loadModelIfNot' - 默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .mask         - struct(.path, .action, .parameterCount, .parameters)
%     .verification - struct(.maskExists, .allParametersSet)
%     .error        - 错误信息

    % ===== 默认参数 =====
    opts = struct();
    opts.parameters = {};
    opts.icon = '';
    opts.documentation = '';
    opts.loadModelIfNot = true;

    % ===== 解析 varargin =====
    i = 1;
    while i <= length(varargin)
        key = varargin{i};
        if ischar(key) || isstring(key)
            key = char(key);
            switch lower(key)
                case 'parameters'
                    if i+1 <= length(varargin)
                        opts.parameters = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'parameters value missing');
                        return;
                    end
                case 'icon'
                    if i+1 <= length(varargin)
                        opts.icon = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'icon value missing');
                        return;
                    end
                case 'documentation'
                    if i+1 <= length(varargin)
                        opts.documentation = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'documentation value missing');
                        return;
                    end
                case 'loadmodelifnot'
                    if i+1 <= length(varargin)
                        opts.loadModelIfNot = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'loadModelIfNot value missing');
                        return;
                    end
                otherwise
                    result = struct('status', 'error', 'error', ['Unknown parameter: ' key]);
                    return;
            end
        else
            result = struct('status', 'error', 'error', ['Invalid parameter at position ' num2str(i)]);
            return;
        end
    end

    % ===== 输入验证 =====
    if nargin < 3 || isempty(modelName) || isempty(blockPath) || isempty(action)
        result = struct('status', 'error', 'error', 'modelName, blockPath, and action are required');
        return;
    end

    action = lower(char(action));
    if ~ismember(action, {'create', 'edit', 'delete', 'inspect'})
        result = struct('status', 'error', 'error', ['Invalid action: ' action '. Use create/edit/delete/inspect.']);
        return;
    end

    % ===== 加载模型 =====
    try
        if opts.loadModelIfNot && ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch me
        result = struct('status', 'error', 'error', ['Failed to load model: ' me.message]);
        return;
    end

    % ===== 检查 blockPath 存在 =====
    try
        allBlocks = find_system(modelName, 'LookUnderMasks', 'all');
        blockFound = false;
        for bi = 1:length(allBlocks)
            if strcmp(allBlocks{bi}, blockPath)
                blockFound = true;
                break;
            end
        end
        if ~blockFound
            result = struct('status', 'error', 'error', ['Block not found: ' blockPath]);
            return;
        end
    catch me
        result = struct('status', 'error', 'error', ['Error checking block: ' me.message]);
        return;
    end

    % ===== 版本检测 =====
    matlabVer = ver('MATLAB');
    verNum = sscanf(matlabVer.Version, '%d.%d');
    hasModernMask = verNum(1) > 9 || (verNum(1) == 9 && verNum(2) >= 2); % R2017a+

    % ===== 根据 action 执行 =====
    try
        switch action
            case 'create'
                result = do_mask_create(blockPath, opts, hasModernMask);
            case 'edit'
                result = do_mask_edit(blockPath, opts, hasModernMask);
            case 'delete'
                result = do_mask_delete(blockPath, hasModernMask);
            case 'inspect'
                result = do_mask_inspect(blockPath, hasModernMask);
        end
    catch me
        result = struct('status', 'error', 'error', ['Mask operation failed: ' me.message]);
        return;
    end

    % ===== 验证 =====
    try
        verification = verify_mask(blockPath, action, opts, hasModernMask);
        result.verification = verification;
    catch me
        result.verification = struct('maskExists', false, 'allParametersSet', false);
    end
end


function result = do_mask_create(blockPath, opts, hasModernMask)
% DO_MASK_CREATE 创建 Mask

    if hasModernMask
        % ===== R2017a+: 使用 Simulink.Mask API =====
        % 先删除已有 Mask（如果有）
        try
            existingMask = Simulink.Mask.get(blockPath);
            if ~isempty(existingMask)
                existingMask.delete();
            end
        catch
            % 没有 Mask，继续
        end

        % 创建新 Mask
        maskObj = Simulink.Mask.create(blockPath);

        % 添加参数
        for pi = 1:length(opts.parameters)
            p = opts.parameters{pi};
            if isstruct(p)
                paramName = get_field_default(p, 'name', ['Param' num2str(pi)]);
                prompt = get_field_default(p, 'prompt', paramName);
                pType = lower(get_field_default(p, 'type', 'edit'));
                defaultVal = get_field_default(p, 'defaultValue', '');

                % 映射 type 到 Simulink.Mask 参数类型
                switch pType
                    case 'edit'
                        maskObj.addParameter('Type', 'edit', 'Prompt', prompt, ...
                            'Name', paramName, 'Value', defaultVal);
                    case 'popup'
                        maskObj.addParameter('Type', 'popup', 'Prompt', prompt, ...
                            'Name', paramName, 'Value', defaultVal, ...
                            'TypeOptions', {'option1','option2'});
                    case 'checkbox'
                        maskObj.addParameter('Type', 'checkbox', 'Prompt', prompt, ...
                            'Name', paramName, 'Value', defaultVal);
                    case 'listbox'
                        maskObj.addParameter('Type', 'listbox', 'Prompt', prompt, ...
                            'Name', paramName, 'Value', defaultVal);
                    otherwise
                        maskObj.addParameter('Type', 'edit', 'Prompt', prompt, ...
                            'Name', paramName, 'Value', defaultVal);
                end
            end
        end

        % 设置图标
        if ~isempty(opts.icon)
            try
                set(maskObj, 'Icon', opts.icon);
            catch
                % 图标命令可能有语法错误，跳过
            end
        end

        % 设置文档
        if ~isempty(opts.documentation)
            try
                set(maskObj, 'Documentation', opts.documentation);
            catch
                % 跳过
            end
        end

        % 读取创建后的参数信息
        paramInfo = get_mask_params_modern(maskObj);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'create';
        result.mask.parameterCount = length(maskObj.Parameters);
        result.mask.parameters = paramInfo;

    else
        % ===== R2016a 回退: Legacy API =====
        % 启用 Mask
        set_param(blockPath, 'Mask', 'on');

        % 设置参数
        if ~isempty(opts.parameters)
            prompts = {};
            vars = {};
            types = {};
            defaults = {};
            for pi = 1:length(opts.parameters)
                p = opts.parameters{pi};
                if isstruct(p)
                    paramName = get_field_default(p, 'name', ['Param' num2str(pi)]);
                    prompt = get_field_default(p, 'prompt', paramName);
                    pType = lower(get_field_default(p, 'type', 'edit'));
                    defaultVal = get_field_default(p, 'defaultValue', '');
                else
                    paramName = ['Param' num2str(pi)];
                    prompt = paramName;
                    pType = 'edit';
                    defaultVal = '';
                end
                prompts{end+1} = prompt;
                vars{end+1} = paramName;
                types{end+1} = pType;
                defaults{end+1} = defaultVal;
            end

            % 用 '|' 拼接字符串
            promptStr = str_join(prompts, '|');
            varStr = str_join(vars, ',');

            set_param(blockPath, 'MaskPromptString', promptStr);
            set_param(blockPath, 'MaskVariables', varStr);

            % 设置类型和默认值
            % Legacy API 用 MaskTlookupValue 等参数
            try
                typeStr = str_join(types, '|');
                set_param(blockPath, 'MaskTlookupValue', typeStr);
            catch
                % 某些版本可能不支持
            end

            try
                defaultStr = str_join(defaults, '|');
                set_param(blockPath, 'MaskInitialization', defaultStr);
            catch
                % 跳过
            end
        end

        % 设置图标
        if ~isempty(opts.icon)
            try
                set_param(blockPath, 'MaskDisplay', opts.icon);
            catch
                % 跳过
            end
        end

        % 设置文档
        if ~isempty(opts.documentation)
            try
                set_param(blockPath, 'MaskHelp', opts.documentation);
            catch
                % 跳过
            end
        end

        % 读取创建后的参数信息
        paramInfo = get_mask_params_legacy(blockPath);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'create';
        result.mask.parameterCount = length(opts.parameters);
        result.mask.parameters = paramInfo;
    end
end


function result = do_mask_edit(blockPath, opts, hasModernMask)
% DO_MASK_EDIT 编辑已有 Mask

    % 检查 Mask 是否存在
    maskExists = false;
    if hasModernMask
        try
            maskObj = Simulink.Mask.get(blockPath);
            maskExists = ~isempty(maskObj);
        catch
            maskExists = false;
        end
    else
        try
            maskVal = get_param(blockPath, 'Mask');
            maskExists = strcmp(maskVal, 'on');
        catch
            maskExists = false;
        end
    end

    if ~maskExists
        result = struct('status', 'error', 'error', 'No mask exists on this block. Use create first.');
        return;
    end

    if hasModernMask
        % ===== R2017a+: 使用 Simulink.Mask API =====
        % 删除旧 Mask，重新创建（比逐个删除参数更可靠）
        try
            oldMask = Simulink.Mask.get(blockPath);
            if ~isempty(oldMask)
                oldMask.delete();
            end
        catch
            % 删除失败，继续
        end

        % 创建新 Mask
        maskObj = Simulink.Mask.create(blockPath);

        % 添加新参数
        if ~isempty(opts.parameters)
            for pi = 1:length(opts.parameters)
                p = opts.parameters{pi};
                if isstruct(p)
                    paramName = get_field_default(p, 'name', ['Param' num2str(pi)]);
                    prompt = get_field_default(p, 'prompt', paramName);
                    pType = lower(get_field_default(p, 'type', 'edit'));
                    defaultVal = get_field_default(p, 'defaultValue', '');

                    switch pType
                        case 'edit'
                            maskObj.addParameter('Type', 'edit', 'Prompt', prompt, ...
                                'Name', paramName, 'Value', defaultVal);
                        case 'popup'
                            maskObj.addParameter('Type', 'popup', 'Prompt', prompt, ...
                                'Name', paramName, 'Value', defaultVal, ...
                                'TypeOptions', {'option1','option2'});
                        case 'checkbox'
                            maskObj.addParameter('Type', 'checkbox', 'Prompt', prompt, ...
                                'Name', paramName, 'Value', defaultVal);
                        case 'listbox'
                            maskObj.addParameter('Type', 'listbox', 'Prompt', prompt, ...
                                'Name', paramName, 'Value', defaultVal);
                        otherwise
                            maskObj.addParameter('Type', 'edit', 'Prompt', prompt, ...
                                'Name', paramName, 'Value', defaultVal);
                    end
                end
            end
        end

        % 更新图标
        if ~isempty(opts.icon)
            try
                set(maskObj, 'Icon', opts.icon);
            catch
                % 跳过
            end
        end

        % 更新文档
        if ~isempty(opts.documentation)
            try
                set(maskObj, 'Documentation', opts.documentation);
            catch
                % 跳过
            end
        end

        paramInfo = get_mask_params_modern(maskObj);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'edit';
        result.mask.parameterCount = length(maskObj.Parameters);
        result.mask.parameters = paramInfo;

    else
        % ===== R2016a 回退: Legacy API =====
        % 直接重新设置 Mask 参数（覆盖式编辑）
        if ~isempty(opts.parameters)
            prompts = {};
            vars = {};
            types = {};
            defaults = {};
            for pi = 1:length(opts.parameters)
                p = opts.parameters{pi};
                if isstruct(p)
                    paramName = get_field_default(p, 'name', ['Param' num2str(pi)]);
                    prompt = get_field_default(p, 'prompt', paramName);
                    pType = lower(get_field_default(p, 'type', 'edit'));
                    defaultVal = get_field_default(p, 'defaultValue', '');
                else
                    paramName = ['Param' num2str(pi)];
                    prompt = paramName;
                    pType = 'edit';
                    defaultVal = '';
                end
                prompts{end+1} = prompt;
                vars{end+1} = paramName;
                types{end+1} = pType;
                defaults{end+1} = defaultVal;
            end

            promptStr = str_join(prompts, '|');
            varStr = str_join(vars, ',');
            set_param(blockPath, 'MaskPromptString', promptStr);
            set_param(blockPath, 'MaskVariables', varStr);

            try
                typeStr = str_join(types, '|');
                set_param(blockPath, 'MaskTlookupValue', typeStr);
            catch, end

            try
                defaultStr = str_join(defaults, '|');
                set_param(blockPath, 'MaskInitialization', defaultStr);
            catch, end
        end

        if ~isempty(opts.icon)
            try
                set_param(blockPath, 'MaskDisplay', opts.icon);
            catch, end
        end

        if ~isempty(opts.documentation)
            try
                set_param(blockPath, 'MaskHelp', opts.documentation);
            catch, end
        end

        paramInfo = get_mask_params_legacy(blockPath);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'edit';
        result.mask.parameterCount = length(opts.parameters);
        result.mask.parameters = paramInfo;
    end
end


function result = do_mask_delete(blockPath, hasModernMask)
% DO_MASK_DELETE 删除 Mask

    if hasModernMask
        % ===== R2017a+: maskObj.delete() =====
        try
            maskObj = Simulink.Mask.get(blockPath);
            if ~isempty(maskObj)
                maskObj.delete();
            end
        catch me
            result = struct('status', 'error', 'error', ['Failed to delete mask: ' me.message]);
            return;
        end
    else
        % ===== R2016a: set_param 'Mask' 'off' =====
        try
            set_param(blockPath, 'Mask', 'off');
        catch me
            result = struct('status', 'error', 'error', ['Failed to delete mask: ' me.message]);
            return;
        end
    end

    result = struct('status', 'ok');
    result.mask = struct();
    result.mask.path = blockPath;
    result.mask.action = 'delete';
    result.mask.parameterCount = 0;
    result.mask.parameters = {};
end


function result = do_mask_inspect(blockPath, hasModernMask)
% DO_MASK_INSPECT 检查 Mask 信息

    % 检查 Mask 是否存在
    maskExists = false;
    if hasModernMask
        try
            maskObj = Simulink.Mask.get(blockPath);
            maskExists = ~isempty(maskObj);
        catch
            maskExists = false;
        end
    else
        try
            maskVal = get_param(blockPath, 'Mask');
            maskExists = strcmp(maskVal, 'on');
        catch
            maskExists = false;
        end
    end

    if ~maskExists
        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'inspect';
        result.mask.parameterCount = 0;
        result.mask.parameters = {};
        return;
    end

    if hasModernMask
        % ===== R2017a+: 读取 Simulink.Mask 对象 =====
        maskObj = Simulink.Mask.get(blockPath);
        paramInfo = get_mask_params_modern(maskObj);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'inspect';
        result.mask.parameterCount = length(maskObj.Parameters);
        result.mask.parameters = paramInfo;

        % 附加额外信息
        try
            result.mask.icon = maskObj.Icon;
        catch, end
        try
            result.mask.documentation = maskObj.Documentation;
        catch, end

    else
        % ===== R2016a: 读取 legacy 参数 =====
        paramInfo = get_mask_params_legacy(blockPath);

        result = struct('status', 'ok');
        result.mask = struct();
        result.mask.path = blockPath;
        result.mask.action = 'inspect';
        result.mask.parameterCount = length(paramInfo);
        result.mask.parameters = paramInfo;

        % 附加额外信息
        try
            result.mask.icon = get_param(blockPath, 'MaskDisplay');
        catch, end
        try
            result.mask.documentation = get_param(blockPath, 'MaskHelp');
        catch, end
    end
end


function paramInfo = get_mask_params_modern(maskObj)
% GET_MASK_PARAMS_MODERN 从 Simulink.Mask 对象读取参数信息

    paramInfo = {};
    try
        params = maskObj.Parameters;
        for pi = 1:length(params)
            p = struct();
            p.name = params(pi).Name;
            p.prompt = params(pi).Prompt;
            p.type = params(pi).Type;
            try
                p.defaultValue = params(pi).Value;
            catch
                p.defaultValue = '';
            end
            % popup 类型读取选项
            if strcmp(lower(params(pi).Type), 'popup')
                try
                    p.typeOptions = params(pi).TypeOptions;
                catch
                    p.typeOptions = {};
                end
            end
            paramInfo{end+1} = p;
        end
    catch
        % 读取失败，返回空
    end
end


function paramInfo = get_mask_params_legacy(blockPath)
% GET_MASK_PARAMS_LEGACY 从 legacy API 读取参数信息

    paramInfo = {};
    try
        promptStr = get_param(blockPath, 'MaskPromptString');
        varStr = get_param(blockPath, 'MaskVariables');

        if isempty(promptStr)
            return;
        end

        % 用 '|' 分割 prompts，用 ',' 分割变量名
        prompts = str_split(promptStr, '|');
        vars = str_split(varStr, ',');

        % 获取类型信息
        try
            typeStr = get_param(blockPath, 'MaskTlookupValue');
            types = str_split(typeStr, '|');
        catch
            types = cell(1, length(prompts));
            for ti = 1:length(types)
                types{ti} = 'edit';
            end
        end

        % 获取默认值
        try
            defaultStr = get_param(blockPath, 'MaskInitialization');
            defaults = str_split(defaultStr, '|');
        catch
            defaults = cell(1, length(prompts));
            for di = 1:length(defaults)
                defaults{di} = '';
            end
        end

        nParams = min([length(prompts), length(vars)]);
        for pi = 1:nParams
            p = struct();
            p.name = strtrim(vars{pi});
            p.prompt = strtrim(prompts{pi});
            if pi <= length(types)
                p.type = strtrim(types{pi});
            else
                p.type = 'edit';
            end
            if pi <= length(defaults)
                p.defaultValue = strtrim(defaults{pi});
            else
                p.defaultValue = '';
            end
            paramInfo{end+1} = p;
        end
    catch
        % 读取失败，返回空
    end
end


function verification = verify_mask(blockPath, action, opts, hasModernMask)
% VERIFY_MASK 验证 Mask 操作结果

    verification = struct();

    % 检查 Mask 是否存在
    if strcmp(action, 'delete')
        % 删除后 Mask 不应存在
        try
            if hasModernMask
                maskObj = Simulink.Mask.get(blockPath);
                verification.maskExists = isempty(maskObj);
            else
                maskVal = get_param(blockPath, 'Mask');
                verification.maskExists = ~strcmp(maskVal, 'on');
            end
        catch
            verification.maskExists = true; % 出错通常意味着没有 Mask，符合预期
        end
    else
        % create/edit/inspect 后 Mask 应存在
        try
            if hasModernMask
                maskObj = Simulink.Mask.get(blockPath);
                verification.maskExists = ~isempty(maskObj);
            else
                maskVal = get_param(blockPath, 'Mask');
                verification.maskExists = strcmp(maskVal, 'on');
            end
        catch
            verification.maskExists = false;
        end
    end

    % 检查参数是否设置
    if strcmp(action, 'delete') || isempty(opts.parameters)
        verification.allParametersSet = true;
    else
        try
            if hasModernMask
                maskObj = Simulink.Mask.get(blockPath);
                if isempty(maskObj)
                    verification.allParametersSet = false;
                else
                    actualCount = length(maskObj.Parameters);
                    verification.allParametersSet = (actualCount >= length(opts.parameters));
                end
            else
                promptStr = get_param(blockPath, 'MaskPromptString');
                if isempty(promptStr)
                    verification.allParametersSet = false;
                else
                    prompts = str_split(promptStr, '|');
                    verification.allParametersSet = (length(prompts) >= length(opts.parameters));
                end
            end
        catch
            verification.allParametersSet = false;
        end
    end
end


function val = get_field_default(s, field, defaultVal)
% GET_FIELD_DEFAULT 安全获取 struct 字段，不存在则返回默认值
    if isfield(s, field)
        val = s.(field);
    else
        val = defaultVal;
    end
end


function result = str_join(cells, delimiter)
% STR_JOIN 用分隔符连接 cell 字符串数组（R2016a 兼容，不用 strjoin）
    if isempty(cells)
        result = '';
        return;
    end
    result = cells{1};
    for i = 2:length(cells)
        result = [result delimiter cells{i}];
    end
end


function parts = str_split(str, delimiter)
% STR_SPLIT 用分隔符分割字符串（R2016a 兼容，不用 strsplit）
    parts = {};
    if isempty(str)
        return;
    end
    remaining = str;
    while ~isempty(remaining)
        idx = strfind(remaining, delimiter);
        if isempty(idx)
            parts{end+1} = remaining;
            remaining = '';
        else
            parts{end+1} = remaining(1:idx(1)-1);
            remaining = remaining(idx(1)+length(delimiter):end);
        end
    end
end
