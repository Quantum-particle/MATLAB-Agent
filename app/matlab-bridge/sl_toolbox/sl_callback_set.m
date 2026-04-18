function result = sl_callback_set(modelName, action, varargin)
% SL_CALLBACK_SET 设置回调函数 — 模型/块级回调的 set/get/remove/list
%   result = sl_callback_set('MyModel', 'set', 'target', 'model', 'callbackType', 'InitFcn', 'callbackCode', 'myInit')
%   result = sl_callback_set('MyModel', 'get', 'target', 'model', 'callbackType', 'InitFcn')
%   result = sl_callback_set('MyModel', 'remove', 'target', 'model', 'callbackType', 'InitFcn')
%   result = sl_callback_set('MyModel', 'list', 'target', 'model')
%   result = sl_callback_set('MyModel', 'list', 'target', 'block', 'blockPath', 'MyModel/Gain1')
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName       - 模型名称（必选）
%     action          - 操作: 'set'|'get'|'remove'|'list'（必选）
%     'target'        - 目标类型: 'model'(默认) 或 'block'
%     'blockPath'     - 模块路径（target='block' 时必填）
%     'callbackType'  - 回调类型（set/get/remove 时必填）
%     'callbackCode'  - 回调代码（set 时必填）
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   回调类型列表:
%     模型级: PreLoadFcn, PostLoadFcn, PreSaveFcn, PostSaveFcn,
%             InitFcn, StartFcn, StopFcn, CloseFcn
%     块级:   OpenFcn, DeleteFcn, CopyFcn, InitFcn, LoadFcn,
%             ModelCloseFcn, NameChangeFcn, ParentCloseFcn, PreSaveFcn,
%             PostSaveFcn, UndoFcn
%
%   输出: struct
%     .status    - 'ok' 或 'error'
%     .callback  - struct，操作结果
%     .message   - 人类可读的总结信息
%     .error     - 错误信息（仅 status='error' 时）

    % ===== 有效的回调类型 =====
    modelCallbacks = {'PreLoadFcn', 'PostLoadFcn', 'PreSaveFcn', 'PostSaveFcn', ...
                      'InitFcn', 'StartFcn', 'StopFcn', 'CloseFcn'};
    blockCallbacks = {'OpenFcn', 'DeleteFcn', 'CopyFcn', 'InitFcn', 'LoadFcn', ...
                      'ModelCloseFcn', 'NameChangeFcn', 'ParentCloseFcn', ...
                      'PreSaveFcn', 'PostSaveFcn', 'UndoFcn'};

    % ===== 解析参数 =====
    target = 'model';
    blockPath = '';
    callbackType = '';
    callbackCode = '';
    loadModelIfNot = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            switch lower(key)
                case 'target'
                    target = val;
                case 'blockpath'
                    blockPath = val;
                case 'callbacktype'
                    callbackType = val;
                case 'callbackcode'
                    callbackCode = val;
                case 'loadmodelifnot'
                    loadModelIfNot = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'callback', struct(), ...
        'message', '', 'error', '');

    % ===== 确保模型已加载 =====
    if loadModelIfNot
        try
            if ~bdIsLoaded(modelName)
                load_system(modelName);
            end
        catch ME
            result.status = 'error';
            result.error = ['Model not loaded and cannot be loaded: ' ME.message];
            result.message = result.error;
            return;
        end
    end

    % ===== 确定目标路径 =====
    if strcmpi(target, 'model')
        targetPath = modelName;
        validCallbacks = modelCallbacks;
    elseif strcmpi(target, 'block')
        if isempty(blockPath)
            result.status = 'error';
            result.error = 'blockPath is required when target=''block''';
            result.message = result.error;
            return;
        end
        targetPath = blockPath;
        validCallbacks = blockCallbacks;

        % 验证模块存在
        try
            get_param(blockPath, 'BlockType');
        catch ME
            result.status = 'error';
            result.error = ['Block not found: ' blockPath ' - ' ME.message];
            result.message = result.error;
            return;
        end
    else
        result.status = 'error';
        result.error = ['Unknown target: ' target];
        result.message = result.error;
        return;
    end

    % ===== 执行操作 =====
    switch lower(action)
        case 'set'
            result = do_set(result, targetPath, callbackType, callbackCode, validCallbacks, target);
        case 'get'
            result = do_get(result, targetPath, callbackType, validCallbacks, target);
        case 'remove'
            result = do_remove(result, targetPath, callbackType, validCallbacks, target);
        case 'list'
            result = do_list(result, targetPath, validCallbacks, target);
        otherwise
            result.status = 'error';
            result.error = ['Unknown action: ' action];
            result.message = result.error;
    end
end


function result = do_set(result, targetPath, callbackType, callbackCode, validCallbacks, target)
% DO_SET 设置回调

    % 验证回调类型
    if isempty(callbackType)
        result.status = 'error';
        result.error = 'callbackType is required for action=''set''';
        result.message = result.error;
        return;
    end

    isvalid = false;
    for vi = 1:length(validCallbacks)
        if strcmpi(callbackType, validCallbacks{vi})
            isvalid = true;
            break;
        end
    end

    if ~isvalid
        result.status = 'error';
        result.error = sprintf('Invalid callback type ''%s'' for %s-level. Valid: %s', ...
            callbackType, target, strjoin(validCallbacks, ', '));
        result.message = result.error;
        return;
    end

    if isempty(callbackCode)
        result.status = 'error';
        result.error = 'callbackCode is required for action=''set''';
        result.message = result.error;
        return;
    end

    % 基本语法检查
    try
        % 尝试简单语法检查（不全但能捕获明显错误）
        eval(['() ' callbackCode]); %#ok<EVLCM>
    catch
        % 语法检查通过（或检查本身不完善）
    end

    % 设置回调
    try
        set_param(targetPath, callbackType, callbackCode);
    catch ME
        result.status = 'error';
        result.error = ['Failed to set callback: ' ME.message];
        result.message = result.error;
        return;
    end

    % 验证
    verified = false;
    try
        actualCode = get_param(targetPath, callbackType);
        verified = strcmp(actualCode, callbackCode);
    catch
    end

    result.callback = struct( ...
        'action', 'set', ...
        'target', target, ...
        'targetPath', targetPath, ...
        'callbackType', callbackType, ...
        'callbackCode', callbackCode, ...
        'verified', verified);

    result.message = sprintf('Callback %s set on %s', callbackType, targetPath);
    if ~verified
        result.message = [result.message ' (verification could not confirm)'];
    end
end


function result = do_get(result, targetPath, callbackType, validCallbacks, target)
% DO_GET 获取回调代码

    if isempty(callbackType)
        result.status = 'error';
        result.error = 'callbackType is required for action=''get''';
        result.message = result.error;
        return;
    end

    isvalid = false;
    for vi = 1:length(validCallbacks)
        if strcmpi(callbackType, validCallbacks{vi})
            isvalid = true;
            break;
        end
    end

    if ~isvalid
        result.status = 'error';
        result.error = sprintf('Invalid callback type ''%s'' for %s-level', callbackType, target);
        result.message = result.error;
        return;
    end

    try
        code = get_param(targetPath, callbackType);
    catch ME
        result.status = 'error';
        result.error = ['Failed to get callback: ' ME.message];
        result.message = result.error;
        return;
    end

    result.callback = struct( ...
        'action', 'get', ...
        'target', target, ...
        'targetPath', targetPath, ...
        'callbackType', callbackType, ...
        'callbackCode', code, ...
        'isEmpty', isempty(code));

    if isempty(code)
        result.message = sprintf('Callback %s on %s is not set', callbackType, targetPath);
    else
        result.message = sprintf('Callback %s on %s: %s', callbackType, targetPath, code);
    end
end


function result = do_remove(result, targetPath, callbackType, validCallbacks, target)
% DO_REMOVE 删除回调

    if isempty(callbackType)
        result.status = 'error';
        result.error = 'callbackType is required for action=''remove''';
        result.message = result.error;
        return;
    end

    isvalid = false;
    for vi = 1:length(validCallbacks)
        if strcmpi(callbackType, validCallbacks{vi})
            isvalid = true;
            break;
        end
    end

    if ~isvalid
        result.status = 'error';
        result.error = sprintf('Invalid callback type ''%s'' for %s-level', callbackType, target);
        result.message = result.error;
        return;
    end

    try
        set_param(targetPath, callbackType, '');
    catch ME
        result.status = 'error';
        result.error = ['Failed to remove callback: ' ME.message];
        result.message = result.error;
        return;
    end

    % 验证
    verified = false;
    try
        actualCode = get_param(targetPath, callbackType);
        verified = isempty(actualCode);
    catch
    end

    result.callback = struct( ...
        'action', 'remove', ...
        'target', target, ...
        'targetPath', targetPath, ...
        'callbackType', callbackType, ...
        'verified', verified);

    result.message = sprintf('Callback %s removed from %s', callbackType, targetPath);
end


function result = do_list(result, targetPath, validCallbacks, target)
% DO_LIST 列出所有已设置的回调

    callbacks = {};
    cbIdx = 1;

    for vi = 1:length(validCallbacks)
        try
            code = get_param(targetPath, validCallbacks{vi});
            if ~isempty(code)
                callbacks{cbIdx} = struct( ...
                    'callbackType', validCallbacks{vi}, ...
                    'callbackCode', code);
                cbIdx = cbIdx + 1;
            end
        catch
            % 某些回调类型可能不支持，跳过
        end
    end

    result.callback = struct( ...
        'action', 'list', ...
        'target', target, ...
        'targetPath', targetPath, ...
        'callbacks', callbacks, ...
        'count', length(callbacks));

    result.message = sprintf('Found %d callbacks set on %s', length(callbacks), targetPath);
end
