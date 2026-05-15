# MATLAB Agent Skill

> **AI 是设计师，不是代码生成器。** Agent 提供底层门控和 API，但 Simulink 建模的子系统划分、信号流、方程离散化完全由 AI 自主完成。
>
> **架构**: `bash` → Python Bridge (--tcp-server) ←TCP→ Node.js Server → REST API。Bridge 独立运行，MATLAB Engine 持久化。6 层 Gate（Python 硬编码）保护每一步正确性，不限制设计空间。
>
> **🔴 调用规则 (v11.8.3)**: `sl_*` 命令必须通过 `POST /api/matlab/sl/:command` 调用（触发 6 层 Gate）；`POST /api/matlab/command` 需要用户手动授权（Gate_RAW_CMD 令牌门控），AI 不可自行绕过。
>
> **🔴 外壳/内部原则 (v11.9)**: 子系统**空壳**（`sl_subsystem_create` 创建的空 SubSystem 块 + **Inport/Outport 端口块**）可以批量创建——`sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` 一步完成外壳+端口。子系统**内部功能块**（Gain/Integrator/Sum/Constant 等）和**连线** **绝对不能批量**——每个子系统的内部设计必须独立走完整的 Gate 防护流程：`micro_design → micro_review → micro_approve → build(添加功能块+连线) → sl_model_complete`。此规则硬编码在 Python Bridge 的 `_handle_sl_command` 中（`Gate_SHELL_ONLY`），AI 不可绕过。
>
> **🔴 启动方式**: TCP 是唯一 Bridge 通信方式（v11.9 固化）。Node.js spawn() 会导致 MATLAB Engine Exit status: 3（Windows DLL 初始化崩溃），因此 Bridge 由 bash 独立启动，Node.js 通过 TCP 连接。不存在 spawn 降级，AI 不可绕过。
>
> **文件管理**: `.slx`/`.m` 在 workspace；中间文件（`.py`/`.json`/`slprj/`）自动隔离到 `workspace/.matlab_agent_tmp/`。

---

## 第一层：启动 → 初始化（开始任何工作前必须完成）

### Step A — 启动服务

```bash
bash app/ensure-running.sh              # 唯一方式: Git Bash。启动 TCP Bridge + Node.js
```

**启动流程**（ensure-running.sh 自动执行，AI 不可绕过）：
1. 清理残留进程（端口 3000 + 旧 Bridge PID）
2. 检查 node_modules
3. **启动 Python Bridge** (`--tcp-server` 模式，bash & 后台独立进程)
4. 等待 Bridge 端口文件出现（最多 30s）
5. 验证 Bridge TCP 连通性
6. 启动 Node.js 服务器
7. 等待 MATLAB Engine 预热（最多 300s）

验证: `curl localhost:3000/api/health` → `"matlab.ready":true`

⚠️ **🔴 核心约束**:
- **TCP 是唯一 Bridge 通信方式** — 不存在 spawn 降级，连接失败 = 服务不可用
- **禁止 CMD `start /B`**（控制台共享 → Engine 崩溃）
- **禁止 Node.js spawn() 启动 Bridge**（Exit status: 3 根因）
- **Python Engine 必须匹配 MATLAB 版本**（`site-packages/matlab/` 来自 `dist/matlab/`）
- 端口 3000 残留脚本自动清理。更多: `references/troubleshooting.md`

### Step B — 初始化工作环境（AI 不可绕过的 Python 层门控）

```bash
python app/setup_workspace.py "<用户工作目录>"   # workspace 由用户显式指定，无自动推断
```

跳过此步 → `run_code` / `create_simulink` 全部返回 `gate_blocked`。

自动完成: MATLAB `pwd`=workspace | `sl_toolbox` 挂载到 MATLAB path | `workspace/.matlab_agent_tmp/` 创建。中文路径通过临时文件 + `eng.workspace` 安全传递。

---

## 第二层：工作流全景

```
Step A: ensure-running.sh (TCP Bridge + Node.js) → Step B: setup_workspace.py (gate)
  │
  ├─ [M 脚本]  run_code → Gate_RAW_CMD 令牌确认 → 执行 MATLAB 代码
  │                        (AI 必须先请求令牌，用户手动授权后才可执行)
  │
  └─ [Simulink]  --- Gate_S0: 场景检测 + 令牌确认（AI 不可绕过）---
                   sl_scene_detect → AskUserQuestion(用户点击) → sl_scene_confirm(令牌)
                         │
                         └─ [Scene 1] sl_model_create (新建模型) → framework_design
                              └─ framework_design → review → approve (Gate_5 多层级, 🔴 depth≤5)
                                   └─ [v11.8] Phase 4: 骨架构建 (全部子系统外壳 + Inport/Outport)
                                   └─ micro_design × N (depth-aware) → review → approve
                                        └─ add_block / add_line / set_param (Gate_2,3)
                                             └─ sl_model_complete (Gate_4)
                                                  └─ sl_sim_run / sl_sim_batch
                                                  └─ cleanup (slprj/, tmp)
```

---

## 第三层：Simulink 门控建模流程

```
                        ┌──────────────────────────────────────────┐
                        │          AI 大模型（自主设计决策）          │
                        └──────┬──────────────────────────┬────────┘
                               │                          │
              ┌────────────────▼─────────────┐          │
              │  Phase 1: 大框架设计            │          │
              │  sl_framework_design(task)    │          │
              │    → designPrompt (引导AI)     │          │
              │    → outputSchema (输出规范)   │          │
              └────────────────┬─────────────┘          │
                               │                        │
                    ┌──────────▼──────────┐             │
                    │   大框架自检           │             │
                    │ sl_framework_review  │             │
                    │    → 11项自检 (v11.8)  │             │
                    └──────────┬──────────┘             │
                               │                        │
                    ┌──────────▼──────────┐             │
                    │   大框架审批 (Gate_5)  │◄────────────┘
                    │ sl_framework_approve │  门控: 端口完备性
                    │    → 框架锁定         │        + 信号流闭环
                    └──────────┬──────────┘
                               │ 框架已审批
              ┌────────────────▼─────────────────┐
              │ Phase 3: 子系统小框架迭代循环        │
              │                                   │
              │  for each 子系统:                   │
              │    sl_micro_design(subsys, task)   │
              │      → designPrompt (含parentCtx)  │
              │      → blockMappingGuide          │
              │    ┌──────────────────────┐       │
              │    │ sl_micro_review       │       │
              │    └──────────┬───────────┘       │
              │               │                    │
              │    ┌──────────▼───────────┐       │
              │    │ sl_micro_approve      │       │
              │    └──────────────────────┘       │
              └────────────────┬─────────────────┘
                               │ 全部子系统审批完成
              ┌────────────────▼─────────────────────────────┐
              │       Phase 4: 搭建 (Gate_2/3 门控保护)        │
              │                                               │
              │  bus_create → subsystem_create → add_block    │
              │    → add_line → set_param → auto_layout       │
              │                                               │
              │  每步自动注入 _verification 验证                │
              │  修改操作需通过 Gate_3 审批（框架锁定后）         │
              └────────────────┬────────────────────────────┘
                               │
              ┌────────────────▼────────────────────────────┐
              │         Phase 5: 完成门控 (Gate_4)             │
              │  sl_model_complete(modelName)                │
              │    → auto-layout (强制)                       │
              │    → 12项验证 (unconnected必须pass)           │
              │    → Goto/From配对 + orphaned检查             │
              │    → canProceed=true 才允许仿真               │
              └────────────────┬────────────────────────────┘
                               │
              ┌────────────────▼────────────────┐
              │       Phase 6: 仿真 & 测试         │
              │  sl_sim_run / sl_sim_batch      │
              │    → Gate_4 前置检查              │
              │  sl_sim_results                 │
              │  sl_baseline_test               │
              └─────────────────────────────────┘
```

### 3.1 7 层 Gate（Python bridge 硬编码）

| Gate | 触发点 | 作用 | 解锁 |
|------|--------|------|------|
| **Gate_S0** 🔴 | 所有 Simulink 操作 | **令牌门控**: 场景未确认→拦截一切 | `sl_scene_detect` → `AskUserQuestion`(用户点击) → `sl_scene_confirm(令牌)` |
| **PROJECT_DIR** | `run_code` / `create_simulink` | 未 setup 阻止一切 | `setup_workspace.py` |
| **Gate_RAW_CMD** 🔴 | `run_code` / `/api/matlab/command` | **原始命令二选一门控**: AI 不可直接执行 MATLAB | `cmd_request` → `AskUserQuestion`(二选一: 同意原始命令 / 用标准流程) → `POST /api/matlab/command`(含令牌) |
| **Gate_2** | `add_block` / `add_line` | 框架未审批禁止搭建 | `sl_framework_design → review → approve` |
| **Gate_3** | `subsystem_create` / 结构修改 | 框架锁定后修改需审批 | `sl_framework_modify → approve` |
| **Gate_4** | `sl_sim_run` | 模型未完成禁止仿真 | `sl_model_complete('complete')` |
| **Gate_5** | `sl_framework_approve` 入口 | 检查端口完备性+信号闭环 | checkItems 全部 pass |

**Gate_S0 令牌机制**: `sl_scene_detect` 返回随机 `confirmationToken`，AI 必须用 `AskUserQuestion` 呈现给用户，用户在可点击选项中确认后，AI 用令牌调用 `sl_scene_confirm`。跳过用户交互 → `TOKEN_MISMATCH` → `gate_blocked`。令牌一次性，用过即失效。

**Gate_RAW_CMD 令牌机制 (v11.8.3)** 🔴: `/api/matlab/command` 是最后手段，AI 应优先使用标准 sl_* API 流程。
- 直接调用 `/api/matlab/command` → `gate_blocked`（要求 AI 先尝试标准流程）
- `POST /api/matlab/command/request {"command": "<预览>"}` → 返回 `cmdToken` + `challengePhrase`
- AI **必须**用 `AskUserQuestion` 展示两个选项给用户:
  - **(1) 同意使用 /api/matlab/command** — 用户授权执行原始命令
  - **(2) 用标准 Simulink 建模流程** — 用户拒绝，AI 改用 sl_* API
- 用户选 (1) → AI 调用 `POST /api/matlab/command {"command": "...", "cmdToken": "..."}`
- 用户选 (2) → AI 必须改用 sl_* API 标准流程
- 令牌一次性使用，120s 过期。

### 3.2 建模流程（Phase 0-6）

**Phase -1 — 场景确认（Gate_S0 令牌门控）**: 🔴 **最先执行！** `sl_scene_detect(workspaceDir)` → 自动检测 `.slx`/`.mdl` → 返回 `confirmationToken` → **【强制】** 用 `AskUserQuestion` 给用户可点击选项 → 用户点击 → `sl_scene_confirm(scene, modelName, confirmationToken)`。场景锁定前，所有 Simulink 操作被 Gate_S0 拦截。

**Phase 0 — 模型创建（仅 Scene 1）**: 🔴 **框架设计前执行！** `sl_model_create(modelName)` → 创建空 `.slx` 文件。Scene 2 跳过此步改用 `sl_model_load`。建模前模型文件必须存在。

**Phase 0.5 — 审视**: `sl_inspect(modelName)` + `sl_get_model_issues(modelName)`。每次操作前检查，永远不盲写。

**Phase 1 — 大框架设计**: `sl_framework_design(taskDescription)` 返回 `designPrompt`。AI 结合领域知识自主设计完整子系统层级树（v11.8: 含递归 childSubsystems + 深度限制 ≤5）。输出结构参考 `references/sl_toolbox_api_guide.md` §框架设计。**从第一性原理出发，不套模板。**

**Phase 2 — 审查审批**: `sl_framework_review(macroFramework)` 自检 11 项 (v11.8.1: 含嵌套深度/内聚性/接口等6项) → `sl_framework_approve(modelName, macroFramework)` Gate_5 多层级门控 → 锁定全部层级。

**Phase 3 — 子系统迭代**: `sl_micro_design(subsys, task, parentContext, 'depth', N)` → AI 深度感知设计→ `sl_micro_review` → `sl_micro_approve`。逐子系统重复。

**Phase 4 — 骨架构建 (v11.8)**: 审批后先创建全部嵌套层级的外壳。🔴 **外壳可批量创建，内部结构必须逐个走 Gate 流程**。

> **🔴 v11.9 关键修正**: `sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` 已经包含 Inport/Outport 创建（共 N+M 个端口块）。**构建脚本禁止重复添加 In1/Out1 块**——重复添加导致端口加倍（228 unconnected 根因）。
>
> 构建流程：
> 1. `sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` — 批量创建外壳 + Inport/Outport
> 2. `sl_micro_design → review → approve` — 逐个审批子系统内部设计
> 3. 添加**功能块**（Gain/Integrator/Sum/Constant 等）— 禁止添加 In1/Out1
> 4. 连线（内部 + 跨子系统）— Inport/Outport 已存在，直接引用端口号
>
> Bridge 自动管理构建顺序（subsystem_tree + build_order），硬深度限制 5 层。

**Phase 5 — 递归构建 (v11.8)**: 按 build_order 自底向上逐层构建每个子系统。`sl_build_status` / `sl_next_target` 查询进度。每个子系统独立走 micro_design(depth-aware) → micro_review → micro_approve → build(add_block/add_line/set_param) → `sl_model_complete(subPath)`。子路径 complete 成功后自动标记节点为 completed，通知下一个构建目标。

**Phase 6 — 顶层集成 & 仿真 (v11.8)**: 全部子系统完成后，`sl_model_complete(modelName)` 顶层 Gate_4 + 🔴 hierarchy 完整性检查（所有子系统必须 completed）。`sl_sim_run` / `sl_sim_batch` / `sl_sim_results` / `sl_baseline_test`。

### 3.3 设计自由度

`sl_framework_design` 和 `sl_micro_design` 只是 **Prompt 组装器 + 结果验证**。不存在预定义模板。AI 可用 Web Search、知识库等外部工具增强设计。

---

## 第四层：API & 约束速查

### 核心 API（56 函数，完整签名见 `references/sl_toolbox_api_guide.md`）

| 类别 | 函数 |
|------|------|
| 场景 🔴 | `sl_scene_detect` `sl_scene_confirm` |
| 模型 🔴 | `sl_model_create` (v11.9) — Scene 1 新建模型 |
| 框架 | `sl_framework_design` `_review` `_approve` `_modify` |
| 子系统 | `sl_micro_design` `_review` `_approve` |
| 层级 🔴 | `sl_hierarchy_validate` `sl_subsystem_tree` `sl_build_status` `sl_next_target` (v11.8) |
| 构建 | `sl_add_block_safe` `sl_add_line_safe` `sl_set_param_safe` `sl_block_position` |
| 配置 | `sl_config_set` `sl_auto_layout` |
| 验证 | `sl_validate_model` `sl_get_model_issues` `sl_inspect` |
| 门控 | `sl_model_complete` `sl_check_port_completeness` `sl_check_signal_closure` |
| 仿真 | `sl_sim_run` `sl_sim_batch` `sl_sim_results` `sl_baseline_test` |

### 反模式 & 陷阱速查

| 禁止 / 陷阱 | 正确 |
|------------|------|
| 跳过 inspection | 始终 `sl_inspect` 先 |
| `set_param` + `sim` 裸跑 | `SimulationInput` + `sim` |
| 跳过 `sl_model_complete` | 仿真前必须通过 Gate_4 |
| 用 `&` 的完整库路径 | block registry 简写 |
| `sl_*_safe` params 传字符串 | **必须 struct**: `struct('Gain','5')` |
| `.m` 中文/emoji | 纯 ASCII，用 `[OK]`/`[WARN]` |
| `Scope` 端口数 | `NumInputPorts` 不是 `NumPorts` |
| `arrangeSystem` 不加 FullLayout | `'FullLayout','true'`，前后 save |
| 新增模块 | 四文件同步: registry.md + .m + bridge.py + api_guide |
| 🔴 批量创建子系统内部块 | **外壳可批量，内部必须逐个 Gate 流程** — `micro_design → review → approve → build` 不可跳过 |
| 🔴 用 Gate_RAW_CMD 绕过子系统内部审查 | 子系统内部块创建永远走 `sl_*` API，不通过 `/api/matlab/command` |
| 🔴 micro_approve 后重复添加 In1/Out1 | `sl_subsystem_create('empty',inputPorts=N,outputPorts=M)` 已包含 Inport/Outport — 构建脚本只需添加功能块+连线 |
| 🔴 构建后不调用 sl_auto_layout | `sl_model_complete` **强制**排版（v11.9 固化）。连续 5+ add_block 后也自动排版。不排版导致块重叠无法阅读 |

> 完整陷阱: `references/pitfalls.md` + `references/pitfall-database.md`

---

## 📂 文件地图

```
SKILL.md (本文件)                          ← 总索引
│
├── app/
│   ├── ensure-running.sh                  ← 唯一启动脚本（Git Bash）
│   ├── setup_workspace.py                 ← 工作环境初始化门控
│   ├── matlab-bridge/
│   │   ├── matlab_bridge.py               ← Python Bridge 核心（~7000行）
│   │   └── sl_toolbox/*.m                 ← 72 个 MATLAB 函数实现 (v11.8.2: +sl_safe_index.m 安全索引)
│   └── server/
│       ├── index.ts                       ← Express 路由 + API 端点 (v11.8.2: +/api/matlab/sl/:command 门控)
│       ├── matlab-controller.ts           ← Bridge 进程管理与通信 (v11.8.2: +executeSlCommand)
│       └── system-prompts.ts              ← AI 系统提示词 + 门控规则 (v11.8.2: API 路由规则)
│
├── references/
│   ├── sl_toolbox_api_guide.md            ← 【建模前必读】51 API 完整签名/参数/返回值
│   ├── pitfalls.md                        ← 踩坑经验详录（33 条）
│   ├── pitfall-database.md                ← 结构化踩坑 DB（Pattern-Key 索引）
│   ├── block-param-registry.md            ← 模块参数类型/枚举值速查
│   └── troubleshooting.md                 ← 启动/配置/运行故障排除
│
└── .learnings/                            ← 自我改进知识库
    ├── LEARNINGS.md
    ├── ERRORS.md
    └── auto_fix_rules.json
```

---

## v11.8.1 更新 (2026-05-10)

### Bug 修复
- **Bug #1 [P0]**: `compute_tree_depth` — `isfield(array)` → 逐元素 `isfield(element)` + try/catch
- **Bug #2 [P1]**: `check_dimensionality` — 逐条比对 → `containers.Map` 按目标聚合
- **REST API string/char**: varargin `string` → `char()` 转换
- **check_subsystem guard**: `has_valid_signalflow()` 守卫 `{{}}` 空 signalFlow

### 框架审查 11 项检查
| # | 检查 | 说明 |
|---|------|------|
| 1 | physics | 子系统输入输出完整性 |
| 2 | signalFlow | 信号流连通性 |
| 3 | subsystem | 数量/命名/循环依赖 |
| 4 | gotoFrom | Goto/From 标签成对 |
| 5 | dimensionality | 维度一致性 (v11.8.1: 多源聚合) |
| 6 | nestingDepth | 🔴 嵌套深度 ≤5 |
| 7 | singleBlock | 单模块子系统检测 |
| 8 | cohesion | 功能内聚性 |
| 9 | crossLevelInterface | 跨层级接口一致性 |
| 10 | treeCompleteness | 树完整性 |
| 11 | leafSubsystems | 叶子子系统非空 |

---

## v11.8.2 更新 (2026-05-12)

### 架构修复

- **Bug #1 [P0]**: REST `sl_*` 命令路由 — 新增 `POST /api/matlab/sl/:command` 端点，通过 `_handle_sl_command` 触发 6 层 Gate。此前 `/api/matlab/command` 绕过所有门控，导致 Gate_S0 令牌机制完全失效。
- **Bug #3 [P0]**: Cell/Struct 索引安全 — 创建 `sl_safe_index.m` 通用索引辅助函数，替换 `sl_framework_review.m` 中 5 个递归函数的直接索引调用。`sl_fw_normalize.m` catch 块从静默改为 warning。
- **Bug #2 [P1]**: signalFlow 字段 — `check_signal_flow()` 增加 `src`/`dst` → `srcSubsystem`/`dstSubsystem` 向后兼容映射。
- **Bug #4 [P1]**: `has_valid_signalflow` 已内联到 `check_subsystem()`，原函数标记 DEPRECATED。`count_signals` 增加 `end` 修复子函数一致性。
- **Bug #5 [P1]**: 中文路径编码 — 新增 `_safe_eval_with_paths()`（workspace 变量传递路径），`execute_script`/`create_simulink` 添加 sanitization。
- **Bug #6 [P2]**: `execute_script` pwd 保存/恢复，异常时也恢复。
- **Bug #7 [P2]**: `run_code` 检测到 Simulink 结构操作后自动 `drawnow` 强制刷新。

### 新增文件
- `sl_safe_index.m` — 统一 cell/struct array 安全索引（R2016a+ 兼容）
- `_safe_eval_with_paths()` — Bridge 级中文路径安全传递

### 新增端点
- `POST /api/matlab/sl/:command` — sl_* 命令门控专用端点（6 层 Gate）

---

## v11.9 更新 (2026-05-14)

### Phase 0-6 建模工作流
- **Phase -1 (Gate_S0)**: 场景确认令牌门控
- **Phase 0**: `sl_model_create` — Scene 1 创建空 .slx（框架设计前强制执行）
- **Phase 1-3**: 大框架设计→审查审批→子系统迭代（同 v11.8）
- **Phase 4**: 骨架构建 — `sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` 批量创建外壳+端口
- **Phase 5**: 递归构建 — 按 build_order 自底向上，每子系统独立走 Gate
- **Phase 6**: 顶层集成 + Gate_4 → 仿真

### 🔴 Gate_SHELL_ONLY (v11.8.4 固化)
子系统**空壳**可批量创建（容器），**内部结构必须逐子系统走 Gate**：
`micro_design → micro_review → micro_approve → build → sl_model_complete`
不可绕过。`sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` 已含 Inport/Outport — 构建时禁止重复添加。

### 🔴 Gate_REVIEW_BUILD (v11.9)
`sl_model_complete` 前强制 `connectionScan`。micro_approve 验证 DESIGN，model_complete 验证 BUILD。

### 新增文件
- `sl_review_core.m` — 统一审查引擎 (portPairing/paramAudit/connectionScan/layoutAudit)
- `sl_subsystem_tree.m` — 子系统树管理 + build_order 计算
- `sl_hierarchy_validate.m` — 递归层级验证（深度 ≤5 硬限制）
- `sl_model_create.m` — Phase 0 空模型创建

### Bug 修复 (v11.9)
- Bug #20 [P0]: assignin 变量名含 `/` — strrep sanitize
- Bug #24 [P0]: model_complete 无 build verification — 新增 Gate_REVIEW_BUILD
- Bug #21 [P0]: sl_ 命令路由前缀缺失 — index.ts 幂等前缀补全
- Bug #23 [P0]: _extract_target_subsystem add_line 参数 — 7参数扫描链

---

## v12 路线图 (2026-05-15) — 计划中

### 🔴 Gate_CONTENT_DEPTH — 工程严谨性评分（Rigor Score）
- 不验证"方程对不对"（无限域），验证"AI有没有认真设计"（有限域）
- 四维评分: 完整性(0.30) + 自洽性(0.35) + 可追溯性(0.20) + 可证明性(0.15)
- 完全领域无关，零物理知识依赖，不限制 AI 建模自由
- 阈值 0.65 → gate_blocked

### Gate 体系加固
- Gate_S0 HMAC 签名令牌（防 workspace 变量伪造）
- Gate_RAW_CMD 建模命令拦截（add_block/add_line/set_param/sim 等）
- 移除 skipDesign 后门
- 审批状态持久化到 `.matlab_agent_tmp/approvals.json`
- Gate_CONNECTIVITY 阈值 12→5 + 全局未连线触发器

### 参数标准化
- `sl_param_registry.m` — 物理参数注册系统（值+单位+范围+来源）

> v12 完整审查报告和修复方案见 `d:\MATLAB_Workspace\MATLAB_Agent开发\matlab_agent_v12_*.md`

