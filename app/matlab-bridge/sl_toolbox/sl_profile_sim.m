function result = sl_profile_sim(modelName, varargin)
% SL_PROFILE_SIM 运行仿真性能分析（Simulink Profiler）
%   result = sl_profile_sim('MyModel', 'action', 'run', ...)
%   result = sl_profile_sim('MyModel', 'action', 'report', ...)
%   result = sl_profile_sim('MyModel', 'action', 'compare', ...)
%
%   借鉴 simulink/skills 的 profiler-analyzer Skill:
%     - 使用 Simulink.profiler.run() 运行分析（R2017a+）
%     - R2016a 回退: profile on/off + sim + 手动分析
%     - 自动识别瓶颈模块 + 提供优化建议
%
%   输入:
%     modelName       - 模型名称（必选）
%     'action'        - 'run'|'report'|'compare'（必选）
%     'stopTime'      - 覆盖仿真停止时间（可选）
%     'baselineProfile' - struct，action='compare'时的基线 profile（可选）
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status          - 'ok' 或 'error'
%     .profileSim      - struct（结构因 action 而异）
%     .message         - 总结信息
%     .error           - 错误信息

    % ===== 解析参数 =====
    opts = struct( ...
        'action', '', ...
        'stopTime', '', ...
        'baselineProfile', struct(), ...
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

    result = struct('status', 'ok', 'profileSim', struct(), ...
        'message', '', 'error', '');

    % ===== 验证 action =====
    validActions = {'run', 'report', 'compare'};
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

    % ===== 验证 baselineProfile =====
    if strcmp(opts.action, 'compare')
        if isempty(opts.baselineProfile) || ~isstruct(opts.baselineProfile)
            result.status = 'error';
            result.error = 'baselineProfile must be a non-empty struct for compare action';
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
        % 不自动加载时检查模型是否可用
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

    useSimProfiler = (verNum >= 9.2); % R2017a+

    % ===== 根据 action 分发 =====
    try
        switch opts.action
            case 'run'
                result = do_run(result, modelName, opts, verNum, useSimProfiler);
            case 'report'
                result = do_report(result, modelName, opts, verNum);
            case 'compare'
                result = do_compare(result, modelName, opts);
        end
    catch ME_unhandled
        % 兜底：未预期的异常不应导致 MATLAB 崩溃
        result.status = 'error';
        result.error = ['Unexpected error in sl_profile_sim: ' ME_unhandled.message];
        result.message = result.error;
    end
end


function result = do_run(result, modelName, opts, verNum, useSimProfiler)
% DO_RUN 运行仿真性能分析

    profileStartTime = tic;
    profileData = [];
    apiUsed = '';

    if useSimProfiler
        % ===== R2017a+ 路径: Simulink.profiler =====
        try
            % 覆盖停止时间
            if ~isempty(opts.stopTime)
                origStopTime = get_param(modelName, 'StopTime');
                set_param(modelName, 'StopTime', num2str(opts.stopTime));
            end

            % 尝试使用 Simulink.profiler.run
            hasProfilerAPI = false;
            try
                m = which('Simulink.profiler.run');
                if ~isempty(m)
                    hasProfilerAPI = true;
                end
            catch
            end

            if hasProfilerAPI
                try
                    profileData = Simulink.profiler.run(modelName);
                    apiUsed = 'Simulink.profiler.run';
                catch ME_prof
                    % Simulink.profiler.run 失败，回退到 profile on/off
                    profileData = run_with_profile(modelName);
                    apiUsed = 'profile_on_off_fallback';
                end
            else
                % 没有 Simulink.profiler API，用 profile on/off
                profileData = run_with_profile(modelName);
                apiUsed = 'profile_on_off_fallback';
            end

            % 恢复停止时间
            if ~isempty(opts.stopTime)
                try
                    set_param(modelName, 'StopTime', origStopTime);
                catch
                end
            end

        catch ME_run
            result.status = 'error';
            result.error = ['Simulink Profiler failed: ' ME_run.message];
            result.message = result.error;
            return;
        end
    else
        % ===== R2016a 回退路径 =====
        try
            profileData = run_with_profile(modelName);
            apiUsed = 'profile_on_off_legacy';
        catch ME_run
            result.status = 'error';
            result.error = ['Profile run failed (R2016a fallback): ' ME_run.message];
            result.message = result.error;
            return;
        end
    end

    % ===== 解析 Profiler 结果 =====
    blockStats = parse_profile_data(profileData, modelName, apiUsed);

    % ===== 生成瓶颈模块排名 =====
    topBottlenecks = identify_bottlenecks(blockStats);

    % ===== 生成优化建议 =====
    suggestions = generate_suggestions(topBottlenecks, blockStats);

    % ===== 计算总时间 =====
    totalTime = 0;
    try
        totalTime = toc(profileStartTime);
    catch
    end

    % ===== 获取求解器信息 =====
    solverInfo = '';
    try
        solverInfo = [get_param(modelName, 'Solver') ' (' get_param(modelName, 'SolverType') ')'];
    catch
        try
            solverInfo = get_param(modelName, 'Solver');
        catch
            solverInfo = 'unknown';
        end
    end

    % ===== 安全构建返回结构 =====
    % [FIX] 关键修复：使用分步赋值代替 struct() 一次性构造
    % 避免 cell 数组字段导致 struct 展开为空数组的问题（踩坑经验 #16）
    ps = struct();
    ps.action = 'run';
    ps.totalTime = sprintf('%.2fs', totalTime);
    ps.apiUsed = apiUsed;
    ps.matlabVersion = sprintf('%.1f', verNum);
    ps.solverInfo = solverInfo;
    ps.blockCount = length(blockStats);
    ps.topBottlenecks = topBottlenecks;
    ps.suggestions = suggestions;
    ps.allBlockStats = blockStats;
    ps.profileData = struct();
    ps.profileData.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    ps.profileData.matlabVersion = sprintf('%.1f', verNum);
    ps.profileData.solverInfo = solverInfo;

    result.profileSim = ps;

    result.message = sprintf('Profile completed in %.2fs using %s (%d blocks, %d bottlenecks)', ...
        totalTime, apiUsed, length(blockStats), length(topBottlenecks));
end


function result = do_report(result, modelName, opts, verNum)
% DO_REPORT 返回上次 profile 结果的详细报告

    % 尝试获取上次的 profile 数据
    lastProfile = [];
    try
        profInfo = profile('info');
        if ~isempty(profInfo)
            lastProfile = profInfo;
        end
    catch
    end

    if isempty(lastProfile)
        result.status = 'error';
        result.error = 'No profile data available. Run sl_profile_sim with action=''run'' first.';
        result.message = result.error;
        return;
    end

    % 解析 profile 数据
    blockStats = parse_profile_data(lastProfile, modelName, 'profile_info');
    topBottlenecks = identify_bottlenecks(blockStats);
    suggestions = generate_suggestions(topBottlenecks, blockStats);

    % [FIX] 分步赋值，避免 struct 展开问题
    ps = struct();
    ps.action = 'report';
    ps.blockCount = length(blockStats);
    ps.topBottlenecks = topBottlenecks;
    ps.suggestions = suggestions;
    ps.allBlockStats = blockStats;

    result.profileSim = ps;

    result.message = sprintf('Profile report: %d blocks, %d bottlenecks', ...
        length(blockStats), length(topBottlenecks));
end


function result = do_compare(result, modelName, opts)
% DO_COMPARE 对比当前 profile 和 baseline profile

    if isempty(opts.baselineProfile) || ~isstruct(opts.baselineProfile)
        result.status = 'error';
        result.error = 'baselineProfile must be a struct with previous profile data';
        result.message = result.error;
        return;
    end

    % 运行当前 profile
    currentProfile = [];
    try
        currentProfile = run_with_profile(modelName);
    catch ME
        result.status = 'error';
        result.error = ['Current profile run failed: ' ME.message];
        result.message = result.error;
        return;
    end

    % 解析当前数据
    currentStats = parse_profile_data(currentProfile, modelName, 'profile_compare');

    % 解析 baseline 数据
    baselineStats = opts.baselineProfile;
    if isfield(baselineStats, 'allBlockStats')
        baselineStats = baselineStats.allBlockStats;
    end

    % 对比
    comparisons = {};
    for ci = 1:length(currentStats)
        curBlock = currentStats{ci};
        matched = false;
        for bi = 1:length(baselineStats)
            if iscell(baselineStats)
                baseBlock = baselineStats{bi};
            else
                baseBlock = baselineStats;
            end
            if ~isstruct(curBlock) || ~isstruct(baseBlock), continue; end
            if ~isfield(curBlock, 'blockPath') || ~isfield(baseBlock, 'blockPath'), continue; end
            if strcmp(curBlock.blockPath, baseBlock.blockPath)
                matched = true;
                curTime = 0; baseTime = 0;
                try curTime = curBlock.totalTime; catch, end
                try baseTime = baseBlock.totalTime; catch, end
                timeDiff = curTime - baseTime;
                if baseTime > 0
                    pctChange = (timeDiff / baseTime) * 100;
                else
                    pctChange = 0;
                end
                comp = struct();
                comp.blockPath = curBlock.blockPath;
                comp.currentTime = curTime;
                comp.baselineTime = baseTime;
                comp.timeDiff = timeDiff;
                comp.pctChange = pctChange;
                comp.change = ternary_str(timeDiff > 0, 'slower', ternary_str(timeDiff < 0, 'faster', 'unchanged'));
                comparisons{end+1} = comp; %#ok<AGROW>
                break;
            end
        end
        if ~matched
            curTime = 0;
            try curTime = curBlock.totalTime; catch, end
            comp = struct();
            comp.blockPath = curBlock.blockPath;
            comp.currentTime = curTime;
            comp.baselineTime = NaN;
            comp.timeDiff = NaN;
            comp.pctChange = NaN;
            comp.change = 'new_block';
            comparisons{end+1} = comp; %#ok<AGROW>
        end
    end

    % 按变化幅度排序
    if ~isempty(comparisons)
        pctChanges = zeros(1, length(comparisons));
        for ci = 1:length(comparisons)
            if ~isnan(comparisons{ci}.pctChange)
                pctChanges(ci) = abs(comparisons{ci}.pctChange);
            else
                pctChanges(ci) = 0;
            end
        end
        [~, sortIdx] = sort(pctChanges, 'descend');
        sortedComparisons = {};
        for si = 1:length(sortIdx)
            sortedComparisons{si} = comparisons{sortIdx(si)};
        end
        comparisons = sortedComparisons;
    end

    % [FIX] 分步赋值
    ps = struct();
    ps.action = 'compare';
    ps.comparisonCount = length(comparisons);
    ps.comparisons = comparisons;

    result.profileSim = ps;

    result.message = sprintf('Profile comparison: %d blocks compared', length(comparisons));
end


function profileData = run_with_profile(modelName)
% RUN_WITH_PROFILE 使用 MATLAB profile on/off 运行仿真并收集 profile 数据

    % 清除旧的 profile 数据
    try profile off; catch, end
    try profile clear; catch, end

    % 启动 profiler
    profile on;

    % 运行仿真
    try
        sim(modelName);
    catch ME
        try profile off; catch, end
        rethrow(ME);
    end

    % 停止 profiler
    profile off;

    % 获取 profile 数据
    profileData = profile('info');

    % 清理
    try profile clear; catch, end
end


function blockStats = parse_profile_data(profileData, modelName, apiUsed)
% PARSE_PROFILE_DATA 解析 profiler 结果，提取模块级统计
% [FIX] 鲁棒性改进：所有字段安全提取，不存在则用默认值

    blockStats = {};

    % 空数据保护
    if isempty(profileData)
        return;
    end

    if strcmpi(apiUsed, 'Simulink.profiler.run') && isstruct(profileData)
        % Simulink.profiler.run 的输出格式
        if isfield(profileData, 'blocks')
            blocks = profileData.blocks;
            for bi = 1:length(blocks)
                s = struct();
                s.blockPath = safe_get(blocks(bi), 'path', '');
                s.blockType = safe_get(blocks(bi), 'type', '');
                s.selfTime = safe_get(blocks(bi), 'selfTime', 0);
                s.totalTime = safe_get(blocks(bi), 'totalTime', 0);
                s.calls = safe_get(blocks(bi), 'calls', 0);
                blockStats{end+1} = s; %#ok<AGROW>
            end
        elseif isfield(profileData, 'ExecutionProfile')
            % 另一种输出格式
            try
                ep = profileData.ExecutionProfile;
                if isfield(ep, 'Children')
                    blockStats = parse_profile_children(ep.Children, modelName);
                end
            catch
            end
        end
        return;
    end

    % profile('info') 的输出格式（MATLAB Profiler）
    if isstruct(profileData) && isfield(profileData, 'FunctionTable')
        funcTable = profileData.FunctionTable;

        % 计算 totalTime（profile('info') 可能没有 TotalTime 字段）
        totalTime = 0;
        if isfield(profileData, 'TotalTime')
            try
                totalTime = profileData.TotalTime;
            catch
            end
        end
        if totalTime == 0
            % 从 FunctionTable 累加计算
            for fi = 1:length(funcTable)
                try
                    totalTime = totalTime + funcTable(fi).TotalTime;
                catch
                end
            end
        end

        for fi = 1:length(funcTable)
            func = funcTable(fi);
            funcName = '';
            try funcName = func.FunctionName; catch, end

            % 只关注与模型相关的函数
            if ~isempty(strfind(funcName, modelName)) || ...
               ~isempty(strfind(funcName, 'sim')) || ...
               ~isempty(strfind(funcName, 'Simulink'))

                s = struct();
                s.blockPath = funcName;
                s.blockType = 'unknown';
                try
                    s.selfTime = func.TotalTime - func.TotalRecursiveTime;
                catch
                    s.selfTime = 0;
                end
                try s.totalTime = func.TotalTime; catch, s.totalTime = 0; end
                try s.calls = func.NumCalls; catch, s.calls = 0; end

                if totalTime > 0
                    try
                        s.percentage = (func.TotalTime / totalTime) * 100;
                    catch
                        s.percentage = 0;
                    end
                else
                    s.percentage = 0;
                end

                % 尝试识别模块类型
                if ~isempty(strfind(funcName, 'MATLAB Function'))
                    s.blockType = 'MATLAB Function';
                elseif ~isempty(strfind(funcName, 'S-Function'))
                    s.blockType = 'S-Function';
                elseif ~isempty(strfind(funcName, 'Interpreted MATLAB Function'))
                    s.blockType = 'Interpreted MATLAB Function';
                end

                blockStats{end+1} = s; %#ok<AGROW>
            end
        end
    end

    % 如果 blockStats 为空，尝试从模型信息构建基本统计
    if isempty(blockStats)
        try
            blocks = find_system(modelName, 'SearchDepth', 1);
            for bi = 2:length(blocks) % 跳过模型自身
                s = struct();
                s.blockPath = blocks{bi};
                try
                    s.blockType = get_param(blocks{bi}, 'BlockType');
                catch
                    s.blockType = 'unknown';
                end
                s.selfTime = 0;
                s.totalTime = 0;
                s.calls = 0;
                s.percentage = 0;
                blockStats{end+1} = s; %#ok<AGROW>
            end
        catch
        end
    end
end


function blockStats = parse_profile_children(children, modelName)
% PARSE_PROFILE_CHILDREN 递归解析 profiler 子节点

    blockStats = {};
    for ci = 1:length(children)
        child = children(ci);
        s = struct();
        try s.blockPath = child.Name; catch, s.blockPath = ''; end
        s.blockType = 'unknown';
        try s.selfTime = child.ExclusiveTime; catch, s.selfTime = 0; end
        try s.totalTime = child.InclusiveTime; catch, s.totalTime = 0; end
        try s.calls = child.NumCalls; catch, s.calls = 0; end

        % 尝试匹配模型中的模块
        try
            if ~isempty(strfind(s.blockPath, modelName))
                parts = strsplit(s.blockPath, '/');
                for pi = 1:length(parts)
                    if ~isempty(find_system(modelName, 'SearchDepth', 1, 'Name', parts{pi}))
                        s.blockPath = fullfile(modelName, parts{pi});
                        try s.blockType = get_param(s.blockPath, 'BlockType'); catch, end
                        break;
                    end
                end
            end
        catch
        end

        blockStats{end+1} = s; %#ok<AGROW>

        % 递归
        if isfield(child, 'Children') && ~isempty(child.Children)
            subStats = parse_profile_children(child.Children, modelName);
            for si = 1:length(subStats)
                blockStats{end+1} = subStats{si}; %#ok<AGROW>
            end
        end
    end
end


function topBottlenecks = identify_bottlenecks(blockStats)
% IDENTIFY_BOTTLENECKS 识别瓶颈模块，按 totalTime 降序排列

    topBottlenecks = {};

    if isempty(blockStats)
        return;
    end

    % 计算总时间
    totalSimTime = 0;
    for bi = 1:length(blockStats)
        if isfield(blockStats{bi}, 'totalTime')
            try
                totalSimTime = totalSimTime + blockStats{bi}.totalTime;
            catch
            end
        end
    end

    if totalSimTime == 0
        return;
    end

    % 按 totalTime 降序排列
    times = zeros(1, length(blockStats));
    for bi = 1:length(blockStats)
        if isfield(blockStats{bi}, 'totalTime')
            try
                times(bi) = blockStats{bi}.totalTime;
            catch
            end
        end
    end
    [~, sortIdx] = sort(times, 'descend');

    % 取前 10 个
    maxBottlenecks = min(10, length(sortIdx));
    for bi = 1:maxBottlenecks
        idx = sortIdx(bi);
        bk = blockStats{idx};

        pct = 0;
        if isfield(bk, 'percentage')
            try pct = bk.percentage; catch, end
        elseif isfield(bk, 'totalTime') && totalSimTime > 0
            try pct = (bk.totalTime / totalSimTime) * 100; catch, end
        end

        if pct > 0.1 % 只报告占比 > 0.1% 的模块
            bottleneck = struct();
            bottleneck.blockPath = bk.blockPath;
            try bottleneck.blockType = bk.blockType; catch, bottleneck.blockType = 'unknown'; end
            try bottleneck.selfTime = sprintf('%.3fs', bk.selfTime); catch, bottleneck.selfTime = '0.000s'; end
            try bottleneck.totalTime = sprintf('%.3fs', bk.totalTime); catch, bottleneck.totalTime = '0.000s'; end
            bottleneck.percentage = round(pct * 10) / 10; % 保留1位小数
            try bottleneck.suggestion = get_block_suggestion(bk.blockType, pct); catch, bottleneck.suggestion = ''; end
            topBottlenecks{end+1} = bottleneck; %#ok<AGROW>
        end
    end
end


function suggestion = get_block_suggestion(blockType, percentage)
% GET_BLOCK_SUGGESTION 根据模块类型和占比给出优化建议

    suggestion = '';

    if isempty(blockType)
        return;
    end

    switch lower(blockType)
        case 'matlab function'
            if percentage > 20
                suggestion = 'Consider replacing with Simulink native blocks for better performance';
            elseif percentage > 10
                suggestion = 'Check if MATLAB Function can be simplified or replaced';
            end
        case 'interpreted matlab function'
            if percentage > 10
                suggestion = 'MUST replace with MATLAB Function block (Interpreted is much slower)';
            end
        case 's-function'
            if percentage > 15
                suggestion = 'Consider upgrading to Level-2 S-Function or replacing with MATLAB Function';
            end
        case {'integrator', 'discrete integrator'}
            if percentage > 25
                suggestion = 'High integration cost - consider fixed-step solver for real-time';
            end
        case 'solver'
            if percentage > 30
                suggestion = 'Consider using a fixed-step solver for real-time applications';
            end
        otherwise
            if percentage > 20
                suggestion = 'High execution time - investigate optimization opportunities';
            end
    end
end


function suggestions = generate_suggestions(topBottlenecks, blockStats)
% GENERATE_SUGGESTIONS 生成综合优化建议

    suggestions = {};

    % 基于瓶颈模块的建议
    for bi = 1:length(topBottlenecks)
        bk = topBottlenecks{bi};
        if ~isfield(bk, 'suggestion') || isempty(bk.suggestion)
            continue;
        end
        sg = struct();
        try
            sg.priority = ternary_str(bk.percentage > 20, 'high', 'medium');
        catch
            sg.priority = 'medium';
        end
        sg.blockPath = bk.blockPath;
        sg.suggestion = bk.suggestion;
        try sg.percentage = bk.percentage; catch, sg.percentage = 0; end
        suggestions{end+1} = sg; %#ok<AGROW>
    end

    % 基于整体模型特征的建议
    hasMATLABFunc = false;
    hasSFunc = false;
    hasInterpreted = false;
    for bi = 1:length(blockStats)
        try
            bt = lower(blockStats{bi}.blockType);
            if strcmp(bt, 'matlab function'), hasMATLABFunc = true; end
            if strcmp(bt, 's-function'), hasSFunc = true; end
            if strcmp(bt, 'interpreted matlab function'), hasInterpreted = true; end
        catch
        end
    end

    if hasInterpreted
        sg = struct();
        sg.priority = 'high';
        sg.blockPath = '';
        sg.suggestion = 'Model contains Interpreted MATLAB Function blocks - replace with MATLAB Function for 10-100x speedup';
        sg.percentage = 0;
        suggestions{end+1} = sg; %#ok<AGROW>
    end

    if hasSFunc
        sg = struct();
        sg.priority = 'medium';
        sg.blockPath = '';
        sg.suggestion = 'Model contains S-Functions - ensure they use TLC for code generation acceleration';
        sg.percentage = 0;
        suggestions{end+1} = sg; %#ok<AGROW>
    end
end


function val = safe_get(obj, field, default)
% SAFE_GET 安全获取对象字段，不存在或出错则返回默认值
    val = default;
    try
        if isstruct(obj) && isfield(obj, field)
            val = obj.(field);
        end
    catch
    end
end


function out = ternary_str(cond, trueVal, falseVal)
% TERNARY_STR 简单三目运算符（字符串版）
    if cond
        out = trueVal;
    else
        out = falseVal;
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
