function result = sl_signal_config(modelName, blockPath, portIndex, config, varargin)
% SL_SIGNAL_CONFIG 配置信号属性 — 设置端口数据类型/采样时间/信号名/记录
%   result = sl_signal_config('MyModel', 'MyModel/Gain1', 1, configStruct)
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName   - 模型名称（必选）
%     blockPath   - 模块完整路径（必选），如 'MyModel/Gain1'
%     portIndex   - 端口索引（必选），从 1 开始
%     config      - struct，要配置的属性:
%                    .portType     - 'outport'(默认) 或 'inport'
%                    .dataType     - 数据类型，如 'double', 'single', 'int32', 'Bus:MyBus'
%                    .sampleTime   - 采样时间，如 '-1'(继承), '0.01'
%                    .signalName   - 信号名称（需先有连线）
%                    .logging      - 是否启用信号记录，true/false
%                    .loggingName  - 信号记录名称
%                    .dimensions   - 信号维度，如 '[3 1]'
%     'validateAfter' - 设置后验证是否生效，默认 true
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error'
%     .signalConfig - struct(.blockPath, .portIndex, .portType, .results, .verification)
%     .message      - 人类可读的总结信息
%     .error        - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    validateAfter = true;
    loadModelIfNot = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if strcmpi(key, 'validateAfter')
                validateAfter = val;
            elseif strcmpi(key, 'loadModelIfNot')
                loadModelIfNot = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'signalConfig', struct(), ...
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

    % ===== 验证模块存在 =====
    try
        blockType = get_param(blockPath, 'BlockType');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== 确定端口类型 =====
    portType = 'outport';
    if isfield(config, 'portType')
        portType = config.portType;
    end

    % ===== 获取端口句柄 =====
    try
        ph = get_param(blockPath, 'PortHandles');
        if strcmpi(portType, 'outport')
            portHandles = ph.Outport;
        else
            portHandles = ph.Inport;
        end

        if portIndex < 1 || portIndex > length(portHandles)
            result.status = 'error';
            result.error = sprintf('Port index %d out of range (1-%d) for %s ports on %s', ...
                portIndex, length(portHandles), portType, blockPath);
            result.message = result.error;
            return;
        end

        portHandle = portHandles(portIndex);
    catch ME
        result.status = 'error';
        result.error = ['Failed to get port handle: ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== 逐项设置配置 =====
    results = {};
    nSuccess = 0;
    nFail = 0;

    % 1. 设置数据类型
    if isfield(config, 'dataType')
        r = set_port_data_type(portHandle, config.dataType, portType);
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    end

    % 2. 设置采样时间
    if isfield(config, 'sampleTime')
        r = set_sample_time(blockPath, config.sampleTime);
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    end

    % 3. 设置信号名称（需要先有连线）
    if isfield(config, 'signalName')
        r = set_signal_name(portHandle, config.signalName, blockPath, portIndex, portType);
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    end

    % 4. 启用信号记录
    if isfield(config, 'logging') && config.logging
        r = set_signal_logging(portHandle, true, config.loggingName);
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    elseif isfield(config, 'logging') && ~config.logging
        r = set_signal_logging(portHandle, false, '');
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    end

    % 5. 设置维度
    if isfield(config, 'dimensions')
        r = set_signal_dimensions(portHandle, config.dimensions, portType);
        results{end+1} = r; %#ok<AGROW>
        if r.success, nSuccess = nSuccess + 1; else, nFail = nFail + 1; end
    end

    % ===== 验证设置是否生效 =====
    verification = struct('allCorrect', true, 'mismatches', {{}});
    if validateAfter && nSuccess > 0
        for ri = 1:length(results)
            if results{ri}.success
                try
                    actualVal = get_param(portHandle, results{ri}.paramName);
                    if ~isempty(actualVal) && ~strcmpi(actualVal, results{ri}.setValue)
                        % 数值容差比较
                        isDiff = true;
                        try
                            numActual = str2double(actualVal);
                            numRequested = str2double(results{ri}.setValue);
                            if ~isnan(numActual) && ~isnan(numRequested) && abs(numActual - numRequested) < 1e-10
                                isDiff = false;
                            end
                        catch
                        end
                        if isDiff
                            verification.allCorrect = false;
                            verification.mismatches{end+1} = results{ri}.property; %#ok<AGROW>
                        end
                    end
                catch
                    % 某些参数无法回读
                end
            end
        end
    end

    % ===== 组装结果 =====
    % 转换 results cell 为 struct 数组
    if ~isempty(results)
        resultStructs = results{1};
        for ri = 2:length(results)
            resultStructs = [resultStructs, results{ri}]; %#ok<AGROW>
        end
    else
        resultStructs = struct('property', {}, 'success', {}, 'setValue', {}, 'message', {});
    end

    result.signalConfig = struct( ...
        'blockPath', blockPath, ...
        'portIndex', portIndex, ...
        'portType', portType, ...
        'results', resultStructs, ...
        'verification', verification);

    % ===== 生成 message =====
    if nFail == 0
        result.message = sprintf('All %d signal properties configured on %s port %d', ...
            nSuccess, blockPath, portIndex);
    else
        result.message = sprintf('%d/%d signal properties configured on %s port %d', ...
            nSuccess, nSuccess + nFail, blockPath, portIndex);
    end
end


function r = set_port_data_type(portHandle, dataType, portType)
% SET_PORT_DATA_TYPE 设置端口数据类型
%   对于封装子系统端口，可能不支持此参数

    r = struct('property', 'dataType', 'success', false, 'setValue', dataType, 'message', '', 'paramName', '');

    try
        if strcmpi(portType, 'outport')
            paramName = 'OutDataTypeStr';
        else
            paramName = 'InDataTypeStr';
        end
        
        % 先检查端口是否支持此参数
        try
            currentVal = get_param(portHandle, paramName);
        catch
            % 封装端口可能不支持此参数
            r.message = ['Not supported: port does not have parameter ' paramName];
            r.paramName = paramName;
            r.success = false;
            return;
        end
        
        set_param(portHandle, paramName, dataType);
        r.paramName = paramName;
        r.success = true;
        r.message = 'Data type set successfully';
    catch ME
        r.message = ['Failed: ' ME.message];
    end
end


function r = set_sample_time(blockPath, sampleTime)
% SET_SAMPLE_TIME 设置模块采样时间

    r = struct('property', 'sampleTime', 'success', false, 'setValue', sampleTime, 'message', '', 'paramName', 'SampleTime');

    try
        if isnumeric(sampleTime)
            sampleTime = num2str(sampleTime);
        end
        set_param(blockPath, 'SampleTime', sampleTime);
        r.success = true;
        r.message = 'Sample time set successfully';
    catch ME
        r.message = ['Failed: ' ME.message];
    end
end


function r = set_signal_name(portHandle, signalName, blockPath, portIndex, portType)
% SET_SIGNAL_NAME 设置信号名称（需要先有连线）

    r = struct('property', 'signalName', 'success', false, 'setValue', signalName, 'message', '', 'paramName', 'Name');

    try
        % 先尝试通过端口句柄的连线设置信号名
        set_param(portHandle, 'Name', signalName);
        r.success = true;
        r.message = 'Signal name set via port handle';
    catch
        % 端口句柄方式可能失败（没有连线时）
        try
            % 尝试通过连线句柄设置
            lines = get_param(portHandle, 'Line');
            if ~isempty(lines) && lines ~= -1
                set_param(lines, 'Name', signalName);
                r.success = true;
                r.message = 'Signal name set via line handle';
            else
                r.message = 'No line connected to this port - signal name requires a connected line';
            end
        catch ME2
            r.message = ['Failed: ' ME2.message];
        end
    end
end


function r = set_signal_logging(portHandle, enable, loggingName)
% SET_SIGNAL_LOGGING 启用/禁用端口级信号记录

    r = struct('property', 'signalLogging', 'success', false, 'setValue', mat2str(enable), 'message', '', 'paramName', 'DataLogging');

    try
        if enable
            set_param(portHandle, 'DataLogging', 'on');
            if ~isempty(loggingName)
                try
                    set_param(portHandle, 'DataLoggingNameMode', 'SignalName');
                    set_param(portHandle, 'Name', loggingName);
                catch
                    % 旧版可能不支持 DataLoggingNameMode
                    try
                        set_param(portHandle, 'Name', loggingName);
                    catch
                    end
                end
            end
            r.success = true;
            r.message = 'Signal logging enabled';
        else
            set_param(portHandle, 'DataLogging', 'off');
            r.success = true;
            r.message = 'Signal logging disabled';
        end
    catch ME
        r.message = ['Failed: ' ME.message];
    end
end


function r = set_signal_dimensions(portHandle, dimensions, portType)
% SET_SIGNAL_DIMENSIONS 设置信号维度

    r = struct('property', 'dimensions', 'success', false, 'setValue', num2str(dimensions), 'message', '', 'paramName', '');

    try
        if isnumeric(dimensions)
            dimStr = num2str(dimensions);
        else
            dimStr = dimensions;
        end

        if strcmpi(portType, 'outport')
            set_param(portHandle, 'OutDimensionsStr', dimStr);
            r.paramName = 'OutDimensionsStr';
        else
            set_param(portHandle, 'InDimensionsStr', dimStr);
            r.paramName = 'InDimensionsStr';
        end
        r.success = true;
        r.message = 'Dimensions set successfully';
    catch ME
        r.message = ['Failed: ' ME.message ' (may require model compile)'];
    end
end
