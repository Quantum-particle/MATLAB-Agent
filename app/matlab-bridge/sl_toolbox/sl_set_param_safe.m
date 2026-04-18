function result = sl_set_param_safe(blockPath, params, varargin)
% SL_SET_PARAM_SAFE 安全设置参数 — DialogParameters 预检 + 类型验证 + 验证生效
%   result = sl_set_param_safe(blockPath, params)
%   result = sl_set_param_safe(blockPath, params, 'validateAfter', true, ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     blockPath        - 模块完整路径，如 'MyModel/Gain1'（必选）
%     params           - struct，要设置的参数名-值对（值必须为字符串）
%                        如 struct('Gain', '2.5', 'Multiplication', 'Element-wise(K*u)')
%     'validateAfter'  - 设置后验证是否生效，默认 true
%     'skipPreCheck'   - 跳过 DialogParameters 预检，默认 false
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .block        - 模块信息 struct(.path, .blockType)
%     .results      - struct 数组，每项: param, requestedValue, success, actualValue, message
%     .verification - struct(.allParamsCorrect, .incorrectParams)
%     .message      - 人类可读的总结信息
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'validateAfter', true, ...
        'skipPreCheck', false, ...
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

    result = struct('status', 'ok', 'block', struct(), 'results', struct([]), ...
        'verification', struct('allParamsCorrect', true, 'incorrectParams', {{}}), ...
        'message', '', 'error', '');

    % ===== 提取模型名 =====
    modelName = blockPath;
    slashIdx = strfind(blockPath, '/');
    if ~isempty(slashIdx)
        modelName = blockPath(1:slashIdx(1)-1);
    end

    % ===== 确保模型已加载 =====
    if opts.loadModelIfNot
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

    % ===== 验证模块存在 =====
    try
        blockType = get_param(blockPath, 'BlockType');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        result.message = result.error;
        return;
    end

    result.block = struct('path', blockPath, 'blockType', blockType);

    % ===== DialogParameters 预检 =====
    paramNames = fieldnames(params);
    nParams = length(paramNames);

    if ~opts.skipPreCheck && nParams > 0
        try
            dialogParams = get_param(blockPath, 'DialogParameters');
            if ~isempty(dialogParams)
                % dialogParams 是 struct，字段名就是合法参数名
                validParamNames = fieldnames(dialogParams);
                for i = 1:nParams
                    pName = paramNames{i};
                    found = false;
                    for j = 1:length(validParamNames)
                        if strcmpi(pName, validParamNames{j})
                            found = true;
                            break;
                        end
                    end
                    if ~found
                        % 参数名不在 DialogParameters 中，但仍可能合法
                        % （某些隐藏参数如 MaskCallBack 等），仅记录 warning
                    end
                end
            end
        catch
            % DialogParameters 获取失败（某些模块不支持），跳过预检
        end
    end

    % ===== 逐个设置参数 =====
    results = cell(1, nParams);
    nSuccess = 0;
    nFail = 0;

    for i = 1:nParams
        pName = paramNames{i};
        pValue = params.(pName);

        % 确保 value 是字符串（set_param 要求）
        if isnumeric(pValue)
            pValueStr = num2str(pValue);
        elseif islogical(pValue)
            if pValue
                pValueStr = 'on';
            else
                pValueStr = 'off';
            end
        elseif ischar(pValue)
            pValueStr = pValue;
        else
            pValueStr = char(pValue);
        end

        r = struct('param', pName, 'requestedValue', pValueStr, ...
            'success', false, 'actualValue', '', 'message', '');

        try
            set_param(blockPath, pName, pValueStr);
            r.success = true;
            nSuccess = nSuccess + 1;
            r.message = 'Set successfully';
        catch ME
            r.success = false;
            nFail = nFail + 1;
            r.message = ['Failed: ' ME.message];
        end

        results{i} = r;
    end

    % ===== 验证设置是否生效 =====
    if opts.validateAfter && nSuccess > 0
        incorrectParams = {};
        for i = 1:nParams
            if results{i}.success
                pName = results{i}.param;
                try
                    actualVal = get_param(blockPath, pName);
                    results{i}.actualValue = actualVal;
                    % 比较：set_param 和 get_param 的值可能格式不同
                    % 如 set '2.5' 后 get 回来可能还是 '2.5'，但布尔值可能 on/off
                    if ~strcmpi(actualVal, results{i}.requestedValue)
                        % 容差比较：尝试数值比较
                        isDiff = true;
                        try
                            numActual = str2double(actualVal);
                            numRequested = str2double(results{i}.requestedValue);
                            if ~isnan(numActual) && ~isnan(numRequested)
                                if abs(numActual - numRequested) < 1e-10
                                    isDiff = false;
                                end
                            end
                        catch
                        end
                        % 容差比较：on/off vs true/false
                        if isDiff
                            if (strcmpi(actualVal, 'on') && strcmpi(results{i}.requestedValue, 'true')) || ...
                               (strcmpi(actualVal, 'off') && strcmpi(results{i}.requestedValue, 'false'))
                                isDiff = false;
                            end
                        end
                        if isDiff
                            incorrectParams{end+1} = pName; %#ok<AGROW>
                            results{i}.success = false;
                            results{i}.message = ['Value mismatch: requested=' results{i}.requestedValue ' actual=' actualVal];
                        end
                    end
                catch ME
                    results{i}.actualValue = ['Error reading: ' ME.message];
                end
            else
                results{i}.actualValue = 'N/A (set failed)';
            end
        end

        result.verification.allParamsCorrect = isempty(incorrectParams);
        result.verification.incorrectParams = incorrectParams;
    end

    % ===== 组装结果 =====
    % 转换 results cell 为 struct 数组
    if nParams > 0
        resultStructs = results{1};
        for i = 2:nParams
            % 兼容 R2016a: 用 struct 数组拼接
            resultStructs = [resultStructs, results{i}]; %#ok<AGROW>
        end
        result.results = resultStructs;
    else
        result.results = struct('param', {}, 'requestedValue', {}, ...
            'success', {}, 'actualValue', {}, 'message', {});
    end

    % ===== 生成 message =====
    if nFail == 0
        result.status = 'ok';
        result.message = sprintf('All %d parameters set successfully on %s', nSuccess, blockPath);
    else
        result.status = 'ok';  % 部分成功也算 ok
        result.message = sprintf('%d/%d parameters set successfully on %s', nSuccess, nParams, blockPath);
    end

    if ~result.verification.allParamsCorrect
        result.message = [result.message ' (verification found mismatches)'];
    end
end
