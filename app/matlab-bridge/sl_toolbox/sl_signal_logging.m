function result = sl_signal_logging(modelName, varargin)
% SL_SIGNAL_LOGGING 信号记录配置 — 替代 To Workspace 块的推荐方式
%   result = sl_signal_logging('MyModel', 'action', 'enable', ...)
%   result = sl_signal_logging('MyModel', 'action', 'disable', ...)
%   result = sl_signal_logging('MyModel', 'action', 'list')
%   result = sl_signal_logging('MyModel', 'action', 'configure', ...)
%
%   反模式 #3 的正确替代方案:
%     - To Workspace 块 → 弃用（不推荐）
%     - Signal Logging → 推荐（内置、更高效、更易管理）
%
%   版本策略: R2012a+ SignalLogging 可用，R2016a DataLogging 可用
%
%   输入:
%     modelName      - 模型名称（必选）
%     'action'       - 操作类型: 'enable'|'disable'|'list'|'configure'（默认 'list'）
%
%     action='enable' 时:
%       'blockPath'    - 模块路径（必选）
%       'portIndex'    - 端口索引，从 1 开始（必选）
%       'portType'     - 'outport'(默认) 或 'inport'
%       'loggingName'  - 信号记录名称（可选）
%       'decimation'   - 抽取因子（可选，默认 1）
%       'limitDataPoints' - 是否限制数据点数（可选，默认 false）
%       'maxPoints'    - 最大数据点数（可选，默认 5000）
%
%     action='disable' 时:
%       'blockPath'    - 模块路径（必选）
%       'portIndex'    - 端口索引（必选）
%       'portType'     - 'outport'(默认) 或 'inport'
%
%     action='configure' 时:
%       'signalLogging' - 模型级信号记录开关 'on'/'off'
%       'loggingName'   - 模型级 logsout 变量名
%       'saveOutput'    - SaveOutput 开关 'on'/'off'
%       'outputSaveName' - 输出变量名
%
%   输出: struct
%     .status         - 'ok' 或 'error'
%     .signalLogging  - struct，操作结果
%     .message        - 人类可读的总结信息
%     .error          - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    action = 'list';
    blockPath = '';
    portIndex = 1;
    portType = 'outport';
    loggingName = '';
    decimation = 1;
    limitDataPoints = false;
    maxPoints = 5000;
    % configure 参数
    cfgSignalLogging = '';
    cfgLoggingName = '';
    cfgSaveOutput = '';
    cfgOutputSaveName = '';
    loadModelIfNot = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            switch lower(key)
                case 'action'
                    action = val;
                case 'blockpath'
                    blockPath = val;
                case 'portindex'
                    portIndex = val;
                case 'porttype'
                    portType = val;
                case 'loggingname'
                    loggingName = val;
                case 'decimation'
                    decimation = val;
                case 'limitdatapoints'
                    limitDataPoints = val;
                case 'maxpoints'
                    maxPoints = val;
                case 'signallogging'
                    cfgSignalLogging = val;
                case 'cfgloggingname'
                    cfgLoggingName = val;
                case 'saveoutput'
                    cfgSaveOutput = val;
                case 'outputsavename'
                    cfgOutputSaveName = val;
                case 'loadmodelifnot'
                    loadModelIfNot = val;
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'signalLogging', struct(), ...
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

    % ===== 执行操作 =====
    switch lower(action)
        case 'enable'
            result = action_enable(result, modelName, blockPath, portIndex, portType, ...
                loggingName, decimation, limitDataPoints, maxPoints);

        case 'disable'
            result = action_disable(result, modelName, blockPath, portIndex, portType);

        case 'list'
            result = action_list(result, modelName);

        case 'configure'
            result = action_configure(result, modelName, cfgSignalLogging, cfgLoggingName, ...
                cfgSaveOutput, cfgOutputSaveName);

        otherwise
            result.status = 'error';
            result.error = ['Unknown action: ' action];
            result.message = result.error;
    end
end


function result = action_enable(result, modelName, blockPath, portIndex, portType, ...
    loggingName, decimation, limitDataPoints, maxPoints)
% ACTION_ENABLE 启用信号记录

    % 确保模型级 SignalLogging 已启用
    try
        currentSL = get_param(modelName, 'SignalLogging');
        if strcmpi(currentSL, 'off')
            set_param(modelName, 'SignalLogging', 'on');
        end
    catch
        % R2012a+ 应该支持
    end

    % 获取端口句柄
    try
        ph = get_param(blockPath, 'PortHandles');
        if strcmpi(portType, 'outport')
            portHandles = ph.Outport;
        else
            portHandles = ph.Inport;
        end

        if portIndex < 1 || portIndex > length(portHandles)
            result.status = 'error';
            result.error = sprintf('Port index %d out of range (1-%d)', portIndex, length(portHandles));
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

    % 启用 DataLogging
    try
        set_param(portHandle, 'DataLogging', 'on');

        % 设置信号名称
        if ~isempty(loggingName)
            try
                set_param(portHandle, 'DataLoggingNameMode', 'SignalName');
            catch
                % R2016a 可能不支持 DataLoggingNameMode，使用 Name 替代
            end
            try
                set_param(portHandle, 'Name', loggingName);
            catch
            end
        end

        % 设置抽取因子
        if decimation > 1
            try
                set_param(portHandle, 'DataLoggingDecimation', num2str(decimation));
            catch
            end
        end

        % 设置数据点限制
        if limitDataPoints
            try
                set_param(portHandle, 'DataLoggingLimitDataPoints', 'on');
                set_param(portHandle, 'DataLoggingMaxPoints', num2str(maxPoints));
            catch
            end
        end

    catch ME
        result.status = 'error';
        result.error = ['Failed to enable DataLogging: ' ME.message];
        result.message = result.error;
        return;
    end

    % 验证
    verification = struct('dataLoggingSet', false, 'nameSet', false);
    try
        actualDL = get_param(portHandle, 'DataLogging');
        verification.dataLoggingSet = strcmpi(actualDL, 'on');
    catch
    end

    if ~isempty(loggingName)
        try
            actualName = get_param(portHandle, 'Name');
            verification.nameSet = strcmpi(actualName, loggingName);
        catch
        end
    else
        verification.nameSet = true; % 没有要求设名称
    end

    result.signalLogging = struct( ...
        'action', 'enable', ...
        'blockPath', blockPath, ...
        'portIndex', portIndex, ...
        'portType', portType, ...
        'loggingEnabled', verification.dataLoggingSet, ...
        'loggingName', loggingName, ...
        'verification', verification);

    result.message = sprintf('Signal logging enabled on %s port %d', blockPath, portIndex);
    if ~verification.dataLoggingSet
        result.message = [result.message ' (verification: DataLogging may not be set)'];
    end
end


function result = action_disable(result, modelName, blockPath, portIndex, portType)
% ACTION_DISABLE 禁用信号记录

    % 获取端口句柄
    try
        ph = get_param(blockPath, 'PortHandles');
        if strcmpi(portType, 'outport')
            portHandles = ph.Outport;
        else
            portHandles = ph.Inport;
        end

        if portIndex < 1 || portIndex > length(portHandles)
            result.status = 'error';
            result.error = sprintf('Port index %d out of range (1-%d)', portIndex, length(portHandles));
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

    % 禁用 DataLogging
    try
        set_param(portHandle, 'DataLogging', 'off');
    catch ME
        result.status = 'error';
        result.error = ['Failed to disable DataLogging: ' ME.message];
        result.message = result.error;
        return;
    end

    % 验证
    disabled = false;
    try
        actualDL = get_param(portHandle, 'DataLogging');
        disabled = strcmpi(actualDL, 'off');
    catch
    end

    result.signalLogging = struct( ...
        'action', 'disable', ...
        'blockPath', blockPath, ...
        'portIndex', portIndex, ...
        'portType', portType, ...
        'loggingDisabled', disabled);

    result.message = sprintf('Signal logging disabled on %s port %d', blockPath, portIndex);
end


function result = action_list(result, modelName)
% ACTION_LIST 列出所有已启用信号记录的端口

    loggingList = {};
    idx = 1;

    % 查找所有端口
    try
        allPorts = find_system(modelName, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'port');

        for pi = 1:length(allPorts)
            try
                dl = get_param(allPorts(pi), 'DataLogging');
                if strcmpi(dl, 'on')
                    % 获取端口所属模块信息
                    portInfo = get_param(allPorts(pi), 'Parent');
                    portType = get_param(allPorts(pi), 'PortType');

                    % 获取端口索引
                    portNum = get_param(allPorts(pi), 'PortNumber');

                    % 获取信号名
                    sigName = '';
                    try
                        sigName = get_param(allPorts(pi), 'Name');
                    catch
                    end

                    loggingList{idx} = struct( ...
                        'blockPath', portInfo, ...
                        'portIndex', portNum, ...
                        'portType', portType, ...
                        'loggingName', sigName);
                    idx = idx + 1;
                end
            catch
                % 某些端口可能不支持 DataLogging
            end
        end
    catch ME
        result.status = 'error';
        result.error = ['Failed to list signal logging: ' ME.message];
        result.message = result.error;
        return;
    end

    % 检查模型级信号记录状态
    modelSL = 'unknown';
    try
        modelSL = get_param(modelName, 'SignalLogging');
    catch
    end

    result.signalLogging = struct( ...
        'action', 'list', ...
        'modelSignalLogging', modelSL, ...
        'enabledPorts', loggingList, ...
        'count', length(loggingList));

    result.message = sprintf('Found %d ports with signal logging enabled in %s', ...
        length(loggingList), modelName);
end


function result = action_configure(result, modelName, cfgSignalLogging, cfgLoggingName, ...
    cfgSaveOutput, cfgOutputSaveName)
% ACTION_CONFIGURE 配置模型级信号记录设置

    configResults = {};

    % SignalLogging 开关
    if ~isempty(cfgSignalLogging)
        try
            set_param(modelName, 'SignalLogging', cfgSignalLogging);
            configResults{end+1} = struct('param', 'SignalLogging', 'value', cfgSignalLogging, 'success', true); %#ok<AGROW>
        catch ME
            configResults{end+1} = struct('param', 'SignalLogging', 'value', cfgSignalLogging, 'success', false, 'error', ME.message); %#ok<AGROW>
        end
    end

    % LoggingName (logsout 变量名)
    if ~isempty(cfgLoggingName)
        try
            set_param(modelName, 'SignalLoggingName', cfgLoggingName);
            configResults{end+1} = struct('param', 'SignalLoggingName', 'value', cfgLoggingName, 'success', true); %#ok<AGROW>
        catch ME
            configResults{end+1} = struct('param', 'SignalLoggingName', 'value', cfgLoggingName, 'success', false, 'error', ME.message); %#ok<AGROW>
        end
    end

    % SaveOutput 开关
    if ~isempty(cfgSaveOutput)
        try
            set_param(modelName, 'SaveOutput', cfgSaveOutput);
            configResults{end+1} = struct('param', 'SaveOutput', 'value', cfgSaveOutput, 'success', true); %#ok<AGROW>
        catch ME
            configResults{end+1} = struct('param', 'SaveOutput', 'value', cfgSaveOutput, 'success', false, 'error', ME.message); %#ok<AGROW>
        end
    end

    % OutputSaveName
    if ~isempty(cfgOutputSaveName)
        try
            set_param(modelName, 'OutputSaveName', cfgOutputSaveName);
            configResults{end+1} = struct('param', 'OutputSaveName', 'value', cfgOutputSaveName, 'success', true); %#ok<AGROW>
        catch ME
            configResults{end+1} = struct('param', 'OutputSaveName', 'value', cfgOutputSaveName, 'success', false, 'error', ME.message); %#ok<AGROW>
        end
    end

    result.signalLogging = struct( ...
        'action', 'configure', ...
        'configResults', configResults);

    result.message = sprintf('Model-level signal logging configured (%d settings applied)', length(configResults));
end
