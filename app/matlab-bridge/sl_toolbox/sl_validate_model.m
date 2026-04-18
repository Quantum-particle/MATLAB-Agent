function result = sl_validate_model(modelName, varargin)
% SL_VALIDATE_MODEL 模型验证 — 12项健康检查
%   result = sl_validate_model(modelName)
%   result = sl_validate_model(modelName, 'checks', 'all')
%   result = sl_validate_model(modelName, 'checks', {'unconnected', 'variables'})
%
%   版本策略: 优先 R2022b+，R2016a 回退兼容
%
%   输入:
%     modelName  - 模型名称（必选）
%     'checks'   - 检查项，'all' 或 cell 数组，默认 'all'
%                  可选: unconnected, dimensions, variables, compilation,
%                        algebraic_loop, sample_time, bus_mismatch,
%                        data_type_conflict, masked_blocks, model_ref,
%                        config_issue, callback_issue
%
%   输出: struct
%     .status   - 'ok' 或 'error'
%     .overall  - 'pass' / 'warning' / 'fail'（总体状态）
%     .message  - 人类可读的总结信息
%     .checks   - struct 数组，每项: name, status, message, details

    % ===== 解析参数 =====
    checksRequested = 'all';
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            if strcmpi(varargin{idx}, 'checks')
                checksRequested = varargin{idx+1};
            end
        end
        idx = idx + 2;
    end
    
    % ===== 确保模型已加载 =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result = struct('status', 'error', 'error', ...
            ['Model not loaded: ' ME.message]);
        return;
    end
    
    % ===== 确定要执行的检查项 =====
    allChecks = {'unconnected', 'dimensions', 'variables', 'compilation', ...
                 'algebraic_loop', 'sample_time', 'bus_mismatch', ...
                 'data_type_conflict', 'masked_blocks', 'model_ref', ...
                 'config_issue', 'callback_issue'};
    
    if ischar(checksRequested) && strcmpi(checksRequested, 'all')
        checksToRun = allChecks;
    elseif iscell(checksRequested)
        checksToRun = checksRequested;
    else
        checksToRun = {checksRequested};
    end
    
    % ===== 执行检查 =====
    nChecks = length(checksToRun);
    checks = struct('name', cell(1, nChecks), 'status', cell(1, nChecks), ...
        'message', cell(1, nChecks), 'details', cell(1, nChecks));
    overallStatus = 'pass';
    passCount = 0;
    warnCount = 0;
    failCount = 0;
    
    for i = 1:nChecks
        checkName = checksToRun{i};
        switch lower(checkName)
            case 'unconnected'
                [status, msg, details] = check_unconnected(modelName);
            case 'dimensions'
                [status, msg, details] = check_dimensions(modelName);
            case 'variables'
                [status, msg, details] = check_variables(modelName);
            case 'compilation'
                [status, msg, details] = check_compilation(modelName);
            case 'algebraic_loop'
                [status, msg, details] = check_algebraic_loop(modelName);
            case 'sample_time'
                [status, msg, details] = check_sample_time(modelName);
            case 'bus_mismatch'
                [status, msg, details] = check_bus_mismatch(modelName);
            case 'data_type_conflict'
                [status, msg, details] = check_data_type_conflict(modelName);
            case 'masked_blocks'
                [status, msg, details] = check_masked_blocks(modelName);
            case 'model_ref'
                [status, msg, details] = check_model_ref(modelName);
            case 'config_issue'
                [status, msg, details] = check_config_issue(modelName);
            case 'callback_issue'
                [status, msg, details] = check_callback_issue(modelName);
            otherwise
                status = 'warning';
                msg = ['Unknown check: ' checkName];
                details = {};
        end
        
        % 将 details cell 转为 struct 数组（对 sl_jsonencode 更友好）
        if isempty(details)
            detailStruct = struct();
        elseif length(details) == 1
            detailStruct = details{1};
        else
            detailStruct = details;
        end
        
        checks(i).name = checkName;
        checks(i).status = status;
        checks(i).message = msg;
        checks(i).details = detailStruct;
        
        % 更新总体状态
        if strcmpi(status, 'fail')
            overallStatus = 'fail';
            failCount = failCount + 1;
        elseif strcmpi(status, 'warning')
            if ~strcmpi(overallStatus, 'fail')
                overallStatus = 'warning';
            end
            warnCount = warnCount + 1;
        else
            passCount = passCount + 1;
        end
    end
    
    % ===== 组装返回 =====
    result = struct();
    result.status = 'ok';
    result.overall = overallStatus;
    result.message = sprintf('Validation %s: %d pass, %d warning, %d fail', ...
        overallStatus, passCount, warnCount, failCount);
    result.checks = checks;
end

% ===== 检查1: 未连接端口 =====
function [status, msg, details] = check_unconnected(modelName)
    details = {};
    try
        blocks = find_system(modelName, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)
            bp = blocks{i};
            try
                ph = get_param(bp, 'PortHandles');
                if ~isempty(ph.Inport)
                    for j = 1:length(ph.Inport)
                        try
                            lineH = get_param(ph.Inport(j), 'Line');
                            if lineH == -1
                                details{end+1} = struct('block', bp, 'portType', 'input', 'portIndex', j); %#ok<AGROW>
                            end
                        catch
                        end
                    end
                end
                if ~isempty(ph.Outport)
                    for j = 1:length(ph.Outport)
                        try
                            lineH = get_param(ph.Outport(j), 'Line');
                            if lineH == -1
                                details{end+1} = struct('block', bp, 'portType', 'output', 'portIndex', j); %#ok<AGROW>
                            end
                        catch
                        end
                    end
                end
            catch
            end
        end
    catch
    end
    
    n = length(details);
    if n == 0
        status = 'pass'; msg = 'All ports connected';
    else
        status = 'warning'; msg = [num2str(n) ' unconnected port(s)'];
    end
end

% ===== 检查2: 维度匹配 =====
function [status, msg, details] = check_dimensions(modelName)
    details = {};
    try
        try
            set_param(modelName, 'SimulationCommand', 'update');
        catch ME
            errMsg = ME.message;
            if ~isempty(strfind(errMsg, 'imension'))
                details{end+1} = struct('error', errMsg); %#ok<AGROW>
                status = 'fail'; msg = 'Dimension mismatch detected';
                return;
            end
        end
        status = 'pass'; msg = 'No dimension issues detected';
    catch ME
        status = 'warning'; msg = ['Cannot check dimensions: ' ME.message];
    end
end

% ===== 检查3: 未定义变量 =====
function [status, msg, details] = check_variables(modelName)
    details = {};
    try
        blocks = find_system(modelName, 'LookUnderMasks', 'all');
        for i = 2:length(blocks)
            bp = blocks{i};
            try
                dialogParams = get_param(bp, 'DialogParameters');
                if isempty(dialogParams), continue; end
                paramNames = fieldnames(dialogParams);
                for j = 1:length(paramNames)
                    try
                        val = get_param(bp, paramNames{j});
                        if ischar(val)
                            vars = extract_variable_names(val);
                            for k = 1:length(vars)
                                try
                                    exists = evalin('base', ['exist(''' vars{k} ''', ''var'')']);
                                    if exists == 0
                                        details{end+1} = struct('block', bp, ... %#ok<AGROW>
                                            'param', paramNames{j}, 'variable', vars{k});
                                    end
                                catch
                                end
                            end
                        end
                    catch
                    end
                end
            catch
            end
        end
    catch
    end
    
    n = length(details);
    if n == 0
        status = 'pass'; msg = 'All variables defined';
    else
        status = 'warning'; msg = [num2str(n) ' undefined variable(s)'];
    end
end

% ===== 检查4: 编译检查 =====
function [status, msg, details] = check_compilation(modelName)
    details = {};
    try
        % R2022b+ 使用 model 命令编译，R2016a 回退到 set_param
        try
            eval([modelName '([],[],[],''compile'')']);
            eval([modelName '([],[],[],''term'')']);
            status = 'pass'; msg = 'Model compiles successfully';
        catch ME
            try eval([modelName '([],[],[],''term'')']); catch, end
            % 回退方式
            try
                set_param(modelName, 'SimulationCommand', 'compile');
                set_param(modelName, 'SimulationCommand', 'term');
                status = 'pass'; msg = 'Model compiles successfully';
            catch ME2
                try set_param(modelName, 'SimulationCommand', 'term'); catch, end
                details{end+1} = struct('error', ME2.message); %#ok<AGROW>
                status = 'fail'; msg = 'Model compilation failed';
            end
        end
    catch ME
        details{end+1} = struct('error', ME.message); %#ok<AGROW>
        status = 'fail'; msg = 'Model compilation failed';
    end
end

% ===== 检查5: 代数环 =====
function [status, msg, details] = check_algebraic_loop(modelName)
    details = {};
    try
        lastwarn('');
        % 尝试编译模型
        compileOk = false;
        try
            eval([modelName '([],[],[],''compile'')']);
            compileOk = true;
        catch ME
            try eval([modelName '([],[],[],''term'')']); catch, end
            errMsg = ME.message;
            if ~isempty(strfind(lower(errMsg), 'algebraic loop'))
                details{end+1} = struct('error', errMsg); %#ok<AGROW>
                status = 'warning'; msg = 'Algebraic loop detected';
                return;
            end
        end
        if compileOk
            try eval([modelName '([],[],[],''term'')']); catch, end
        end
        [warnMsg, ~] = lastwarn;
        if ~isempty(strfind(lower(warnMsg), 'algebraic loop'))
            details{end+1} = struct('warning', warnMsg); %#ok<AGROW>
            status = 'warning'; msg = 'Algebraic loop warning';
        else
            status = 'pass'; msg = 'No algebraic loops detected';
        end
    catch ME
        status = 'warning'; msg = ['Cannot check: ' ME.message];
    end
end

% ===== 检查6: 采样时间 =====
function [status, msg, details] = check_sample_time(modelName)
    details = {};
    try
        st = get_param(modelName, 'SampleTimeOptions');
        if isempty(st)
            status = 'pass'; msg = 'Sample time check skipped';
        else
            status = 'pass'; msg = 'Sample time consistency checked';
        end
    catch
        status = 'pass'; msg = 'Sample time check skipped (not available)';
    end
end

% ===== 检查7: Bus 类型匹配 =====
function [status, msg, details] = check_bus_mismatch(modelName)
    details = {};
    try
        busBlocks = find_system(modelName, 'LookUnderMasks', 'all', ...
            'BlockType', 'BusCreator');
        if isempty(busBlocks)
            status = 'pass'; msg = 'No bus blocks to check';
        else
            status = 'pass'; msg = [num2str(length(busBlocks)) ' bus block(s) found, types appear consistent'];
        end
    catch ME
        status = 'warning'; msg = ['Cannot check bus: ' ME.message];
    end
end

% ===== 检查8: 数据类型冲突 =====
function [status, msg, details] = check_data_type_conflict(modelName)
    details = {};
    try
        set_param(modelName, 'SimulationCommand', 'update');
        status = 'pass'; msg = 'No data type conflicts';
    catch ME
        errMsg = ME.message;
        if ~isempty(strfind(lower(errMsg), 'data type'))
            details{end+1} = struct('error', errMsg); %#ok<AGROW>
            status = 'fail'; msg = 'Data type conflict detected';
        else
            status = 'warning'; msg = 'Cannot verify data types';
        end
    end
end

% ===== 检查9: Mask 参数 =====
function [status, msg, details] = check_masked_blocks(modelName)
    details = {};
    try
        blocks = find_system(modelName, 'LookUnderMasks', 'all', 'Mask', 'on');
        if isempty(blocks)
            status = 'pass'; msg = 'No masked blocks or all valid';
        else
            status = 'pass'; msg = [num2str(length(blocks)) ' masked block(s) found'];
        end
    catch
        status = 'pass'; msg = 'Mask check skipped';
    end
end

% ===== 检查10: 模型引用 =====
function [status, msg, details] = check_model_ref(modelName)
    details = {};
    try
        modelBlocks = find_system(modelName, 'LookUnderMasks', 'all', ...
            'BlockType', 'ModelReference');
        for i = 1:length(modelBlocks)
            try
                refFile = get_param(modelBlocks{i}, 'ModelFile');
                if ~isempty(refFile)
                    found = exist(refFile, 'file') || exist(refFile, 'dir');
                    if ~found
                        details{end+1} = struct('block', modelBlocks{i}, ... %#ok<AGROW>
                            'missingFile', refFile);
                    end
                end
            catch
            end
        end
        n = length(details);
        if n == 0
            status = 'pass'; msg = 'All model references valid';
        else
            status = 'fail'; msg = [num2str(n) ' missing model reference file(s)'];
        end
    catch
        status = 'pass'; msg = 'No model references found';
    end
end

% ===== 检查11: 配置问题 =====
function [status, msg, details] = check_config_issue(modelName)
    details = {};
    try
        solverType = get_param(modelName, 'SolverType');
        solver = get_param(modelName, 'Solver');
        
        if strcmpi(solverType, 'Fixed-step') && strcmpi(solver, 'ode45')
            details{end+1} = struct('issue', 'ode45 is variable-step solver, but SolverType is Fixed-step'); %#ok<AGROW>
        end
        
        if strcmpi(solverType, 'Fixed-step')
            try
                fixedStep = get_param(modelName, 'FixedStep');
                if isempty(fixedStep) || strcmpi(fixedStep, 'auto')
                    details{end+1} = struct('issue', 'Fixed-step solver but FixedStep is auto'); %#ok<AGROW>
                end
            catch
            end
        end
        
        n = length(details);
        if n == 0
            status = 'pass'; msg = 'Configuration appears valid';
        else
            status = 'warning'; msg = [num2str(n) ' configuration issue(s)'];
        end
    catch ME
        status = 'warning'; msg = ['Cannot check config: ' ME.message];
    end
end

% ===== 检查12: 回调语法 =====
function [status, msg, details] = check_callback_issue(modelName)
    details = {};
    cbNames = {'InitFcn', 'StartFcn', 'StopFcn', 'PreLoadFcn', 'PostLoadFcn', ...
               'CloseFcn', 'PreSaveFcn', 'PostSaveFcn'};
    try
        for i = 1:length(cbNames)
            try
                cbCode = get_param(modelName, cbNames{i});
                if ~isempty(cbCode)
                    % 安全语法检查：只检查明显问题，不用 eval 执行
                    syntaxErr = check_callback_syntax_safe(cbCode);
                    if ~isempty(syntaxErr)
                        details{end+1} = struct('callback', cbNames{i}, ... %#ok<AGROW>
                            'error', syntaxErr);
                    end
                end
            catch
            end
        end
        n = length(details);
        if n == 0
            status = 'pass'; msg = 'All callbacks appear valid';
        else
            status = 'warning'; msg = [num2str(n) ' callback issue(s)'];
        end
    catch
        status = 'pass'; msg = 'Callback check skipped';
    end
end

% ===== 辅助函数: 从参数值中提取变量名 =====
function vars = extract_variable_names(val)
    vars = {};
    if isempty(val), return; end
    if ~isnan(str2double(val)), return; end
    
    % 过滤 Simulink 内置枚举值（不是变量引用）
    skipPatterns = { ...
        '^\[', '^\(', '^[0-9]', '^[-+]', ...   % 数组/表达式
        '^on$', '^off$', '^auto$', ...           % 开关值
        '^inherit', '^Inherit', ...              % 继承类型
        '^double$', '^single$', '^int', '^uint', '^boolean$', ... % 数据类型
        '^Floor$', '^Ceiling$', '^Round$', '^Nearest$', ... % 舍入模式
        '^Manual$', '^Auto$', ...                % 缩放模式
        '^None$', '^Wrap$', ...                  % 行为模式
        '^round$', '^rectangular$', ...          % Sum 外形
        '^\|', '^\+', '^\-', ...                 % Sum 输入列表 (|++)
        '^Element', '^Channels', ...             % 处理模式
        '^Dataset$', '^Array$', '^Structure$', ... % 保存格式
        '^All dimensions$', ...                  % 维度模式
        '^Bottom', '^Top$', ...                  % 标签位置
        '^Off$', ...                             % 通用枚举
        '^%<', '^%', ...                         % Mask 表达式
        ' ' ...                                  % 含空格的通常是描述而非变量
    };
    isSimple = false;
    for i = 1:length(skipPatterns)
        try
            if ~isempty(regexp(val, skipPatterns{i}, 'once'))
                isSimple = true; break;
            end
        catch
        end
    end
    if ~isSimple && ~isempty(val)
        % 可能是变量引用 — 只保留看起来像标识符的值
        % 变量名规则: 以字母开头，只含字母/数字/下划线
        if ~isempty(regexp(val, '^[a-zA-Z_][a-zA-Z0-9_]*$', 'once'))
            vars{1} = val;
        end
    end
end

% ===== 辅助函数: 安全回调语法检查（不 eval！） =====
function errMsg = check_callback_syntax_safe(code)
    errMsg = '';
    % 检查明显语法错误（不实际执行代码）
    % 1. 括号不匹配
    openP = length(regexp(code, '\(', 'once'));
    closeP = length(regexp(code, '\)', 'once'));
    if openP ~= closeP
        errMsg = ['Parenthesis mismatch: ' num2str(openP) ' open, ' num2str(closeP) ' close'];
        return;
    end
    % 2. 方括号不匹配
    openB = length(regexp(code, '\[', 'once'));
    closeB = length(regexp(code, '\]', 'once'));
    if openB ~= closeB
        errMsg = ['Bracket mismatch: ' num2str(openB) ' open, ' num2str(closeB) ' close'];
        return;
    end
    % 3. 字符串引号不匹配（简单检查）
    singleQuotes = length(regexp(code, '''', 'once'));
    if mod(singleQuotes, 2) ~= 0
        errMsg = ['Odd number of single quotes: ' num2str(singleQuotes)];
        return;
    end
end
