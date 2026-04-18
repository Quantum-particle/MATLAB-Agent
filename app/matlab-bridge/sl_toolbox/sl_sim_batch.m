function result = sl_sim_batch(modelName, varargin)
% SL_SIM_BATCH 批量/并行仿真 — parsim 并行优先 + 串行 sim 回退
%   result = sl_sim_batch('MyModel', 'parameterName', 'Kp', ...
%                         'parameterValues', [0.5 1.0 1.5 2.0 2.5])
%   result = sl_sim_batch('MyModel', 'parameterName', 'Kp', ...
%                         'parameterValues', gains, 'parallel', true)
%
%   借鉴 simulink/skills:
%     - repmat(SimulationInput, N, 1) + parsim(in) 并行仿真
%     - 适合参数扫描、蒙特卡洛仿真等场景
%
%   版本策略: R2017a+ parsim 可用，R2016a 回退到串行循环 sim()
%
%   输入:
%     modelName          - 模型名称（必选）
%     'parameterName'    - 要扫描的参数名（必选）
%     'parameterValues'  - 参数值数组（必选）
%     'baseConfig'       - struct，基础仿真配置:
%                            .stopTime - 停止时间
%                            .solver   - 求解器
%     'parallel'         - 是否使用并行（parsim），默认 true（R2017a+）
%     'showProgress'     - 是否显示进度，默认 true
%     'timeout'          - 单次仿真超时（秒），默认 60
%     'extractSummary'   - 是否提取每次仿真摘要，默认 true
%     'loadModelIfNot'   - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status    - 'ok' 或 'error'
%     .simBatch  - struct(.totalRuns, .completedRuns, .failedRuns, .apiUsed, .elapsedTime, .results)
%     .message   - 人类可读的总结信息
%     .error     - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    % 两种模式:
    %   模式1: sl_sim_batch(model, 'parameterName', 'Kp', 'parameterValues', [1 2 3])
    %   模式2: sl_sim_batch(model, paramSets, 'stopTime', '10')
    %          其中 paramSets = {struct('Gain',2), struct('Gain',5), struct('Gain',10)}
    parameterName = '';
    parameterValues = [];
    paramSets = {};  % 模式2: cell of struct
    useMode2 = false;
    baseConfig = struct();
    useParallel = true;
    showProgress = true;
    timeout = 60;
    extractSummary = true;
    loadModelIfNot = true;

    % 检查是否为模式2（第二个参数是 cell 数组）
    if length(varargin) >= 1 && iscell(varargin{1}) && ~isempty(varargin{1})
        paramSets = varargin{1};
        useMode2 = true;
        idx = 2;
    else
        idx = 1;
    end

    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            switch lower(key)
                case 'parametername'
                    parameterName = val;
                case 'parametervalues'
                    parameterValues = val;
                case 'baseconfig'
                    baseConfig = val;
                case 'parallel'
                    useParallel = val;
                case 'showprogress'
                    showProgress = val;
                case 'timeout'
                    timeout = val;
                case 'extractsummary'
                    extractSummary = val;
                case 'loadmodelifnot'
                    loadModelIfNot = val;
                case 'stoptime'
                    baseConfig.stopTime = val;
            end
        end
        idx = idx + 2;
    end

    result = struct();
    result.status = 'ok';
    result.simBatch = struct();
    result.message = '';
    result.error = '';

    % ===== 验证输入 =====
    if useMode2
        % 模式2: paramSets 必须非空
        if isempty(paramSets)
            result.status = 'error';
            result.error = 'paramSets cannot be empty';
            result.message = result.error;
            return;
        end
        nRuns = length(paramSets);
    else
        % 模式1: parameterName + parameterValues
        if isempty(parameterName)
            result.status = 'error';
            result.error = 'parameterName is required (or use paramSets as 2nd arg)';
            result.message = result.error;
            return;
        end

        if isempty(parameterValues)
            result.status = 'error';
            result.error = 'parameterValues is required';
            result.message = result.error;
            return;
        end
        nRuns = length(parameterValues);
    end

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

    % ===== 检测 MATLAB 版本 =====
    matlabVer = ver('MATLAB');
    verNum = 0;
    try
        verParts = sscanf(matlabVer.Version, '%d.%d');
        if length(verParts) >= 2
            verNum = verParts(1) + verParts(2) / 10;
        end
    catch
    end

    useSimInput = (verNum >= 9.2); % R2017a = 9.2

    % ===== 运行批量仿真 =====
    batchStartTime = tic;
    completedRuns = 0;
    failedRuns = 0;
    apiUsed = '';
    batchResults = cell(1, nRuns);

    if useSimInput && useParallel
        % ===== R2017a+ parsim 并行路径 =====
        apiUsed = 'parsim';

        try
            % 创建 SimulationInput 数组
            in = repmat(Simulink.SimulationInput(modelName), nRuns, 1);

            for k = 1:nRuns
                if useMode2
                    % 模式2: paramSets — 每个元素是 struct，设置多个变量
                    if isstruct(paramSets{k})
                        fields = fieldnames(paramSets{k});
                        for fi = 1:length(fields)
                            in(k) = in(k).setVariable(fields{fi}, paramSets{k}.(fields{fi}));
                        end
                    end
                else
                    % 模式1: 单参数扫描
                    in(k) = in(k).setVariable(parameterName, parameterValues(k));
                end

                % 覆盖基础配置
                if isfield(baseConfig, 'stopTime') && ~isempty(baseConfig.stopTime)
                    in(k) = in(k).setModelParameter('StopTime', baseConfig.stopTime);
                end
                if isfield(baseConfig, 'solver') && ~isempty(baseConfig.solver)
                    in(k) = in(k).setModelParameter('Solver', baseConfig.solver);
                end
            end

            % 运行并行仿真
            if showProgress
                simOut = parsim(in, 'ShowProgress', 'on', ...
                    'TransferBaseWorkspaceVariables', 'on');
            else
                simOut = parsim(in, 'TransferBaseWorkspaceVariables', 'on');
            end

            % 提取每次仿真的结果
            for k = 1:nRuns
                try
                    batchResults{k} = extract_run_summary(simOut(k), k, parameterValues(k), extractSummary);
                    completedRuns = completedRuns + 1;
                catch ME
                    batchResults{k} = struct( ...
                        'index', k, ...
                        'parameterValue', parameterValues(k), ...
                        'status', 'error', ...
                        'message', ME.message);
                    failedRuns = failedRuns + 1;
                end
            end

        catch ME_parsim
            % parsim 失败，回退到串行模式
            apiUsed = 'serial sim loop (parsim fallback)';
            [completedRuns, failedRuns, batchResults] = run_serial( ...
                modelName, parameterName, parameterValues, baseConfig, ...
                timeout, extractSummary, nRuns, useMode2, paramSets);
        end

    else
        % ===== R2016a 串行回退路径 =====
        apiUsed = 'serial sim loop';
        [completedRuns, failedRuns, batchResults] = run_serial( ...
            modelName, parameterName, parameterValues, baseConfig, ...
            timeout, extractSummary, nRuns, useMode2, paramSets);
    end

    elapsedTime = toc(batchStartTime);

    % ===== 组装结果 =====
    % batchResults 保持 cell 数组格式（避免 struct 数组维度不匹配）

    result.simBatch = struct();
    result.simBatch.totalRuns = nRuns;
    result.simBatch.completedRuns = completedRuns;
    result.simBatch.failedRuns = failedRuns;
    result.simBatch.apiUsed = apiUsed;
    result.simBatch.elapsedTime = sprintf('%.2fs', elapsedTime);
    result.simBatch.results = batchResults;

    % ===== 生成 message =====
    if failedRuns == 0
        result.message = sprintf('All %d simulations completed in %s using %s', ...
            nRuns, result.simBatch.elapsedTime, apiUsed);
    else
        result.message = sprintf('%d/%d simulations completed (%d failed) in %s using %s', ...
            completedRuns, nRuns, failedRuns, result.simBatch.elapsedTime, apiUsed);
    end
end


function [completedRuns, failedRuns, batchResults] = run_serial( ...
    modelName, parameterName, parameterValues, baseConfig, ...
    timeout, extractSummary, nRuns, useMode2, paramSets)
% RUN_SERIAL 串行循环仿真（R2016a 回退或 parsim 失败时）

    completedRuns = 0;
    failedRuns = 0;
    batchResults = cell(1, nRuns);

    % 保存原始参数
    origStopTime = '';
    origSolver = '';
    try
        origStopTime = get_param(modelName, 'StopTime');
        origSolver = get_param(modelName, 'Solver');
    catch
    end

    % 覆盖基础配置
    if isfield(baseConfig, 'stopTime') && ~isempty(baseConfig.stopTime)
        try
            set_param(modelName, 'StopTime', baseConfig.stopTime);
        catch
        end
    end
    if isfield(baseConfig, 'solver') && ~isempty(baseConfig.solver)
        try
            set_param(modelName, 'Solver', baseConfig.solver);
        catch
        end
    end

    for k = 1:nRuns
        % 注入参数值
        if useMode2
            % 模式2: 设置多个变量
            if isstruct(paramSets{k})
                fields = fieldnames(paramSets{k});
                for fi = 1:length(fields)
                    assignin('base', fields{fi}, paramSets{k}.(fields{fi}));
                end
            end
        else
            % 模式1: 单参数
            assignin('base', parameterName, parameterValues(k));
        end

        % 超时保护
        timeoutTimer = [];
        if timeout > 0
            timeoutTimer = timer( ...
                'TimerFcn', @(~,~) set_param(modelName, 'SimulationCommand', 'stop'), ...
                'StartDelay', timeout);
            start(timeoutTimer);
        end

        try
            simOut = sim(modelName);
            if useMode2
                batchResults{k} = extract_run_summary_legacy(simOut, k, paramSets{k}, extractSummary);
            else
                batchResults{k} = extract_run_summary_legacy(simOut, k, parameterValues(k), extractSummary);
            end
            completedRuns = completedRuns + 1;
        catch ME
            r = struct();
            r.index = k;
            if useMode2
                r.paramSet = paramSets{k};
            else
                r.parameterValue = parameterValues(k);
            end
            r.status = 'error';
            r.message = ME.message;
            batchResults{k} = r;
            failedRuns = failedRuns + 1;
        end

        % 清理超时计时器
        try
            if ~isempty(timeoutTimer) && isvalid(timeoutTimer)
                stop(timeoutTimer);
                delete(timeoutTimer);
            end
        catch
        end

        % 确保仿真停止
        try
            set_param(modelName, 'SimulationCommand', 'stop');
        catch
        end
    end

    % 恢复原始参数
    try
        if ~isempty(origStopTime)
            set_param(modelName, 'StopTime', origStopTime);
        end
        if ~isempty(origSolver)
            set_param(modelName, 'Solver', origSolver);
        end
    catch
    end
end


function s = extract_run_summary(simOut, index, paramValue, extractSummary)
% EXTRACT_RUN_SUMMARY 从 SimulationOutput 提取单次仿真摘要

    s = struct();
    s.index = index;
    s.parameterValue = paramValue;
    s.status = 'ok';

    if extractSummary
        % 尝试获取关键输出
        try
            % 获取输出变量
            outVars = simOut.find();
            s.outputVars = outVars;
        catch
            s.outputVars = {};
        end

        % 尝试获取 logsout 信号
        try
            logsout = simOut.get('logsout');
            if isa(logsout, 'Simulink.SimulationData.Dataset')
                try
                    elemNames = logsout.getElementNames();
                    s.loggedSignals = elemNames;

                    % 提取第一个信号的摘要
                    if length(elemNames) > 0
                        sigData = logsout.get(1).Values;
                        if isa(sigData, 'timeseries')
                            d = sigData.Data(:);
                            s.summary = struct();
                            s.summary.min = min(d);
                            s.summary.max = max(d);
                            s.summary.mean = mean(d);
                            s.summary.finalValue = d(end);
                        end
                    end
                catch
                end
            end
        catch
        end

        % 尝试获取 yout
        try
            yout = simOut.get('yout');
            if ~isempty(yout)
                d = [];
                if isnumeric(yout)
                    d = yout(:);
                elseif isstruct(yout) && isfield(yout, 'signals')
                    d = yout.signals(1).values(:);
                end
                if ~isempty(d)
                    s.youtSummary = struct();
                    s.youtSummary.min = min(d);
                    s.youtSummary.max = max(d);
                    s.youtSummary.mean = mean(d);
                    s.youtSummary.finalValue = d(end);
                end
            end
        catch
        end
    end
end


function s = extract_run_summary_legacy(simOut, index, paramValue, extractSummary)
% EXTRACT_RUN_SUMMARY_LEGACY 从旧版 sim 输出提取摘要

    s = struct();
    s.index = index;
    if isstruct(paramValue) && ~isempty(fieldnames(paramValue))
        s.paramSet = paramValue;
    else
        s.parameterValue = paramValue;
    end
    s.status = 'ok';

    if ~extractSummary
        return;
    end

    % R2016a sim 可能返回 SimulationOutput 或 [t,x,y]
    if isa(simOut, 'Simulink.SimulationOutput')
        s = extract_run_summary(simOut, index, paramValue, extractSummary);
    elseif isstruct(simOut)
        % Structure with time
        if isfield(simOut, 'signals') && ~isempty(simOut.signals)
            try
                d = simOut.signals(1).values(:);
                s.summary = struct();
                    s.summary.min = min(d);
                    s.summary.max = max(d);
                    s.summary.mean = mean(d);
                    s.summary.finalValue = d(end);
            catch
            end
        end
    elseif isnumeric(simOut) && ~isempty(simOut)
        d = simOut(:);
        s.summary = struct();
        s.summary.min = min(d);
        s.summary.max = max(d);
        s.summary.mean = mean(d);
        s.summary.finalValue = d(end);
    end
end
