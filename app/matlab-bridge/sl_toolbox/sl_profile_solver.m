function result = sl_profile_solver(modelName, varargin)
% SL_PROFILE_SOLVER 运行求解器性能分析（Solver Profiler）
%   result = sl_profile_solver('MyModel', 'action', 'run', ...)
%   result = sl_profile_solver('MyModel', 'action', 'report', ...)
%
%   借鉴 simulink/skills 的 solver-profiler-analyzer Skill:
%     - R2020b+ 使用 Simulink.sdi.diag.solverProfiler
%     - R2017a~R2020a 回退: 编译模型 + 分析编译信息
%     - R2016a 回退: 手动检查求解器配置
%     - 诊断零交叉、重置、代数环、刚性等问题
%
%   输入:
%     modelName       - 模型名称（必选）
%     'action'        - 'run'|'report'（必选）
%     'stopTime'      - 覆盖仿真停止时间（可选）
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status          - 'ok' 或 'error'
%     .profileSolver   - struct
%     .message         - 总结信息
%     .error           - 错误信息

    % ===== 解析参数 =====
    opts = struct( ...
        'action', '', ...
        'stopTime', '', ...
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

    result = struct('status', 'ok', 'profileSolver', struct(), ...
        'message', '', 'error', '');

    % ===== 验证 action =====
    validActions = {'run', 'report'};
    if isempty(opts.action) || ~ismember(opts.action, validActions)
        result.status = 'error';
        result.error = sprintf('Invalid action: must be one of {%s}. Got: %s', ...
            strjoin(validActions, ', '), dispval(opts.action));
        result.message = result.error;
        return;
    end

    % ===== 验证 modelName =====
    if ~ischar(modelName) || isempty(modelName)
        result.status = 'error';
        result.error = 'modelName must be a non-empty string';
        result.message = result.error;
        return;
    end

    % ===== 验证 stopTime =====
    if ~isempty(opts.stopTime)
        if ~(ischar(opts.stopTime) || isnumeric(opts.stopTime))
            result.status = 'error';
            result.error = 'stopTime must be a string or numeric value';
            result.message = result.error;
            return;
        end
        if isnumeric(opts.stopTime) && opts.stopTime <= 0
            result.status = 'error';
            result.error = 'stopTime must be positive';
            result.message = result.error;
            return;
        end
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
    else
        if ~bdIsLoaded(modelName)
            result.status = 'error';
            result.error = ['Model not loaded: ' modelName '. Set loadModelIfNot=true to auto-load.'];
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

    % ===== 根据 action 分发 =====
    try
        switch opts.action
            case 'run'
                result = do_run(result, modelName, opts, verNum);
            case 'report'
                result = do_report(result, modelName, opts);
        end
    catch ME_unhandled
        % 兜底：未预期的异常不应导致 MATLAB 崩溃
        result.status = 'error';
        result.error = ['Unexpected error in sl_profile_solver: ' ME_unhandled.message];
        result.message = result.error;
    end
end


function result = do_run(result, modelName, opts, verNum)
% DO_RUN 运行求解器性能分析

    % ===== 获取当前求解器信息 =====
    solverInfo = struct();
    try
        solverInfo.name = get_param(modelName, 'Solver');
    catch
        solverInfo.name = 'unknown';
    end
    try
        solverInfo.type = get_param(modelName, 'SolverType');
    catch
        % 推断求解器类型
        solverName = lower(solverInfo.name);
        if any(strcmp(solverName, {'ode1', 'ode2', 'ode3', 'ode4', 'ode5', 'ode8', 'ode14x', 'ode1be', 'discrete'}))
            solverInfo.type = 'Fixed-step';
        else
            solverInfo.type = 'Variable-step';
        end
    end

    % ===== 检测可用的 Solver Profiler API =====
    useSolverProfiler = false;
    if verNum >= 10.0 % R2020b = 10.0
        try
            m = which('Simulink.sdi.diag.solverProfiler');
            if ~isempty(m)
                useSolverProfiler = true;
            end
        catch
        end
    end

    % ===== 覆盖停止时间 =====
    origStopTime = '';
    if ~isempty(opts.stopTime)
        try
            origStopTime = get_param(modelName, 'StopTime');
            if isnumeric(opts.stopTime)
                set_param(modelName, 'StopTime', num2str(opts.stopTime));
            else
                set_param(modelName, 'StopTime', opts.stopTime);
            end
        catch
        end
    end

    % ===== 运行分析 =====
    diagnostics = struct();
    apiUsed = '';

    if useSolverProfiler
        % ===== R2020b+ 路径: Solver Profiler =====
        try
            sp = Simulink.sdi.diag.solverProfiler(modelName);
            sp.run();
            profReport = sp.report();

            % 解析 Solver Profiler 结果
            diagnostics = parse_solver_profiler_report(profReport, modelName);
            apiUsed = 'Simulink.sdi.diag.solverProfiler';

        catch ME_sp
            % Solver Profiler 失败，回退到手动分析
            try
                diagnostics = run_manual_analysis(modelName);
            catch ME_manual
                diagnostics = create_empty_diagnostics();
                diagnostics.warningInfo = ['Solver Profiler fallback also failed: ' ME_manual.message];
            end
            apiUsed = 'manual_analysis_fallback';
        end
    else
        % ===== R2016a~R2020a 回退路径: 手动分析 =====
        try
            diagnostics = run_manual_analysis(modelName);
        catch ME_manual
            diagnostics = create_empty_diagnostics();
            diagnostics.warningInfo = ['Manual analysis failed: ' ME_manual.message];
        end
        if verNum >= 9.2
            apiUsed = 'manual_analysis_R2017a';
        else
            apiUsed = 'manual_analysis_R2016a';
        end
    end

    % ===== 恢复停止时间 =====
    if ~isempty(opts.stopTime) && ~isempty(origStopTime)
        try
            set_param(modelName, 'StopTime', origStopTime);
        catch
        end
    end

    % ===== 生成求解器推荐 =====
    solverRecommendations = generate_solver_recommendations(solverInfo, diagnostics);

    % [FIX] 安全构建返回结构 — 分步赋值，避免 struct 展开问题
    ps = struct();
    ps.action = 'run';
    ps.apiUsed = apiUsed;
    ps.matlabVersion = sprintf('%.1f', verNum);
    ps.solverInfo = solverInfo;
    ps.diagnostics = diagnostics;
    ps.solverRecommendations = solverRecommendations;

    result.profileSolver = ps;

    % ===== 生成摘要 message =====
    diagParts = {};
    if isfield(diagnostics, 'zeroCrossings') && isfield(diagnostics.zeroCrossings, 'count')
        try
            if diagnostics.zeroCrossings.count > 0
                diagParts{end+1} = sprintf('%d zero-crossings', diagnostics.zeroCrossings.count); %#ok<AGROW>
            end
        catch
        end
    end
    if isfield(diagnostics, 'resets') && isfield(diagnostics.resets, 'count')
        try
            if diagnostics.resets.count > 0
                diagParts{end+1} = sprintf('%d resets', diagnostics.resets.count); %#ok<AGROW>
            end
        catch
        end
    end
    if isfield(diagnostics, 'algebraicLoops') && isfield(diagnostics.algebraicLoops, 'detected')
        try
            if diagnostics.algebraicLoops.detected
                diagParts{end+1} = 'algebraic loop(s)'; %#ok<AGROW>
            end
        catch
        end
    end
    if isfield(diagnostics, 'stiffness') && isfield(diagnostics.stiffness, 'detected')
        try
            if diagnostics.stiffness.detected
                diagParts{end+1} = 'stiffness detected'; %#ok<AGROW>
            end
        catch
        end
    end

    if isempty(diagParts)
        result.message = sprintf('Solver profile completed (%s, %s) - no issues detected', ...
            solverInfo.name, solverInfo.type);
    else
        result.message = sprintf('Solver profile completed (%s, %s) - issues: %s', ...
            solverInfo.name, solverInfo.type, strjoin(diagParts, ', '));
    end
end


function result = do_report(result, modelName, opts)
% DO_REPORT 返回上次 solver profile 的详细报告

    % 由于 Solver Profiler 的结果不会持久化，
    % report 功能要求先运行 run 再调用 report
    % 这里尝试从模型编译信息中提取

    diagnostics = struct();

    % 尝试获取编译信息
    try
        % 编译模型获取诊断信息
        wasCompiled = false;
        try
            modelName('compile');
            wasCompiled = true;
        catch
        end

        % 获取编译后的信息
        diagnostics = run_manual_analysis(modelName);

        % 取消编译
        if wasCompiled
            try modelName('term'); catch, end
        end
    catch ME
        result.status = 'error';
        result.error = ['Cannot generate solver report: ' ME.message];
        result.message = result.error;
        return;
    end

    solverInfo = struct();
    try solverInfo.name = get_param(modelName, 'Solver'); catch, solverInfo.name = 'unknown'; end
    try solverInfo.type = get_param(modelName, 'SolverType'); catch, solverInfo.type = 'unknown'; end

    solverRecommendations = generate_solver_recommendations(solverInfo, diagnostics);

    % [FIX] 分步赋值
    ps = struct();
    ps.action = 'report';
    ps.solverInfo = solverInfo;
    ps.diagnostics = diagnostics;
    ps.solverRecommendations = solverRecommendations;

    result.profileSolver = ps;

    result.message = sprintf('Solver report for %s (%s)', solverInfo.name, solverInfo.type);
end


function diagnostics = create_empty_diagnostics()
% CREATE_EMPTY_DIAGNOSTICS 创建空诊断结构（安全兜底）
% [FIX] 使用分步赋值代替 struct('field',cellVal)，避免空 cell 导致 struct 展开为空数组

    diagnostics = struct();
    diagnostics.zeroCrossings = struct();
    diagnostics.zeroCrossings.count = 0;
    diagnostics.zeroCrossings.locations = {};
    diagnostics.zeroCrossings.suggestion = '';
    diagnostics.resets = struct();
    diagnostics.resets.count = 0;
    diagnostics.resets.locations = {};
    diagnostics.resets.suggestion = '';
    diagnostics.algebraicLoops = struct();
    diagnostics.algebraicLoops.detected = false;
    diagnostics.algebraicLoops.locations = {};
    diagnostics.algebraicLoops.suggestion = '';
    diagnostics.stiffness = struct();
    diagnostics.stiffness.detected = false;
    diagnostics.stiffness.suggestion = '';
    diagnostics.stepSizeHistory = struct();
    diagnostics.stepSizeHistory.available = false;
    diagnostics.stepSizeHistory.summary = '';
end


function diagnostics = parse_solver_profiler_report(profReport, modelName)
% PARSE_SOLVER_PROFILER_REPORT 解析 Solver Profiler 的输出报告

    diagnostics = create_empty_diagnostics();

    % 零交叉诊断
    try
        if isfield(profReport, 'zeroCrossings')
            zc = profReport.zeroCrossings;
            if isnumeric(zc)
                diagnostics.zeroCrossings.count = zc;
            elseif isstruct(zc)
                diagnostics.zeroCrossings.count = length(zc);
                for zi = 1:length(zc)
                    try
                        diagnostics.zeroCrossings.locations{zi} = zc(zi).blockPath;
                    catch
                        diagnostics.zeroCrossings.locations{zi} = ['zeroCrossing_' num2str(zi)];
                    end
                end
            end
        end
    catch
    end

    if diagnostics.zeroCrossings.count > 10
        diagnostics.zeroCrossings.suggestion = 'High zero-crossing count. Consider using fixed-step solver or smoothing discontinuities.';
    end

    % 状态重置诊断
    try
        if isfield(profReport, 'resets')
            rst = profReport.resets;
            if isnumeric(rst)
                diagnostics.resets.count = rst;
            elseif isstruct(rst)
                diagnostics.resets.count = length(rst);
                for ri = 1:length(rst)
                    try
                        diagnostics.resets.locations{ri} = rst(ri).blockPath;
                    catch
                        diagnostics.resets.locations{ri} = ['reset_' num2str(ri)];
                    end
                end
            end
        end
    catch
    end

    if diagnostics.resets.count > 3
        diagnostics.resets.suggestion = 'Integrator resets detected. Check if initial condition sources are stable.';
    end

    % 代数环检测
    try
        if isfield(profReport, 'algebraicLoops')
            al = profReport.algebraicLoops;
            if (isnumeric(al) && al > 0) || (isstruct(al) && ~isempty(al))
                diagnostics.algebraicLoops.detected = true;
                if isstruct(al)
                    for ai = 1:length(al)
                        try
                            diagnostics.algebraicLoops.locations{ai} = al(ai).blockPath;
                        catch
                        end
                    end
                end
            end
        end
    catch
    end

    if diagnostics.algebraicLoops.detected
        diagnostics.algebraicLoops.suggestion = 'Algebraic loop detected. Consider adding Delay/Memory block or using ode14x solver.';
    end

    % 刚性诊断
    try
        if isfield(profReport, 'stiffness')
            diagnostics.stiffness.detected = profReport.stiffness;
        end
        if isfield(profReport, 'stepSizeVariation')
            % 步长变化 > 3 个数量级 → 可能刚性
            stepVar = profReport.stepSizeVariation;
            if isnumeric(stepVar) && stepVar > 1000
                diagnostics.stiffness.detected = true;
            end
        end
    catch
    end

    if diagnostics.stiffness.detected
        diagnostics.stiffness.suggestion = 'Model appears stiff. Consider switching to ode15s or ode23t solver.';
    end

    % 步长历史摘要
    try
        if isfield(profReport, 'stepSizeHistory')
            diagnostics.stepSizeHistory.available = true;
            diagnostics.stepSizeHistory.summary = 'Step size data available from Solver Profiler';
        end
    catch
    end

    % 求解器步数信息
    try
        if isfield(profReport, 'totalSteps')
            diagnostics.solverSteps = profReport.totalSteps;
        end
    catch
    end
end


function diagnostics = run_manual_analysis(modelName)
% RUN_MANUAL_ANALYSIS 手动分析求解器性能（R2020b 以下回退方案）

    diagnostics = create_empty_diagnostics();

    % ===== 零交叉检测 =====
    try
        % 查找可能产生零交叉的模块
        zcBlockTypes = {'HitCross', 'RelationalOperator', 'Switch', 'Logic', ...
            'Signum', 'Abs', 'MinMax', 'ZeroOrderHold'};
        zcBlocks = {};
        for ti = 1:length(zcBlockTypes)
            try
                found = find_system(modelName, 'LookUnderMasks', 'on', ...
                    'BlockType', zcBlockTypes{ti});
                for fi = 1:length(found)
                    zcBlocks{end+1} = found{fi}; %#ok<AGROW>
                end
            catch
            end
        end
        diagnostics.zeroCrossings.count = length(zcBlocks);
        diagnostics.zeroCrossings.locations = zcBlocks;

        if length(zcBlocks) > 10
            diagnostics.zeroCrossings.suggestion = 'High number of potential zero-crossing sources. Consider fixed-step solver or smoothing.';
        end
    catch
    end

    % ===== 状态重置检测 =====
    try
        % 查找 Integrator 模块（可能有重置）
        integrators = find_system(modelName, 'LookUnderMasks', 'on', 'BlockType', 'Integrator');
        resetBlocks = {};
        for ii = 1:length(integrators)
            try
                % 检查是否有外部重置
                extReset = get_param(integrators{ii}, 'ExternalReset');
                if ~strcmpi(extReset, 'none') && ~isempty(extReset)
                    resetBlocks{end+1} = integrators{ii}; %#ok<AGROW>
                end
            catch
            end
        end
        diagnostics.resets.count = length(resetBlocks);
        diagnostics.resets.locations = resetBlocks;

        if length(resetBlocks) > 3
            diagnostics.resets.suggestion = 'Multiple Integrator resets detected. Check if initial condition sources are stable.';
        end
    catch
    end

    % ===== 代数环检测 =====
    try
        % 尝试编译模型来检测代数环
        wasCompiled = false;
        try
            modelName('compile');
            wasCompiled = true;
        catch
        end

        % 检查编译警告
        if wasCompiled
            try
                % 在编译后检查是否有代数环警告
                warnStruct = lastwarn;
                if ~isempty(warnStruct) && ...
                   (~isempty(strfind(lower(warnStruct), 'algebraic')) || ...
                    ~isempty(strfind(lower(warnStruct), 'algebraic loop')))
                    diagnostics.algebraicLoops.detected = true;
                end
            catch
            end
        end

        if wasCompiled
            try modelName('term'); catch, end
        end
    catch
    end

    % 另一种检测方式：查找构成代数环的模块组合
    try
        feedbackTypes = {'Gain', 'Sum', 'Add', 'Subtract', 'Product', 'Math'};
        feedbackBlocks = {};
        for fi = 1:length(feedbackTypes)
            try
                found = find_system(modelName, 'LookUnderMasks', 'on', ...
                    'BlockType', feedbackTypes{fi});
                for fi2 = 1:length(found)
                    feedbackBlocks{end+1} = found{fi2}; %#ok<AGROW>
                end
            catch
            end
        end

        % 如果有大量直接反馈模块，可能存在代数环（保守估计）
        if length(feedbackBlocks) > 5 && ~diagnostics.algebraicLoops.detected
            diagnostics.algebraicLoops.detected = false;
            diagnostics.algebraicLoops.note = 'Direct feedback blocks detected - algebraic loop possible';
        end
    catch
    end

    if diagnostics.algebraicLoops.detected
        diagnostics.algebraicLoops.suggestion = 'Algebraic loop detected. Consider adding Delay/Memory block or using ode14x solver.';
    end

    % ===== 刚性诊断 =====
    try
        % 检查求解器类型和步长设置
        solverType = '';
        try solverType = get_param(modelName, 'SolverType'); catch, end

        if strcmpi(solverType, 'Variable-step')
            % 变步长求解器，检查步长设置
            try
                maxStep = get_param(modelName, 'MaxStep');
                minStep = get_param(modelName, 'MinStep');
                if ~isempty(maxStep) && ~isempty(minStep)
                    maxVal = str2double(maxStep);
                    minVal = str2double(minStep);
                    if ~isnan(maxVal) && ~isnan(minVal) && minVal > 0 && maxVal > 0
                        ratio = maxVal / minVal;
                        if ratio > 1000
                            diagnostics.stiffness.detected = true;
                        end
                    end
                end
            catch
            end
        end

        % 检查是否有刚性相关的模块
        try
            stiffIndicators = find_system(modelName, 'LookUnderMasks', 'on', ...
                'BlockType', 'TransferFcn');
            transportDelay = find_system(modelName, 'LookUnderMasks', 'on', ...
                'BlockType', 'TransportDelay');
            if length(stiffIndicators) > 2 || length(transportDelay) > 0
                diagnostics.stiffness.detected = true;
            end
        catch
        end

    catch
    end

    if diagnostics.stiffness.detected
        diagnostics.stiffness.suggestion = 'Model appears stiff. Consider switching to ode15s or ode23t solver.';
    end

    % ===== 步长历史摘要（手动模式有限信息） =====
    diagnostics.stepSizeHistory = struct('available', false, 'summary', ...
        'Step size history not available in manual analysis mode. Use R2020b+ for full Solver Profiler.');

    % ===== 求解器步数估算 =====
    try
        stopTime = str2double(get_param(modelName, 'StopTime'));
        solverType = '';
        try solverType = get_param(modelName, 'SolverType'); catch, end
        if strcmpi(solverType, 'Fixed-step')
            try
                fixedStep = str2double(get_param(modelName, 'FixedStep'));
                if ~isnan(stopTime) && ~isnan(fixedStep) && fixedStep > 0
                    diagnostics.solverSteps = ceil(stopTime / fixedStep);
                end
            catch
            end
        end
    catch
    end
end


function recommendations = generate_solver_recommendations(solverInfo, diagnostics)
% GENERATE_SOLVER_RECOMMENDATIONS 根据诊断结果生成求解器推荐

    recommendations = {};

    % 刚性 + 变步长
    if isfield(diagnostics, 'stiffness') && isfield(diagnostics.stiffness, 'detected')
        try
            if diagnostics.stiffness.detected
                if isfield(solverInfo, 'type') && strcmpi(solverInfo.type, 'Variable-step')
                    r = struct();
                    r.currentSolver = solverInfo.name;
                    r.recommendedSolver = 'ode15s';
                    r.reason = 'Stiff model with variable-step solver - ode15s is designed for stiff systems';
                    r.priority = 'high';
                    recommendations{end+1} = r; %#ok<AGROW>

                    r2 = struct();
                    r2.currentSolver = solverInfo.name;
                    r2.recommendedSolver = 'ode23t';
                    r2.reason = 'Moderately stiff with zero-crossing handling';
                    r2.priority = 'medium';
                    recommendations{end+1} = r2; %#ok<AGROW>
                else
                    r = struct();
                    r.currentSolver = solverInfo.name;
                    r.recommendedSolver = 'ode14x';
                    r.reason = 'Stiff model requiring fixed-step - ode14x handles stiff systems with fixed step';
                    r.priority = 'high';
                    recommendations{end+1} = r; %#ok<AGROW>
                end
            end
        catch
        end
    end

    % 零交叉多
    if isfield(diagnostics, 'zeroCrossings') && isfield(diagnostics.zeroCrossings, 'count')
        try
            if diagnostics.zeroCrossings.count > 10
                r = struct();
                r.currentSolver = solverInfo.name;
                r.recommendedSolver = 'ode23t';
                r.reason = 'High zero-crossing count - ode23t handles zero-crossings well';
                r.priority = 'medium';
                recommendations{end+1} = r; %#ok<AGROW>

                r2 = struct();
                r2.currentSolver = solverInfo.name;
                r2.recommendedSolver = 'Fixed-step (ode4/ode5)';
                r2.reason = 'High zero-crossing count - fixed-step avoids zero-crossing iteration overhead';
                r2.priority = 'medium';
                recommendations{end+1} = r2; %#ok<AGROW>
            end
        catch
        end
    end

    % 代数环
    if isfield(diagnostics, 'algebraicLoops') && isfield(diagnostics.algebraicLoops, 'detected')
        try
            if diagnostics.algebraicLoops.detected
                r = struct();
                r.currentSolver = solverInfo.name;
                r.recommendedSolver = 'ode14x';
                r.reason = 'Algebraic loop detected - ode14x can handle algebraic constraints';
                r.priority = 'high';
                recommendations{end+1} = r; %#ok<AGROW>
            end
        catch
        end
    end

    % 非刚性 + 快速仿真
    if ~isfield(diagnostics, 'stiffness') || ~isfield(diagnostics.stiffness, 'detected') || ~diagnostics.stiffness.detected
        try
            if isfield(solverInfo, 'type') && strcmpi(solverInfo.type, 'Variable-step')
                if ~strcmpi(solverInfo.name, 'ode23') && ~strcmpi(solverInfo.name, 'ode45')
                    r = struct();
                    r.currentSolver = solverInfo.name;
                    r.recommendedSolver = 'ode45';
                    r.reason = 'Non-stiff model - ode45 is the standard variable-step solver';
                    r.priority = 'low';
                    recommendations{end+1} = r; %#ok<AGROW>
                end
            end
        catch
        end
    end

    % 如果没有推荐，添加默认建议
    if isempty(recommendations)
        r = struct();
        r.currentSolver = solverInfo.name;
        r.recommendedSolver = solverInfo.name;
        r.reason = 'Current solver appears appropriate for this model';
        r.priority = 'info';
        recommendations{end+1} = r; %#ok<AGROW>
    end
end


function s = dispval(v)
% DISPVAL 安全显示变量值，用于错误消息
    try
        if isempty(v)
            s = '(empty)';
        elseif ischar(v)
            s = ['''' v ''''];
        elseif isnumeric(v)
            s = num2str(v);
        else
            s = class(v);
        end
    catch
        s = '(unknown)';
    end
end
