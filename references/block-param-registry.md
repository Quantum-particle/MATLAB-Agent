# Simulink 模块参数注册表

> **版本**: v10.2
> **维护**: 本文档记录每个 Simulink 模块的正确参数名、参数类型、枚举值
> **用途**: AI 大模型设置模块参数时，必须查阅本表获取正确参数信息

---

## 参数类型说明

| 类型 | 说明 | 示例 |
|------|------|------|
| `scalar` | 数值标量 | `5`, `0.5` |
| `vector` | 数值向量 | `[1 2 3]`, `[0 1; 0 1]` |
| `matrix` | 矩阵 | `[1 0; 0 1]` |
| `bool` | 布尔值 (on/off) | `'on'`, `'off'` |
| `enum` | 枚举值（固定选项） | `'AND'`, `'sqrt'` |
| `string` | 字符串 | `'MySignal'`, `'u1*2'` |
| `scalar_or_string` | 标量或字符串 | `'5'` 或 `'varName'` |

---

## Sources（信号源模块）

### Step
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Time` | scalar | - | 步跃时间 |
| `Before` | scalar_or_string | - | 初始值 |
| `After` | scalar_or_string | - | 最终值 |
| `SampleTime` | scalar | - | 采样时间 |

### Sine Wave
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Amplitude` | scalar | - | 幅值 |
| `Bias` | scalar | - | 偏置 |
| `Frequency` | scalar | - | 频率 (rad/s) |
| `Phase` | scalar | - | 初相 (rad) |
| `SampleTime` | scalar | - | 采样时间 |

### Constant
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Value` | scalar_or_string | - | 常数值 |

### Ramp
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Slope` | scalar | - | 斜率 |
| `StartTime` | scalar | - | 开始时间 |
| `InitialOutput` | scalar_or_string | - | 初始输出 |

### Pulse Generator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Amplitude` | scalar | - | 幅值 |
| `Period` | scalar | - | 周期 (secs) |
| `PulseWidth` | scalar | - | 脉冲宽度 (%) |
| `PhaseDelay` | scalar | - | 相位延迟 |

### Signal Generator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `WaveForm` | enum | `square`/`sawtooth`/`sine`/`random` | 波形类型 |
| `Frequency` | scalar | - | 频率 (Hz) |
| `Amplitude` | scalar | - | 幅值 |

### Random Number
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Mean` | scalar | - | 均值 |
| `Variance` | scalar | - | 方差 |
| `Seed` | scalar | - | 随机种子 |

### Clock
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无常用参数) | - | - | - |

### Chirp Signal
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InitialFrequency` | scalar | - | 初始频率 (Hz) |
| `TargetFrequency` | scalar | - | 目标频率 (Hz) |
| `TargetTime` | scalar | - | 目标时间 (secs) |

---

## Sinks（输出模块）

### Scope
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumInputPorts` | scalar | - | 输入端口数 |
| `Floating` | bool | `'on'`/`'off'` | 浮动模式 |

### Display
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Decimation` | scalar | - | 抽取因子 |

### To Workspace
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `VariableName` | string | - | 变量名 |
| `MaxDataPoints` | scalar | - | 最大数据点数 |

### Out1
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Port` | scalar | - | 端口号 |

### Terminator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无参数) | - | - | - |

---

## Math Operations（数学运算）

### Gain
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Gain` | scalar_or_matrix | - | 增益值 |
| `Multiplication` | enum | `Element-wise(K.*u)`/`Matrix(K*u)` | 乘法模式 |

### Sum
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar_or_string | `++`, `|+-|`, `|||` 等 | 输入符号列表 |

### Add
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar_or_string | `+++`, `++-` 等 | 输入符号列表 |

### Subtract
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar_or_string | `--`, `-+` 等 | 输入符号列表 |

### Product
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar_or_string | - | 输入数量或符号 |
| `Multiplication` | enum | `Element-wise(K.*u)`/`Matrix(K*u)` | 乘法模式 |

### Divide
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Multiplication` | enum | `Element-wise(K.*u)`/`Matrix(K*u)` | 乘法模式 |

### Bias
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Bias` | scalar | - | 偏置值 |

### Abs
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无常用参数) | - | - | - |

### Sign
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无常用参数) | - | - | - |

### MinMax
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Function` | enum | `min`/`max` | 功能选择 |

### Math Function
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `sqrt`/`log`/`log10`/`ln`/`exp`/`pow`/`abs` 等 | 数学函数 |

### Trigonometric Function
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `sin`/`cos`/`tan`/`asin`/`acos`/`atan` 等 | 三角函数 |

### Slider Gain
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Gain` | scalar | - | 增益 |
| `Minimum` | scalar | - | 最小值 |
| `Maximum` | scalar | - | 最大值 |

### Dot Product
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Multiplication` | enum | `Element-wise(Element.*u)`/`Matrix(u'*v)` | 乘法模式 |

---

## Continuous（连续系统）

### Integrator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InitialCondition` | scalar_or_string | - | 初始条件 |

> 注意: `LimitOutput`, `UpperSaturationLimit`, `LowerSaturationLimit` 等参数在某些 MATLAB 版本可能不可用

### Transfer Fcn
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Numerator` | vector | `[1 2]` | 分子系数 |
| `Denominator` | vector | `[1 3 2]` | 分母系数 |

### State-Space
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `A` | matrix | `[0 1;-2 -3]` | A 矩阵 |
| `B` | matrix | `[0;1]` | B 矩阵 |
| `C` | matrix | `[1 0]` | C 矩阵 |
| `D` | matrix | `[0]` | D 矩阵 |
| `InitialCondition` | vector_or_matrix | - | 初始条件 |

### Zero-Pole
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Zeros` | vector | `[1]` | 零点 |
| `Poles` | vector | `[-1 -2]` | 极点 |
| `Gain` | scalar_or_matrix | - | 增益 |

### PID Controller
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `P` | string | - | 比例增益 |
| `I` | string | - | 积分增益 |
| `D` | string | - | 微分增益 |

### Derivative
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无常用参数) | - | - | - |

### Transport Delay
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `DelayTime` | scalar_or_string | - | 延迟时间 |

---

## Discrete（离散系统）

### Discrete Transfer Fcn
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Numerator` | vector | - | 分子系数 |
| `Denominator` | vector | - | 分母系数 |
| `SampleTime` | scalar | - | 采样时间 |

### Discrete State-Space
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `A` | matrix | - | A 矩阵 |
| `B` | matrix | - | B 矩阵 |
| `C` | matrix | - | C 矩阵 |
| `D` | matrix | - | D 矩阵 |
| `SampleTime` | scalar | - | 采样时间 |

### Discrete Filter
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Numerator` | vector | - | 分子系数 |
| `Denominator` | vector | - | 分母系数 |

### Discrete PID Controller
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `P` | string | - | 比例增益 |
| `I` | string | - | 积分增益 |
| `D` | string | - | 微分增益 |

### Zero-Order Hold
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `SampleTime` | scalar | - | 采样时间 |

### Unit Delay
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InitialCondition` | scalar_or_string | - | 初始条件 |
| `SampleTime` | scalar_or_string | - | 采样时间 |

### Memory
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InitialCondition` | scalar_or_string | - | 初始条件 |

### Difference
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `IC` | scalar | - | 初始条件 |

---

## Signal Routing（信号路由）

### Mux
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar_or_string | - | 输入数量 |

### Demux
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Outputs` | scalar | - | 输出数量 |

### Bus Creator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar | - | 输入数量 |

### Bus Selector
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutputSignals` | string | `signal1,signal2` | 输出信号列表 |

### Selector
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `IndexOptionArray` | string | `Index numbers`/`Starting (CS-1)`/`Index (dialog)` | 索引选项 |
| `IndexParamArray` | string | `Index` | 索引参数 |
| `NumberOfDimensions` | scalar | - | 维度数 |
| `SampleTime` | scalar_or_string | - | 采样时间 |

### Switch
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Threshold` | scalar | - | 切换阈值 |

### Merge
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Inputs` | scalar | - | 输入数量 |

### Goto
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `GotoTag` | string | - | Goto 标签名 |
| `TagVisibility` | enum | `local`/`scoped`/`global` | 标签作用域 |

### From
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `GotoTag` | string | - | Goto 标签名 |

### Manual Switch
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无参数) | - | - | - |

### Index Vector
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Index` | scalar_or_string | - | 索引 |

---

## Ports & Subsystems

### In1
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `IconDisplay` | string | `Port number`/`Port number(port)` 等 | 图标显示 |

### Subsystem
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无固定参数) | - | - | - |

### If
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumInputs` | scalar | - | 输入数量 |
| `IfExpression` | string | `u1 > 0` | 条件表达式 |

### Switch Case
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `CaseConditions` | string | `'{"1","2","3"}'` | Case 条件 |

### For Iterator Subsystem
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无固定参数) | - | - | - |

### While Iterator Subsystem
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无固定参数) | - | - | - |

---

## Logic Operations

### Logical Operator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `AND`/`OR`/`NOT`/`NAND`/`NOR`/`XOR`/`NXOR` | 逻辑运算符 |
| `NumberOfInputPorts` | scalar | - | 输入端口数 |

### Relational Operator
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `==`/`~=`/`<`/`>`/`<=`/`>=` | 关系运算符 |

### Compare To Constant
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Constant` | scalar | - | 常量值 |
| `RelOp` | enum | `==`/`~=`/`<`/`>`/`<=`/`>=` | 关系运算符 |

### Compare To Zero
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `==`/`~=`/`<`/`>`/`<=`/`>=` | 关系运算符 |

### Bit Set
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `iBit` | scalar | - | 位索引(0-31) |

### Bit Clear
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `iBit` | scalar | - | 位索引(0-31) |

### Shift Arithmetic
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Shift` | scalar | - | 移位数 |
| `ShiftType` | enum | `arithmetic`/`logical`/`circular`/`shift` | 移位类型 |

---

## Lookup Tables

### 1-D Lookup Table
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Table` | vector | - | 查表值 |
| `BreakpointsForDimension1` | vector | - | 断点向量 |

### 2-D Lookup Table
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Table` | matrix | - | 查表值 |
| `BreakpointsForDimension1` | vector | - | 行断点 |
| `BreakpointsForDimension2` | vector | - | 列断点 |

### Prelookup
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `BreakpointsForDimension1` | vector | - | 断点向量 |

---

## User-Defined Functions

### MATLAB Function
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无固定参数) | - | - | 内嵌 MATLAB 函数 |

### Interpreted MATLAB Function
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `MATLABFunction` | string | - | 函数名 |

### Fcn
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Expression` | string | `u1*2` | 表达式 |

---

## Signal Attributes

### Data Type Conversion
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutDataTypeStr` | enum | `double`/`single`/`int8`/`uint8`/`int16`/`uint16`/`int32`/`uint32`/`boolean` | 输出数据类型 |

### Rate Transition
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `RateTransition` | string | `Automatically determine` | 速率转换模式 |

### Signal Specification
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Dimension` | scalar_or_string | - | 维度 |

### IC
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Value` | scalar | - | 初始值 |

### Probe
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `ProbeWidth` | bool | `'on'`/`'off'` | 探测宽度 |

---

## Model Verification

### Assertion
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Enabled` | bool | `'on'`/`'off'` | 使能断言 |

---

## 枚举值速查表

### WaveForm（Signal Generator）
| 值 | 说明 |
|----|------|
| `sine` | 正弦波 |
| `square` | 方波 |
| `sawtooth` | 锯齿波 |
| `random` | 随机 |

### Operator（逻辑/数学）
| 值 | 说明 |
|----|------|
| `AND` | 与 |
| `OR` | 或 |
| `NOT` | 非 |
| ` NAND`/`NOR`/`XOR`/`NXOR` | 各种逻辑 |
| `min`/`max` | 最值 |
| `sqrt`/`log`/`log10`/`exp`/`pow` | 数学函数 |
| `sin`/`cos`/`tan`/`asin`/`acos`/`atan` | 三角函数 |

### TagVisibility（Goto/From）
| 值 | 说明 |
|----|------|
| `local` | 局部 |
| `scoped` | 作用域 |
| `global` | 全局 |

### OutDataTypeStr（数据类型）
| 值 | 说明 |
|----|------|
| `double` | 双精度浮点 |
| `single` | 单精度浮点 |
| `int8`/`uint8`/`int16`/`uint16`/`int32`/`uint32` | 整数类型 |
| `boolean` | 布尔 |

---

## Discontinuities（不连续模块库）- v10.3 新增

> **库路径**: `simulink/Discontinuities`

### Saturation（饱和）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `UpperLimit` | scalar | - | 上限 |
| `LowerLimit` | scalar | - | 下限 |

### Saturation Dynamic（动态饱和）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `UpperLimit` | scalar | - | 上限端口 |
| `LowerLimit` | scalar | - | 下限端口 |

### Dead Zone（死区）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `LowerValue` | scalar | - | 死区下限 |
| `UpperValue` | scalar | - | 死区上限 |

### Dead Zone Dynamic（动态死区）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Start` | scalar | - | 死区开始端口 |
| `End` | scalar | - | 死区结束端口 |

### Rate Limiter（速率限制）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `RisingSlewLimit` | scalar | - | 上升斜率限制 |
| `FallingSlewLimit` | scalar | - | 下降斜率限制 |
| `InitialCondition` | scalar_or_string | - | 初始条件 |

### Rate Limiter Dynamic（动态速率限制）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `dU` | scalar | - | 变化率端口 |

### Relay（继电器）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OnSwitchValue` | scalar | - | 开启阈值 |
| `OffSwitchValue` | scalar | - | 关闭阈值 |
| `OnOutputValue` | scalar | - | 开启时的输出 |
| `OffOutputValue` | scalar | - | 关闭时的输出 |

### Quantizer（量化器）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `QuantizationInterval` | scalar | - | 量化间隔 |

### Backlash（间隙）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `DeadbandWidth` | scalar | - | 死区宽度 |
| `InitialOutput` | scalar | - | 初始输出 |

### Coulomb and Viscous Friction（库仑和粘性摩擦）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `CoefficientofStaticFriction` | scalar | - | 静摩擦系数 |
| `CoefficientofViscousFriction` | scalar | - | 粘性摩擦系数 |
| `InitialInput` | scalar | - | 初始输入 |

### Hit Crossing（穿越检测）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `HitOffset` | scalar | - | 穿越偏移量 |
| `ShowOutputPort` | bool | `'on'`/`'off'` | 显示输出端口 |
| `Direction` | enum | `either`/`rising`/`falling` | 穿越方向 |

### Wrap To Zero（归零）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Threshold` | scalar | - | 阈值 |

---

## Additional Math & Discrete（附加数学与离散库）- [REMOVED v10.4.1]

> **注意**: R2023b 中 `simulink/Additional Math & Discrete` 路径不存在，以下模块暂不可用：
> - Weighted Sample Time Math
> - Algebraic Constraint
> - Increment Real Image / Decrement Real Image
> - Decrement Time / Increment Simple / Decrement To Zero
> 如需使用这些模块，请确认 MATLAB 版本或使用替代方案。

---

## Lookup Tables 扩展 - v10.3 新增

### n-D Lookup Table（n维查找表）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Table` | matrix | - | 查表值 |
| `BreakpointsForDimension1` | vector | - | 第1维断点 |
| `BreakpointsForDimension2` | vector | - | 第2维断点 |
| `BreakpointsForDimension3` | vector | - | 第3维断点 |
| `BreakpointsForDimension4` | vector | - | 第4维断点 |
| `NumberOfTableDimensions` | scalar | - | 表维度数 |

### Lookup Table Dynamic（动态查找表）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `x` | vector | - | x坐标（输入） |
| `y` | vector | - | y坐标（输出） |

### Interpolation Using Prelookup（预插值）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

---

## Math Operations 扩展 - v10.3 新增

### Polynomial（多项式）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Coefs` | vector | - | 多项式系数（降序） |

### Repeat Vector（重复向量）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumContiguousRepetitions` | scalar | - | 重复次数 |

### Assignment（赋值）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumberOfIndices` | scalar | - | 索引数 |
| `Indices` | matrix | - | 索引值 |

### Matrix Concatenate（矩阵拼接）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumInputs` | scalar | - | 输入数量 |
| `concatenationDimension` | scalar | - | 拼接维度 |

---

## Signal Routing 扩展 - v10.3 新增

### Multiport Switch（多端口开关）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NumberOfInputs` | scalar | - | 数据输入数量 |
| `IndexMode` | enum | `Zero-based`/`One-based` | 索引模式 |

### Bus Assignment（总线赋值）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `AssignedSignals` | string | - | 指定信号 |
| `InputSignals` | string | - | 输入信号 |

### Bus to Vector（总线转向量）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无额外参数) | - | - | 将虚拟总线转换为向量 |

### Vector to Bus（向量转总线）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutputBusType` | string | - | 输出总线类型 |

---

## Sources 扩展 - v10.3 新增

### From Workspace（从工作区读取）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `VariableName` | string | - | 变量名 |
| `OutputAfterFullData` | enum | `Extrapolation`/`Error`/`Hold Last Value`/`Zero` | 数据耗尽后输出 |

### From File（从文件读取）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `FileName` | string | - | 文件名 |
| `OutputAfterFullData` | enum | 同上 | 数据耗尽后输出 |

### Repeating Sequence（重复序列）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutputValues` | vector | - | 输出值序列 |

### Repeating Sequence Interpolated（插值重复序列）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `TimeValues` | vector | - | 时间值 |
| `OutputValues` | vector | - | 输出值 |
| `EndTime` | scalar | - | 结束时间 |

### Repeating Sequence Stair（阶梯重复序列）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `TimeValues` | vector | - | 时间值 |
| `OutputValues` | vector | - | 输出值 |

### Band-Limited White Noise（限带宽白噪声）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `NoisePower` | scalar | - | 噪声功率 |
| `SampleTime` | scalar | - | 采样时间 |
| `Seed` | scalar | - | 随机种子 |

### Signal Builder（信号构建器）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `SignalGroupNames` | string | - | 信号组名称 |

---

## Sinks 扩展 - v10.3 新增

### To File（写入文件）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `FileName` | string | - | 文件名 |
| `VariableName` | string | - | 变量名 |
| `MaxDataPoints` | scalar | - | 最大数据点数 |

### XY Graph（XY图）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `xmin` | scalar | - | X轴最小值 |
| `xmax` | scalar | - | X轴最大值 |
| `ymin` | scalar | - | Y轴最小值 |
| `ymax` | scalar | - | Y轴最大值 |

### Out Variable（变量输出）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `VariableName` | string | - | 变量名 |
| `MaxDataPoints` | scalar | - | 最大数据点数 |

---

## Continuous 扩展 - v10.3 新增

### Second-Order Integrator（二阶积分器）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InitialConditionSource` | enum | `internal`/`external` | 初始条件来源 |
| `x0` | scalar | - | 初始位置 |
| `xdot0` | scalar | - | 初始速度 |
| `LimitOutput` | bool | `'on'`/`'off'` | 限制输出 |
| `UpperLimit` | scalar | - | 上限 |
| `LowerLimit` | scalar | - | 下限 |

### Variable Transport Delay（可变传输延迟）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `DelayTimeSource` | enum | `internal`/`external` | 延迟时间来源 |
| `MaximumDelay` | scalar | - | 最大延迟 |

### Variable Time Delay（可变时间延迟）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `DelayTimeSource` | enum | `internal`/`external` | 延迟时间来源 |
| `MaximumDelay` | scalar | - | 最大延迟 |

---

## Discrete 扩展 - v10.3 新增

### Discrete PID Controller (2DOF)（离散双自由度PID）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `P` | string | - | 比例增益 |
| `I` | string | - | 积分增益 |
| `D` | string | - | 微分增益 |
| `B` | string | - | 设定点加权（微分） |
| `C` | string | - | 设定点加权（比例） |
| `FilterCoefficient` | string | - | 滤波器系数 |

### Discrete Zero-Pole（离散零极点）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Zeros` | vector | - | 零点 |
| `Poles` | vector | - | 极点 |
| `Gain` | scalar | - | 增益 |

---

## Model Verification 扩展 - v10.3 新增

### Check Static Range（检查静态范围）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `External` | bool | `'on'`/`'off'` | 外部输入 |
| `Minimum` | scalar | - | 最小值 |
| `Maximum` | scalar | - | 最大值 |

### Check Static Upper Bound（检查静态上限）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Bound` | scalar | - | 界限值 |

### Check Static Lower Bound（检查静态下限）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Bound` | scalar | - | 界限值 |

### Check Dynamic Range（检查动态范围）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `MinimumInputPort` | scalar | - | 最小值端口 |
| `MaximumInputPort` | scalar | - | 最大值端口 |

### Check Dynamic Gap（检查动态间隙）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `MinimumGap` | scalar | - | 最小间隙 |
| `MaximumGap` | scalar | - | 最大间隙 |

### Check Input Resolution（检查输入分辨率）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Resolution` | scalar | - | 分辨率值 |

### Check Discrete Gradient（检查离散梯度）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `MaximumJump` | scalar | - | 最大跳变 |

### Assertion 扩展
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Enabled` | bool | `'on'`/`'off'` | 使能断言 |
| `StopWhenAssertionFails` | bool | `'on'`/`'off'` | 断言失败时停止 |
| `AssertionMode` | enum | `all`/`any` | 模式 |

---

## Ports & Subsystems 扩展 - v10.3 新增

### Triggered Subsystem（触发子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `TriggerType` | enum | `rising`/`falling`/`either`/`function-call` | 触发类型 |

### Enabled Subsystem（使能子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `EnableInit` | enum | `held`/`reset` | 初始化动作 |
| `EnableDelay` | scalar | - | 使能延迟 |

### Enabled and Triggered Subsystem（使能触发子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### Function-Call Subsystem（函数调用子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### For Iterator Subsystem（For循环子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `IterationLimit` | scalar_or_string | - | 迭代次数限制 |

### While Iterator Subsystem（While循环子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `MaximumNumberOfIterations` | scalar | - | 最大迭代次数 |

### Resettable Subsystem（可重置子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### If Action Subsystem（If动作子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### Switch Case Action Subsystem（Switch Case动作子系统）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

---

## Signal Attributes 扩展 - v10.3 新增

### Data Type Conversion（数据类型转换）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutDataTypeStr` | enum | `double`/`single`/`int8`/`uint8`/`int16`/`uint16`/`int32`/`uint32`/`boolean` | 输出数据类型 |
| `SaturateOnIntegerOverflow` | bool | `'on'`/`'off'` | 整数溢出饱和 |
| `LockScale` | bool | `'on'`/`'off'` | 锁定缩放 |
| `RndMeth` | enum | `Floor`/`Ceiling`/`Convergent`/`Zero` | 取整方法 |
| `SampleTime` | scalar | - | 采样时间 |
| `OutMin` | scalar_or_string | - | 输出最小值 |
| `OutMax` | scalar_or_string | - | 输出最大值 |
| `ConvertRealWorld` | enum | `Keep most efficient`/`Normalized zero/Clear | 世界值转换 |
| 注意 | R2023b中`InputSanityCheck`参数已移除，请使用`SaturateOnIntegerOverflow` | - | - |

### Data Type Conversion Inherited（继承数据类型转换）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### Data Type Strip（数据类型剥离）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|

### Signal Specification 扩展
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Dimension` | scalar_or_string | - | 维度 |
| `SampleTime` | scalar_or_string | - | 采样时间 |
| `DataType` | enum | `auto`/`double`/... | 数据类型 |

### Rate Transition 扩展
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutPortSampleTime` | scalar | - | 输出采样时间 |
| `TreatMyselfAsKnown` | bool | `'on'`/`'off'` | 视为已知块 |

### Probe 扩展
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `ProbeWidth` | bool | `'on'`/`'off'` | 探测宽度 |
| `ProbeSampleTime` | bool | `'on'`/`'off'` | 探测采样时间 |
| `ProbeComplexSignal` | bool | `'on'`/`'off'` | 探测复数信号 |

### Width（宽度）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| (无额外参数) | - | - | 输出输入信号宽度 |

---

## Logic and Bit Operations 扩展 - v10.3 新增

### Combinatorial Logic（组合逻辑）
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `TruthTable` | matrix | - | 真值表 |

### Logical Operator 扩展
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Operator` | enum | `AND`/`OR`/`NOT`/`NAND`/`NOR`/`XOR`/`NXOR` | 运算符 |
| `NumberOfInputPorts` | scalar | - | 输入端口数 |
| `OutputDataTypeMode` | string | `Inherit via internal rule`/`boolean`/... | 输出数据类型模式 |

---

## 枚举值速查表扩展 - v10.3 新增

### Direction（Hit Crossing）
| 值 | 说明 |
|----|------|
| `either` | 双向 |
| `rising` | 上升沿 |
| `falling` | 下降沿 |

### TriggerType（触发子系统）
| 值 | 说明 |
|----|------|
| `rising` | 上升沿触发 |
| `falling` | 下降沿触发 |
| `either` | 双向触发 |
| `function-call` | 函数调用 |

### EnableInit（使能子系统）
| 值 | 说明 |
|----|------|
| `held` | 保持 |
| `reset` | 复位 |

### IntegerRoundingMode（数据类型转换）
| 值 | 说明 |
|----|------|
| `floor` | 向下取整 |
| `ceil` | 向上取整 |
| `round` | 四舍五入 |
| `convergent` | 收敛取整 |
| `zero` | 向零取整 |

### ConvOverflowMsg（溢出处理）
| 值 | 说明 |
|----|------|
| `none` | 不处理 |
| `warning` | 警告 |
| `error` | 错误 |

### AssertionMode（断言模式）
| 值 | 说明 |
|----|------|
| `all` | 检查所有 |
| `any` | 检查任一 |

### OutputAfterFullData（数据耗尽后）
| 值 | 说明 |
|----|------|
| `Extrapolation` | 外推 |
| `Error` | 报错 |
| `Hold Last Value` | 保持最后值 |
| `Zero` | 归零 |

---

## Unit Conversion（单位转换模块）- v10.4 新增

> **库路径**: `simulink/Signal Attributes`
> **Simscape相关**: `simscape/Utilities`

### Unit Conversion（单位转换）

| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutputDataType` | enum | `Inherit via internal rule`/`Inherit via back propagation` | 输出数据类型 |

**转换类型**:
| 类型 | 公式 |
|------|------|
| 线性比例 | `y = a * U` |
| 带偏移 | `y = a * U + b` |
| 倒数 | `y = a / U` |

**支持的单位系统**:
| 单位系统 | 主要单位 |
|----------|----------|
| SI 单位 | m, kg, s, A, K, N, J, W, V, Ω, Hz, Pa |
| 英制单位 | in, ft, mi, lbm, lbf, psi, mph |
| CGS 单位 | cm, g, dyn |

**常用单位转换**:
| 转换 | 输入→输出 |
|------|-----------|
| 长度 | `m`→`ft` |
| 质量 | `kg`→`lbm` |
| 力 | `N`→`lbf` |
| 压力 | `Pa`→`psi` |
| 温度(相对) | `degC`→`K` |
| 温度(绝对) | `degF`→`K` |

---

### PS-Simulink Converter（物理信号转Simulink信号）

> **库路径**: `simscape/Utilities`

| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `OutputSignalUnit` | string | - | 输出信号单位 |

**可选输出单位**: `V`, `A`, `m^3/s`, `Pa`, `N`, `m`, `m/s`, `N*m`, `rad/s`, `rad`, `K`, `kg/s`, `J/s`, `kg`, `Wb`, `rpm`, `mm/s` 等

---

### Simulink-PS Converter（Simulink信号转物理信号）

> **库路径**: `simscape/Utilities`

| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `InputSignalUnit` | string | - | 输入信号单位（默认`1`） |
| `ApplyAffineConversion` | bool | `'on'`/`'off'` | 仿射转换（温度专用） |
| `FilteringAndDerivatives` | enum | 见下表 | 滤波和导数模式 |
| `ProvidedSignals` | enum | `Input only`/`Input and first derivative`/`Input and first two derivatives` | 提供的信号类型 |
| `InputFilteringOrder` | enum | `First-order filtering`/`Second-order filtering` | 输入滤波阶数 |
| `InputFilteringTimeConstant` | scalar | - | 输入滤波时间常数(秒) |

**FilteringAndDerivatives 枚举值**:
| 值 | 说明 |
|----|------|
| `Provide signals` | 通过附加输入端口提供导数 |
| `Filter input and compute derivatives` | 通过低通滤波器自动计算导数 |
| `Zero derivatives (piecewise constant)` | 导数设为零（适用于阶跃信号） |

**输入信号单位可选值**:
```
V, A, m^3/s, Pa, N, m, m/s, N*m, rad/s, rad, K, kg/s, J/s, kg, Wb
rpm, mm/s, degC, degF, degK, degR
```

---

### 单位前缀速查

| 前缀 | 符号 | 因子 |
|------|------|------|
| exa/peta/tera/giga | E/P/T/G | 10^18/15/12/9 |
| mega/kilo/hecto/deka | M/k/h/da | 10^6/3/2/1 |
| deci/centi/milli | d/c/m | 10^-1/-2/-3 |
| micro/nano/pico/femto/atto | u/n/p/f/a | 10^-6/-9/-12/-15/-18 |

**常用复合单位**:
| 物理量 | 单位 | ASCII符号 |
|--------|------|-----------|
| 体积流量 | 立方米/秒 | `m^3/s` |
| 力矩 | 牛顿·米 | `N*m` |
| 角速度 | 弧度/秒 | `rad/s` |
| 功率 | 焦耳/秒 | `J/s` |
| 转速 | 转/分 | `rpm` |

---

## 角度与速度单位转换 - v10.4 新增

### 角度转换模块

#### Degrees to Radians（度转弧度）

> **库路径**: `simulink/Sources`

| 参数名 | 类型 | 说明 |
|--------|------|------|
| (无额外参数) | - | 输入deg，输出rad |

#### Radians to Degrees（弧度转度）

> **库路径**: `simulink/Sources`

| 参数名 | 类型 | 说明 |
|--------|------|------|
| (无额外参数) | - | 输入rad，输出deg |

---

### 角度单位转换速查

| 转换 | 输入→输出 | 公式 |
|------|-----------|------|
| 角度 | `deg`→`rad` | `rad = deg * π/180` |
| 角度 | `rad`→`deg` | `deg = rad * 180/π` |
| 角度 | `rev`→`rad` | `rad = rev * 2π` |
| 角度 | `rev`→`deg` | `deg = rev * 360` |

---

### 角速度单位转换速查

| 转换 | 输入→输出 | 公式 |
|------|-----------|------|
| 角速度 | `rad/s`→`deg/s` | `deg/s = rad/s * 180/π` |
| 角速度 | `rad/s`→`rpm` | `rpm = rad/s * 60/(2π)` |
| 角速度 | `rpm`→`rad/s` | `rad/s = rpm * 2π/60` |
| 角速度 | `rpm`→`deg/s` | `deg/s = rpm * 6` |
| 角速度 | `deg/s`→`rad/s` | `rad/s = deg/s * π/180` |
| 角速度 | `Hz`→`rad/s` | `rad/s = Hz * 2π` |
| 角速度 | `Hz`→`rpm` | `rpm = Hz * 60` |

**常用角速度单位**: `rad/s`, `deg/s`, `rpm`, `rev/s`, `Hz`

---

### 速度单位转换速查

| 转换 | 输入→输出 | 公式 |
|------|-----------|------|
| 速度 | `m/s`→`km/h` | `km/h = m/s * 3.6` |
| 速度 | `km/h`→`m/s` | `m/s = km/h / 3.6` |
| 速度 | `m/s`→`mph` | `mph = m/s * 2.23694` |
| 速度 | `mph`→`m/s` | `m/s = mph * 0.44704` |
| 速度 | `m/s`→`ft/s` | `ft/s = m/s * 3.28084` |
| 速度 | `ft/s`→`m/s` | `m/s = ft/s * 0.3048` |
| 速度 | `km/h`→`mph` | `mph = km/h * 0.621371` |
| 速度 | `knot`→`m/s` | `m/s = knot * 0.514444` |

**常用速度单位**: `m/s`, `km/h`, `mph`, `ft/s`, `knot`

---

### Aerospace Blockset 专用转换模块 - v10.4 新增

> **库路径**: `aeroblks/Aerospace Utilities`

#### Angular Velocity Conversion（角速度转换）

| 参数名 | 类型 | 枚举值 | 说明 |
|--------|------|--------|------|
| `InputVelocityUnit` | enum | `rad/s`/`deg/s`/`rpm`/`rev/s`/`Hz` | 输入单位 |
| `OutputVelocityUnit` | enum | `rad/s`/`deg/s`/`rpm`/`rev/s`/`Hz` | 输出单位 |

#### Length Conversion（长度转换）

| 参数名 | 类型 | 枚举值 | 说明 |
|--------|------|--------|------|
| `InputLengthUnit` | enum | `m`/`km`/`cm`/`mm`/`in`/`ft`/`yd`/`mi`/`nmi` | 输入单位 |
| `OutputLengthUnit` | enum | 同上 | 输出单位 |

#### Velocity Conversion（速度转换）

| 参数名 | 类型 | 枚举值 | 说明 |
|--------|------|--------|------|
| `InputVelocityUnit` | enum | `m/s`/`km/h`/`mph`/`ft/s`/`knot`等 | 输入单位 |
| `OutputVelocityUnit` | enum | 同上 | 输出单位 |

---

**MATLAB 命令**:
```matlab
showunitslist  % 查看完整单位列表
```

---

**文档版本**: v10.4
**最后更新**: 2026-04-22
