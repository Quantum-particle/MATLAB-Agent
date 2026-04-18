function result = sl_sim_results(modelName, varargin)
% SL_SIM_RESULTS 提取仿真结果 — timeseries/Dataset/struct/array 自动识别 + 降采样
%   result = sl_sim_results(modelName)
%   result = sl_sim_results(modelName, 'variables', {'yout', 'logsout'}, ...)
%   result = sl_sim_results(modelName, 'format', 'summary', 'maxRows', 1000)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName    - 模型名称（必选）
%     'variables'  - 要提取的变量名，cell 数组，如 {'yout','logsout'}
%                    默认: 自动检测 {'yout','logsout','tout','xout'}
%     'format'     - 输出格式: 'summary'（默认）/'full'
%     'maxRows'    - full 格式最大行数（降采样），默认 1000
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .results  - struct，每个变量一个字段
%     .message  - 人类可读的总结信息
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    variablesRequested = {};
    fmt = 'summary';
    maxRows = 1000;
    loadModelIfNot = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            if strcmpi(varargin{idx}, 'variables')
                variablesRequested = varargin{idx+1};
            elseif strcmpi(varargin{idx}, 'format')
                fmt = varargin{idx+1};
            elseif strcmpi(varargin{idx}, 'maxRows')
                maxRows = varargin{idx+1};
            elseif strcmpi(varargin{idx}, 'loadModelIfNot')
                loadModelIfNot = varargin{idx+1};
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'results', struct(), ...
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

    % ===== 确定要提取的变量 =====
    if isempty(variablesRequested)
        % 自动检测可用变量
        defaultVars = {'yout', 'logsout', 'tout', 'xout', 'simOut'};
        variablesRequested = {};
        for vi = 1:length(defaultVars)
            try
                val = evalin('base', defaultVars{vi});
                variablesRequested{end+1} = defaultVars{vi}; %#ok<AGROW>
            catch
                % 变量不存在，跳过
            end
        end
        
        % 如果 base workspace 没有任何变量，检查 simOut 对象
        if isempty(variablesRequested)
            try
                simOutObj = evalin('base', 'simOut');
                if isa(simOutObj, 'Simulink.SimulationOutput')
                    % 从 simOut 中提取变量名
                    try
                        outVarNames = simOutObj.find();
                        for vi = 1:length(outVarNames)
                            variablesRequested{end+1} = outVarNames{vi}; %#ok<AGROW>
                        end
                    catch
                        % find() 不可用，尝试常见变量
                        commonVars = {'tout', 'yout', 'logsout', 'xout'};
                        for vi = 1:length(commonVars)
                            try
                                simOutObj.get(commonVars{vi});
                                variablesRequested{end+1} = commonVars{vi}; %#ok<AGROW>
                            catch
                            end
                        end
                    end
                end
            catch
                % simOut 也不存在
            end
        end
    end

    if isempty(variablesRequested)
        result.status = 'ok';
        result.message = 'No simulation output variables found in workspace';
        return;
    end

    % ===== 逐变量提取 =====
    nFound = 0;
    nError = 0;
    warnings = {};

    for vi = 1:length(variablesRequested)
        varName = variablesRequested{vi};

        try
            varData = evalin('base', varName);
            nFound = nFound + 1;

            % 解析数据
            result.results.(varName) = parse_variable(varData, varName, fmt, maxRows);

        catch ME
            % 变量不在 base workspace，尝试从 simOut 中提取
            try
                simOutObj = evalin('base', 'simOut');
                if isa(simOutObj, 'Simulink.SimulationOutput')
                    varData = simOutObj.get(varName);
                    nFound = nFound + 1;
                    result.results.(varName) = parse_variable(varData, varName, fmt, maxRows);
                else
                    nError = nError + 1;
                    result.results.(varName) = struct( ...
                        'type', 'not_found', ...
                        'error', ME.message);
                    warnings{end+1} = ['Cannot read ' varName ': ' ME.message]; %#ok<AGROW>
                end
            catch ME2
                nError = nError + 1;
                result.results.(varName) = struct( ...
                    'type', 'not_found', ...
                    'error', ME.message);
                warnings{end+1} = ['Cannot read ' varName ': ' ME.message]; %#ok<AGROW>
            end
        end
    end

    % ===== 生成 message =====
    result.message = sprintf('Extracted %d/%d variables from %s', ...
        nFound, length(variablesRequested), modelName);

    if ~isempty(warnings)
        result.warnings = warnings;
    end
end


function parsed = parse_variable(data, varName, fmt, maxRows)
% PARSE_VARIABLE 识别数据类型并提取结构化信息

    parsed = struct();
    parsed.name = varName;

    % ===== 类型识别 =====
    if isa(data, 'Simulink.SimulationData.Dataset')
        parsed.type = 'Dataset';
        parsed = parse_dataset(data, parsed, fmt, maxRows);

    elseif isa(data, 'timeseries')
        parsed.type = 'timeseries';
        parsed = parse_timeseries(data, parsed, fmt, maxRows);

    elseif isstruct(data)
        % Structure with time (Simulink 仿真输出格式)
        if isfield(data, 'time') && isfield(data, 'signals')
            parsed.type = 'struct_with_time';
            parsed = parse_struct_with_time(data, parsed, fmt, maxRows);
        else
            parsed.type = 'struct';
            parsed.fields = fieldnames(data);
            parsed.fieldCount = length(fieldnames(data));
            % 逐字段简要信息
            fnames = fieldnames(data);
            for fi = 1:length(fnames)
                try
                    val = data.(fnames{fi});
                    parsed.(['field_' fnames{fi}]) = class(val);
                catch
                end
            end
        end

    elseif isnumeric(data)
        parsed.type = 'numeric';
        parsed.dimensions = mat2str(size(data));
        d = data(:);
        parsed = add_statistics(parsed, d);

        if strcmpi(fmt, 'full')
            parsed.data = downsample_data(d, maxRows);
        end

    elseif iscell(data)
        parsed.type = 'cell';
        parsed.dimensions = mat2str(size(data));

    else
        parsed.type = class(data);
    end
end


function parsed = parse_dataset(data, parsed, fmt, maxRows)
% PARSE_DATASET 解析 Simulink.SimulationData.Dataset

    try
        elemNames = data.getElementNames();
        parsed.numElements = length(elemNames);
        parsed.elementNames = elemNames;
    catch
        parsed.numElements = length(data);
        parsed.elementNames = {};
    end

    elements = struct();
    for ei = 1:parsed.numElements
        try
            elem = data.get(ei);
            elemInfo = struct();
            elemInfo.name = char(elem.Name);

            if isa(elem.Values, 'timeseries')
                elemInfo.type = 'timeseries';
                elemInfo = parse_timeseries(elem.Values, elemInfo, fmt, maxRows);
            elseif isa(elem.Values, 'timetable')
                elemInfo.type = 'timetable';
                try
                    elemInfo.dimensions = mat2str(size(elem.Values));
                catch
                end
            elseif isnumeric(elem.Values)
                elemInfo.type = 'numeric';
                elemInfo.dimensions = mat2str(size(elem.Values));
            else
                elemInfo.type = class(elem.Values);
            end

            % 用合法字段名
            safeName = ['elem' num2str(ei)];
            try
                safeName = matlab.lang.makeValidName(elemInfo.name);
            catch
                % R2016a 没有 matlab.lang.makeValidName
                safeName = ['elem' num2str(ei)];
            end
            elements.(safeName) = elemInfo;
        catch ME
            elements.(['elem' num2str(ei)]) = struct('error', ME.message);
        end
    end

    parsed.elements = elements;
end


function parsed = parse_timeseries(ts, parsed, fmt, maxRows)
% PARSE_TIMESERIES 解析 timeseries 对象

    try
        parsed.tsName = ts.Name;
    catch
    end

    try
        parsed.dimensions = mat2str(size(ts.Data));
    catch
    end

    try
        if ~isempty(ts.Time)
            parsed.timeRange = sprintf('[%g, %g]', ts.Time(1), ts.Time(end));
            parsed.numTimePoints = length(ts.Time);
        end
    catch
    end

    try
        d = ts.Data(:);
        parsed = add_statistics(parsed, d);
    catch
    end

    % full 模式返回降采样数据
    if strcmpi(fmt, 'full')
        try
            parsed.timeData = downsample_data(ts.Time, maxRows);
            parsed.signalData = downsample_data(ts.Data, maxRows);
        catch
        end
    end
end


function parsed = parse_struct_with_time(data, parsed, fmt, maxRows)
% PARSE_STRUCT_WITH_TIME 解析 Structure with time 格式

    try
        parsed.timeRange = sprintf('[%g, %g]', data.time(1), data.time(end));
        parsed.numTimePoints = length(data.time);
    catch
    end

    try
        parsed.numSignals = length(data.signals);
    catch
    end

    signals = struct();
    for si = 1:length(data.signals)
        sigInfo = struct();
        try
            sigInfo.label = data.signals(si).label;
        catch
            sigInfo.label = ['signal_' num2str(si)];
        end

        try
            sigInfo.dimensions = mat2str(size(data.signals(si).values));
            d = data.signals(si).values(:);
            sigInfo = add_statistics(sigInfo, d);

            if strcmpi(fmt, 'full')
                sigInfo.data = downsample_data(d, maxRows);
            end
        catch
        end

        safeName = ['signal_' num2str(si)];
        try
            safeName = matlab.lang.makeValidName(sigInfo.label);
        catch
        end
        signals.(safeName) = sigInfo;
    end

    parsed.signals = signals;
end


function parsed = add_statistics(parsed, d)
% ADD_STATISTICS 添加统计摘要

    try
        parsed.min = min(d);
        parsed.max = max(d);
        parsed.mean = mean(d);
        if ~isempty(d)
            parsed.finalValue = d(end);
        end
    catch
    end
end


function sampled = downsample_data(data, maxRows)
% DOWNSAMPLE_DATA 降采样数据以控制输出大小

    if isvector(data)
        n = length(data);
    else
        n = size(data, 1);
    end

    if n <= maxRows
        sampled = data;
    else
        idx = round(linspace(1, n, maxRows));
        if isvector(data)
            sampled = data(idx);
        else
            sampled = data(idx, :);
        end
    end
end
