function result = sl_config_set(modelName, config, varargin)
% SL_CONFIG_SET 设置模型配置 — 逐参数设置 + SolverType 变更特殊处理 + 验证
%   result = sl_config_set(modelName, config)
%   result = sl_config_set(modelName, config, 'autoVerify', true, ...)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   Solver 名称映射（MathWorks 官方）:
%     变步长: ode45, ode23, ode113, ode15s, ode23s, ode23t, ode23tb
%     固定步长: ode1(Euler), ode2(Heun), ode3(Bogacki-Shampine), ode4(Runge-Kutta),
%               ode5(Dormand-Prince), ode14x, ode1be, ode8
%
%   输入:
%     modelName     - 模型名称（必选）
%     config        - struct，要设置的配置参数名-值对
%                     如 struct('StopTime', '20', 'Solver', 'ode4', 'FixedStep', '0.001')
%     'autoVerify'  - 设置后验证每个参数是否生效，默认 true
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .results      - struct 数组，每项: param, value, success, actualValue, message
%     .verification - struct(.allCorrect, .incorrectParams)
%     .solverAdvice - SolverType 变更时的自动建议（如有）
%     .message      - 人类可读的总结信息
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'autoVerify', true, ...
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

    result = struct('status', 'ok', 'results', struct([]), ...
        'verification', struct('allCorrect', true, 'incorrectParams', {{}}), ...
        'solverAdvice', '', 'message', '', 'error', '');

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

    % ===== SolverType 变更特殊处理 =====
    paramNames = fieldnames(config);
    nParams = length(paramNames);
    solverAdvice = '';

    % 检测是否在切换 SolverType
    changingSolverType = false;
    newSolverType = '';
    for i = 1:nParams
        if strcmpi(paramNames{i}, 'SolverType')
            changingSolverType = true;
            newSolverType = config.(paramNames{i});
            break;
        end
    end

    if changingSolverType
        try
            currentSolverType = get_param(modelName, 'SolverType');
            if ~strcmpi(currentSolverType, newSolverType)
                if strcmpi(newSolverType, 'Fixed-step')
                    solverAdvice = 'Switching to Fixed-step: ensure FixedStep is set (not auto)';
                elseif strcmpi(newSolverType, 'Variable-step')
                    solverAdvice = 'Switching to Variable-step: consider setting MaxStep and RelTol';
                end
            end
        catch
        end
    end

    result.solverAdvice = solverAdvice;

    % ===== 逐个设置参数 =====
    results = cell(1, nParams);
    nSuccess = 0;
    nFail = 0;

    for i = 1:nParams
        pName = paramNames{i};
        pValue = config.(pName);

        % 确保 value 是字符串
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

        r = struct('param', pName, 'value', pValueStr, ...
            'success', false, 'actualValue', '', 'message', '');

        try
            set_param(modelName, pName, pValueStr);
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
    if opts.autoVerify && nSuccess > 0
        incorrectParams = {};
        for i = 1:nParams
            if results{i}.success
                pName = results{i}.param;
                try
                    actualVal = get_param(modelName, pName);
                    results{i}.actualValue = actualVal;
                    
                    if ~strcmpi(actualVal, results{i}.value)
                        % 容差比较
                        isDiff = true;
                        try
                            numActual = str2double(actualVal);
                            numRequested = str2double(results{i}.value);
                            if ~isnan(numActual) && ~isnan(numRequested)
                                if abs(numActual - numRequested) < 1e-10
                                    isDiff = false;
                                end
                            end
                        catch
                        end
                        % on/off vs true/false
                        if isDiff
                            if (strcmpi(actualVal, 'on') && strcmpi(results{i}.value, 'true')) || ...
                               (strcmpi(actualVal, 'off') && strcmpi(results{i}.value, 'false'))
                                isDiff = false;
                            end
                        end
                        if isDiff
                            incorrectParams{end+1} = pName; %#ok<AGROW>
                            results{i}.success = false;
                            results{i}.message = ['Value mismatch: requested=' results{i}.value ' actual=' actualVal];
                        end
                    end
                catch ME
                    results{i}.actualValue = ['Error reading: ' ME.message];
                end
            else
                results{i}.actualValue = 'N/A (set failed)';
            end
        end

        result.verification.allCorrect = isempty(incorrectParams);
        result.verification.incorrectParams = incorrectParams;
    end

    % ===== 组装结果 =====
    if nParams > 0
        resultStructs = results{1};
        for i = 2:nParams
            resultStructs = [resultStructs, results{i}]; %#ok<AGROW>
        end
        result.results = resultStructs;
    else
        result.results = struct('param', {}, 'value', {}, ...
            'success', {}, 'actualValue', {}, 'message', {});
    end

    % ===== 生成 message =====
    if nFail == 0
        result.status = 'ok';
        result.message = sprintf('All %d config parameters set successfully on %s', nSuccess, modelName);
    else
        result.status = 'ok';  % 部分成功也算 ok
        result.message = sprintf('%d/%d config parameters set successfully on %s', nSuccess, nParams, modelName);
    end

    if ~isempty(solverAdvice)
        result.message = [result.message ' | ' solverAdvice];
    end

    if ~result.verification.allCorrect
        result.message = [result.message ' (verification found mismatches)'];
    end
end
