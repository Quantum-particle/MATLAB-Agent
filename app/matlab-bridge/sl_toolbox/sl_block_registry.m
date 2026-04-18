function path = sl_block_registry(shortName)
% SL_BLOCK_REGISTRY Simulink 模块库路径注册表
%   path = sl_block_registry('Step') → 'simulink/Sources/Step'
%
%   版本策略：高版本优先
%     所有版本：先查内置注册表（60+ 常用模块）→ 大小写不敏感匹配 → 库搜索回退
%     R2022b+: find_system 搜索选项更丰富
%     R2016a:  基本 find_system 回退
%
%   覆盖 12 大库 70+ 常用模块。
%   如果 shortName 不在注册表中，自动在 Simulink 库中模糊搜索。

    persistent registry;
    if isempty(registry)
        registry = build_registry();
    end
    
    % 1. 精确查询（区分大小写，最快）
    if registry.isKey(shortName)
        path = registry(shortName);
        return;
    end
    
    % 2. 大小写不敏感匹配
    allKeys = registry.keys;
    for i = 1:length(allKeys)
        if strcmpi(allKeys{i}, shortName)
            path = registry(allKeys{i});
            return;
        end
    end
    
    % 3. 包含匹配（部分名称匹配，如 'PID' 可匹配 'PID Controller'）
    for i = 1:length(allKeys)
        if contains_ci(allKeys{i}, shortName)
            path = registry(allKeys{i});
            return;
        end
    end
    
    % 4. 搜索 Simulink 库（最慢，最后回退）
    path = sl_search_block_library(shortName);
end

function found = contains_ci(str, pattern)
% 大小写不敏感的包含检查
% R2016a 兼容：不使用 contains() 函数（R2016b+ 才有）
    found = ~isempty(strfind(lower(str), lower(pattern)));
end

function registry = build_registry()
% 构建模块路径注册表
    registry = containers.Map();
    
    % ===== 信号源 (Sources) =====
    registry('Step') = 'simulink/Sources/Step';
    registry('Sine Wave') = 'simulink/Sources/Sine Wave';
    registry('Constant') = 'simulink/Sources/Constant';
    registry('Ramp') = 'simulink/Sources/Ramp';
    registry('Pulse Generator') = 'simulink/Sources/Pulse Generator';
    registry('Signal Generator') = 'simulink/Sources/Signal Generator';
    registry('From Workspace') = 'simulink/Sources/From Workspace';
    registry('Random Number') = 'simulink/Sources/Random Number';
    registry('Band-Limited White Noise') = 'simulink/Sources/Band-Limited White Noise';
    registry('Clock') = 'simulink/Sources/Clock';
    registry('Repeating Sequence') = 'simulink/Sources/Repeating Sequence';
    registry('Ground') = 'simulink/Sources/Ground';
    registry('Chirp Signal') = 'simulink/Sources/Chirp Signal';
    
    % ===== 信号接收 (Sinks) =====
    registry('Scope') = 'simulink/Sinks/Scope';
    registry('To Workspace') = 'simulink/Sinks/To Workspace';
    registry('Display') = 'simulink/Sinks/Display';
    registry('To File') = 'simulink/Sinks/To File';
    registry('XY Graph') = 'simulink/Sinks/XY Graph';
    registry('Floating Scope') = 'simulink/Sinks/Floating Scope';
    registry('Terminator') = 'simulink/Sinks/Terminator';
    registry('Out1') = 'simulink/Sinks/Out1';
    
    % ===== 数学运算 (Math Operations) =====
    registry('Gain') = 'simulink/Math Operations/Gain';
    registry('Sum') = 'simulink/Math Operations/Sum';
    registry('Product') = 'simulink/Math Operations/Product';
    registry('Add') = 'simulink/Math Operations/Add';
    registry('Bias') = 'simulink/Math Operations/Bias';
    registry('Abs') = 'simulink/Math Operations/Abs';
    registry('Sign') = 'simulink/Math Operations/Sign';
    registry('MinMax') = 'simulink/Math Operations/MinMax';
    registry('Math Function') = 'simulink/Math Operations/Math Function';
    registry('Trigonometric Function') = 'simulink/Math Operations/Trigonometric Function';
    registry('Slider Gain') = 'simulink/Math Operations/Slider Gain';
    registry('Subtract') = 'simulink/Math Operations/Subtract';
    registry('Divide') = 'simulink/Math Operations/Divide';
    registry('Dot Product') = 'simulink/Math Operations/Dot Product';
    registry('Matrix Multiply') = 'simulink/Math Operations/Matrix Multiply';
    registry('Gain1') = 'simulink/Math Operations/Gain';
    registry('Sum1') = 'simulink/Math Operations/Sum';
    
    % ===== 连续系统 (Continuous) =====
    registry('Integrator') = 'simulink/Continuous/Integrator';
    registry('Transfer Fcn') = 'simulink/Continuous/Transfer Fcn';
    registry('State-Space') = 'simulink/Continuous/State-Space';
    registry('Zero-Pole') = 'simulink/Continuous/Zero-Pole';
    registry('PID Controller') = 'simulink/Continuous/PID Controller';
    registry('PID Controller (2DOF)') = 'simulink/Continuous/PID Controller (2DOF)';
    registry('Derivative') = 'simulink/Continuous/Derivative';
    registry('Transport Delay') = 'simulink/Continuous/Transport Delay';
    registry('Variable Time Delay') = 'simulink/Continuous/Variable Time Delay';
    registry('Second-Order Integrator') = 'simulink/Continuous/Second-Order Integrator';
    
    % ===== 离散系统 (Discrete) =====
    registry('Discrete Transfer Fcn') = 'simulink/Discrete/Discrete Transfer Fcn';
    registry('Discrete State-Space') = 'simulink/Discrete/Discrete State-Space';
    registry('Discrete Filter') = 'simulink/Discrete/Discrete Filter';
    registry('Discrete Zero-Pole') = 'simulink/Discrete/Discrete Zero-Pole';
    registry('Discrete PID Controller') = 'simulink/Discrete/Discrete PID Controller';
    registry('Discrete Integrator') = 'simulink/Discrete/Discrete Integrator';
    registry('Zero-Order Hold') = 'simulink/Discrete/Zero-Order Hold';
    registry('Unit Delay') = 'simulink/Discrete/Unit Delay';
    registry('Difference') = 'simulink/Discrete/Difference';
    registry('Memory') = 'simulink/Discrete/Memory';
    
    % ===== 信号路由 (Signal Routing) =====
    registry('Mux') = 'simulink/Signal Routing/Mux';
    registry('Demux') = 'simulink/Signal Routing/Demux';
    registry('Bus Creator') = 'simulink/Signal Routing/Bus Creator';
    registry('Bus Selector') = 'simulink/Signal Routing/Bus Selector';
    registry('Selector') = 'simulink/Signal Routing/Selector';
    registry('Switch') = 'simulink/Signal Routing/Switch';
    registry('Multiport Switch') = 'simulink/Signal Routing/Multiport Switch';
    registry('Merge') = 'simulink/Signal Routing/Merge';
    registry('Goto') = 'simulink/Signal Routing/Goto';
    registry('From') = 'simulink/Signal Routing/From';
    registry('Data Store Read') = 'simulink/Signal Routing/Data Store Read';
    registry('Data Store Write') = 'simulink/Signal Routing/Data Store Write';
    registry('Data Store Memory') = 'simulink/Signal Routing/Data Store Memory';
    registry('Manual Switch') = 'simulink/Signal Routing/Manual Switch';
    registry('Index Vector') = 'simulink/Signal Routing/Index Vector';
    
    % ===== 端口与子系统 (Ports & Subsystems) =====
    registry('In1') = 'simulink/Ports & Subsystems/In1';
    registry('Subsystem') = 'simulink/Ports & Subsystems/Subsystem';
    registry('Trigger') = 'simulink/Ports & Subsystems/Trigger';
    registry('Enable') = 'simulink/Ports & Subsystems/Enable';
    registry('Model') = 'simulink/Ports & Subsystems/Model';
    registry('If') = 'simulink/Ports & Subsystems/If';
    registry('Switch Case') = 'simulink/Ports & Subsystems/Switch Case';
    registry('For Iterator Subsystem') = 'simulink/Ports & Subsystems/For Iterator Subsystem';
    registry('While Iterator Subsystem') = 'simulink/Ports & Subsystems/While Iterator Subsystem';
    registry('Enable Port') = 'simulink/Ports & Subsystems/Enable Port';
    registry('Trigger Port') = 'simulink/Ports & Subsystems/Trigger Port';
    registry('Function-Call Generator') = 'simulink/Ports & Subsystems/Function-Call Generator';
    registry('Function-Call Subsystem') = 'simulink/Ports & Subsystems/Function-Call Subsystem';
    registry('For Each Subsystem') = 'simulink/Ports & Subsystems/For Each Subsystem';
    registry('Atomic Subsystem') = 'simulink/Ports & Subsystems/Subsystem';
    
    % ===== 逻辑运算 (Logic and Bit Operations) =====
    registry('Logical Operator') = 'simulink/Logic and Bit Operations/Logical Operator';
    registry('Relational Operator') = 'simulink/Logic and Bit Operations/Relational Operator';
    registry('Compare To Constant') = 'simulink/Logic and Bit Operations/Compare To Constant';
    registry('Compare To Zero') = 'simulink/Logic and Bit Operations/Compare To Zero';
    registry('Bit Set') = 'simulink/Logic and Bit Operations/Bit Set';
    registry('Bit Clear') = 'simulink/Logic and Bit Operations/Bit Clear';
    registry('Shift Arithmetic') = 'simulink/Logic and Bit Operations/Shift Arithmetic';
    
    % ===== 查表 (Lookup Tables) =====
    registry('1-D Lookup Table') = 'simulink/Lookup Tables/1-D Lookup Table';
    registry('2-D Lookup Table') = 'simulink/Lookup Tables/2-D Lookup Table';
    registry('n-D Lookup Table') = 'simulink/Lookup Tables/n-D Lookup Table';
    registry('Interpolation Using Prelookup') = 'simulink/Lookup Tables/Interpolation Using Prelookup';
    registry('Prelookup') = 'simulink/Lookup Tables/Prelookup';
    
    % ===== 用户定义 (User-Defined Functions) =====
    registry('MATLAB Function') = 'simulink/User-Defined Functions/MATLAB Function';
    registry('Interpreted MATLAB Function') = 'simulink/User-Defined Functions/Interpreted MATLAB Function';
    registry('S-Function') = 'simulink/User-Defined Functions/S-Function';
    registry('Level-2 MATLAB S-Function') = 'simulink/User-Defined Functions/Level-2 MATLAB S-Function';
    registry('MATLAB System') = 'simulink/User-Defined Functions/MATLAB System';
    registry('Fcn') = 'simulink/User-Defined Functions/Fcn';
    registry('MATLAB Function1') = 'simulink/User-Defined Functions/MATLAB Function';
    
    % ===== 信号属性 (Signal Attributes) =====
    registry('Data Type Conversion') = 'simulink/Signal Attributes/Data Type Conversion';
    registry('Rate Transition') = 'simulink/Signal Attributes/Rate Transition';
    registry('Signal Specification') = 'simulink/Signal Attributes/Signal Specification';
    registry('IC') = 'simulink/Signal Attributes/IC';
    registry('Probe') = 'simulink/Signal Attributes/Probe';
    registry('Width') = 'simulink/Signal Attributes/Width';
    
    % ===== 模型验证 (Model Verification) =====
    registry('Check Static Range') = 'simulink/Model Verification/Check Static Range';
    registry('Check Dynamic Range') = 'simulink/Model Verification/Check Dynamic Range';
    registry('Assertion') = 'simulink/Model Verification/Assertion';
    
    % ===== 端口与子系统 - 输出 (重复映射) =====
    % Out1 同时存在于 Sinks 和 Ports & Subsystems，优先用 Ports & Subsystems
    registry('Out1') = 'simulink/Ports & Subsystems/Out1';
end

function path = sl_search_block_library(shortName)
% 在 Simulink 库浏览器中递归搜索模块
% 版本策略：高版本优先
%   R2022b+: find_system 搜索选项更丰富
%   R2016a:  基本 find_system 回退
    try
        load_system('simulink');
        blocks = find_system('simulink', 'LookUnderMasks', 'none');
        % 先精确匹配
        for i = 1:length(blocks)
            [~, name, ~] = fileparts(blocks{i});
            if strcmpi(name, shortName)
                path = blocks{i};
                return;
            end
        end
        % 再模糊匹配（部分名称包含）
        for i = 1:length(blocks)
            [~, name, ~] = fileparts(blocks{i});
            if ~isempty(strfind(lower(name), lower(shortName)))
                path = blocks{i};
                return;
            end
        end
        % 未找到 → 返回原始输入（让 add_block 报错给出清晰信息）
        path = shortName;
    catch
        path = shortName;
    end
end
