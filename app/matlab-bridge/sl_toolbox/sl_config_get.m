function result = sl_config_get(modelName, varargin)
% SL_CONFIG_GET 获取模型配置 — 按 Solver/Simulation/Codegen/Diagnostics 分类
%   result = sl_config_get(modelName)
%   result = sl_config_get(modelName, 'categories', {'solver', 'simulation'})
%   result = sl_config_get(modelName, 'categories', 'all')
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName     - 模型名称（必选）
%     'categories'  - 要获取的配置类别，默认 'all'
%                     可选: 'solver', 'simulation', 'codegen', 'diagnostics'
%                     或 cell 数组如 {'solver', 'simulation'}
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .config   - struct，按类别组织
%     .message  - 人类可读的总结信息
%     .error    - 错误信息（仅 status='error' 时）

    % ===== 解析参数 =====
    categoriesRequested = 'all';
    loadModelIfNot = true;

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            if strcmpi(varargin{idx}, 'categories')
                categoriesRequested = varargin{idx+1};
            elseif strcmpi(varargin{idx}, 'loadModelIfNot')
                loadModelIfNot = varargin{idx+1};
            end
        end
        idx = idx + 2;
    end

    result = struct('status', 'ok', 'config', struct(), ...
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

    % ===== 定义各类别的参数 =====
    % Solver 参数组
    solverParams = { ...
        'Solver', 'SolverType', 'FixedStep', 'MaxStep', 'MinStep', ...
        'InitialStep', 'RelTol', 'AbsTol', 'ZeroCrossControl'};

    % Simulation 参数组
    simulationParams = { ...
        'StopTime', 'StartTime', 'SaveOutput', 'OutputSaveName', ...
        'SaveState', 'StateSaveName', 'SaveFinalState'};

    % Codegen 参数组
    codegenParams = { ...
        'SystemTargetFile', 'TargetLang', 'GenerateReport', 'RTWVerbose'};

    % Diagnostics 参数组
    diagnosticsParams = { ...
        'AlgebraicLoopMsg', 'MinStepSizeMsg', 'UnconnectedInputMsg', ...
        'UnconnectedOutputMsg', 'UnconnectedLineMsg', 'SignalRangeMsg'};

    % ===== 确定要获取的类别 =====
    allCategories = {'solver', 'simulation', 'codegen', 'diagnostics'};
    
    if ischar(categoriesRequested) && strcmpi(categoriesRequested, 'all')
        categories = allCategories;
    elseif iscell(categoriesRequested)
        categories = categoriesRequested;
    else
        categories = {categoriesRequested};
    end

    % ===== 逐类别获取配置 =====
    config = struct();
    totalParams = 0;
    totalOk = 0;
    warnings = {};

    for ci = 1:length(categories)
        cat = lower(categories{ci});
        
        % 选择参数列表
        switch cat
            case 'solver'
                paramList = solverParams;
            case 'simulation'
                paramList = simulationParams;
            case 'codegen'
                paramList = codegenParams;
            case 'diagnostics'
                paramList = diagnosticsParams;
            otherwise
                warnings{end+1} = ['Unknown category: ' cat]; %#ok<AGROW>
                continue;
        end

        % 获取该类别下所有参数
        catConfig = struct();
        for pi = 1:length(paramList)
            pName = paramList{pi};
            totalParams = totalParams + 1;
            try
                val = get_param(modelName, pName);
                catConfig.(pName) = val;
                totalOk = totalOk + 1;
            catch ME
                % R2016a 可能不支持某些新参数名
                catConfig.(pName) = ['<unsupported: ' ME.message '>'];
                warnings{end+1} = ['Cannot read ' pName ': ' ME.message]; %#ok<AGROW>
            end
        end

        config.(cat) = catConfig;
    end

    result.config = config;
    
    % ===== 生成 message =====
    result.message = sprintf('Retrieved %d/%d config parameters from %s', ...
        totalOk, totalParams, modelName);
    
    if ~isempty(warnings)
        result.warnings = warnings;
    end
end
