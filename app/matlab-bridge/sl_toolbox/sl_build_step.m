function result = sl_build_step(modelName, varargin)
% SL_BUILD_STEP 标准建模步骤 — 操作+验证原子操作
%   result = sl_build_step('MyModel', 'steps', stepsStruct, ...)
%
%   将多步建模操作打包为原子执行，每步后自动验证。
%   AI 只需一次 API 调用即可完成"操作->验证->返回验证结果"的完整流程。
%
%   输入:
%     modelName      - 模型名称（必选）
%     'steps'        - struct 数组，每步操作定义:
%       .type        - 'add_block'/'add_line'/'set_param'/'delete'
%       .blockType   - 模块类型（add_block 时必填）
%       .blockPath   - 目标模块路径（set_param/delete/add_line 时使用）
%       .srcSpec     - 源端口规格 'BlockPath/portNum'（add_line 时必填）
%       .dstSpec     - 目标端口规格 'BlockPath/portNum'（add_line 时必填）
%       .params      - struct，参数键值对（set_param 时使用）
%       .position    - [l,b,r,t] 位置（add_block 时使用）
%     'verifyAfterEach' - 每步后验证，默认 true
%     'verifyAfterAll'  - 全部完成后验证，默认 true
%     'loadModelIfNot'  - 模型未加载时自动加载，默认 true
%
%   输出: struct
%     .status       - 'ok' 或 'error' 或 'partial'
%     .steps        - struct 数组，每步执行结果 + 验证结果
%     .verification - 最终验证结果 struct（verifyAfterAll 时）
%     .error        - 错误信息

    % ===== 默认参数 =====
    opts = struct();
    opts.steps = [];
    opts.verifyAfterEach = true;
    opts.verifyAfterAll = true;
    opts.loadModelIfNot = true;

    % ===== 解析 varargin =====
    i = 1;
    while i <= length(varargin)
        key = varargin{i};
        if ischar(key) || isstring(key)
            key = char(key);
            switch lower(key)
                case 'steps'
                    if i+1 <= length(varargin)
                        opts.steps = varargin{i+1};
                        i = i + 2;
                    else
                        result = struct('status', 'error', 'error', 'steps value missing');
                        return;
                    end
                case 'verifyaftereach'
                    if i+1 <= length(varargin)
                        opts.verifyAfterEach = varargin{i+1};
                        i = i + 2;
                    else
                        i = i + 1;
                    end
                case 'verifyafterall'
                    if i+1 <= length(varargin)
                        opts.verifyAfterAll = varargin{i+1};
                        i = i + 2;
                    else
                        i = i + 1;
                    end
                case 'loadmodelifnot'
                    if i+1 <= length(varargin)
                        opts.loadModelIfNot = varargin{i+1};
                        i = i + 2;
                    else
                        i = i + 1;
                    end
                otherwise
                    i = i + 1;
            end
        else
            i = i + 1;
        end
    end

    % ===== 前置检查 =====
    if isempty(opts.steps)
        result = struct('status', 'error', 'error', 'No steps provided');
        return;
    end

    % 确保模型已加载
    if opts.loadModelIfNot
        try
            loaded = find_system('Type', 'BlockDiagram');
            if ~any(strcmp(loaded, modelName))
                load_system(modelName);
            end
        catch
            result = struct('status', 'error', 'error', ['Cannot load model: ' modelName]);
            return;
        end
    end

    % ===== 逐步执行 =====
    stepResults = {};
    hasError = false;
    errorStep = 0;

    for si = 1:length(opts.steps)
        step = opts.steps(si);
        stepType = lower(char(step.type));
        stepResult = struct('stepIndex', si, 'type', stepType, 'status', 'pending');

        try
            switch stepType
                case 'add_block'
                    % 调用 sl_add_block_safe
                    srcBlock = char(step.blockType);
                    nv = {};
                    if isfield(step, 'blockPath') && ~isempty(char(step.blockPath))
                        nv{end+1} = 'destPath'; nv{end+1} = char(step.blockPath);
                    end
                    if isfield(step, 'position') && ~isempty(step.position)
                        nv{end+1} = 'position'; nv{end+1} = step.position;
                    end
                    if isfield(step, 'params') && ~isempty(step.params)
                        nv{end+1} = 'params'; nv{end+1} = step.params;
                    end
                    stepResult.operation = sl_add_block_safe(modelName, srcBlock, nv{:});

                case 'add_line'
                    % 调用 sl_add_line_safe
                    srcSpec = char(step.srcSpec);
                    dstSpec = char(step.dstSpec);
                    nv = {};
                    if isfield(step, 'autoRouting')
                        nv{end+1} = 'autoRouting'; nv{end+1} = step.autoRouting;
                    end
                    stepResult.operation = sl_add_line_safe(modelName, srcSpec, dstSpec, nv{:});

                case 'set_param'
                    % 调用 sl_set_param_safe
                    bPath = char(step.blockPath);
                    params = step.params;
                    if isempty(params)
                        params = struct();
                    end
                    stepResult.operation = sl_set_param_safe(bPath, params);

                case 'delete'
                    % 调用 sl_delete_safe
                    bPath = char(step.blockPath);
                    stepResult.operation = sl_delete_safe(bPath);

                otherwise
                    stepResult.status = 'error';
                    stepResult.error = ['Unknown step type: ' stepType];
            end

            % 检查操作结果
            if isfield(stepResult, 'operation') && isfield(stepResult.operation, 'status')
                stepResult.status = stepResult.operation.status;
                if strcmp(stepResult.operation.status, 'error')
                    hasError = true;
                    errorStep = si;
                end
            end

            % 每步后验证
            if opts.verifyAfterEach && ~hasError
                try
                    stepResult.verification = sl_model_status_snapshot(modelName, 'format', 'comment', 'depth', 1, 'includeParams', false, 'includeLines', true);
                    % 检查未连接端口
                    if isfield(stepResult.verification, 'unconnectedPorts')
                        unconnCount = length(stepResult.verification.unconnectedPorts);
                        stepResult.unconnectedPortCount = unconnCount;
                        if unconnCount > 0
                            stepResult.verificationNote = [num2str(unconnCount) ' unconnected port(s) remain'];
                        end
                    end
                catch
                    stepResult.verification = struct('status', 'skipped', 'error', 'Verification failed');
                end
            end

        catch ME
            stepResult.status = 'error';
            stepResult.error = ME.message;
            hasError = true;
            errorStep = si;
        end

        stepResults{end+1} = stepResult;

        % 出错后停止执行后续步骤
        if hasError
            break;
        end
    end

    % ===== 全部完成后验证 =====
    finalVerification = [];
    if opts.verifyAfterAll && ~hasError
        try
            finalVerification = sl_model_status_snapshot(modelName, 'format', 'comment', 'depth', 0, 'includeParams', false, 'includeLines', true);
        catch
            finalVerification = struct('status', 'skipped', 'error', 'Final verification failed');
        end
    end

    % ===== 构建返回结果 =====
    if hasError
        result = struct( ...
            'status', 'partial', ...
            'steps', stepResults, ...
            'completedSteps', errorStep - 1, ...
            'failedStep', errorStep, ...
            'verification', finalVerification, ...
            'error', ['Step ' num2str(errorStep) ' failed']);
    else
        result = struct( ...
            'status', 'ok', ...
            'steps', stepResults, ...
            'completedSteps', length(opts.steps), ...
            'failedStep', 0, ...
            'verification', finalVerification);
    end
end
