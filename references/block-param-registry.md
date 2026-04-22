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
| `Index` | vector_or_string | `[1]` 或 `idx` | 索引 |

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
| `Bit` | scalar | - | 要设置的位 |

### Bit Clear
| 参数名 | 类型 | 枚举值/格式 | 说明 |
|--------|------|-------------|------|
| `Bit` | scalar | - | 要清除的位 |

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

**文档版本**: v10.2
**最后更新**: 2026-04-21
