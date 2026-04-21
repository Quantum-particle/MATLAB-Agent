# sl_toolbox API 使用说明书

> **版本**: v15.0 (v9.0 标准化建模工作流版)  
> **更新日期**: 2026-04-20  
> **适用范围**: 大模型通过 @skill://matlab-agent 调用 Simulink 建模函数时，**必须先阅读本手册**，防止语法错误  
> **同步规则**: 任何 .m 函数的 API 签名或返回结构变更后，**必须同步更新本手册对应条目**

---

## AI 大模型调用 matlab-agent 工作流架构图

> **这是 AI 大模型调用 @skill://matlab-agent 的标准工作流。每次建模任务都应遵循此流程！**

```
[AI 大模型]
    |
    | Step 0: 加载提示词（获取专家知识 + 建模指导）
    |-----------> GET /simulink/prompt/list          列出可用场景和参考主题
    |-----------> GET /simulink/prompt/scenario       获取场景提示词（核心层+场景层）
    |-----------> GET /simulink/prompt/reference      获取参考层技术文档
    |
    | Step 1: 准备（初始化 + 查看最佳实践 + 创建模型）
    |-----------> POST /matlab/run  sl_init()         初始化 sl_toolbox
    |-----------> POST /simulink/best_practices       查看8大反模式+现代API
    |-----------> POST /simulink/inspect              查看已有模型状态（修改模型时必做！）
    |-----------> POST /matlab/simulink/create         创建新模型（新建模型时）
    |
    | Step 2: 构建（总线 + 子系统 + 模块 + 连线 + 参数）
    |-----------> POST /simulink/bus_create            创建总线对象（数据接口定义）
    |-----------> POST /simulink/bus_inspect           检查总线结构
    |-----------> POST /simulink/subsystem_create      创建子系统（结构化建模）
    |-----------> POST /simulink/add_block             添加模块（含反模式防护）
    |-----------> POST /simulink/add_line              连线（自动选择最佳API）
    |-----------> POST /simulink/set_param             设置参数（struct格式！）
    |-----------> POST /simulink/block_position        模块位置（替代裸Position）
    |-----------> POST /simulink/subsystem_mask        子系统Mask封装
    |-----------> POST /simulink/signal_config         信号属性配置
    |-----------> POST /simulink/signal_logging        信号记录（替代To Workspace）
    |-----------> POST /simulink/callback_set          设置回调函数
    |
    | Step 3: 配置（Solver + 仿真参数）
    |-----------> POST /simulink/config_get            获取当前模型配置
    |-----------> POST /simulink/config_set            设置模型配置（struct格式！）
    |
    | Step 4: 验证 + 排版 + 快照
    |-----------> POST /simulink/validate              模型健康检查（12项）
    |-----------> POST /simulink/auto_layout           自动排版
    |-----------> POST /simulink/snapshot              创建快照（重要操作前必做！）
    |-----------> POST /simulink/find_blocks           查找模块（验证构建结果）
    |-----------> GET  /simulink/model_status          [v8.0] 查看模型完整状态（含端口+连线诊断）
    |
    | Step 5: 仿真 + 结果 + 测试
    |-----------> POST /simulink/sim_run               运行仿真（SimulationInput优先）
    |-----------> POST /simulink/sim_results           提取仿真结果
    |-----------> POST /simulink/sim_batch             批量仿真（参数扫描）
    |-----------> POST /simulink/baseline_test         基线回归测试
    |-----------> POST /simulink/profile_sim           仿真性能分析
    |-----------> POST /simulink/profile_solver        求解器性能分析
    |
    | 出错恢复（任何步骤出错时）:
    |-----------> POST /simulink/parse_error           精确错误解析+修复建议
    |-----------> POST /simulink/snapshot(rollback)    回滚到之前快照
    |-----------> POST /simulink/delete                安全删除模块
    |-----------> POST /simulink/replace_block         替换模块
    |-----------> POST /simulink/subsystem_expand      展开子系统
    |
    | 兜底: POST /matlab/run  { code: "..." }         直接写MATLAB代码（中间件不够用时）
```

### 工作流 5 步法速记

| 步骤 | 动作 | 核心API | 必做程度 |
|------|------|---------|---------|
| Step 0 | 加载提示词 | prompt/list, prompt/scenario, prompt/reference | **每次任务首步！** |
| Step 1 | 准备 | sl_init, best_practices, inspect, create | 必须 |
| Step 2 | 构建 | bus_create, subsystem_create, add_block, add_line, set_param, ... | 必须 |
| Step 3 | 配置 | config_get, config_set | 必须 |
| Step 4 | 验证+排版 | validate, auto_layout, snapshot, find_blocks | **强烈推荐** |
| Step 5 | 仿真+测试 | sim_run, sim_results, sim_batch, baseline_test, profile_* | 必须 |

---

## API 弃用标注机制（v6.1 新增）

> 本手册支持 API 弃用标注。当某个函数签名或参数用法被弃用时，会在对应条目中标注 `[DEPRECATED]`。

**标注格式**:
```
[DEPRECATED since v10.0] 旧用法描述
→ 替代方案：新用法描述
```

**弃用触发条件**:
1. 函数签名变更（参数增删、类型变更）
2. 返回结构字段重命名
3. 更优 API 替代（如 connectBlocks 替代 add_line）

**当前弃用标注**:
（暂无 — 随着版本迭代，旧用法被弃用时会在此标注）

---

## 目录（按建模工作流排序）

> **重要**: 目录按 AI 大模型实际使用顺序排列，不是按开发顺序。请按此顺序阅读和调用！

### Step 0: 提示词加载（首步必做）
1. [提示词分层架构 (Part 8)](#1-提示词分层架构-part-8)

### Step 1: 准备（初始化 + 最佳实践 + 模型检查）
2. [初始化](#2-初始化)
3. [最佳实践](#3-最佳实践)
4. [模型检查](#4-模型检查)
5. [模块注册表](#5-模块注册表)

### Step 2: 构建（总线 + 子系统 + 模块 + 连线 + 参数）
6. [总线创建](#6-总线创建)
7. [总线检查](#7-总线检查)
8. [子系统创建](#8-子系统创建)
9. [子系统 Mask](#9-子系统-mask)
10. [添加模块](#10-添加模块)
11. [安全连线](#11-安全连线)
12. [设置参数](#12-设置参数)
13. [模块位置](#13-模块位置)
14. [信号配置](#14-信号配置)
15. [信号记录](#15-信号记录)
16. [回调设置](#16-回调设置)

### Step 3: 配置
17. [模型配置](#17-模型配置)

### Step 4: 验证+排版+快照
18. [模型验证](#18-模型验证)
19. [自动排版](#19-自动排版)
20. [布局整理](#20-布局整理)
21. [模型快照](#21-模型快照)
22. [查找模块](#22-查找模块)

### Step 5: 仿真+测试
23. [仿真运行](#23-仿真运行)
24. [仿真结果](#24-仿真结果)
25. [批量仿真](#25-批量仿真)
26. [基线测试](#26-基线测试)
27. [仿真性能分析](#27-仿真性能分析)
28. [求解器性能分析](#28-求解器性能分析)

### 出错恢复
29. [错误解析](#29-错误解析)
30. [删除模块](#30-删除模块)
31. [替换模块](#31-替换模块)
32. [子系统展开](#32-子系统展开)

### 基础设施与集成参考
33. [JSON 编码](#33-json-编码)
34. [通用约定](#34-通用约定)
35. [Python Bridge 集成 (Part 6)](#35-python-bridge-集成-part-6)
36. [智能体自我改进机制 (Part 10)](#36-智能体自我改进机制-part-10)
37. [Node.js + Express 路由 (Part 7)](#37-node-js-express-路由-part-7)

---

> **Step 0: 提示词加载**

## 1. 提示词分层架构 (Part 8)

> **v10.0 新增，v11.0 修订** — 三层提示词架构 + 3 个查询 API，支持场景化提示词和参考信息动态加载。

### 1.1 三层架构

| 层级 | 类型 | 说明 | 优先级 |
|------|------|------|--------|
| 核心 (Core) | 始终加载 | Simulink 基础操作规则 + 反模式防护 + API 概览 | 最高 |
| 场景 (Scenario) | 按需加载 | 特定建模场景的提示词（如 PID 设计、通信系统、电力系统） | 中 |
| 参考 (Reference) | 按需加载 | 详细技术参考（如 Solver 配置、信号路由、总线规范） | 最低 |

### 1.2 查询 API 端点

| 端点 | 方法 | 参数 | 说明 |
|------|------|------|------|
| `/api/matlab/simulink/prompt/list` | GET | 无 | 列出所有可用场景和参考主题 |
| `/api/matlab/simulink/prompt/scenario` | GET | `?scenario=<name>` | 获取核心层 + 指定场景层提示词 |
| `/api/matlab/simulink/prompt/reference` | GET | `?topic=<name>` | 获取指定参考层内容 |

### 1.3 请求/响应示例

**列出可用场景和参考主题**:
```
GET /api/matlab/simulink/prompt/list
```
```json
{
  "status": "ok",
  "scenarios": ["pid_control", "communication_system", "power_system"],
  "referenceTopics": ["solver_config", "signal_routing", "bus_specification"],
  "usage": {
    "scenario": "GET /api/matlab/simulink/prompt/scenario?scenario=<name>",
    "reference": "GET /api/matlab/simulink/prompt/reference?topic=<name>",
    "fullPrompt": "GET /api/matlab/simulink/prompt/scenario?scenario=<name> returns core+scenario layers"
  }
}
```

**获取场景提示词**:
```
GET /api/matlab/simulink/prompt/scenario?scenario=pid_control
```
```json
{
  "status": "ok",
  "scenario": "pid_control",
  "prompt": "# Simulink Prompt\n\n## Core Layer\n...\n## Scenario: PID Control\n..."
}
```

**获取参考内容**:
```
GET /api/matlab/simulink/prompt/reference?topic=solver_config
```
```json
{
  "status": "ok",
  "topic": "solver_config",
  "reference": "## Solver Configuration Reference\n..."
}
```

---


---

> **Step 1: 准备**

## 2. 初始化

### `sl_init()`

初始化 sl_toolbox 工具箱 — 自动定位目录并添加到 MATLAB path

```matlab
result = sl_init()
```

**参数**: 无

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.toolbox_path` | char | sl_toolbox 目录完整路径 |
| `result.file_count` | double | 可用的 .m 文件数量 |
| `result.files` | cell{char} | .m 文件名列表 |
| `result.message` | char | 状态信息 |

**使用注意**:
- 通过 `mfilename('fullpath')` 自定位，**不依赖外部路径传参**，中文路径安全
- 幂等操作：重复调用不会重复添加路径
- 通常由 Python Bridge 的 `eng.workspace['sl_toolbox_dir']` 触发

---

## 3. 最佳实践

### `sl_best_practices()`

返回 Simulink 建模最佳实践与反模式规则

```matlab
result = sl_best_practices()
```

**参数**: 无

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.antiPatterns` | cell{struct} | 8 大反模式规则 |
| `result.modernAPIs` | cell{struct} | 推荐的现代 API |
| `result.versionPractices` | cell{struct} | 版本相关实践 |
| `result.version` | char | `'v5.0'` |
| `result.source` | char | 来源信息 |

**8 大反模式**:
| # | 名称 | 级别 | 嵌入函数 |
|---|------|------|----------|
| 1 | Discourage Sum Block | warning | sl_add_block_safe |
| 2 | Discourage To Workspace Block | warning | sl_add_block_safe |
| 3 | Prefer connectBlocks over add_line | info | sl_add_line_safe |
| 4 | Discourage Manual Position Setting | warning | sl_arrange_model |
| 5 | Discourage set_param + sim Pattern | error | sl_validate_model |
| 6 | Discourage Manual Subsystem Creation | warning | — |
| 7 | Check Unconnected Ports | warning | sl_inspect_model, sl_validate_model |
| 8 | Check Port Dimensions Before Connecting | error | sl_add_line_safe |

**⚠️ 关键注意**:
- `antiPatterns` 是 **cell 数组**，访问用 `result.antiPatterns{i}.description`（不是 `.message`）
- `modernAPIs` 的字段是 `.name`, `.introduced`, `.replaces`, `.usage`, `.benefit`（不是 `.api`）

---

## 4. 模型检查

### `sl_inspect_model(modelName, varargin)`

模型全景检查 — 让 AI 能"看到"模型完整状态

```matlab
result = sl_inspect_model('MyModel')
result = sl_inspect_model('MyModel', 'depth', 1, 'includeParams', true)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'depth'` | double | `1` | 检查深度，0=全部层级 |
| `'includeParams'` | logical | `true` | 是否包含模块参数 |
| `'includePorts'` | logical | `true` | 是否包含端口信息 |
| `'includeLines'` | logical | `true` | 是否包含连线信息 |
| `'includeCallbacks'` | logical | `false` | 是否包含回调 |
| `'includeConfig'` | logical | `false` | 是否包含模型配置 |
| `'blockFilter'` | char | `''` | 只检查特定 BlockType |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.model.name` | char | 模型名称 |
| `result.model.blockCount` | double | 模块数量 |
| `result.model.subsystemCount` | double | 子系统数量 |
| `result.model.lineCount` | double | 连线数量 |
| `result.model.inportCount` | double | Inport 模块数量 |
| `result.model.outportCount` | double | Outport 模块数量 |
| `result.model.blocks` | cell{struct} | 模块信息列表 |
| `result.model.lines` | cell{struct} | 连线信息（`includeLines=true` 时） |
| `result.model.unconnectedPorts` | cell{struct} | 未连接端口（如有） |
| `result.model.config` | struct | 模型配置（`includeConfig=true` 时） |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- **`blockCount` 在 `result.model` 下，不是 `result` 顶层！** 访问路径：`result.model.blockCount`
- `blocks` 是 **cell 数组**，访问需用 `result.model.blocks{i}.path`
- `find_system` 的 `SearchDepth` 必须放在 Simulink 参数名之前

---

## 5. 模块注册表

### `sl_block_registry(shortName)`

Simulink 模块库路径注册表 — 简称→完整路径映射

```matlab
path = sl_block_registry('Step')     % → 'simulink/Sources/Step'
path = sl_block_registry('Gain')     % → 'simulink/Math Operations/Gain'
path = sl_block_registry('PID Controller')  % → 'simulink/Continuous/PID Controller'
```

**参数**:
| 参数 | 类型 | 说明 |
|------|------|------|
| `shortName` | char | **必选**，模块简称（如 `'Gain'`, `'Step'`） |

**返回**: char — 模块完整库路径

**匹配顺序**:
1. 精确匹配（区分大小写）
2. 大小写不敏感匹配
3. 包含匹配（部分名称匹配）
4. 搜索 Simulink 库（最慢，最后回退）

**⚠️ 关键注意**:
- **必须传 shortName 参数！无参调用会报错**
- 返回值是字符串（char），不是 struct
- 注册表覆盖 12 大库 70+ 常用模块
- 不在注册表中的简称会自动在 Simulink 库中模糊搜索

---


---

> **Step 2: 构建**

## 6. 总线创建

### `sl_bus_create(busName, elements, varargin)`

创建总线对象 — 从字段定义创建 Simulink.Bus → 保存到 workspace/dictionary/file

```matlab
elems = [struct('name','alpha','dataType','double','dimensions',3); ...
         struct('name','beta','dataType','single')];
result = sl_bus_create('FlightData_Bus', elems)
result = sl_bus_create('FlightData_Bus', elems, 'saveTo', 'workspace', 'overwrite', true)
```

**REST API 调用格式**（v11.0 重要）：
```json
POST /api/matlab/simulink/bus_create
{
  "busName": "FlightData",
  "elements": [
    {"name": "altitude", "dataType": "double"},
    {"name": "speed", "dataType": "double"}
  ],
  "overwrite": true
}
```

> **注意**: REST API 传入 `elements` 为 JSON list of dicts，Bridge 自动转换为 MATLAB struct 数组 `[struct;struct]`（通过 `_pos_2_special` 机制）。不要传入 cell 数组格式。

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `busName` | char | 必选 | 总线对象名称 |
| `elements` | **struct 数组** | 必选 | 每个元素含 `.name`(必选), `.dataType`, `.dimensions`, `.complexity`, `.samplingMode` |
| `'saveTo'` | char | `'workspace'` | `'workspace'`/`'dictionary'`/`'file'` |
| `'dictionaryPath'` | char | `''` | 数据字典路径（saveTo='dictionary' 时必填） |
| `'filePath'` | char | `''` | 保存文件路径（saveTo='file' 时必填） |
| `'description'` | char | `''` | 总线描述信息 |
| `'overwrite'` | logical | `false` | 是否覆盖已有同名总线 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.bus.name` | char | 总线名称 |
| `result.bus.elementCount` | double | 元素数量 |
| `result.bus.elements` | struct 数组 | 元素信息（`.name`, `.dataType`, `.dimensions`, `.complexity`） |
| `result.bus.savedTo` | char | 保存目标 |
| `result.bus.verified` | logical | 是否验证成功 |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- `elements` 必须是 **struct 数组**（不是 cell），且每个元素必须有 `.name` 字段
- struct 数组用 `[struct(...); struct(...)]` 构造（注意用 `;` 分号分行）
- `.dataType` 默认 `'double'`，`.dimensions` 默认 `1`

---

## 7. 总线检查

### `sl_bus_inspect(busName, varargin)`

检查总线结构 — 字段/类型/维度/嵌套 Bus + 使用方查找

```matlab
result = sl_bus_inspect('MyBus')
result = sl_bus_inspect('MyBus', 'source', 'dictionary', 'dictionaryPath', 'path.sldd')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `busName` | char | 必选 | 总线对象名称 |
| `'source'` | char | `'workspace'` | `'workspace'`/`'dictionary'` |
| `'dictionaryPath'` | char | `''` | 数据字典路径 |
| `'findUsage'` | logical | `true` | 是否查找使用方模块 |
| `'recursive'` | logical | `true` | 是否递归解析嵌套 Bus |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.bus.name` | char | 总线名称 |
| `result.bus.elementCount` | double | 元素数量 |
| `result.bus.elements` | **cell{struct}** | 元素信息（`.name`, `.dataType`, `.dimensions`, `.isNestedBus`） |
| `result.bus.usedByBlocks` | cell{char} | 使用方模块路径 |
| `result.bus.nestedBuses` | cell{char} | 嵌套 Bus 名称列表 |
| `result.bus.nestedBusDetails` | struct | 嵌套 Bus 详情（递归时） |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **`elements` 是 cell 数组**（不是 struct 数组），访问用 `result.bus.elements{i}.name`
- 嵌套 Bus 的 dataType 格式为 `'Bus:BusName'`

---

## 8. 子系统创建

### `sl_subsystem_create(modelName, subsystemName, mode, varargin)`

创建子系统 — group/empty 两种模式 + createSubsystem 优先

```matlab
% group 模式: 从现有模块分组创建子系统
result = sl_subsystem_create('MyModel', 'Controller', 'group', 'blocksToGroup', {'MyModel/Gain1','MyModel/Sum1'})

% empty 模式: 创建空子系统
result = sl_subsystem_create('MyModel', 'Controller', 'empty', 'inputPorts', 2, 'outputPorts', 1)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `subsystemName` | char | 必选 | 子系统名称，如 'Controller' |
| `mode` | char | 必选 | `'group'`（从现有模块分组）或 `'empty'`（创建空子系统） |
| `'blocksToGroup'` | cell{char} | `{}` | mode='group' 时必填，如 `{'MyModel/Gain1','MyModel/Sum1'}` |
| `'position'` | double[] | `[200,100,400,250]` | mode='empty' 时使用 |
| `'inputPorts'` | double | `1` | 空子系统输入端口数 |
| `'outputPorts'` | double | `1` | 空子系统输出端口数 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.subsystem` | struct | `.path`, `.mode`, `.inputPorts`, `.outputPorts`, `.internalBlocks`(cell) |
| `result.verification` | struct | `.subsystemExists`, `.externalConnectionsPreserved` |
| `result.apiUsed` | char | `'createSubsystem'` / `'manual_group'` / `'manual_empty'` |
| `result.antiPatternInfo` | struct | 反模式#6警告（如触发） |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **createSubsystem 使用模块 handles（数值数组），不是字符串路径！** 函数内部已自动处理
- group 模式下，R2009a+ 使用 `Simulink.BlockDiagram.createSubsystem`，回退为手动实现
- empty 模式下，先添加默认 Subsystem，删除默认连线，再添加指定数量端口
- 反模式#6: 手动创建子系统时返回 warning，建议使用 createSubsystem

---

## 9. 子系统 Mask

### `sl_subsystem_mask(modelName, blockPath, action, varargin)`

创建/编辑 Mask — R2017a+ 推荐 Simulink.Mask / R2016a 回退 legacy API

```matlab
% 创建 Mask
params = {struct('name','Kp','prompt','比例增益','type','edit','defaultValue','1.0'), ...
          struct('name','Ki','prompt','积分增益','type','edit','defaultValue','0.5')};
result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'create', 'parameters', params, 'icon', 'disp(''PID'')')

% 检查 Mask
result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'inspect')

% 编辑 Mask
result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'edit', 'parameters', newParams)

% 删除 Mask
result = sl_subsystem_mask('MyModel', 'MyModel/Controller', 'delete')
```

**REST API 调用格式**（v11.0 重要）：
```json
POST /api/matlab/simulink/subsystem_mask
{
  "modelName": "MyModel",
  "blockPath": "MyModel/Controller",
  "action": "create",
  "parameters": [
    {"name": "Kp", "prompt": "比例增益", "type": "edit", "defaultValue": "1.0"},
    {"name": "Ki", "prompt": "积分增益", "type": "edit", "defaultValue": "0.5"}
  ],
  "icon": "disp('PID')"
}
```

> **注意**: REST API 的参数名为 `parameters`（不是 `maskParams`）。Bridge 自动将 list of dicts 转为 MATLAB cell{struct} 格式（通过 `__special__` 机制）。

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `blockPath` | char | 必选 | 子系统完整路径 |
| `action` | char | 必选 | `'create'`/`'edit'`/`'delete'`/`'inspect'` |
| `'parameters'` | cell{struct} | `{}` | 每个 struct 含 `.name`, `.prompt`, `.type`, `.defaultValue` |
| `'icon'` | char | `''` | Mask 图标命令，如 `'disp(''PID'')'` |
| `'documentation'` | char | `''` | Mask 文档说明 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.mask` | struct | `.path`, `.action`, `.parameterCount`, `.parameters` |
| `result.verification` | struct | `.maskExists`, `.allParametersSet` |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **`parameters` 是 cell{struct}，不是 struct 数组！** 访问用 `opts.parameters{i}.name`
- `type` 可选值: `'edit'`/`'popup'`/`'checkbox'`/`'listbox'`
- R2017a+ 使用 `Simulink.Mask.create`，R2016a 回退 `set_param('Mask','on')` + `MaskPromptString`
- **`maskObj.ParameterCount` 不存在！** 用 `length(maskObj.Parameters)` 获取参数数量
- **删除 Mask 用 `maskObj.delete()`，不是 `Simulink.Mask.delete(blockPath)`！** 后者不存在
- **edit 操作实际是"删除旧 Mask → 重建新 Mask"**，比逐个删除参数更可靠

---

## 10. 添加模块

### `sl_add_block_safe(modelName, sourceBlock, varargin)`

安全添加模块 — 含名称冲突检测+注册表解析+反模式防护+自动验证

```matlab
result = sl_add_block_safe('MyModel', 'Gain')
result = sl_add_block_safe('MyModel', 'simulink/Math Operations/Gain', 'destPath', 'MyModel/Kp', 'params', struct('Gain', '2.5'))
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `sourceBlock` | char | 必选 | 源模块路径或简称（如 `'Gain'` 自动查注册表） |
| `'destPath'` | char | `''` | 目标路径，默认自动命名（如 `'MyModel/Gain'`） |
| `'position'` | double[] | `[]` | 位置 `[left,bottom,right,top]` |
| `'makeNameUnique'` | logical | `true` | 名称冲突时自动重命名 |
| `'params'` | **struct** | `struct()` | **添加后立即设置的参数，必须是 struct！** |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |
| `'skipAntiPatternCheck'` | logical | `false` | 跳过反模式检查 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.block` | struct | `.path`, `.type`, `.sourceBlock`, `.position`, `.params`(如有) |
| `result.verification` | struct | `.blockExists`, `.actualType`, `.allParamsCorrect`, `.incorrectParams` |

**⚠️ 子系统内使用说明**:
- `modelName` 参数支持传入子系统路径（如 `'MyModel/Cart'`），函数会自动提取顶层模型名（`/` 之前的部分）用于 `bdIsLoaded`/`load_system` 检查
- 在子系统内添加模块时，`destPath` 应使用子系统内的相对路径（如 `'MyModel/Cart/Gain1'`），或留空让函数自动命名
- 示例：`sl_add_block_safe('MyModel/Cart', 'Gain', 'destPath', 'MyModel/Cart/Kp', 'params', struct('Gain', '2.5'))`
| `result.antiPatternWarnings` | cell{struct} | 反模式警告（如有），每项含 `.rule`, `.level`, `.message`, `.suggestion` |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- **`params` 必须是 struct，不是 name-value pairs！**
  - ✅ `'params', struct('Gain', '2.5', 'Multiplication', 'Element-wise(K*u)')`
  - ❌ `'params', 'Gain', '2.5'`（错误！会被当成另一个 name-value 参数）
- `sourceBlock` 不含 `/` 时自动查 `sl_block_registry`，如 `'Gain'` → `'simulink/Math Operations/Gain'`
- `destPath` 为空时自动生成为 `modelName/类型名`，如 `'MyModel/Gain'`
- 反模式 #1: Sum 块会触发 warning，建议用 Add/Subtract
- 反模式 #2: To Workspace 块会触发 warning，建议用 sl_signal_logging

---

## 11. 安全连线

### `sl_add_line_safe(modelName, varargin)`

安全连线 — 含端口预检+占用检查+反模式防护+自动验证

```matlab
% 格式1: 5参数
result = sl_add_line_safe('MyModel', 'MyModel/Step', 1, 'MyModel/Sum', 1)

% 格式2: 'Block/port' 格式（推荐！更简洁）
result = sl_add_line_safe('MyModel', 'Step/1', 'Sum/1')
result = sl_add_line_safe('MyModel', 'MyModel/Step/1', 'MyModel/Sum/1')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| **格式1**: `srcBlock, srcPort, dstBlock, dstPort` | char, double, char, double | — | 源模块路径, 源端口序号, 目标模块路径, 目标端口序号 |
| **格式2**: `'srcBlock/portNum', 'dstBlock/portNum'` | char, char | — | 如 `'Step/1'`, `'Sum/1'` |
| `'autoRouting'` | logical | `true` | 自动布线 |
| `'checkBusMatch'` | logical | `false` | 检查 Bus 类型匹配 |
| `'checkDimensions'` | logical | `true` | 检查端口维度匹配（反模式 #8） |
| `'skipAntiPatternCheck'` | logical | `false` | 跳过反模式检查 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.line` | struct | `.srcBlock`, `.srcPort`, `.dstBlock`, `.dstPort`, `.handle` |
| `result.verification` | struct | `.lineExists`, `.srcPortConnected`, `.dstPortConnected` |
| `result.antiPatternInfo` | struct | `.apiUsed`, `.modernAPI`, `.dimensionCheck`(如有) |

**⚠️ 子系统内连线说明**:
- 当 `modelName` 传入子系统路径（如 `'MyModel/Cart'`）时，格式2 的 `'BlockName/1'` 中的 BlockName 是**子系统内的相对路径**（不含模型前缀）
- 例如在 Cart 子系统内连线：`sl_add_line_safe('MyModel/Cart', 'In1/1', 'Gain1/1')` — 不是 `'MyModel/Cart/In1/1'`
- 这是因为 `add_line` 在子系统内执行时，模块名是相对于该子系统的
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- **推荐使用格式2** (`'Block/port'`)，更简洁且自动补全模型名前缀
- 格式2 中 `'Step/1'` 会自动补全为 `'MyModel/Step'`，端口为 1
- `add_line` 内部需要**相对路径**（不含模型名前缀），函数已自动处理
- R2024b+ 会优先使用 `connectBlocks`（反模式 #3），旧版回退 `add_line`
- 端口序号**从 1 开始**，不是 0
- 目标输入端口已被占用时会报错（一个输入端口只能有一条线）

---

## 12. 设置参数

### `sl_set_param_safe(blockPath, params, varargin)`

安全设置参数 — DialogParameters 预检 + 类型转换 + 验证生效

```matlab
result = sl_set_param_safe('MyModel/Kp', struct('Gain', '2.5'))
result = sl_set_param_safe('MyModel/Kp', struct('Gain', '5', 'Multiplication', 'Element-wise(K*u)'), 'validateAfter', true)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `blockPath` | char | 必选 | 模块完整路径，如 `'MyModel/Kp'` |
| `params` | **struct** | 必选 | **要设置的参数名-值对，值必须是字符串！** |
| `'validateAfter'` | logical | `true` | 设置后验证是否生效 |
| `'skipPreCheck'` | logical | `false` | 跳过 DialogParameters 预检 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.block` | struct | `.path`, `.blockType` |
| `result.results` | struct 数组 | 每项: `.param`, `.requestedValue`, `.success`, `.actualValue`, `.message` |
| `result.verification` | struct | `.allParamsCorrect`, `.incorrectParams`(cell) |
| `result.message` | char | 人类可读的总结信息 |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- **第二个参数 `params` 必须是 struct，不是 name-value pairs！**
  - ✅ `sl_set_param_safe('MyModel/Kp', struct('Gain', '5'))`
  - ❌ `sl_set_param_safe('MyModel/Kp', 'Gain', '5')`（错误！）
- `set_param` 要求值为字符串，函数内部自动转换：numeric → `num2str`，logical → `'on'`/`'off'`
- `verification` 中的 `incorrectParams` 是 cell 数组
- 部分成功也返回 `status='ok'`，需检查 `verification.allParamsCorrect`

---

## 13. 模块位置

### `sl_block_position(modelName, varargin)`

模块位置操作（替代裸 Position 向量）— 反模式 #2 的正确替代方案

```matlab
% 获取位置
result = sl_block_position('MyModel', 'action', 'get', 'blockPath', 'MyModel/Gain1')

% 设置位置
result = sl_block_position('MyModel', 'action', 'set', 'blockPath', 'MyModel/Gain1', 'position', [200 100 280 140])

% 相对移动
result = sl_block_position('MyModel', 'action', 'set', 'blockPath', 'MyModel/Gain1', 'relativeMove', [50 0])

% 拓扑排列
result = sl_block_position('MyModel', 'action', 'arrange', 'blockPaths', {'MyModel/Step','MyModel/Gain1'}, 'spacing', 150)

% 对齐
result = sl_block_position('MyModel', 'action', 'align', 'blockPaths', {'MyModel/Step','MyModel/Gain1'}, 'alignDirection', 'horizontal')
```

**REST API 调用格式**（v11.0 重要）：
```json
// 对齐
POST /api/matlab/simulink/block_position
{
  "modelName": "MyModel",
  "action": "align",
  "blockPaths": ["MyModel/Step", "MyModel/Gain1"],
  "alignDirection": "horizontal"
}

// 排列
POST /api/matlab/simulink/block_position
{
  "modelName": "MyModel",
  "action": "arrange",
  "blockPaths": ["MyModel/Step", "MyModel/Gain1"],
  "spacing": 150
}
```

> **注意**: REST API 支持 `blockPaths`（数组）、`alignDirection`、`spacing` 参数（v11.0 补充）。

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'action'` | char | 必选 | `'get'`/`'set'`/`'arrange'`/`'align'` |
| `'blockPath'` | char | `''` | 模块路径（get/set 时必选） |
| `'blockPaths'` | cell{char} | `{}` | 多个模块路径（arrange/align 时必选） |
| `'position'` | double[] | `[]` | `[left, top, right, bottom]`（set 时必选） |
| `'relativeMove'` | double[] | `[]` | `[dx, dy]`（可选，set 时使用） |
| `'alignDirection'` | char | `''` | `'horizontal'`/`'vertical'`（align 时必选） |
| `'spacing'` | double | `150` | 间距（arrange/align 时使用） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**: struct（结构因 action 不同而异）
- **get**: `.blockPosition.position`, `.blockPosition.dimensions{width,height}`, `.blockPosition.center{x,y}`
- **set**: `.blockPosition.oldPosition`, `.blockPosition.newPosition`, `.blockPosition.dimensions`
- **arrange**: `.blockPosition.arranged`（cell{struct}），每项含 `.path`, `.oldPosition`, `.newPosition`
- **align**: `.blockPosition.aligned`（cell{struct}），每项含 `.path`, `.newPosition`

**⚠️ 关键注意**:
- **Position 格式是 `[left, top, right, bottom]`，不是 `[x, y, width, height]`！**
- `relativeMove` 是相对移动 `[dx, dy]`，会同时调整 left/right 和 top/bottom
- arrange 使用 BFS 拓扑排序，自动确定模块的层次位置
- align 的 `horizontal` 模式统一 top 坐标并水平等间距

---

## 14. 信号配置

### `sl_signal_config(modelName, blockPath, portIndex, config, varargin)`

配置信号属性 — 端口数据类型/采样时间/信号名/记录

```matlab
result = sl_signal_config('MyModel', 'MyModel/Gain1', 1, struct('dataType', 'single', 'sampleTime', '0.01'))
result = sl_signal_config('MyModel', 'MyModel/Plant', 1, struct('logging', true, 'loggingName', 'plant_output'))
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `blockPath` | char | 必选 | 模块完整路径 |
| `portIndex` | double | 必选 | 端口索引（从 1 开始） |
| `config` | **struct** | 必选 | 配置项（见下方） |
| `'validateAfter'` | logical | `true` | 验证是否生效 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**`config` struct 可含字段**:
| 字段 | 说明 |
|------|------|
| `.portType` | `'outport'`(默认) 或 `'inport'` |
| `.dataType` | 数据类型，如 `'double'`, `'single'`, `'Bus:MyBus'` |
| `.sampleTime` | 采样时间，如 `'-1'`(继承), `'0.01'` |
| `.signalName` | 信号名称（需先有连线） |
| `.logging` | 是否启用信号记录，`true`/`false` |
| `.loggingName` | 信号记录名称 |
| `.dimensions` | 信号维度，如 `'[3 1]'` |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.signalConfig.blockPath` | char | 模块路径 |
| `result.signalConfig.portIndex` | double | 端口索引 |
| `result.signalConfig.portType` | char | 端口类型 |
| `result.signalConfig.results` | struct 数组 | 每项: `.property`, `.success`, `.setValue`, `.message` |
| `result.signalConfig.verification` | struct | `.allCorrect`, `.mismatches` |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

---

## 15. 信号记录

### `sl_signal_logging(modelName, varargin)`

信号记录配置 — 替代 To Workspace 块的推荐方式

```matlab
% 列出已启用记录的端口
result = sl_signal_logging('MyModel')

% 启用信号记录
result = sl_signal_logging('MyModel', 'action', 'enable', 'blockPath', 'MyModel/Plant', 'portIndex', 1)

% 禁用信号记录
result = sl_signal_logging('MyModel', 'action', 'disable', 'blockPath', 'MyModel/Plant', 'portIndex', 1)

% 配置模型级设置
result = sl_signal_logging('MyModel', 'action', 'configure', 'signalLogging', 'on', 'cfgLoggingName', 'myLogs')
```

**参数**（根据 `action` 不同）:
| 参数 | 类型 | 说明 |
|------|------|------|
| `modelName` | char | 必选，模型名称 |
| `'action'` | char | `'enable'`/`'disable'`/`'list'`/`'configure'` |
| `'blockPath'` | char | enable/disable 时必选 |
| `'portIndex'` | double | enable/disable 时必选 |
| `'portType'` | char | `'outport'`(默认) 或 `'inport'` |
| `'loggingName'` | char | 信号记录名称（enable 时可选） |
| `'decimation'` | double | 抽取因子（默认 1） |
| `'limitDataPoints'` | logical | 是否限制数据点数 |
| `'maxPoints'` | double | 最大数据点数（默认 5000） |
| `'signalLogging'` | char | configure: 模型级开关 `'on'`/`'off'` |
| `'cfgLoggingName'` | char | configure: logsout 变量名 |
| `'saveOutput'` | char | configure: SaveOutput 开关 |
| `'outputSaveName'` | char | configure: 输出变量名 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.signalLogging` | struct | 操作结果（结构因 action 不同而异） |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **enable 时 `blockPath` 和 `portIndex` 是必填参数！**
- configure 的 `cfgLoggingName` 参数名有前缀 `cfg`（避免与 enable 的 `loggingName` 冲突）
- 反模式 #2 的正确替代方案：用 `sl_signal_logging` 替代 To Workspace 块

---

## 16. 回调设置

### `sl_callback_set(modelName, action, varargin)`

设置回调函数 — 模型/块级回调的 set/get/remove/list

```matlab
% 设置模型级回调
result = sl_callback_set('MyModel', 'set', 'target', 'model', 'callbackType', 'StartFcn', 'callbackCode', 'disp(''sim_start'')')

% 设置块级回调
result = sl_callback_set('MyModel', 'set', 'target', 'block', 'blockPath', 'MyModel/Gain1', 'callbackType', 'InitFcn', 'callbackCode', 'disp(''init'')')

% 获取回调
result = sl_callback_set('MyModel', 'get', 'target', 'model', 'callbackType', 'StartFcn')

% 列出所有回调
result = sl_callback_set('MyModel', 'list', 'target', 'model')

% 删除回调
result = sl_callback_set('MyModel', 'remove', 'target', 'model', 'callbackType', 'StartFcn')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `action` | char | 必选 | `'set'`/`'get'`/`'remove'`/`'list'` |
| `'target'` | char | `'model'` | `'model'` 或 `'block'` |
| `'blockPath'` | char | `''` | 模块路径（target='block' 时必填） |
| `'callbackType'` | char | `''` | 回调类型（set/get/remove 时必填） |
| `'callbackCode'` | char | `''` | 回调代码（set 时必填） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**模型级回调类型**: `PreLoadFcn`, `PostLoadFcn`, `PreSaveFcn`, `PostSaveFcn`, `InitFcn`, `StartFcn`, `StopFcn`, `CloseFcn`

**块级回调类型**: `OpenFcn`, `DeleteFcn`, `CopyFcn`, `InitFcn`, `LoadFcn`, `ModelCloseFcn`, `NameChangeFcn`, `ParentCloseFcn`, `PreSaveFcn`, `PostSaveFcn`, `UndoFcn`

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.callback` | struct | 操作结果（结构因 action 不同而异） |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **`action` 是第二个位置参数**，不是 name-value 对
- `set` 时必须同时提供 `callbackType` 和 `callbackCode`
- `callbackCode` 中的单引号需要双重转义：`'disp(''''hello'''')'`

---


---

> **Step 3: 配置**

## 17. 模型配置

### `sl_config_get(modelName, varargin)`

获取模型配置 — 按 Solver/Simulation/Codegen/Diagnostics 分类

```matlab
result = sl_config_get('MyModel')
result = sl_config_get('MyModel', 'categories', {'solver', 'simulation'})
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'categories'` | char 或 cell | `'all'` | `'solver'`/`'simulation'`/`'codegen'`/`'diagnostics'` 或 cell 数组 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.config` | struct | 按类别组织，如 `.solver.Solver`, `.simulation.StopTime` |
| `result.message` | char | 总结信息 |
| `result.warnings` | cell{char} | 警告列表（如有） |
| `result.error` | char | 错误信息 |

---

### `sl_config_set(modelName, config, varargin)`

设置模型配置 — 逐参数设置 + SolverType 变更特殊处理 + 验证

```matlab
result = sl_config_set('MyModel', struct('StopTime', '20', 'Solver', 'ode4', 'FixedStep', '0.001'))
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `config` | **struct** | 必选 | **要设置的配置参数名-值对** |
| `'autoVerify'` | logical | `true` | 设置后验证每个参数是否生效 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.results` | struct 数组 | 每项: `.param`, `.value`, `.success`, `.actualValue`, `.message` |
| `result.verification` | struct | `.allCorrect`, `.incorrectParams`(cell) |
| `result.solverAdvice` | char | SolverType 变更时的自动建议 |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **第二个参数 `config` 必须是 struct！**
  - ✅ `sl_config_set('MyModel', struct('StopTime', '50'))`
  - ❌ `sl_config_set('MyModel', 'StopTime', '50')`（错误！）
- Solver 名称映射：变步长 `ode45/ode23/...`，固定步长 `ode1/ode2/ode4/...`
- 切换 `SolverType` 时会自动给出建议（如切换到 Fixed-step 需设置 FixedStep）

---


---

> **Step 4: 验证+排版+快照**

## 18. 模型验证

### `sl_validate_model(modelName, varargin)`

12 项健康检查

```matlab
result = sl_validate_model('MyModel')
result = sl_validate_model('MyModel', 'checks', 'all')
result = sl_validate_model('MyModel', 'checks', {'unconnected', 'variables'})
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'checks'` | char 或 cell | `'all'` | 检查项：`unconnected`, `dimensions`, `variables`, `compilation`, `algebraic_loop`, `sample_time`, `bus_mismatch`, `data_type_conflict`, `masked_blocks`, `model_ref`, `config_issue`, `callback_issue` |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.overall` | char | `'pass'` / `'warning'` / `'fail'` |
| `result.message` | char | 总结信息 |
| `result.checks` | struct 数组 | 每项含 `.name`, `.status`, `.message`, `.details` |

**⚠️ 关键注意**:
- `checks` 是 **struct 数组**（不是 cell），访问用 `result.checks(i).name`
- `compilation` 检查用 `model('compile')` 方式，在 Engine 模式下可能不支持

---

## 19. 自动排版

### `sl_auto_layout(modelName, varargin)`

自动排版 — R2023a+ arrangeSystem 优先 / 旧版手动回退

```matlab
result = sl_auto_layout('MyModel')
result = sl_auto_layout('MyModel', 'target', 'top', 'routeExistingLines', true)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'target'` | char | `'top'` | `'top'`（顶层）或具体子系统路径 |
| `'routeExistingLines'` | logical | `true` | 是否自动布线已有信号线 |
| `'resizeBlocks'` | logical | `false` | 是否调整模块大小（R2024b+） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.layout` | struct | `.target`, `.blocksRearranged`, `.linesRouted`, `.method` |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **`arrangeSystem` 的 `FullLayout` 参数接受字符串 `'true'`/`'false'`，不是逻辑值！**
- **`routeLine` 接受 line handles 数组，不是模型名！** 函数内部已自动处理
- **[v11.0 严重] `arrangeSystem` 在 MATLAB Engine 模式下可能清空模型内容！** v11.0 已添加排版前 `save_system` + 排版后 `find_system` 验证完整性 + 异常恢复（close_system + load_system）
- R2023a+ 使用 `arrangeSystem` + `routeLine`，R2016a~R2022b 使用 BFS 拓扑排序手动布局
- `method` 返回值: `'native_arrangeSystem'` / `'fallback_manual'`
- 与 `sl_arrange_model` 的区别: `sl_auto_layout` 更轻量（无 layoutGuide、无 scale），`sl_arrange_model` 功能更丰富

---

## 20. 布局整理

### `sl_arrange_model(modelName, varargin)`

整理模型布局 — 让 AI 构建的模型人类可读

```matlab
result = sl_arrange_model('MyModel')
result = sl_arrange_model('MyModel', 'routeLines', true, 'scale', 1.5)
result = sl_arrange_model('MyModel', 'layoutGuide', guideStruct)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'routeLines'` | logical | `true` | 是否整理连线走向 |
| `'scale'` | double | `1.0` | arrangeSystem 后的缩放因子（仅 native，>1.0 才缩放） |
| `'spacing'` | double | `200` | 同层模块垂直间距（仅 fallback） |
| `'layerGap'` | double | `400` | 层间水平间距（仅 fallback） |
| `'blockGap'` | double | 同 spacing | 同层相邻模块间垂直间距（仅 fallback） |
| `'margin'` | double[] | `[80 80]` | 左上角起始边距 [x,y] |
| `'layoutGuide'` | struct | `[]` | 布局语义指导（见下方说明） |
| `'forceNative'` | logical | `false` | 强制使用高版本 API |
| `'forceFallback'` | logical | `false` | 强制使用回退方案 |

**`layoutGuide` 结构**:
```matlab
guide = struct();
guide.lanes = {struct('name','forward','blocks',{'Step','Sum','Gain'},'yCenter',100)};
guide.feedbacks = {struct('blocks',{'Gain'},'yOffset',150)};
```

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.method` | char | `'native'`/`'fallback'`/`'guided_native'`/`'guided_fallback'` |
| `result.message` | char | 人类可读的描述信息 |
| `result.blocks` | cell{struct} | 整理后的模块位置信息 |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- R2018b+ 使用 `arrangeSystem('FullLayout','true')` + `routeLine`
- R2016a~R2018a 使用拓扑排序 + 分层居中布局（fallback）
- **`FullLayout` 参数接受字符串 `'true'`/`'false'`，不是逻辑值！**
- `arrangeSystem` 只改变模块位置，不改变尺寸
- `routeLine` 接受的是 line handles 数组（不是模型名！），函数内部已处理

---

## 21. 模型快照

### `sl_snapshot_model(modelName, action, varargin)`

模型快照/回滚 — 保存模型快照到临时目录 → 可回滚到任意快照

```matlab
% 创建快照
result = sl_snapshot_model('MyModel', 'create')
result = sl_snapshot_model('MyModel', 'create', 'snapshotName', 'before_pid', 'description', 'Before PID')

% 列出快照
result = sl_snapshot_model('MyModel', 'list')

% 回滚到快照
result = sl_snapshot_model('MyModel', 'rollback', 'snapshotName', 'before_pid')

% 删除快照
result = sl_snapshot_model('MyModel', 'delete', 'snapshotName', 'before_pid')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `action` | char | 必选 | `'create'`/`'rollback'`/`'list'`/`'delete'` |
| `'snapshotName'` | char | 自动时间戳 | 快照名称（create/delete/rollback 时可选） |
| `'description'` | char | `''` | 快照描述（create 时可选） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**: struct（结构因 action 不同而异）
- **create**: `.snapshot.action`, `.snapshot.snapshotName`, `.snapshot.snapshotPath`, `.snapshot.modelName`, `.snapshot.timestamp`, `.snapshot.description`
- **rollback**: `.snapshot.snapshotName`, `.snapshot.restored`, `.snapshot.originalPath`
- **list**: `.snapshot.count`, `.snapshot.snapshots`(cell{struct})
- **delete**: `.snapshot.snapshotName`, `.snapshot.deleted`

**⚠️ 关键注意**:
- 快照存储位置: `tempdir/sl_snapshots/<modelName>/`
- **快照名不能与模型名相同！** 如果相同会自动添加 `sl_snap_` 前缀
- 回滚流程: 关闭模型 → 加载快照 → 保存到原始路径
- 快照是完整 .slx 文件副本，占用磁盘空间

---

## 22. 查找模块

### `sl_find_blocks(modelName, varargin)`

高级查找 — 按类型/参数/连接状态过滤

```matlab
result = sl_find_blocks('MyModel')
result = sl_find_blocks('MyModel', 'blockType', 'Gain', 'searchDepth', 1)
result = sl_find_blocks('MyModel', 'connectionFilter', 'unconnected_input')
result = sl_find_blocks('MyModel', 'connected', false)  % 快捷参数
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'blockType'` | char | `''` | 按 BlockType 过滤 |
| `'paramFilter'` | struct | `struct()` | 按参数值过滤，如 `struct('Gain','2.5')` |
| `'connectionFilter'` | char | `''` | `'unconnected_input'`/`'unconnected_output'`/`'connected'` |
| `'connected'` | logical | — | 快捷参数: `true`=已连接, `false`=未连接输入 |
| `'maskFilter'` | logical | `false` | 只返回有 Mask 的模块 |
| `'searchDepth'` | double | `1` | 搜索深度，0=全部层级 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.count` | double | 匹配模块数 |
| `result.blocks` | **cell{struct}** | 每项含 `.path`, `.type`, `.params`(struct) |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- **`blocks` 是 cell 数组，不是 struct 数组！** 访问需用 `result.blocks{i}.path`
- `connected` 是 `connectionFilter` 的快捷别名
- `paramFilter` 的值比较是字符串不区分大小写

---


---

> **Step 5: 仿真+测试**

## 23. 仿真运行

### `sl_sim_run(modelName, varargin)`

增强版仿真运行 — SimulationInput 优先 + 超时保护 + 变量注入 + 结果摘要

```matlab
result = sl_sim_run('MyModel')
result = sl_sim_run('MyModel', 'stopTime', '10', 'solver', 'ode45')
result = sl_sim_run('MyModel', 'variables', struct('Kp', 2.0), 'stopTime', '20')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'stopTime'` | char | `''` | 仿真停止时间 |
| `'solver'` | char | `''` | 求解器 |
| `'variables'` | struct | `struct()` | 仿真前注入工作区变量 |
| `'preCheck'` | logical | `true` | 仿真前自动检查 |
| `'returnResults'` | logical | `true` | 是否自动提取结果摘要 |
| `'timeout'` | double | `300` | 仿真超时（秒） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.simulation.success` | logical | 仿真是否成功 |
| `result.simulation.elapsedTime` | char | 耗时如 `'1.23s'` |
| `result.simulation.solver` | char | 实际使用的求解器 |
| `result.simulation.stopTime` | char | 实际停止时间 |
| `result.simulation.apiUsed` | char | `'SimulationInput'` 或 `'legacy sim'` |
| `result.preCheckResults` | struct | `.passed`, `.warnings`（仅 preCheck=true） |
| `result.results` | struct | `.outputVars`, `.loggedSignals`, `.summary` |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- R2017a+ 使用 `Simulink.SimulationInput`，R2016a 回退 `set_param+sim()`
- `variables` 通过 `SimulationInput.setVariable()` 注入（R2017a+），或 `assignin('base',...)` （R2016a）
- 超时保护通过 MATLAB `timer` 实现
- `simulation.success` 是 logical 值

---

## 24. 仿真结果

### `sl_sim_results(modelName, varargin)`

提取仿真结果 — timeseries/Dataset/struct/array 自动识别 + 降采样

```matlab
result = sl_sim_results('MyModel')
result = sl_sim_results('MyModel', 'variables', {'yout', 'logsout'})
result = sl_sim_results('MyModel', 'format', 'full', 'maxRows', 1000)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'variables'` | cell{char} | `{'yout','logsout','tout','xout'}` | 要提取的变量名 |
| `'format'` | char | `'summary'` | `'summary'` 或 `'full'` |
| `'maxRows'` | double | `1000` | full 格式最大行数（降采样） |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.results` | struct | 每个变量一个字段，含 `.type`, `.dimensions`, 统计等 |
| `result.message` | char | 总结信息 |
| `result.warnings` | cell{char} | 警告列表 |

---

## 25. 批量仿真

### `sl_sim_batch(modelName, varargin)`

批量/并行仿真 — parsim 并行优先 + 串行 sim 回退

```matlab
% 模式1: 单参数扫描
result = sl_sim_batch('MyModel', 'parameterName', 'Kp', 'parameterValues', [0.5 1.0 1.5 2.0])

% 模式2: 多变量 paramSets
paramSets = {struct('Gain',2), struct('Gain',5), struct('Gain',10)};
result = sl_sim_batch('MyModel', paramSets, 'stopTime', '10')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| **模式1**: `'parameterName'` | char | — | 要扫描的参数名 |
| **模式1**: `'parameterValues'` | double[] | — | 参数值数组 |
| **模式2**: 第2个参数 | cell{struct} | — | paramSets，如 `{struct('Gain',2), struct('Gain',5)}` |
| `'baseConfig'` | struct | `struct()` | 基础仿真配置 `.stopTime`, `.solver` |
| `'parallel'` | logical | `true` | 是否使用并行（parsim） |
| `'showProgress'` | logical | `true` | 显示进度 |
| `'timeout'` | double | `60` | 单次仿真超时（秒） |
| `'extractSummary'` | logical | `true` | 提取每次仿真摘要 |
| `'stopTime'` | char | — | 快捷参数，等同于 `baseConfig.stopTime` |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.simBatch.totalRuns` | double | 总运行次数 |
| `result.simBatch.completedRuns` | double | 完成次数 |
| `result.simBatch.failedRuns` | double | 失败次数 |
| `result.simBatch.apiUsed` | char | `'parsim'`/`'serial sim loop'` |
| `result.simBatch.elapsedTime` | char | 总耗时 |
| `result.simBatch.results` | cell{struct} | 每次仿真结果 |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- **模式2 的 paramSets 是第2个位置参数**，不是 name-value 对！
  - ✅ `sl_sim_batch('MyModel', {struct('Gain',2), struct('Gain',5)}, 'stopTime', '10')`
  - ❌ `sl_sim_batch('MyModel', 'paramSets', {struct('Gain',2)})`（错误！）
- `results` 是 **cell 数组**，不是 struct 数组
- R2017a+ 使用 `parsim` 并行，R2016a 回退串行循环

---

## 26. 基线测试

### `sl_baseline_test(modelName, varargin)`

创建或运行基线回归测试 — 仿真一次生成基线数据，后续运行自动比较信号一致性

```matlab
% 创建基线测试（生成基线数据 + 测试文件）
result = sl_baseline_test('MyModel', 'action', 'create')

% 创建时指定名称和容差
result = sl_baseline_test('MyModel', 'action', 'create', 'testName', 'pid_test', ...
    'tolerance', struct('relTol', 0.02, 'absTol', 1e-5))

% 运行基线测试
result = sl_baseline_test('MyModel', 'action', 'run')

% 重新生成基线数据
result = sl_baseline_test('MyModel', 'action', 'regenerate')

% 列出所有基线测试
result = sl_baseline_test('MyModel', 'action', 'list')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'action'` | char | 必选 | `'create'`/`'run'`/`'regenerate'`/`'list'` |
| `'testName'` | char | `modelName+'Test'` | 测试名称 |
| `'baselineDir'` | char | `sl_toolbox/tests/baselines/` | 基线文件保存目录 |
| `'tolerance'` | **struct** | `struct('relTol',0.01,'absTol',1e-6)` | 比较容差 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**: struct（结构因 action 不同而异）
- **create**: `.baselineTest.action`, `.baselineTest.testName`, `.baselineTest.testFilePath`, `.baselineTest.baselineFilePath`, `.baselineTest.status`, `.baselineTest.hasSLTestLicense`, `.baselineTest.signalCount`
- **run**: `.baselineTest.action`, `.baselineTest.testName`, `.baselineTest.status`(`'passed'`/`'failed'`), `.baselineTest.hasSLTestLicense`, `.baselineTest.failedSignals`(cell, 无许可证时), `.baselineTest.passedSignals`(cell, 无许可证时), `.baselineTest.failureInfo`(char, 有许可证时)
- **regenerate**: `.baselineTest.action`, `.baselineTest.baselineFilePath`, `.baselineTest.signalCount`, `.baselineTest.timestamp`
- **list**: `.baselineTest.action`, `.baselineTest.modelName`, `.baselineTest.baselineCount`, `.baselineTest.baselines`(cell{struct}), `.baselineTest.testFileCount`, `.baselineTest.testFiles`(cell{char})

**⚠️ 关键注意**:
- **`tolerance` 必须是 struct，包含 `.relTol` 和 `.absTol` 字段！**
- 有 Simulink Test 许可证时生成 `sltest.TestCase`，无许可证时生成手动比较测试
- 基线数据存储为 `.mat` 文件（`<modelName>_baseline.mat`）
- 测试文件存储在 `sl_toolbox/tests/` 目录下
- `regenerate` 会重新运行仿真并覆盖基线数据

---

## 27. 仿真性能分析

### `sl_profile_sim(modelName, varargin)`

运行仿真性能分析（Simulink Profiler）— 识别瓶颈模块 + 生成优化建议

```matlab
% 运行仿真性能分析
result = sl_profile_sim('MyModel', 'action', 'run')

% 指定停止时间
result = sl_profile_sim('MyModel', 'action', 'run', 'stopTime', '20')

% 查看上次分析报告
result = sl_profile_sim('MyModel', 'action', 'report')

% 与基线 profile 对比
result = sl_profile_sim('MyModel', 'action', 'compare', 'baselineProfile', prevResult.profileSim)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'action'` | char | 必选 | `'run'`/`'report'`/`'compare'` |
| `'stopTime'` | char | `''` | 覆盖仿真停止时间 |
| `'baselineProfile'` | struct | `struct()` | action='compare' 时的基线 profile 数据 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**: struct（结构因 action 不同而异）
- **run**: `.profileSim.action`, `.profileSim.totalTime`, `.profileSim.apiUsed`, `.profileSim.matlabVersion`, `.profileSim.solverInfo`, `.profileSim.blockCount`, `.profileSim.topBottlenecks`(cell{struct}), `.profileSim.suggestions`(cell{struct}), `.profileSim.allBlockStats`(cell{struct}), `.profileSim.profileData`
- **report**: `.profileSim.action`, `.profileSim.blockCount`, `.profileSim.topBottlenecks`, `.profileSim.suggestions`, `.profileSim.allBlockStats`
- **compare**: `.profileSim.action`, `.profileSim.comparisonCount`, `.profileSim.comparisons`(cell{struct})

**`topBottlenecks` 每项含**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.blockPath` | char | 模块路径 |
| `.blockType` | char | 模块类型 |
| `.selfTime` | char | 自身耗时（如 `'0.123s'`） |
| `.totalTime` | char | 总耗时（含子调用） |
| `.percentage` | double | 占总时间百分比 |
| `.suggestion` | char | 优化建议 |

**`suggestions` 每项含**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.priority` | char | `'high'`/`'medium'`/`'low'` |
| `.blockPath` | char | 关联模块路径（为空表示全局建议） |
| `.suggestion` | char | 优化建议文本 |
| `.percentage` | double | 影响占比 |

**`comparisons` 每项含**（action='compare'时）:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.blockPath` | char | 模块路径 |
| `.currentTime` | double | 当前耗时 |
| `.baselineTime` | double | 基线耗时 |
| `.timeDiff` | double | 耗时差值 |
| `.pctChange` | double | 变化百分比 |
| `.change` | char | `'slower'`/`'faster'`/`'unchanged'`/`'new_block'` |

**⚠️ 关键注意**:
- R2017a+ 优先使用 `Simulink.profiler.run()`，R2016a 回退 `profile on/off + sim`
- `report` 需要先运行 `run`，否则会返回错误
- `compare` 的 `baselineProfile` 可以是上次 `run` 结果的 `.profileSim` 或其 `.allBlockStats`
- `allBlockStats` 是 **cell 数组**，访问用 `result.profileSim.allBlockStats{i}.blockPath`
- 瓶颈排名最多返回 10 个，只报告占比 > 0.1% 的模块
- Interpreted MATLAB Function 模块会触发高优先级建议（替换为 MATLAB Function）

---

## 28. 求解器性能分析

### `sl_profile_solver(modelName, varargin)`

运行求解器性能分析（Solver Profiler）— 诊断零交叉/重置/代数环/刚性 + 求解器推荐

```matlab
% 运行求解器性能分析
result = sl_profile_solver('MyModel', 'action', 'run')

% 指定停止时间
result = sl_profile_solver('MyModel', 'action', 'run', 'stopTime', '50')

% 查看求解器报告
result = sl_profile_solver('MyModel', 'action', 'report')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `'action'` | char | 必选 | `'run'`/`'report'` |
| `'stopTime'` | char | `''` | 覆盖仿真停止时间 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**: struct（结构因 action 不同而异）
- **run**: `.profileSolver.action`, `.profileSolver.apiUsed`, `.profileSolver.matlabVersion`, `.profileSolver.solverInfo`, `.profileSolver.diagnostics`, `.profileSolver.solverRecommendations`(cell{struct})
- **report**: `.profileSolver.action`, `.profileSolver.solverInfo`, `.profileSolver.diagnostics`, `.profileSolver.solverRecommendations`

**`solverInfo` 结构**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.name` | char | 求解器名称（如 `'ode45'`） |
| `.type` | char | `'Variable-step'`/`'Fixed-step'` |

**`diagnostics` 结构**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.zeroCrossings` | struct | `.count`(double), `.locations`(cell{char}), `.suggestion`(char) |
| `.resets` | struct | `.count`(double), `.locations`(cell{char}), `.suggestion`(char) |
| `.algebraicLoops` | struct | `.detected`(logical), `.locations`(cell{char}), `.suggestion`(char), `.note`(char, 可选) |
| `.stiffness` | struct | `.detected`(logical), `.suggestion`(char) |
| `.stepSizeHistory` | struct | `.available`(logical), `.summary`(char) |
| `.warningInfo` | char | 警告信息（可选，分析回退时出现） |
| `.solverSteps` | double | 估算的求解器步数（可选） |

**`solverRecommendations` 每项含**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `.currentSolver` | char | 当前求解器 |
| `.recommendedSolver` | char | 推荐求解器 |
| `.reason` | char | 推荐原因 |
| `.priority` | char | `'high'`/`'medium'`/`'low'`/`'info'` |

**⚠️ 关键注意**:
- R2020b+ 使用 `Simulink.sdi.diag.solverProfiler`，R2016a~R2020a 回退手动分析
- 手动分析通过 `find_system` 查找零交叉源模块、Integrator 重置等，精度有限
- `report` 会尝试编译模型来检测代数环，可能影响模型状态
- 刚性诊断依据: 步长比 > 1000、TransferFcn > 2 个、或存在 TransportDelay
- 零交叉 > 10 个会触发建议使用固定步长求解器
- 求解器类型推断: `ode1/ode2/ode3/ode4/ode5/ode8/ode14x/ode1be/discrete` → Fixed-step，其余 → Variable-step
- `diagnostics.warningInfo` 为可选字段，仅在 Solver Profiler 或手动分析回退失败时出现

---

## 通用编码规则

> **以下规则适用于所有 sl_toolbox .m 函数，大模型生成 MATLAB 代码时必须遵守！**

1. **禁止 4 字节 UTF-8 emoji**：🔴✅❌⚠️ 等在 .m 文件中会导致"文本字符无效"错误，必须用 ASCII 标记如 `[CRITICAL]`/`[OK]`/`[X]`/`[WARN]`
2. **struct 字段名不能以 `_` 开头**：`obj._warning` 非法，必须用 `obj.warningInfo` 等合法命名
3. **struct 构造必须分步赋值**：`struct('field', cellVal)` 中 cell 会导致 struct 展开为空数组，必须 `s=struct(); s.field=cellVal`
4. **R2016a 兼容**：不用 `contains()`/`newline`/字符串空格拼接，用 `~isempty(strfind())`/`char(10)`/`[]`

---


---

> **出错恢复**

## 29. 错误解析

### `sl_parse_error(errorMessage, varargin)`

精确错误解析 — 15 种错误类型正则匹配 + 结构化诊断 + 修复建议

```matlab
result = sl_parse_error('Dimension mismatch at port 1')
result = sl_parse_error(errMsg, 'modelName', 'MyModel')
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `errorMessage` | char | 必选 | Simulink 错误信息字符串 |
| `'modelName'` | char | `''` | 关联模型名 |
| `'context'` | struct | `struct()` | 上下文信息 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'`（成功解析）或 `'unknown'`（无匹配） |
| `result.errorAnalysis.type` | char | 错误类型标识符 |
| `result.errorAnalysis.confidence` | char | `'high'`/`'medium'`/`'low'` |
| `result.errorAnalysis.description` | char | 错误描述 |
| `result.errorAnalysis.suggestion` | char | 修复建议 |
| `result.errorAnalysis.relatedBlock` | char | 关联模块路径 |
| `result.errorAnalysis.severity` | char | `'error'`/`'warning'`/`'info'` |
| `result.alternatives` | cell{struct} | 其他可能的匹配 |
| `result.message` | char | 总结信息 |

**⚠️ 关键注意**:
- **错误类型在 `result.errorAnalysis.type`，不是 `result.errorType`！**
- 支持中文错误消息（如 `函数或变量 'xxx' 无法识别` → `unresolved_variable`）
- 15 种错误类型包括：`port_dimension_mismatch`, `target_port_occupied`, `unresolved_variable`, `algebraic_loop`, `invalid_block_path`, `compilation_error`, `sample_time_conflict`, `data_type_mismatch`, `bus_not_found`, `block_diagram_error`, `mask_parameter_error`, `model_ref_not_found`, `solver_error`, `signal_logging_error`, `codegen_error`

---

## 30. 删除模块

### `sl_delete_safe(blockPath, varargin)`

安全删除模块 — 记录连线 + 可选级联删除悬空连线 + 验证删除

```matlab
result = sl_delete_safe('MyModel/Gain1')
result = sl_delete_safe('MyModel/Gain1', 'cascade', true)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `blockPath` | char | 必选 | 模块完整路径，如 `'MyModel/Gain1'` |
| `'cascade'` | logical | `false` | 级联删除悬空连线 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |
| `'force'` | logical | `false` | 强制删除（不检查是否被引用） |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.deleted` | struct | `.blockPath`, `.blockType`, `.connectedLines`(cell{struct}) |
| `result.orphanedLines` | cell{struct} | 悬空连线列表（`cascade=false` 时） |
| `result.cascadeResult` | struct | `.deleted`(cell), `.errors`(cell)（`cascade=true` 时） |
| `result.message` | char | 人类可读的总结信息 |
| `result.error` | char | 错误信息（仅 status='error'） |

**⚠️ 关键注意**:
- `delete_block` 会自动删除与被删模块关联的所有连线
- `cascade=true` 时会额外清理悬空连线，`orphanedLines` 会被清空
- 模型名自动从 `blockPath` 中提取（取第一个 `/` 之前的部分）

---

## 31. 替换模块

### `sl_replace_block(modelName, blockPath, newBlockType, varargin)`

替换模块 — 保留连线 + 参数迁移 + 新模块自动对齐端口位置

```matlab
result = sl_replace_block('MyModel', 'MyModel/Gain1', 'Sine Wave')
result = sl_replace_block('MyModel', 'MyModel/Gain1', 'simulink/Sources/Sine Wave', ...
    'preservePosition', true, 'migrateParams', struct('Gain', 'Amplitude'))
```

**REST API 调用格式**（v11.0 重要）：
```json
POST /api/matlab/simulink/replace_block
{
  "modelName": "MyModel",
  "blockPath": "MyModel/Gain1",
  "newBlockType": "Sine Wave",
  "preservePosition": true,
  "migrateParams": {"Gain": "Amplitude"}
}
```

> **注意**: REST API 的 `migrateParams` 默认值为 `{}`（空对象/空 struct），不是 `true`。如需自动迁移参数，请传入参数名映射对象，如 `{"Gain": "Amplitude"}`。

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `blockPath` | char | 必选 | 要替换的模块完整路径 |
| `newBlockType` | char | 必选 | 新模块类型或完整路径（如 `'Sine Wave'` 或 `'simulink/Sources/Sine Wave'`） |
| `'preservePosition'` | logical | `true` | 保留原位置 |
| `'migrateParams'` | struct | `struct()` | 旧参数名→新参数名映射，如 `struct('Gain','Amplitude')` |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.replaced` | struct | `.oldBlock`, `.newBlock`, `.connectionsPreserved`, `.paramsMigrated` |
| `result.verification` | struct | `.newBlockExists`, `.allConnectionsRestored` |
| `result.message` | char | 总结信息 |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- `newBlockType` 不含 `/` 时自动查 `sl_block_registry`
- 替换流程: 记录连线 → 删除旧模块 → 添加新模块 → 恢复连线 → 参数迁移
- 连线恢复使用 `'BlockName/portIdx'` 字符串格式，带 `'autorouting','on'`
- 端口数量不匹配时连接尽可能多的端口，剩余报 warning
- 端口数量不匹配时连接尽可能多的端口，剩余报 warning

---

## 32. 子系统展开

### `sl_subsystem_expand(modelName, subsystemPath, varargin)`

展开子系统 — 解除 Mask → 移动内部模块到父级 → 删除子系统外壳

```matlab
result = sl_subsystem_expand('MyModel', 'MyModel/Controller')
result = sl_subsystem_expand('MyModel', 'MyModel/Controller', 'preservePosition', true)
```

**参数**:
| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `modelName` | char | 必选 | 模型名称 |
| `subsystemPath` | char | 必选 | 子系统完整路径 |
| `'preservePosition'` | logical | `true` | 保留原坐标 |
| `'loadModelIfNot'` | logical | `true` | 模型未加载时自动加载 |

**返回**:
| 字段 | 类型 | 说明 |
|------|------|------|
| `result.status` | char | `'ok'` 或 `'error'` |
| `result.expanded` | struct | `.subsystemPath`, `.blocksMoved`(cell), `.connectionsRestored` |
| `result.verification` | struct | `.subsystemRemoved`, `.allBlocksExist` |
| `result.error` | char | 错误信息 |

**⚠️ 关键注意**:
- R2023b+ 使用 `Simulink.BlockDiagram.expandSubsystem`，R2016a 回退手动实现
- 手动回退: 记录内部模块 → 复制到父级 → 重建连线 → 删除子系统
- **展开前会自动解除 Mask**，使用 `maskObj.delete()`（非 `Simulink.Mask.delete`）

---


---

> **基础设施与集成参考**

## 33. JSON 编码

### `sl_jsonencode(data)`

兼容 R2016a+ 的 JSON 编码器

```matlab
jsonStr = sl_jsonencode(result)
```

**参数**:
| 参数 | 类型 | 说明 |
|------|------|------|
| `data` | 任意 | 要编码的数据 |

**返回**: char — JSON 字符串

**⚠️ 关键注意**:
- R2016b+ 优先使用内置 `jsonencode`，R2016a 回退自定义实现
- 不支持自定义对象，需先手动转为 struct
- R2023b 内置 `jsonencode` 对 struct 中的 cell 数组会展开，需扁平化结构

---

## 34. 通用约定

### 所有函数通用的约定

1. **返回结构统一**:
   - `result.status` — `'ok'` 或 `'error'`（所有函数都有）
   - `result.message` — 人类可读的总结信息（几乎所有函数都有）
   - `result.error` — 错误信息（仅 status='error' 时有内容）

2. **参数传递方式**:
   - 所有函数使用 **name-value pairs + varargin** 模式
   - `params`/`config` 类参数统一使用 **struct**（不是额外的 name-value pairs）
   - 例外：`sl_callback_set` 的 `action` 是第二个位置参数

3. **数据类型约定**:
   - `set_param` 要求值为字符串，函数内部自动转换
   - 逻辑值：`'on'`/`'off'` → MATLAB 内部 `true`/`false`
   - 数值：`num2str` 自动转换

4. **模块路径格式**:
   - 完整路径：`'ModelName/BlockName'`（如 `'pid_temp_ctrl/Kp'`）
   - 相对路径：`'BlockName'`（如 `'Kp'`，部分函数内部自动补全）

5. **端口索引从 1 开始**（不是 0）

6. **`loadModelIfNot` 参数**: 大多数函数支持，默认 `true`

7. **R2016a 兼容性**:
   - 不用 `contains()`，用 `~isempty(strfind(lower(s),lower(p)))`
   - 不用 `newline`，用 `char(10)`
   - 不用字符串空格拼接，用 `[]`
   - cell 动态增长 `{end+1}` 不可靠，预分配 `cell(1,N)`

8. **find_system SearchDepth 顺序**: SearchDepth 必须放在 Simulink 参数名（如 Type）之前，否则被忽略

---

## 35. Python Bridge 集成 (Part 6)

> **v8.0 新增** — Python Bridge 层新增 26 个 `sl_*` 命令处理器，实现 Node.js → Python → MATLAB 的完整调用链路。

### 35.1 架构概览

```
AI Agent → Node.js (/api/matlab/run) → Python Bridge (matlab_bridge.py) → MATLAB Engine → sl_toolbox .m 函数
```

### 35.2 新增基础设施函数

| 函数 | 用途 |
|------|------|
| `_call_sl_function(func_name, args_dict)` | 统一 .m 函数调用器，构造 MATLAB 代码并通过 diary 执行 |
| `_dict_to_matlab_struct(d)` | Python dict → MATLAB struct 字符串 |
| `_list_to_matlab_cell(lst)` | Python list → MATLAB cell 字符串 |
| `_python_to_matlab_value(v)` | Python 值 → MATLAB 表达式（递归） |
| `_safe_json_parse(raw_output)` | 安全 JSON 解析（处理 NaN/Infinity/控制码） |
| `_detect_matlab_version()` | 检测 MATLAB 版本（缓存） |
| `_is_matlab_at_least(release)` | 版本比较（如 `>= 'R2017a'`） |

### 35.3 反模式防护中间件

| 函数 | 用途 |
|------|------|
| `_anti_pattern_check(command, params)` | 在调用 .m 函数前检查参数是否触发反模式规则 |

当前规则：
- `sl_add_block` 的 `sourceBlock` 含 `Sum` → 警告建议用 Add/Subtract
- `sl_add_block` 的 `sourceBlock` 含 `ToWorkspace` → 警告建议用 sl_signal_logging

### 35.4 并发保护

| 函数 | 用途 |
|------|------|
| `_get_model_lock(model_name)` | 获取/创建模型级互斥锁 |

修改型命令（`sl_add_block`, `sl_add_line`, `sl_set_param`, `sl_delete` 等）自动获取模型锁，防止并发修改。

### 35.5 位置参数标记规则

`_build_sl_args` 返回的参数字典中，`_pos_N` 键表示位置参数（N 从 1 开始），其余键值对以 Name-Value 格式传递。

**示例**：
```python
# sl_snapshot_model(modelName, action, varargin)
{'_pos_1': 'test_p6', '_pos_2': 'create', 'snapshotName': 'snap1'}
# 生成 MATLAB: sl_snapshot_model('test_p6', 'create', 'snapshotName', 'snap1')
```

### 35.5.1 _pos_N_special 机制（v11.0 新增）

当位置参数的值已经是 MATLAB 表达式字符串，不需要再经过 `_python_to_matlab_value` 转换时，使用 `_pos_N_special` 键。

**适用场景**：`sl_bus_create` 的 `elements` 参数（list of dicts → MATLAB struct 数组 `[struct;struct]`）

**示例**：
```python
# sl_bus_create(busName, elements, varargin)
# elements: [{"name":"alpha","dataType":"double"},{"name":"beta","dataType":"single"}]
# → MATLAB: [struct('name','alpha','dataType','double');struct('name','beta','dataType','single')]
{
    '_pos_1': 'FlightData',
    '_pos_2_special': "[struct('name','alpha','dataType','double');struct('name','beta','dataType','single')]",
    'saveTo': 'workspace'
}
```

### 35.5.2 __special__ 标记（v11.0 新增）

Name-Value 参数中，当值已经是预转换的 MATLAB 表达式时，用 `('__special__', expr)` 元组标记。

**适用场景**：`sl_subsystem_mask` 的 `parameters` 参数（list of dicts → MATLAB cell{struct}）

**示例**：
```python
# sl_subsystem_mask(modelName, blockPath, action, 'parameters', params, ...)
{
    '_pos_1': 'MyModel',
    '_pos_2': 'MyModel/Controller',
    '_pos_3': 'create',
    'parameters': ('__special__', "{struct('name','Kp','prompt','Gain','type','edit');struct('name','Ki','prompt','Integral','type','edit')}"),
    'icon': "disp('PID')"
}
# 生成 MATLAB: ... 'parameters', {struct('name','Kp',...);struct('name','Ki',...)}, 'icon', disp('PID')
```

### 35.5.3 REST API 参数别名映射（v11.0 新增）

Bridge `_build_sl_args` 支持参数别名，确保 REST API 使用更直观的参数名时也能正确映射到 .m 函数参数：

| 命令 | REST API 参数名 | .m 函数参数名 | 说明 |
|------|----------------|--------------|------|
| `sl_subsystem_create` | `blocks` | `blocksToGroup` | 要分组的模块列表 |
| `sl_subsystem_mask` | `maskParams` | `parameters` | Mask 参数定义 |
| `sl_replace_block` | — | `migrateParams` | 默认值改为 `{}`（空 struct），不再接受 `true` |

### 35.6 26 个 sl_* 命令映射

| API 命令 | .m 函数 | 位置参数 |
|----------|---------|----------|
| `sl_inspect` | sl_inspect_model | _pos_1: modelName |
| `sl_add_block` | sl_add_block_safe | _pos_1: modelName, _pos_2: sourceBlock |
| `sl_add_line` | sl_add_line_safe | _pos_1: modelName, _pos_2: srcSpec, _pos_3: dstSpec |
| `sl_set_param` | sl_set_param_safe | _pos_1: blockPath, _pos_2: params |
| `sl_delete` | sl_delete_safe | _pos_1: blockPath |
| `sl_find_blocks` | sl_find_blocks | _pos_1: modelName |
| `sl_replace_block` | sl_replace_block | _pos_1: modelName, _pos_2: blockPath, _pos_3: newBlockType |
| `sl_bus_create` | sl_bus_create | _pos_1: busName, _pos_2: elements |
| `sl_bus_inspect` | sl_bus_inspect | _pos_1: busName |
| `sl_signal_config` | sl_signal_config | _pos_1-4: modelName, blockPath, portIndex, config |
| `sl_signal_logging` | sl_signal_logging | _pos_1: modelName |
| `sl_subsystem_create` | sl_subsystem_create | _pos_1-3: modelName, subsystemName, mode |
| `sl_subsystem_mask` | sl_subsystem_mask | _pos_1-3: modelName, blockPath, action |
| `sl_subsystem_expand` | sl_subsystem_expand | _pos_1-2: modelName, subsystemPath |
| `sl_config_get` | sl_config_get | _pos_1: modelName |
| `sl_config_set` | sl_config_set | _pos_1-2: modelName, config |
| `sl_sim_run` | sl_sim_run | _pos_1: modelName |
| `sl_sim_results` | sl_sim_results | _pos_1: modelName |
| `sl_callback_set` | sl_callback_set | _pos_1-2: modelName, action |
| `sl_sim_batch` | sl_sim_batch | _pos_1: modelName |
| `sl_validate` | sl_validate_model | _pos_1: modelName |
| `sl_parse_error` | sl_parse_error | _pos_1: errorMessage |
| `sl_block_position` | sl_block_position | _pos_1: modelName |
| `sl_auto_layout` | sl_auto_layout | _pos_1: modelName |
| `sl_snapshot` | sl_snapshot_model | _pos_1-2: modelName, action |
| `sl_baseline_test` | sl_baseline_test | _pos_1: modelName |
| `sl_profile_sim` | sl_profile_sim | _pos_1: modelName |
| `sl_profile_solver` | sl_profile_solver | _pos_1: modelName |
| `sl_best_practices` | sl_best_practices | （无参数） |

### 35.7 sl_add_line 的特殊格式

`sl_add_line_safe` 有两种调用格式，Bridge 使用**格式2**（更简洁）：

```
格式1: sl_add_line_safe(model, srcBlock, srcPort, dstBlock, dstPort, ...)
格式2: sl_add_line_safe(model, 'srcBlock/portNum', 'dstBlock/portNum', ...)
```

Bridge 自动将 `srcBlock` + `srcPort` 合并为 `'srcBlock/srcPort'` 格式。

---

## 36. 智能体自我改进机制 (Part 10)

> **v10.0 新增** — 四层自我改进体系，Bridge 层自动学习并优化 API 调用行为。

### 36.1 四层体系

| 层级 | 名称 | 机制 | 触发条件 |
|------|------|------|----------|
| Layer 1 | 预防学习 | `_auto_fix_args` — 自动修正已知参数格式错误 | 每次命令调用前 |
| Layer 2 | 主动学习 | `_log_error_context` — 记录失败命令完整上下文到 `.learnings/ERRORS.md` | 命令执行失败时 |
| Layer 3 | 预测学习 | `_check_pitfall_patterns` — 踩坑模式匹配 + 警告 | 命令参数命中 PITFALL_PATTERNS 时 |
| Layer 4 | 系统进化 | `_update_command_stats` — API 调用统计 | 每次命令完成后 |

### 36.2 自动修正规则 (Layer 1)

| 命令 | 检测条件 | 修正动作 |
|------|----------|----------|
| `sl_set_param` | params 是 dict 而非 string | 自动转为 string 格式 |
| `sl_config_set` | config 是 dict 而非 string | 自动转为 string 格式 |
| `sl_bus_create` | elements 是 string 而非 list | 尝试 JSON parse |
| `sl_add_block` | sourceBlock 含库路径前缀 | 验证并提取 shortName |

### 36.3 踩坑模式库 (Layer 3)

| Pattern ID | 检测条件 | 级别 | 建议 |
|------------|----------|------|------|
| PITFALL-SUM | `sl_add_block` + sourceBlock 含 `Sum` | warning | 使用 Add/Subtract 替代 |
| PITFALL-TOWS | `sl_add_block` + sourceBlock 含 `ToWorkspace` | warning | 使用 sl_signal_logging 替代 |

> 模式库存储在 `pitfall-database.md`，支持动态扩展。

### 36.4 错误上下文记录 (Layer 2)

失败命令自动记录到 `.learnings/ERRORS.md`，格式：
```
## [ERR-YYYYMMDD-TAG] error_title
**Logged**: ISO timestamp
**Priority**: high/medium/low
**Status**: fixed/open
**Area**: bridge/matlab-api/unknown
### Summary: 简要描述
### Error: 错误信息
### Context: 命令、参数、MATLAB 版本、Bridge 模式
### Suggested Fix: 修复建议
```

### 36.5 API 调用统计 (Layer 4)

统计信息保存在 Bridge 内存中，可通过 `/api/matlab/stats` 查询：
- 每个命令的调用次数、失败次数
- 最近一次失败原因
- 失败率 Top 5 命令

---

## 37. Node.js + Express 路由 (Part 7)

> **v9.0 新增** — 26 个 sl_* REST API 端点，实现 HTTP → Node.js → Python Bridge → MATLAB 的完整调用链路。

### 37.1 架构概览

```
AI Agent → HTTP POST /api/matlab/simulink/<command> → Node.js (Express) → Python Bridge → MATLAB Engine → sl_toolbox .m 函数
```

### 37.2 新增文件

| 文件 | 变更内容 |
|------|----------|
| `matlab-controller.ts` | 新增 29 个导出函数 + 26 个超时配置 |
| `index.ts` | 新增 26 个 Express 路由 |

### 37.3 REST API 端点列表

| 端点 | 对应命令 | 必需参数 | 超时 |
|------|----------|----------|------|
| `POST /api/matlab/simulink/inspect` | sl_inspect | modelName | 30s |
| `POST /api/matlab/simulink/add_block` | sl_add_block | modelName, sourceBlock | 30s |
| `POST /api/matlab/simulink/add_line` | sl_add_line | modelName | 30s |
| `POST /api/matlab/simulink/set_param` | sl_set_param | blockPath | 30s |
| `POST /api/matlab/simulink/delete` | sl_delete | blockPath | 30s |
| `POST /api/matlab/simulink/find_blocks` | sl_find_blocks | modelName | 30s |
| `POST /api/matlab/simulink/replace_block` | sl_replace_block | modelName, blockPath, newBlockType | 60s |
| `POST /api/matlab/simulink/bus_create` | sl_bus_create | busName, elements | 30s |
| `POST /api/matlab/simulink/bus_inspect` | sl_bus_inspect | busName | 30s |
| `POST /api/matlab/simulink/signal_config` | sl_signal_config | modelName, blockPath | 30s |
| `POST /api/matlab/simulink/signal_logging` | sl_signal_logging | modelName | 30s |
| `POST /api/matlab/simulink/subsystem_create` | sl_subsystem_create | modelName, subsystemName | 60s |
| `POST /api/matlab/simulink/subsystem_mask` | sl_subsystem_mask | modelName, blockPath | 60s |
| `POST /api/matlab/simulink/subsystem_expand` | sl_subsystem_expand | modelName, subsystemPath | 60s |
| `POST /api/matlab/simulink/config_get` | sl_config_get | modelName | 30s |
| `POST /api/matlab/simulink/config_set` | sl_config_set | modelName, config | 30s |
| `POST /api/matlab/simulink/sim_run` | sl_sim_run | modelName | 5min |
| `POST /api/matlab/simulink/sim_results` | sl_sim_results | modelName | 60s |
| `POST /api/matlab/simulink/callback_set` | sl_callback_set | modelName | 30s |
| `POST /api/matlab/simulink/sim_batch` | sl_sim_batch | modelName | 10min |
| `POST /api/matlab/simulink/validate` | sl_validate | modelName | 60s |
| `POST /api/matlab/simulink/parse_error` | sl_parse_error | errorMessage | 15s |
| `POST /api/matlab/simulink/block_position` | sl_block_position | modelName | 60s |
| `POST /api/matlab/simulink/auto_layout` | sl_auto_layout | modelName | 2min |
| `POST /api/matlab/simulink/snapshot` | sl_snapshot | modelName | 60s |
| `POST /api/matlab/simulink/baseline_test` | sl_baseline_test | modelName | 5min |
| `POST /api/matlab/simulink/profile_sim` | sl_profile_sim | modelName | 5min |
| `POST /api/matlab/simulink/profile_solver` | sl_profile_solver | modelName | 5min |
| `POST /api/matlab/simulink/best_practices` | sl_best_practices | （无） | 15s |
| `GET /api/matlab/simulink/prompt/list` | — | 无 | 5s |
| `GET /api/matlab/simulink/prompt/scenario` | — | scenario | 5s |
| `GET /api/matlab/simulink/prompt/reference` | — | topic | 5s |

### 37.4 请求/响应格式

**请求**:
```json
POST /api/matlab/simulink/inspect
Content-Type: application/json

{
  "modelName": "test_model",
  "depth": 2,
  "includeParams": true
}
```

**响应**:
```json
{
  "status": "ok",
  "command": "sl_inspect",
  "matlabFunction": "sl_inspect_model",
  "model": { ... },
  "blocks": [ ... ],
  "antiPatternWarnings": [ ... ]
}
```

### 37.5 Bridge 进程异常保护

- `_handle_sl_command` 添加了 try-catch，防止 sl_* 命令异常导致 Bridge 进程崩溃
- `server_mode` 主循环添加了全局异常保护，确保单条命令失败不会终止整个进程

---

## 38. 常见问题 FAQ

### Q1: Scope 模块如何设置多个输入端口？

Scope 模块的输入端口数参数是 `NumInputPorts`（**不是** `NumPorts`）：

```matlab
% 错误写法：
sl_set_param_safe('MyModel/Scope', struct('NumPorts', '2'))   % 无效参数名

% 正确写法：
sl_set_param_safe('MyModel/Scope', struct('NumInputPorts', '2'))
```

### Q2: sl_sim_run 仿真后 sl_sim_results 返回空？

sl_sim_run 使用 SimulationInput 模式时，仿真输出存储在 `Simulink.SimulationOutput` 对象中而非 base workspace。v12.1 已修复：仿真完成后自动将关键变量（logsout、tout、yout 等）导出到 base workspace。同时 sl_sim_results 也增强为：如果 base workspace 中没有变量，会自动从 simOut 对象提取。

### Q3: sl_sim_batch 首次运行很慢？

首次使用 `parsim` 时 MATLAB 需要启动 Parallel Pool（约 30-60 秒），后续调用会复用已启动的 Pool。这不是 Bug，但在 AI 工作流中需要考虑：
- 建议将 `timeout` 参数设置足够大（至少 120 秒）
- 首次 batch 仿真可以在测试时单独运行，不要与其他耗时操作一起

### Q4: sl_add_block_safe / sl_add_line_safe 在子系统内使用的路径规则？

- `modelName` 支持传入子系统路径（如 `'MyModel/Cart'`），函数会自动提取顶层模型名
- 在子系统内连线时，格式2 的 BlockName 是**子系统内的相对路径**（不含模型前缀）
- 示例：`sl_add_line_safe('MyModel/Cart', 'In1/1', 'Gain1/1')`

---

## 版本历史

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v5.0 | 2026-04-17 | 初始版本，覆盖 Part 0~3 全部 23 个 .m 函数 |
| v6.0 | 2026-04-17 | 新增 Part 4 全部 7 个函数：sl_subsystem_create, sl_subsystem_mask, sl_subsystem_expand, sl_replace_block, sl_block_position, sl_auto_layout, sl_snapshot_model |
| v6.1 | 2026-04-17 | Bug 修复: struct+cell 构造、Mask delete/edit API、align sortrows 维度、replace_block 连线恢复、snapshot delete、empty subsystem path |
| v7.0 | 2026-04-17 | 新增 Part 5 全部 3 个函数：sl_baseline_test, sl_profile_sim, sl_profile_solver |
| v7.1 | 2026-04-18 | Bug 修复: (1) diagnostics._warning 改名 warningInfo（struct 字段名不能以 _ 开头），(2) create_empty_diagnostics 分步赋值修复空 cell 展开，(3) 移除 .m 文件中所有 emoji，(4) 新增通用编码规则节 |
| v8.0 | 2026-04-18 | 新增 Part 6 Python Bridge 集成: 26 个 sl_* 命令处理器 + 反模式防护中间件 + 并发保护 + 版本检测 + 位置参数标记 + 统一 .m 函数调用器 |
| v9.0 | 2026-04-18 | 新增 Part 7 Node.js + Express 路由: 26 个 REST API 端点 + 29 个导出函数 + 超时配置 + Bridge 异常保护 |
| v10.0 | 2026-04-18 | 新增 Part 8 提示词分层架构 + Part 10 自我改进机制 + API 弃用标注机制 |
| v11.0 | 2026-04-18 | Part 9 端到端测试 74/74 通过 + 6 个 Bridge/.m bug 修复: (1) sl_bus_create elements 格式→struct 数组(_pos_N_special), (2) arrangeSystem 排版后验证完整性, (3) sl_subsystem_create blocks→blocksToGroup 别名, (4) sl_subsystem_mask maskParams→parameters 别名+__special__ 机制, (5) sl_replace_block migrateParams 默认值 True→{}, (6) sl_block_position 补充 blockPaths/alignDirection/spacing 参数 |
| v12.0 | 2026-04-18 | **工作流重构版**: (1) 新增 AI 大模型调用工作流架构图（5 步法），(2) 目录+正文 37 个章节全部按建模工作流重新排序（提示词为首步→准备→构建→配置→验证→仿真→出错恢复→基础设施），(3) Bridge sl_add_line 新增 srcSpec/dstSpec 支持，(4) sl_add_line_safe 新增 find_common_system 子系统内部连线修复 |
| v12.1 | 2026-04-18 | **二阶倒立摆测试修复版**: (1) Bug#3 修复: sl_sim_run 仿真后自动将 SimulationOutput 关键变量 assignin 到 base workspace，(2) sl_sim_results 增强: 支持从 simOut 对象提取结果，(3) sl_add_block_safe/sl_add_line_safe 补充子系统内路径规则说明，(4) 新增 FAQ 节（Scope NumInputPorts、sim_batch 超时、子系统路径规则） |
| v13.0 | 2026-04-18 | **Layer 5 源码级自我改进**: (1) 新增 sl_self_improve API（9 个 action），(2) _auto_fix_args 集成动态规则引擎（JSON 持久化），(3) patch_source 源码补丁（含安全保护+自动备份），(4) auto_learn 从 ERRORS.md 自动推断修复规则，(5) 五层自我改进体系（Layer 1~5） |

---

## 39. sl_self_improve — 源码级自我改进 API (v7.0 Layer 5)

> **自由度最高的自我改进层 — AI 可以直接修改自己的源码、动态添加修复规则**

### 端点

`POST /api/matlab/simulink/self_improve`

### 参数

| 参数 | 类型 | 必选 | 说明 |
|------|------|------|------|
| `action` | string | 是 | 操作类型（见下表） |
| 其他 | any | 视 action | 各 action 的特有参数 |

### Action 列表

| action | 说明 | 必需参数 |
|--------|------|----------|
| `list_rules` | 列出所有动态修复规则 | - |
| `add_rule` | 添加新规则 | `rule: {command, field, detect_pattern, fix_action}` |
| `remove_rule` | 删除规则 | `rule_id` |
| `update_rule` | 更新规则 | `rule_id, updates` |
| `test_rule` | 测试规则（不实际应用） | `rule, test_params` |
| `patch_source` | 直接修改源码文件 | `file_path, old_content, new_content, description` |
| `get_errors` | 获取错误历史 | - |
| `auto_learn` | 自动从 ERRORS.md 学习新规则 | - |
| `stats` | 获取自我改进统计 | - |

### 动态规则格式

```json
{
  "id": "RULE-001",
  "command": "sl_bus_create",
  "field": "elements",
  "detect_pattern": "list_of_str",
  "fix_action": "convert_to_dict",
  "fix_params": {},
  "source": "auto_learned | user_defined | manual",
  "created_at": "ISO-8601",
  "hit_count": 0,
  "last_hit": null
}
```

**detect_pattern 可选值**:

| 值 | 检测逻辑 |
|----|----------|
| `list_of_str` | 字段是纯字符串列表（应为 dict/struct） |
| `dict_instead_of_str` | 字段应为字符串但收到 dict |
| `missing_prefix` | 字段值缺少模型名前缀 |
| `wrong_type_bool` | 字段是 bool 但应为 struct |
| `missing_field` | 必需字段缺失 |
| `custom` | 自定义检测函数（`detect_fn` Python 代码字符串） |

**fix_action 可选值**:

| 值 | 修复逻辑 |
|----|----------|
| `convert_to_dict` | 字符串列表转 dict（Name-Value → struct） |
| `prepend_model` | 补全模型前缀 |
| `set_default` | 设置默认值（`fix_params.default`） |
| `bool_to_dict` | bool 转空 dict |
| `custom` | 自定义修复函数（`fix_fn` Python 代码字符串） |

### patch_source 安全规则

1. 只允许修改 **skill 目录内** 的文件
2. 只允许 **白名单扩展名**: `.m`, `.py`, `.ts`, `.js`, `.json`, `.md`, `.bat`, `.ps1`
3. 修改前自动创建 `.bak` 备份文件
4. `old_content` 必须精确匹配文件中已有内容（防止误修改）
5. 每次只替换第一个匹配

### 使用示例

```bash
# 1. 查看当前所有动态规则
POST /api/matlab/simulink/self_improve
{"action": "list_rules"}

# 2. 添加自动修复规则
POST /api/matlab/simulink/self_improve
{"action": "add_rule", "rule": {
  "command": "sl_bus_create",
  "field": "elements",
  "detect_pattern": "list_of_str",
  "fix_action": "convert_to_dict"
}}

# 3. 直接修改源码文件
POST /api/matlab/simulink/self_improve
{"action": "patch_source", "file_path": "C:/Users/.../sl_toolbox/sl_sim_results.m",
 "old_content": "variablesRequested = {};",
 "new_content": "variablesRequested = {};\n% v7.0: auto-detect simOut",
 "description": "Add simOut detection comment"}

# 4. 自动学习
POST /api/matlab/simulink/self_improve
{"action": "auto_learn"}

# 5. 查看统计
POST /api/matlab/simulink/self_improve
{"action": "stats"}
```

---

## 40. sl_model_status_snapshot — 模型结构化状态快照 (v8.0)

> **获取模型的完整结构化状态快照，含端口坐标、连线路由、未连接端口诊断 — AI 自动连线和验证的基础**

### 端点

- `POST /api/matlab/simulink/model_status`
- `GET /api/matlab/simulink/model_status?modelName=xxx&format=comment&depth=1`

### MATLAB 函数签名

```matlab
result = sl_model_status_snapshot(modelName)
result = sl_model_status_snapshot(modelName, 'format', 'both')
result = sl_model_status_snapshot(modelName, 'depth', 0)
```

### 参数

| 参数 | 类型 | 必选 | 默认值 | 说明 |
|------|------|------|--------|------|
| `modelName` | string | 是 | - | 模型名称 |
| `format` | string | 否 | 'both' | 'json' / 'comment' / 'both' |
| `depth` | number | 否 | 1 | find_system SearchDepth，0=全部 |
| `includeParams` | boolean | 否 | true | 包含模块参数 |
| `includeLines` | boolean | 否 | true | 包含连线信息 |
| `includeHidden` | boolean | 否 | false | 包含隐藏块 |

### 返回结构

```json
{
  "status": "ok",
  "snapshot": {
    "modelName": "MyModel",
    "timestamp": "2026-04-20 10:00:00",
    "totalBlocks": 25,
    "totalLines": 18,
    "unconnectedPorts": 3,
    "diagnosticsCount": 2
  },
  "blocks": [
    {
      "path": "MyModel/Gain",
      "name": "Gain",
      "type": "Gain",
      "handle": 12345.0,
      "position": {
        "left": 100, "bottom": 50, "right": 200, "top": 100,
        "center": { "x": 150, "y": 75 }
      },
      "ports": {
        "inputs": [
          {
            "index": 1, "handle": 111.0,
            "position": { "x": 100, "y": 75 },
            "connected": true,
            "connectedTo": { "block": "MyModel/Constant", "port": 1, "lineHandle": 222.0 }
          }
        ],
        "outputs": [
          {
            "index": 1, "handle": 121.0,
            "position": { "x": 200, "y": 75 },
            "connected": true,
            "connectedTo": [{ "block": "MyModel/Scope", "port": 1, "lineHandle": 223.0 }]
          }
        ]
      },
      "params": { "Gain": "2.5" }
    }
  ],
  "lines": [
    {
      "handle": 222.0,
      "name": "",
      "sourceBlock": "MyModel/Constant",
      "sourcePort": 1,
      "sourcePosition": { "x": 200, "y": 75 },
      "destinations": [{ "block": "MyModel/Gain", "port": 1, "position": { "x": 100, "y": 75 } }],
      "routingPoints": [{ "x": 250, "y": 75 }],
      "isConnected": true
    }
  ],
  "unconnectedPorts": [
    { "block": "MyModel/In1", "portType": "output", "portIndex": 1 }
  ],
  "diagnostics": [
    {
      "level": "WARNING",
      "code": "PORT_UNCONNECTED",
      "message": "Port 1 of block 'MyModel/Out1' is not connected",
      "block": "MyModel/Out1",
      "suggestion": "Add a signal line connecting to this input port"
    }
  ],
  "reportJson": "{...}",
  "reportComment": "%% Model Status Snapshot\n%% Model: MyModel\n..."
}
```

### 诊断代码说明

| 代码 | 级别 | 说明 |
|------|------|------|
| `PORT_UNCONNECTED` | WARNING | 模块端口未连接 |
| `GOTO_FROM_UNPAIRED` | ERROR | From 模块的 GotoTag 为空 |
| `GOTO_FROM_NO_MATCH` | ERROR | From 模块引用的 GotoTag 无对应 Goto |
| `GOTO_NO_FROM` | WARNING | Goto 模块无对应 From |
| `SUBSYSTEM_NO_INTERFACE` | WARNING | 子系统无 Inport/Outport |

### 使用示例

```bash
# POST 方式
POST /api/matlab/simulink/model_status
{"modelName": "MyModel", "format": "both", "depth": 1}

# GET 方式（轻量查询）
GET /api/matlab/simulink/model_status?modelName=MyModel&format=comment&depth=1

# 全深度扫描（含子系统内部）
GET /api/matlab/simulink/model_status?modelName=MyModel&depth=0&includeHidden=true
```

---

## 41. _verification — 写操作自动验证字段 (v8.0)

> **v8.0 强制验证-执行循环的核心机制 — Bridge 层自动注入，AI 不可绕过**

### 触发条件

以下 14 个写操作在 Bridge 层执行成功后，自动调用 `sl_model_status_snapshot` 获取模型状态并注入 `_verification` 字段：

| 命令 | 验证类型 |
|------|----------|
| `sl_add_block` | block |
| `sl_add_line` | line |
| `sl_set_param` | param |
| `sl_delete` | block |
| `sl_replace_block` | block |
| `sl_subsystem_create` | subsystem |
| `sl_subsystem_mask` | subsystem |
| `sl_config_set` | param |
| `sl_bus_create` | block |
| `sl_block_position` | block |
| `sl_auto_layout` | model |
| `sl_signal_config` | param |
| `sl_signal_logging` | param |
| `sl_callback_set` | param |

### _verification 返回结构

```json
{
  "_verification": {
    "verified": true,
    "verifyType": "block",
    "command": "sl_add_block",
    "checks": [
      { "check": "block_exists", "passed": true, "detail": "MyModel/Gain exists (Type: Gain)" },
      { "check": "all_ports_connected", "passed": false, "detail": "2 unconnected port(s) on MyModel/Sum" },
      { "check": "model_unconnected_ports", "passed": false, "detail": "3 unconnected port(s) in model MyModel" }
    ],
    "allPassed": false,
    "warnings": [
      "MyModel/Sum Port-1(input) is UNCONNECTED",
      "MyModel/Sum Port-2(input) is UNCONNECTED"
    ],
    "suggestions": [
      "Add signal line to connect MyModel/Sum input port 1",
      "Connect remaining 3 unconnected port(s) before declaring task complete"
    ]
  },
  "verifyStatus": "ISSUES_FOUND",
  "verifyMessage": "2 warning(s), 2 suggestion(s)",
  "reportComment": "%% -- Auto Verification --\n%% [ISSUES FOUND] 1/3 checks passed\n%%   [PASS] block_exists: MyModel/Gain exists\n%%   [FAIL] all_ports_connected: 2 unconnected\n%% [WARNING] MyModel/Sum Port-1(input) is UNCONNECTED\n%% [ACTION] Add signal line to connect..."
}
```

### 各验证类型检查项

| 验证类型 | 检查项 |
|----------|--------|
| block | block_exists, all_ports_connected, model_unconnected_ports |
| line | source_port_connected, dest_port_connected |
| param | param_applied |
| subsystem | subsystem_exists, subsystem_has_interface |
| model | model_integrity (blocks_count, lines_count) |

### AI 必须遵守的验证流程

1. 写操作返回后，检查 `verifyStatus` 字段
2. 如果 `verifyStatus === 'ISSUES_FOUND'`：
   - 读取 `warnings` 和 `suggestions`
   - 根据建议修复问题
   - 修复后再次检查
3. 不允许在有未连接端口时声明建模完成
4. 可使用 `GET /api/matlab/simulink/model_status?modelName=xxx` 主动查询完整状态

### 跳过验证（仅调试用）

在请求参数中添加 `"_skip_verify": true` 可跳过自动验证。**生产环境禁止使用！**

---

## 42. _auto_layout — 自动排版字段 (v9.0)

> **v9.0 标准化建模工作流的核心机制 — Bridge 层自动触发排版，AI 不需要主动调用 sl_auto_layout**

### 触发条件

以下条件满足任一时，Bridge 层自动调用 `sl_auto_layout`（即 `Simulink.BlockDiagram.arrangeSystem`）排版模型：

| 规则 | 触发条件 | 说明 |
|------|---------|------|
| 规则1 | 连续 3+ 次 add 操作 | 连线/建模阶段可能结束 |
| 规则2 | 从 add 切换到 set_param | 建模阶段可能结束 |
| 规则3 | sl_subsystem_create 后 | 子系统需定位 |
| 防抖 | 距上次排版 <5秒 | 跳过排版，避免频繁调用 |

### _auto_layout 返回结构

```json
{
  "_auto_layout": {
    "arranged": true,
    "phase": "framework",
    "integrityOk": true,
    "message": "Auto-arranged v9_test_model (framework phase)",
    "reason": "3 consecutive add operations detected"
  }
}
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| arranged | boolean | 排版是否成功执行 |
| phase | string | 触发排版时的建模阶段 (framework/subsystem/simulation) |
| integrityOk | boolean | 排版后模型完整性（块数是否不变） |
| message | string | 排版结果描述 |
| reason | string | 触发排版的原因 |

### 安全保护

- 排版前自动 `save_system`（防踩坑 #31: arrangeSystem 可能清空模型）
- 排版后验证块数不变（integrityOk=false 时警告）

---

## 43. _workflow — 工作流状态字段 (v9.0)

> **v9.0 标准化建模工作流的核心机制 — 每个写操作后自动注入工作流阶段和建议**

### 三层迭代建模流程

```
第一层（framework）：建立大框架
  → In/Out、子系统占位、总线信号占位

第二层（subsystem）：填充每个子系统
  → 内部模块和连线

第三层（simulation）：总体检查与仿真
  → 验证→设参数→运行→查看结果
```

### _workflow 返回结构

```json
{
  "_workflow": {
    "model": "v9_test_model",
    "phase": "framework",
    "phaseStep": "building",
    "nextSuggestedAction": "Connect 4 remaining port(s) in the framework",
    "subsystemQueue": ["v9_test_model/Controller", "v9_test_model/Plant"],
    "subsystemDone": [],
    "checksRemaining": ["4 unconnected port(s)", "2 empty subsystem(s) need content"]
  }
}
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| model | string | 模型名称 |
| phase | string | 当前阶段: framework / subsystem / simulation |
| phaseStep | string | 当前步骤: building / layout / checking / simulation |
| nextSuggestedAction | string | 建议的下一步操作（AI 必须遵循） |
| subsystemQueue | string[] | 待填充的空子系统路径列表 |
| subsystemDone | string[] | 已完成的子系统路径列表 |
| checksRemaining | string[] | 待解决的事项列表 |

### 阶段转换逻辑

| 当前阶段 | 条件 | 下一阶段 |
|---------|------|---------|
| framework | 未连接端口=0 且有空子系统 | subsystem |
| framework | 未连接端口=0 且无子系统 | simulation |
| subsystem | 所有子系统已填充 | simulation |
| simulation | 发现未连接端口 | framework（回退） |

### AI 必须遵守的工作流规则

1. **必须遵循 `nextSuggestedAction` 的建议**
2. **不允许在有未连接端口时声明建模完成**
3. **排版由代码自动触发，AI 不需要主动调用 sl_auto_layout**
4. **子系统必须先建空壳（第一层），再填充内容（第二层）**

---

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v15.0 | 2026-04-20 | **v9.0 标准化建模工作流**: (1) 新增 _auto_layout 自动排版字段说明（#42），(2) 新增 _workflow 工作流状态字段说明（#43），(3) 三层迭代建模流程，(4) 阶段自动检测和转换，(5) 子系统队列追踪，(6) 排版5秒防抖机制 |
| v14.0 | 2026-04-20 | **v8.0 强制验证-执行循环**: (1) 新增 sl_model_status_snapshot API 说明（#40），(2) 新增 _verification 自动验证字段说明（#41），(3) 14 个写操作自动注入验证结果，(4) model_status GET/POST 双端点，(5) AI 验证流程规范 |

---

> **维护提醒**: 每次 .m 函数的 API 签名或返回结构变更后，**必须同步更新本手册对应条目**。这是大模型正确使用 sl_toolbox 的唯一参考依据！
