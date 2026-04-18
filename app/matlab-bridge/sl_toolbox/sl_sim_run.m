function result = sl_sim_run(modelName, varargin)
% SL_SIM_RUN 增强版仿真运行 — 预检查 + 变量注入 + SimulationInput优先 + 超时保护
%   result = sl_sim_run(modelName)
%   result = sl_sim_run(modelName, 'stopTime', '10', 'solver', 'ode45', ...)
%   result = sl_sim_run(modelName, 'variables', struct('Kp', 2.0), ...)
%
%   版本策略: R2017a+ SimulationInput 优先，R2016a 回退到 set_param+sim()
%
%   输入:
%     modelName      - 模型名称（必选）
%     'stopTime'     - 仿真停止时间，如 '10'（可选，覆盖模型设置）
%     'solver'       - 求解器，如 'ode45'（可选，覆盖模型设置）
%     'variables'    - struct，仿真前注入工作区变量（可选）
%     'preCheck'     - 仿真前自动检查，默认 true
%     'returnResults' - 是否自动提取结果摘要，默认 true
%     'timeout'      - 仿真超时（秒），默认 300
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status          - 'ok' 或 'error'
%     .simulation      - struct(.success, .elapsedTime, .solver, .stopTime, .apiUsed)
%     .preCheckResults - struct(.passed, .warnings)（仅 preCheck=true 时）
%     .results         - struct(.outputVars, .loggedSignals, .summary)
%     .message         - 人类可读的总结信息
%     .error           - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    opts = struct( ...
        'stopTime', '', ...
        'solver', '', ...
        'variables', struct(), ...
        'preCheck', true, ...
        'returnResults', true, ...
        'timeout', 300, ...
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

    result = struct('status', 'ok', 'simulation', struct(), ...
        'message', '', 'error', '');

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

    % ===== 仿真前检查 =====
    if opts.preCheck
        preCheckWarns = {};
        preCheckPassed = true;
        try
            % 检查模型是否能编译（使用 evalc 安全方式）
            try
                % 注意：model('compile') 在 Engine 模式下可能不支持
                % 改用 set_param + SimulationCommand 方式
                set_param(modelName, 'SimulationCommand', 'update');
            catch ME_compile
                % 编译失败不算致命错误，只记录警告
                preCheckWarns{end+1} = ['Model update check: ' ME_compile.message]; %#ok<AGROW>
            end

            % 检查变量是否在工作区中
            if ~isempty(opts.variables)
                varNames = fieldnames(opts.variables);
                for vi = 1:length(varNames)
                    % 变量将在仿真前注入，不需要预检
                end
            end

            % 检查模型是否有 Outport
            outports = find_system(modelName, 'SearchDepth', 1, 'BlockType', 'Outport');
            if isempty(outports)
                preCheckWarns{end+1} = 'No Outport blocks found - results may be empty'; %#ok<AGROW>
            end
        catch ME_check
            preCheckWarns{end+1} = ['Pre-check error: ' ME_check.message]; %#ok<AGROW>
        end

        result.preCheckResults = struct('passed', preCheckPassed, 'warnings', preCheckWarns);

        if ~preCheckPassed
            result.status = 'error';
            result.error = 'Pre-check failed, simulation aborted';
            result.message = result.error;
            return;
        end
    end

    % ===== 注入变量到工作区 =====
    if ~isempty(opts.variables)
        varNames = fieldnames(opts.variables);
        for vi = 1:length(varNames)
            assignin('base', varNames{vi}, opts.variables.(varNames{vi}));
        end
    end

    % ===== 运行仿真 =====
    simStartTime = tic;
    simSuccess = false;
    simOut = [];
    apiUsed = '';
    actualSolver = '';
    actualStopTime = '';

    % 检测 MATLAB 版本以决定 API 路径
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

    try
        if useSimInput
            % ===== R2017a+ 路径: Simulink.SimulationInput =====
            simIn = Simulink.SimulationInput(modelName);

            % 覆盖停止时间
            if ~isempty(opts.stopTime)
                simIn = simIn.setModelParameter('StopTime', opts.stopTime);
            end

            % 覆盖求解器
            if ~isempty(opts.solver)
                simIn = simIn.setModelParameter('Solver', opts.solver);
            end

            % 注入变量（通过 SimulationInput）
            if ~isempty(opts.variables)
                varNames = fieldnames(opts.variables);
                for vi = 1:length(varNames)
                    simIn = simIn.setVariable(varNames{vi}, opts.variables.(varNames{vi}));
                end
            end

            % 超时保护
            timeoutTimer = [];
            if opts.timeout > 0
                timeoutTimer = timer( ...
                    'TimerFcn', @(~,~) set_param(modelName, 'SimulationCommand', 'stop'), ...
                    'StartDelay', opts.timeout);
                start(timeoutTimer);
            end

            % 运行仿真
            simOut = sim(simIn);
            simSuccess = true;
            apiUsed = 'SimulationInput';

            % 停止超时计时器
            if ~isempty(timeoutTimer) && isvalid(timeoutTimer)
                stop(timeoutTimer);
                delete(timeoutTimer);
            end

        else
            % ===== R2016a 回退路径: set_param + sim() =====
            % 保存原始参数
            origStopTime = get_param(modelName, 'StopTime');
            origSolver = get_param(modelName, 'Solver');

            % 覆盖参数
            if ~isempty(opts.stopTime)
                set_param(modelName, 'StopTime', opts.stopTime);
            end
            if ~isempty(opts.solver)
                set_param(modelName, 'Solver', opts.solver);
            end

            % 超时保护
            timeoutTimer = [];
            if opts.timeout > 0
                timeoutTimer = timer( ...
                    'TimerFcn', @(~,~) set_param(modelName, 'SimulationCommand', 'stop'), ...
                    'StartDelay', opts.timeout);
                start(timeoutTimer);
            end

            % 运行仿真（R2016a 方式）
            simOut = sim(modelName);
            simSuccess = true;
            apiUsed = 'legacy sim';

            % 停止超时计时器
            if ~isempty(timeoutTimer) && isvalid(timeoutTimer)
                stop(timeoutTimer);
                delete(timeoutTimer);
            end

            % 恢复原始参数
            try
                set_param(modelName, 'StopTime', origStopTime);
                set_param(modelName, 'Solver', origSolver);
            catch
            end
        end

    catch ME_sim
        simSuccess = false;

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

        result.status = 'error';
        result.error = ['Simulation failed: ' ME_sim.message];
        result.message = result.error;
        result.simulation = struct('success', false, 'elapsedTime', '', ...
            'solver', '', 'stopTime', '', 'apiUsed', apiUsed);
        return;
    end

    elapsedTime = toc(simStartTime);

    % ===== 获取实际使用的配置 =====
    try
        actualSolver = get_param(modelName, 'Solver');
    catch
        actualSolver = opts.solver;
    end
    try
        actualStopTime = get_param(modelName, 'StopTime');
    catch
        actualStopTime = opts.stopTime;
    end

    result.simulation = struct( ...
        'success', simSuccess, ...
        'elapsedTime', sprintf('%.2fs', elapsedTime), ...
        'solver', actualSolver, ...
        'stopTime', actualStopTime, ...
        'apiUsed', apiUsed);

    % ===== 将 SimulationOutput 关键变量导出到 base workspace =====
    % Bug #3 修复: sl_sim_results 在 base workspace 中找不到 SimulationInput 模式的输出
    % 必须将 simOut 中的变量 assignin 到 base workspace，以便 sl_sim_results 能提取
    if simSuccess && (strcmpi(apiUsed, 'SimulationInput') || isa(simOut, 'Simulink.SimulationOutput'))
        try
            % 1. 先将 simOut 本身保存到 base workspace
            assignin('base', 'simOut', simOut);
            
            % 2. 逐个提取 simOut 中的变量并导出
            outVarNames = simOut.find();
            for vi = 1:length(outVarNames)
                try
                    varData = simOut.(outVarNames{vi});
                    assignin('base', outVarNames{vi}, varData);
                catch
                    % 某些变量无法导出，跳过
                end
            end
            
            % 3. 如果有 logsout（信号记录），也导出
            try
                logsout = simOut.get('logsout');
                assignin('base', 'logsout', logsout);
            catch
            end
            
            % 4. 如果有 tout/yout，也导出
            try
                tout = simOut.get('tout');
                assignin('base', 'tout', tout);
            catch
            end
            try
                yout = simOut.get('yout');
                assignin('base', 'yout', yout);
            catch
            end
        catch
            % simOut.find() 可能不可用（R2016a），尝试旧方式
            try
                assignin('base', 'simOut', simOut);
            catch
            end
        end
    end

    % ===== 提取结果摘要 =====
    if opts.returnResults && simSuccess
        result.results = extract_result_summary(simOut, modelName, apiUsed);
    elseif simSuccess
        result.results = struct('outputVars', {{}}, 'loggedSignals', {{}}, 'summary', struct());
    end

    % ===== 生成 message =====
    if simSuccess
        result.message = sprintf('Simulation completed in %s using %s (solver=%s, stopTime=%s)', ...
            result.simulation.elapsedTime, apiUsed, actualSolver, actualStopTime);
    end
end


function summary = extract_result_summary(simOut, modelName, apiUsed)
% EXTRACT_RESULT_SUMMARY 从仿真输出中提取结果摘要

    outputVars = {};
    loggedSignals = {};
    summaryStruct = struct();

    if strcmpi(apiUsed, 'SimulationInput') || isa(simOut, 'Simulink.SimulationOutput')
        % R2017a+ SimulationOutput 对象
        try
            % 获取输出变量名列表
            outVarNames = simOut.find();
            for vi = 1:length(outVarNames)
                outputVars{end+1} = outVarNames{vi}; %#ok<AGROW>
                try
                    varData = simOut.(outVarNames{vi});
                    % 提取摘要
                    summaryStruct.(outVarNames{vi}) = summarize_data(varData);
                catch ME_var
                    % 某些变量可能无法序列化，跳过
                    summaryStruct.(outVarNames{vi}) = struct('type', 'error', 'message', ME_var.message);
                end
            end
        catch
            % find() 可能不可用或返回空
            try
                % 尝试获取 tout
                tout = simOut.get('tout');
                outputVars{end+1} = 'tout'; %#ok<AGROW>
                try
                    summaryStruct.tout = summarize_data(tout);
                catch
                    summaryStruct.tout = struct('type', class(tout));
                end
            catch
            end
            try
                yout = simOut.get('yout');
                outputVars{end+1} = 'yout'; %#ok<AGROW>
                try
                    summaryStruct.yout = summarize_data(yout);
                catch
                    summaryStruct.yout = struct('type', class(yout));
                end
            catch
            end
        end

        % 检查 logsout
        try
            logsout = simOut.get('logsout');
            if isa(logsout, 'Simulink.SimulationData.Dataset')
                try
                    elemNames = logsout.getElementNames();
                    for ei = 1:length(elemNames)
                        loggedSignals{end+1} = elemNames{ei}; %#ok<AGROW>
                    end
                catch
                end
                loggedSignals{end+1} = 'logsout'; %#ok<AGROW>
                summaryStruct.logsout = struct('type', 'Dataset', ...
                    'numElements', length(logsout));
            end
        catch
        end

    else
        % R2016a legacy: simOut 可能是 [t, x, y] 或 SimulationOutput
        if isstruct(simOut)
            % Structure with time 模式
            if isfield(simOut, 'time')
                outputVars{end+1} = 'time'; %#ok<AGROW>
                summaryStruct.time = summarize_data(simOut.time);
            end
            if isfield(simOut, 'signals')
                for si = 1:length(simOut.signals)
                    sigName = ['signal_' num2str(si)];
                    if isfield(simOut.signals(si), 'label') && ~isempty(simOut.signals(si).label)
                        sigName = simOut.signals(si).label;
                    end
                    loggedSignals{end+1} = sigName; %#ok<AGROW>
                    if isfield(simOut.signals(si), 'values')
                        summaryStruct.(['sig_' num2str(si)]) = summarize_data(simOut.signals(si).values);
                    end
                end
            end
        elseif isnumeric(simOut)
            outputVars{end+1} = 'simOut'; %#ok<AGROW>
            summaryStruct.simOut = summarize_data(simOut);
        end

        % 从工作区获取 logsout
        try
            logsout = evalin('base', 'logsout');
            if isa(logsout, 'Simulink.SimulationData.Dataset')
                loggedSignals{end+1} = 'logsout'; %#ok<AGROW>
                try
                    elemNames = logsout.getElementNames();
                    for ei = 1:length(elemNames)
                        loggedSignals{end+1} = elemNames{ei}; %#ok<AGROW>
                    end
                catch
                end
            end
        catch
        end
    end

    summary = struct();
    summary.outputVars = outputVars;
    summary.loggedSignals = loggedSignals;
    summary.summary = summaryStruct;
end


function s = summarize_data(data)
% SUMMARIZE_DATA 对数据生成摘要统计

    s = struct();

    if isa(data, 'timeseries')
        s.type = 'timeseries';
        s.name = data.Name;
        s.dimensions = mat2str(size(data.Data));
        try
            if ~isempty(data.Time)
                s.timeRange = sprintf('[%g, %g]', data.Time(1), data.Time(end));
            end
        catch
        end
        try
            d = data.Data(:);
            s.min = min(d);
            s.max = max(d);
            s.mean = mean(d);
            s.finalValue = d(end);
        catch
        end
    elseif isnumeric(data)
        s.type = 'numeric';
        s.dimensions = mat2str(size(data));
        try
            d = data(:);
            s.min = min(d);
            s.max = max(d);
            s.mean = mean(d);
            if ~isempty(d)
                s.finalValue = d(end);
            end
        catch
        end
    elseif isstruct(data)
        s.type = 'struct';
        s.fields = fieldnames(data);
    elseif iscell(data)
        s.type = 'cell';
        s.dimensions = mat2str(size(data));
    else
        s.type = class(data);
    end
end
