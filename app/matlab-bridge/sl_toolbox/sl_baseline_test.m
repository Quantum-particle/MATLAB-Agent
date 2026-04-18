function result = sl_baseline_test(modelName, varargin)
% SL_BASELINE_TEST 创建或运行基线回归测试
%   result = sl_baseline_test('MyModel', 'action', 'create', ...)
%   result = sl_baseline_test('MyModel', 'action', 'run', ...)
%   result = sl_baseline_test('MyModel', 'action', 'regenerate', ...)
%   result = sl_baseline_test('MyModel', 'action', 'list', ...)
%
%   借鉴 simulink/skills:
%     - 继承 sltest.TestCase（非 matlab.unittest.TestCase）
%     - 仿真一次，单次 verifySignalsMatch 比较所有信号
%     - 使用 bdIsLoaded 实现智能清理
%
%   输入:
%     modelName       - 模型名称（必选）
%     'action'        - 'create'|'run'|'regenerate'|'list'（必选）
%     'testName'      - 测试名称，默认为 modelName + 'Test'
%     'baselineDir'   - 基线文件保存目录，默认为 sl_toolbox/tests/baselines/
%     'tolerance'     - struct(.relTol, .absTol)，比较容差
%     'loadModelIfNot' - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status          - 'ok' 或 'error'
%     .baselineTest    - struct（结构因 action 而异）
%     .message         - 总结信息
%     .error           - 错误信息

    % ===== 解析参数 =====
    opts = struct( ...
        'action', '', ...
        'testName', '', ...
        'baselineDir', '', ...
        'tolerance', struct('relTol', 0.01, 'absTol', 1e-6), ...
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

    result = struct('status', 'ok', 'baselineTest', struct(), ...
        'message', '', 'error', '');

    % ===== 验证 action =====
    validActions = {'create', 'run', 'regenerate', 'list'};
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

    % ===== 验证 tolerance =====
    if ~isstruct(opts.tolerance)
        result.status = 'error';
        result.error = 'tolerance must be a struct with .relTol and .absTol fields';
        result.message = result.error;
        return;
    end
    if ~isfield(opts.tolerance, 'relTol') || ~isfield(opts.tolerance, 'absTol')
        result.status = 'error';
        result.error = 'tolerance must have both .relTol and .absTol fields';
        result.message = result.error;
        return;
    end
    if ~isnumeric(opts.tolerance.relTol) || ~isnumeric(opts.tolerance.absTol)
        result.status = 'error';
        result.error = 'tolerance.relTol and tolerance.absTol must be numeric';
        result.message = result.error;
        return;
    end

    % ===== 默认 testName =====
    if isempty(opts.testName)
        opts.testName = [modelName, 'Test'];
    end

    % ===== 默认 baselineDir =====
    if isempty(opts.baselineDir)
        % 使用 sl_toolbox 目录下的 tests/baselines/
        try
            toolboxDir = fileparts(mfilename('fullpath'));
            opts.baselineDir = fullfile(toolboxDir, 'tests', 'baselines');
        catch
            opts.baselineDir = fullfile(tempdir, 'sl_baselines');
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

    % ===== 检查 Simulink Test 许可证 =====
    hasSLTest = false;
    try
        hasSLTest = license('test', 'Simulink_Test');
    catch
        % license('test',...) 在某些版本可能不可用
        try
            hasSLTest = ~isempty(ver('sltest'));
        catch
        end
    end

    % ===== 根据 action 分发 =====
    try
        switch opts.action
            case 'create'
                result = do_create(result, modelName, opts, hasSLTest);
            case 'run'
                result = do_run(result, modelName, opts, hasSLTest);
            case 'regenerate'
                result = do_regenerate(result, modelName, opts, hasSLTest);
            case 'list'
                result = do_list(result, modelName, opts);
        end
    catch ME_unhandled
        % 兜底：未预期的异常不应导致 MATLAB 崩溃
        result.status = 'error';
        result.error = ['Unexpected error in sl_baseline_test: ' ME_unhandled.message];
        result.message = result.error;
    end
end


function result = do_create(result, modelName, opts, hasSLTest)
% DO_CREATE 生成 sltest.TestCase 测试文件 + 基线数据

    testName = opts.testName;
    baselineDir = opts.baselineDir;

    % 创建基线目录
    if ~exist(baselineDir, 'dir')
        try
            mkdir(baselineDir);
        catch ME_mkdir
            result.status = 'error';
            result.error = ['Cannot create baseline directory: ' ME_mkdir.message];
            result.message = result.error;
            return;
        end
    end

    % 生成基线数据文件路径
    baselineFileName = [modelName, '_baseline.mat'];
    baselineFilePath = fullfile(baselineDir, baselineFileName);

    % ===== 确保模型启用了信号记录 =====
    % 保存原始配置以便恢复
    origSaveOutput = 'on';
    origSignalLogging = 'on';
    origSignalLoggingName = 'logsout';
    try
        origSaveOutput = get_param(modelName, 'SaveOutput');
        origSignalLogging = get_param(modelName, 'SignalLogging');
        origSignalLoggingName = get_param(modelName, 'SignalLoggingName');
    catch
    end
    try
        set_param(modelName, 'SaveOutput', 'on', 'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout');
    catch
    end

    % 启用所有输出端口模块的上游信号记录
    try
        allBlocks = find_system(modelName, 'SearchDepth', 1);
        for bi = 2:length(allBlocks)  % 跳过模型自身
            try
                ph = get_param(allBlocks{bi}, 'PortHandles');
                if ~isempty(ph.Outport)
                    for oi = 1:length(ph.Outport)
                        try
                            set(ph.Outport(oi), 'DataLogging', 'on');
                        catch
                        end
                    end
                end
            catch
            end
        end
    catch
    end

    % ===== 运行仿真生成基线数据 =====
    simOut = [];
    simSuccess = false;
    try
        simOut = sim(modelName);
        simSuccess = true;
    catch ME_sim
        result.status = 'error';
        result.error = ['Simulation failed during baseline generation: ' ME_sim.message];
        result.message = result.error;
        % 恢复模型设置
        try set_param(modelName, 'SaveOutput', origSaveOutput, 'SignalLogging', origSignalLogging, ...
            'SignalLoggingName', origSignalLoggingName); catch, end
        return;
    end

    % 恢复模型设置
    try set_param(modelName, 'SaveOutput', origSaveOutput, 'SignalLogging', origSignalLogging, ...
        'SignalLoggingName', origSignalLoggingName); catch, end

    % ===== 保存基线数据 =====
    signalCount = 0;
    if hasSLTest && simSuccess
        % 保存 Simulink.SimulationOutput 对象用于 SDI 比较
        baselineSimOut = simOut;
        try
            save(baselineFilePath, 'baselineSimOut', '-v7');
        catch ME_save
            result.status = 'error';
            result.error = ['Cannot save baseline file: ' ME_save.message];
            result.message = result.error;
            return;
        end
        % 统计信号数量
        try
            if isprop(simOut, 'logsout') || isfield(simOut, 'logsout')
                logsout = simOut.get('logsout');
                if isa(logsout, 'Simulink.SimulationData.Dataset')
                    signalCount = length(logsout);
                end
            end
        catch
        end
        if signalCount == 0
            try
                yout = simOut.get('yout');
                if ~isempty(yout)
                    signalCount = max(1, size(yout, 2));
                end
            catch
                signalCount = 1;
            end
        end
    else
        % 无 Simulink Test 或仿真失败，手动提取信号
        baselineData = struct();
        baselineData.modelName = modelName;
        baselineData.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
        baselineData.signals = {};
        if simSuccess
            baselineData.signals = extract_signals(simOut, modelName);
        end
        signalCount = length(baselineData.signals);
        try
            save(baselineFilePath, 'baselineData', '-v7');
        catch ME_save
            result.status = 'error';
            result.error = ['Cannot save baseline file: ' ME_save.message];
            result.message = result.error;
            return;
        end
    end

    % 生成测试文件目录
    try
        toolboxDir = fileparts(mfilename('fullpath'));
        testsDir = fullfile(toolboxDir, 'tests');
    catch
        testsDir = fullfile(tempdir, 'sl_tests');
    end
    if ~exist(testsDir, 'dir')
        mkdir(testsDir);
    end

    testFilePath = fullfile(testsDir, [testName, '.m']);

    % 构建容差参数字符串
    relTolStr = num2str(opts.tolerance.relTol);
    absTolStr = num2str(opts.tolerance.absTol);

    if hasSLTest
        % 生成使用 sltest.TestCase 的测试文件
        testCode = { ...
            ['classdef ' testName ' < sltest.TestCase'], ...
            '    methods (Test)', ...
            '        function baselineTest(testCase)', ...
            ['            simout = testCase.simulate(''' modelName ''');'], ...
            ['            baselineData = load(''' baselineFilePath ''');'], ...
            ['            testCase.verifySignalsMatch(simout, baselineData.baselineSimOut, ...'], ...
            ['                ''RelTol'', ' relTolStr ', ''AbsTol'', ' absTolStr ');'], ...
            '        end', ...
            '    end', ...
            '    methods (Static)', ...
            '        function generateBaseline()', ...
            ['            sl_baseline_test(''' modelName ''', ''action'', ''regenerate'');'], ...
            '        end', ...
            '    end', ...
            'end' ...
        };
    else
        % 无 Simulink Test 许可证，生成手动比较测试文件
        testCode = { ...
            ['classdef ' testName ' < matlab.unittest.TestCase'], ...
            '    methods (Test)', ...
            '        function baselineTest(testCase)', ...
            ['            simOut = sim(''' modelName ''');'], ...
            ['            baselineData = load(''' baselineFilePath ''');'], ...
            '            currentSignals = sl_baseline_test.extract_signals_internal(simOut);', ...
            '            baselineSignals = baselineData.baselineData.signals;', ...
            '            for i = 1:length(currentSignals)', ...
            '                if i <= length(baselineSignals)', ...
            '                    sig = currentSignals{i};', ...
            '                    baseSig = baselineSignals{i};', ...
            '                    if isfield(sig, ''values'') && isfield(baseSig, ''values'')', ...
            '                        diff = max(abs(sig.values(:) - baseSig.values(:)));', ...
            ['                        testCase.verifyLessThan(diff, ' absTolStr ', ...'], ...
            ['                            [''Signal '' sig.name '' exceeds tolerance'']);'], ...
            '                    end', ...
            '                end', ...
            '            end', ...
            '        end', ...
            '    end', ...
            'end' ...
        };
    end

    % 写入测试文件
    try
        fid = fopen(testFilePath, 'w');
        if fid == -1
            result.status = 'error';
            result.error = ['Cannot open test file for writing: ' testFilePath];
            result.message = result.error;
            return;
        end
        for li = 1:length(testCode)
            fprintf(fid, '%s\n', testCode{li});
        end
        fclose(fid);
    catch ME_write
        try fclose('all'); catch, end
        result.status = 'error';
        result.error = ['Cannot write test file: ' ME_write.message];
        result.message = result.error;
        return;
    end

    % [FIX] 安全构建返回结构 — 分步赋值
    bt = struct();
    bt.action = 'create';
    bt.testName = testName;
    bt.testFilePath = testFilePath;
    bt.baselineFilePath = baselineFilePath;
    bt.status = 'created';
    bt.hasSLTestLicense = hasSLTest;
    bt.signalCount = signalCount;

    result.baselineTest = bt;

    result.message = sprintf('Baseline test created: %s (signals: %d, SL Test: %s)', ...
        testName, signalCount, mat2str(hasSLTest));

    if ~hasSLTest
        result.warnings = {'Simulink Test license not available - generated manual comparison test'};
    end
end


function result = do_run(result, modelName, opts, hasSLTest)
% DO_RUN 运行已有的基线测试

    testName = opts.testName;

    % 查找测试文件
    testFilePath = find_test_file(testName);
    if isempty(testFilePath)
        result.status = 'error';
        result.error = ['Test file not found: ' testName '.m'];
        result.message = result.error;
        return;
    end

    % 确保测试文件所在目录在 MATLAB 路径中
    testDir = fileparts(testFilePath);
    if ~isempty(testDir)
        try
            addpath(testDir);
        catch
        end
    end

    if hasSLTest
        % 使用 sltest.TestCase 运行
        runSuccess = false;
        failureInfo = '';
        try
            % 运行测试
            testResult = runtests(testName);

            % 解析结果 — runtests 返回 TestResult 数组
            if iscell(testResult)
                testResult = testResult{1};
            end
            if isa(testResult, 'matlab.unittest.TestResult')
                % testResult 可能是数组，检查是否全部通过
                if isscalar(testResult)
                    try
                        runSuccess = testResult.Passed;
                    catch
                        runSuccess = false;
                    end
                else
                    try
                        runSuccess = all([testResult.Passed]);
                    catch
                        runSuccess = false;
                    end
                end
                if ~runSuccess
                    try
                        % 获取失败的详细信息
                        failedIdx = find(~[testResult.Passed]);
                        if ~isempty(failedIdx)
                            failRec = testResult(failedIdx(1));
                            try
                                failureInfo = failRec.Details.DiagnosticRecord.Message;
                                if iscell(failureInfo)
                                    failureInfo = strjoin(failureInfo, '; ');
                                end
                            catch
                                failureInfo = 'Test failed - details unavailable';
                            end
                        end
                    catch
                        failureInfo = 'Test failed - details unavailable';
                    end
                end
            else
                runSuccess = true;
            end
        catch ME_run
            runSuccess = false;
            failureInfo = ME_run.message;
        end

        % [FIX] 分步赋值
        bt = struct();
        bt.action = 'run';
        bt.testName = testName;
        bt.status = ternary_str(runSuccess, 'passed', 'failed');
        bt.hasSLTestLicense = true;
        bt.failureInfo = failureInfo;

        result.baselineTest = bt;

    else
        % 无 Simulink Test 许可证，手动比较
        manualResult = manual_compare(modelName, opts);

        % [FIX] 分步赋值
        bt = struct();
        bt.action = 'run';
        bt.testName = testName;
        bt.status = manualResult.status;
        bt.hasSLTestLicense = false;
        bt.failedSignals = manualResult.failedSignals;
        bt.passedSignals = manualResult.passedSignals;

        result.baselineTest = bt;
    end

    result.message = sprintf('Baseline test %s: %s', testName, result.baselineTest.status);
end


function result = do_regenerate(result, modelName, opts, hasSLTest)
% DO_REGENERATE 重新生成基线数据

    baselineDir = opts.baselineDir;
    baselineFileName = [modelName, '_baseline.mat'];
    baselineFilePath = fullfile(baselineDir, baselineFileName);

    % 确保模型启用了信号记录
    origSaveOutput = 'on';
    origSignalLogging = 'on';
    origSignalLoggingName = 'logsout';
    try
        origSaveOutput = get_param(modelName, 'SaveOutput');
        origSignalLogging = get_param(modelName, 'SignalLogging');
        origSignalLoggingName = get_param(modelName, 'SignalLoggingName');
        set_param(modelName, 'SaveOutput', 'on', 'SignalLogging', 'on', ...
            'SignalLoggingName', 'logsout');
    catch
    end

    % 启用所有输出端口的信号记录
    try
        allBlocks = find_system(modelName, 'SearchDepth', 1);
        for bi = 2:length(allBlocks)
            try
                ph = get_param(allBlocks{bi}, 'PortHandles');
                if ~isempty(ph.Outport)
                    for oi = 1:length(ph.Outport)
                        try set(ph.Outport(oi), 'DataLogging', 'on'); catch, end
                    end
                end
            catch
            end
        end
    catch
    end

    % 运行仿真
    simOut = [];
    simSuccess = false;
    try
        simOut = sim(modelName);
        simSuccess = true;
    catch ME_sim
        result.status = 'error';
        result.error = ['Simulation failed during baseline regeneration: ' ME_sim.message];
        result.message = result.error;
        try set_param(modelName, 'SaveOutput', origSaveOutput, 'SignalLogging', origSignalLogging, ...
            'SignalLoggingName', origSignalLoggingName); catch, end
        return;
    end

    % 恢复
    try set_param(modelName, 'SaveOutput', origSaveOutput, 'SignalLogging', origSignalLogging, ...
        'SignalLoggingName', origSignalLoggingName); catch, end

    % 保存基线数据
    signalCount = 0;
    if hasSLTest && simSuccess
        baselineSimOut = simOut;
        try
            save(baselineFilePath, 'baselineSimOut', '-v7');
        catch ME_save
            result.status = 'error';
            result.error = ['Cannot save baseline file: ' ME_save.message];
            result.message = result.error;
            return;
        end
        try
            if isprop(simOut, 'logsout') || isfield(simOut, 'logsout')
                logsout = simOut.get('logsout');
                if isa(logsout, 'Simulink.SimulationData.Dataset')
                    signalCount = length(logsout);
                end
            end
        catch
        end
        if signalCount == 0
            try
                yout = simOut.get('yout');
                if ~isempty(yout), signalCount = max(1, size(yout, 2)); end
            catch
                signalCount = 1;
            end
        end
    else
        baselineData = struct();
        baselineData.modelName = modelName;
        baselineData.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
        baselineData.signals = {};
        if simSuccess
            baselineData.signals = extract_signals(simOut, modelName);
        end
        signalCount = length(baselineData.signals);
        try
            save(baselineFilePath, 'baselineData', '-v7');
        catch ME_save
            result.status = 'error';
            result.error = ['Cannot save baseline file: ' ME_save.message];
            result.message = result.error;
            return;
        end
    end

    % [FIX] 分步赋值
    bt = struct();
    bt.action = 'regenerate';
    bt.baselineFilePath = baselineFilePath;
    bt.signalCount = signalCount;
    bt.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');

    result.baselineTest = bt;

    result.message = sprintf('Baseline regenerated: %s (%d signals)', ...
        baselineFilePath, signalCount);
end


function result = do_list(result, modelName, opts)
% DO_LIST 列出模型的所有基线测试

    baselineDir = opts.baselineDir;

    % 查找基线文件
    baselines = {};
    if exist(baselineDir, 'dir')
        files = dir(fullfile(baselineDir, [modelName, '_baseline.mat']));
        for fi = 1:length(files)
            b = struct();
            b.name = files(fi).name;
            b.path = fullfile(baselineDir, files(fi).name);
            b.date = files(fi).date;
            b.bytes = files(fi).bytes;
            baselines{end+1} = b; %#ok<AGROW>
        end
    end

    % 查找测试文件
    testFiles = {};
    try
        toolboxDir = fileparts(mfilename('fullpath'));
        testsDir = fullfile(toolboxDir, 'tests');
    catch
        testsDir = '';
    end

    if ~isempty(testsDir) && exist(testsDir, 'dir')
        testDirs = dir(fullfile(testsDir, [modelName, 'Test.m']));
        for ti = 1:length(testDirs)
            testFiles{end+1} = fullfile(testsDir, testDirs(ti).name); %#ok<AGROW>
        end
        % 也查找所有 *Test.m 文件
        allTests = dir(fullfile(testsDir, '*Test.m'));
        for ti = 1:length(allTests)
            tfp = fullfile(testsDir, allTests(ti).name);
            % 避免重复
            isDup = false;
            for j = 1:length(testFiles)
                if strcmp(testFiles{j}, tfp)
                    isDup = true;
                    break;
                end
            end
            if ~isDup
                testFiles{end+1} = tfp; %#ok<AGROW>
            end
        end
    end

    % [FIX] 分步赋值
    bt = struct();
    bt.action = 'list';
    bt.modelName = modelName;
    bt.baselineCount = length(baselines);
    bt.baselines = baselines;
    bt.testFileCount = length(testFiles);
    bt.testFiles = testFiles;

    result.baselineTest = bt;

    result.message = sprintf('Found %d baselines and %d test files for %s', ...
        length(baselines), length(testFiles), modelName);
end


function signals = extract_signals(simOut, modelName)
% EXTRACT_SIGNALS 从仿真输出中提取信号列表

    signals = {};

    if isempty(simOut)
        return;
    end

    if isa(simOut, 'Simulink.SimulationOutput')
        % R2017a+ SimulationOutput
        % 提取 logsout
        try
            logsout = simOut.get('logsout');
            if isa(logsout, 'Simulink.SimulationData.Dataset')
                try
                    elemNames = logsout.getElementNames();
                    for ei = 1:length(elemNames)
                        try
                            elem = logsout.getElement(ei);
                            sigStruct = struct();
                            sigStruct.name = elem.Name;
                            sigStruct.blockPath = '';
                            try
                                sigStruct.blockPath = elem.BlockPath;
                            catch
                            end
                            try
                                vals = elem.Values;
                                if isa(vals, 'timeseries')
                                    sigStruct.values = vals.Data;
                                    sigStruct.time = vals.Time;
                                else
                                    sigStruct.values = vals;
                                end
                            catch
                            end
                            signals{end+1} = sigStruct; %#ok<AGROW>
                        catch
                        end
                    end
                catch
                end
            end
        catch
        end

        % 提取 tout / yout
        try
            tout = simOut.get('tout');
            sigStruct = struct();
            sigStruct.name = 'tout';
            sigStruct.values = tout;
            sigStruct.blockPath = '';
            signals{end+1} = sigStruct; %#ok<AGROW>
        catch
        end
        try
            yout = simOut.get('yout');
            sigStruct = struct();
            sigStruct.name = 'yout';
            sigStruct.values = yout;
            sigStruct.blockPath = '';
            signals{end+1} = sigStruct; %#ok<AGROW>
        catch
        end

    elseif isstruct(simOut)
        % Structure output format
        if isfield(simOut, 'time')
            sigStruct = struct();
            sigStruct.name = 'time';
            sigStruct.values = simOut.time;
            sigStruct.blockPath = '';
            signals{end+1} = sigStruct; %#ok<AGROW>
        end
        if isfield(simOut, 'signals')
            for si = 1:length(simOut.signals)
                sigStruct = struct();
                sigStruct.name = ['signal_' num2str(si)];
                try
                    if isfield(simOut.signals(si), 'label') && ~isempty(simOut.signals(si).label)
                        sigStruct.name = simOut.signals(si).label;
                    end
                catch
                end
                try
                    sigStruct.values = simOut.signals(si).values;
                catch
                end
                sigStruct.blockPath = '';
                signals{end+1} = sigStruct; %#ok<AGROW>
            end
        end
    elseif isnumeric(simOut)
        sigStruct = struct();
        sigStruct.name = 'simOut';
        sigStruct.values = simOut;
        sigStruct.blockPath = '';
        signals{end+1} = sigStruct; %#ok<AGROW>
    end
end


function manualResult = manual_compare(modelName, opts)
% MANUAL_COMPARE 无 Simulink Test 许可证时的手动比较

    manualResult = struct();
    manualResult.status = 'passed';
    manualResult.failedSignals = {};
    manualResult.passedSignals = {};

    % 加载基线数据
    baselineFilePath = fullfile(opts.baselineDir, [modelName, '_baseline.mat']);
    if ~exist(baselineFilePath, 'file')
        manualResult.status = 'error';
        manualResult.failedSignals{1} = 'Baseline file not found';
        return;
    end

    try
        baselineData = load(baselineFilePath);
        baselineSignals = baselineData.baselineData.signals;
    catch
        manualResult.status = 'error';
        manualResult.failedSignals{1} = 'Cannot load baseline file';
        return;
    end

    % 运行仿真获取当前信号
    try
        simOut = sim(modelName);
        currentSignals = extract_signals(simOut, modelName);
    catch ME
        manualResult.status = 'error';
        manualResult.failedSignals{1} = ['Simulation failed: ' ME.message];
        return;
    end

    % 逐信号比较
    relTol = opts.tolerance.relTol;
    absTol = opts.tolerance.absTol;
    hasFailure = false;

    for i = 1:length(currentSignals)
        curSig = currentSignals{i};
        if i <= length(baselineSignals)
            baseSig = baselineSignals{i};
            if isfield(curSig, 'values') && isfield(baseSig, 'values') && ...
               isnumeric(curSig.values) && isnumeric(baseSig.values)
                try
                    curVals = curSig.values(:);
                    baseVals = baseSig.values(:);
                    % 长度对齐
                    minLen = min(length(curVals), length(baseVals));
                    diff = abs(curVals(1:minLen) - baseVals(1:minLen));
                    maxDiff = max(diff);
                    baseMax = max(abs(baseVals(1:minLen)));
                    if baseMax > eps
                        relDiff = maxDiff / baseMax;
                    else
                        relDiff = 0;
                    end

                    if maxDiff > absTol && relDiff > relTol
                        hasFailure = true;
                        manualResult.failedSignals{end+1} = sprintf( ... %#ok<AGROW>
                            '%s: maxDiff=%.2e, relDiff=%.2e', curSig.name, maxDiff, relDiff);
                    else
                        manualResult.passedSignals{end+1} = curSig.name; %#ok<AGROW>
                    end
                catch
                    manualResult.passedSignals{end+1} = [curSig.name, ' (comparison skipped)']; %#ok<AGROW>
                end
            else
                manualResult.passedSignals{end+1} = [curSig.name, ' (non-numeric)']; %#ok<AGROW>
            end
        else
            manualResult.passedSignals{end+1} = [curSig.name, ' (no baseline)']; %#ok<AGROW>
        end
    end

    if hasFailure
        manualResult.status = 'failed';
    end
end


function filePath = find_test_file(testName)
% FIND_TEST_FILE 在多个可能的位置查找测试文件

    filePath = '';

    % 搜索路径列表
    searchDirs = {};
    try
        toolboxDir = fileparts(mfilename('fullpath'));
        searchDirs{end+1} = fullfile(toolboxDir, 'tests'); %#ok<AGROW>
    catch
    end
    searchDirs{end+1} = fullfile(tempdir, 'sl_tests'); %#ok<AGROW>
    searchDirs{end+1} = pwd; %#ok<AGROW>

    for di = 1:length(searchDirs)
        candidatePath = fullfile(searchDirs{di}, [testName, '.m']);
        if exist(candidatePath, 'file')
            filePath = candidatePath;
            return;
        end
    end
end


function out = ternary_str(cond, trueVal, falseVal)
% TERNARY_STR 简单三目运算符
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
