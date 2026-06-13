# MATLAB Agent Skill

> **AI 是设计师，不是代码生成器。** Agent 提供底层门控和 API，但 Simulink 建模的子系统划分、信号流、方程离散化完全由 AI 自主完成。
>
> **架构**: `bash` → Python Bridge (--tcp-server) ←TCP→ Node.js Server → REST API。Bridge 独立运行，MATLAB Engine 持久化。6 层 Gate（Python 硬编码）保护每一步正确性，不限制设计空间。
>
> **🔴 调用规则 (v11.8.3)**: `sl_*` 命令必须通过 `POST /api/matlab/sl/:command` 调用（触发 6 层 Gate）；`POST /api/matlab/command` 需要用户手动授权（Gate_RAW_CMD 令牌门控），AI 不可自行绕过。
>
> **🔴 外壳/内部原则 (v18.3)**: 子系统**空壳**（`sl_subsystem_create` 创建的空 SubSystem 块 + **Inport/Outport 端口块**）分为两级创建：**(1) 顶层外壳（depth=1）** 在 `framework_approve` 时批量创建（仅容器骨架，不含任何内部块）。**(2) 子外壳（depth≥2）** 在首次 `sl_micro_design` 时**懒创建**——当父子系统被设计时才创建其孩子外壳。**禁止批量创建全部深度外壳再逐个填充**。子系统**内部功能块**（Gain/Integrator/Sum/Constant 等）和**连线** **绝对不能批量**——必须通过 `micro_design → micro_review → micro_approve → build → sl_model_complete` 逐个完成。此规则硬编码在 Python Bridge（`Gate_SHELL_ONLY` + `_batch_create_all_shells(max_depth=1)` + `_create_child_shells_for_subsystem`）和 `sl_model_complete.m` 中，AI 不可绕过。
>
> **🔴 启动方式**: TCP 是唯一 Bridge 通信方式（v11.9 固化）。Node.js spawn() 会导致 MATLAB Engine Exit status: 3（Windows DLL 初始化崩溃），因此 Bridge 由 bash 独立启动，Node.js 通过 TCP 连接。不存在 spawn 降级，AI 不可绕过。
>
> **文件管理**: `.slx`/`.m` 在 workspace；中间文件（`.py`/`.json`/`slprj/`）自动隔离到 `workspace/.matlab_agent_tmp/`。

---

## 第零层：根本设计原则（代码级不可绕过）

### 🔴 matlab-agent 的本质

**matlab-agent 是一个代码级强制性的标准化 Simulink 建模监管框架。** 它是一个嵌入到 API 层的 Gate 体系，AI 必须处于这个迭代循环的监管、监督和引导之下。

- AI 的角色：**自主设计师**——决定子系统划分、信号流、方程离散化、块拓扑、参数值、构建顺序
- Agent 的角色：**代码级强制监管者**——通过 Python 硬编码的 Gate 体系确保每一步不可跳过
- AI **不可以**跳过任何 Gate 检查
- AI **不可以**绕过标准化作业流程中的任何一步
- 一旦 AI 尝试跳过 → Gate 硬编码返回 `gate_blocked`，明确告知缺失步骤

### 🔴 标准化作业流程（硬编码，按 Gate 顺序执行）

```
Phase -1  Gate_S0              场景确认         sl_scene_detect → sl_scene_confirm
Phase  1  Gate_1               大框架批准       sl_framework_approve
Phase  3  Gate_APPROVE_NO_     子系统迭代       每个子系统独立:
         REVIEW                                   sl_micro_design → sl_micro_review → sl_micro_approve
Phase  5  Gate_SHELL_ONLY      构建封锁          仅 micro_approved 的子系统可 add_block/add_line
         Gate_CONNECTIVITY     连通性强制         building 阶段阈值 15，connecting 阶段阈值 5
         Gate_SUBSYSTEM_       子系统封锁        当前子系统 sl_model_complete passed 之前，
         CLOSURE                                  禁止开始下一个子系统的内部构建
Phase  6  Gate_4               集成验收          sl_model_complete(model) passed → sl_sim_run
```

**每步都有对应的 Gate，每步都可被 Gate 拦截。没有"跳过"选项。**

### 🔴 v12.1 Gate 体系补全 (2026-05-16)

| Gate | 触发命令 | 作用 |
|------|---------|------|
| **Gate_MODEL_EXISTS** 🆕 | 所有写操作 (Scene 1) | Phase 0 强制: .slx 不存在→拦截一切 |
| **Gate_FRAMEWORK_SEQUENCE** 🆕 | `sl_framework_approve` | 大框架 approve 前强制 review |
| **Gate_APPROVE_NO_REVIEW** ✅ 重新启用 | `sl_micro_approve` | 小框架 approve 前强制 review |
| **Gate_MICRO_DESIGN_CLOSURE** 🆕 | `sl_micro_design` | 前一子系统未 complete → 拦截下一个设计 |
| **Gate_SUBSYSTEM_CLOSURE** 🆕 | `add_block/add_line` | 前一子系统未 complete → 拦截下一个构建 |
| **Gate_CONNECTIVITY** (增强) | `sl_add_block` | 分阶段阈值: building=15, default=5 |

### 🔴 Gate_SUBSYSTEM_CLOSURE（v12.1 新增）

这是补全迭代循环的关键 Gate。它的逻辑是：

> 当子系统 A 已 micro_approve 但尚未 sl_model_complete(subPath) 通过时，对子系统 B 的任何 add_block 操作都将被 Gate_SUBSYSTEM_CLOSURE 拦截。

这意味着 AI 无法：
- 一次性审批全部子系统后批量构建
- 在未验证子系统 A 的情况下开始子系统 B 的内部构建
- 跳过 sl_model_complete(subPath) 直接进入下一个

**唯一合法路径**: `micro_approve(A) → build(A) → complete(A) → micro_approve(B) → build(B) → complete(B) → ...`

### 🔴 Gate_MICRO_DESIGN_CLOSURE（v12.1 新增）

补全设计阶段的迭代循环：

> 当子系统 A 已 micro_approve 但尚未 sl_model_complete(subPath) 通过时，对子系统 B 的 micro_design 调用将被 Gate_MICRO_DESIGN_CLOSURE 拦截。

这意味着 AI 无法在设计阶段就批量设计所有子系统。


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
> 构建流程 (v18.3)：
> 1. `framework_approve` 阶段：`_batch_create_all_shells(max_depth=1)` — 仅批量创建顶层外壳 + Inport/Outport
> 2. `sl_micro_design` 阶段：`_create_child_shells_for_subsystem` — 懒创建该子系统下的子外壳
> 3. `sl_micro_design → review → approve` — 逐个审批子系统内部设计
> 4. 添加**功能块**（Gain/Integrator/Sum/Constant 等）— 禁止添加 In1/Out1
> 5. 连线（内部 + 跨子系统）— Inport/Outport 已存在，直接引用端口号
>
> Bridge 自动管理构建顺序（subsystem_tree + build_order + 懒创建），硬深度限制 5 层。

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
| 删除 🔴 | `sl_delete_block` `sl_delete` `sl_delete_approval` |
| 配置 | `sl_config_set` `sl_auto_layout` |
| 验证 | `sl_validate_model` `sl_get_model_issues` `sl_inspect` |
| 门控 🔴 | `sl_model_complete` `sl_check_port_completeness` `sl_check_signal_closure` `sl_retry_plan` |
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
| 🔴 批量创建所有深度子系统外壳 | **顶层外壳可批量（depth=1），子外壳在 micro_design 时懒创建，内部块必须逐个 Gate 流程** — `micro_design → review → approve → build` 不可跳过 |
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
│   │   ├── matlab_bridge.py               ← Python Bridge 核心 (~7350行, v15: Bugfix 7项)
│   │   └── sl_toolbox/*.m                 ← 76 个 MATLAB 函数实现 (v12.0: +sl_rigor_score.m, sl_rigor_utils.m, sl_param_registry.m, sl_micro_approve_guard.m)
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
- **Phase 4**: 骨架构建 — `sl_subsystem_create('empty', inputPorts=N, outputPorts=M)` 仅顶层外壳批量创建 (depth=1)，子外壳在 micro_design 时懒创建
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

## v12 路线图 (2026-05-15) — 已实现

### Gate_CONTENT_DEPTH — 工程严谨性评分（Rigor Score）
- **sl_rigor_score.m** — 四维评分引擎: 完整性(0.30) + 自洽性(0.35) + 可追溯性(0.20) + 可证明性(0.15)
- **sl_rigor_utils.m** — 符号分析工具（9个辅助函数）：变量提取、导数算子计数、操作覆盖检查等
- **sl_micro_approve_guard.m** — 审批前置检查：review 已通过 + rigor >= 0.65
- 完全领域无关，零物理知识依赖，不限制 AI 建模自由
- 阈值 0.65 → gate_blocked

### Gate 体系加固 (全部 P0/P1 修复)
- **Gate_APPROVE_NO_REVIEW**: 审批前强制检查 review 已调用并通过 (HC-07)
- **Gate_S0 加固**: 移除 workspace 变量依赖路径（Python _SCENE_STATE 主控）
- **Gate_RAW_CMD 建模拦截**: 9 命令黑名单（add_block/add_line/set_param/sim 等），含 cmdToken 也拦截 (GT-03/GT-07)
- **skipDesign 后门移除**: 设计阶段必须完成 (GT-08)
- **Gate_CONNECTIVITY 加固**: 阈值 12→5 + 全局未连线 >10 触发 (CN-03)
- **审批持久化**: `_MICRO_APPROVED_SUBSYSTEMS` → `.matlab_agent_tmp/approvals.json` (GT-01)

### 审查系统升级
- **sl_micro_review.m**: check_physics 委托 rigor score 引擎子维度 (HC-02/HC-03)
- **sl_framework_review.m**: check_physics 检查 physicsEquations 存在性 + 置信度缩放 (HC-01)
- **sl_validate_model.m**: check_unconnected warning → fail (CN-01)
- **sl_review_core.m**: connectionScan 线性衰减公式 + paramAudit 硬编码检测 (CN-02/PM-02)
- **sl_model_complete.m**: paramAudit 加入 mustPassChecks (>20% 硬编码 → canProceed=false) (PM-02)
- **sl_add_line_safe.m**: catch 分支 fail-closed + src/dst 双端口验证 (CN-07)

### 参数标准化 & Prompt 对齐
- **sl_param_registry.m** — 物理参数注册系统（值+单位+范围+来源），预置 quadrotor/pendulum/RLC 模板
- **sl_micro_prompts.m**: outputSchema +parameters +derivedFrom +assumptions；系统提示词 +rigor 自检要求
- **sl_framework_prompts.m**: outputSchema +parameters +assumptions

### 新增文件 (4个)
| 文件 | 行数 | 描述 |
|------|------|------|
| `sl_toolbox/sl_rigor_score.m` | ~350 | 四维评分引擎 |
| `sl_toolbox/sl_rigor_utils.m` | ~320 | 符号分析工具 |
| `sl_toolbox/sl_param_registry.m` | ~300 | 参数注册系统 |
| `sl_toolbox/sl_micro_approve_guard.m` | ~130 | approve 前置检查 |

### 修改文件 (11个)
| 文件 | 变更 | 描述 |
|------|------|------|
| `matlab_bridge.py` | ~300 行 | 5 个 Gate 变更 + 审批持久化 |
| `sl_micro_review.m` | ~50 行 | check_physics → rigor |
| `sl_framework_review.m` | ~35 行 | check_physics 升级 |
| `sl_review_core.m` | ~60 行 | paramAudit + connectionScan |
| `sl_validate_model.m` | 1 行 | unconnected → fail |
| `sl_model_complete.m` | ~30 行 | paramAudit mustPass |
| `sl_add_line_safe.m` | 2 行 | 假阳性修复 |
| `sl_micro_prompts.m` | ~20 行 | outputSchema 扩展 |
| `sl_framework_prompts.m` | ~10 行 | outputSchema 扩展 |
| `SKILL.md` | ~50 行 | v12 已实现文档 |

### 待验证
- [ ] Quadrotor_ADRC 全量重建 (所有子系统 rigor >= 0.65)
- [ ] 端到端仿真测试 (零 unconnected, < 20% 硬编码)
- [ ] R2016a 兼容性验证

---

## v12.1 Bugfix (2026-05-16)

### 10 个 Bug 修复 (P1×5 + P2×5)
基于 `matlab_agent_v12.1_code_review_report_2026-05-16` 第二部分工程级修复方案执行。

| Bug ID | 严重度 | 描述 | 文件 |
|--------|:------:|------|------|
| #31 | P1 | `_persist_approvals` 静默吞异常 | matlab_bridge.py |
| #32 | P1 | `_load_approvals` 静默吞异常 | matlab_bridge.py |
| #33 | P1 | `_SUBSYSTEM_STATES` 无锁访问 | matlab_bridge.py |
| #34 | P1 | SearchDepth=1 模型级漏检内部块 | sl_validate_model.m |
| #35 | P1 | Inport 输入端口误报 unconnected | sl_validate_model.m |
| #36 | P2 | micro_frameworks/micro_framework 存储不一致 | matlab_bridge.py (6处) |
| #37 | P2 | ALLOWED_COMMANDS 重复条目 | index.ts |
| #38 | P2 | 裸 except: → except Exception: (17处) | matlab_bridge.py |
| #39 | P2 | 错误响应格式不一致 | index.ts |
| #40 | P2 | ensure-running.sh 无 trap 清理 | ensure-running.sh |

### 测试结果
- 静态代码分析: 16/16 通过
- BUGFIX 标记验证: 4/4 通过
- 动态测试: 3/4 通过 (1 项需服务重启)
- **总计: 23/24 通过**

---

## v15 Bugfix (2026-05-18)

### 修复概述
基于 `matlab_agent_v15_bugfix_research_and_plan_2026-05-17.md` 修复方案，7 项 Bug 修复（含复查中发现的 1 项额外修复），改动量 ~43 行。

| Bug ID | 严重度 | 描述 | 文件 | 改动 |
|--------|:------:|------|------|:----:|
| #50 | P0 | signalDimensions 空值崩溃 (空 struct {} 无 input/output 字段) | sl_micro_review.m | +3行 |
| #50-ext | P0 | blockPlan 检查中 mf.signalDimensions.states 缺少 isfield 守卫 (复查发现) | sl_micro_review.m | +1行 |
| #54 | P0 | Gate_SUBSYSTEM_CLOSURE 父子系统死锁 — 祖先豁免 | matlab_bridge.py | +8行 |
| #51/53 | P0 | micro_approve modelName 自动推导 (从 subsystemName 回退) | matlab_bridge.py | +3行 |
| #55 | P1 | consecutive_adds 计数器跨子系统不重置 | matlab_bridge.py | +5行 |
| #49 | P1 | frameworkFile 文件路径支持 (替代 inline JSON) 🆕 | matlab_bridge.py | +15行 |
| #56 | P1 | 模型创建时旧持久化状态残留 | matlab_bridge.py | +8行 |

### 关键变更

#### Bug #50 — signalDimensions 空值保护
`sl_micro_review.m` 新增 `isfield(sd, 'input')` / `isfield(sd, 'output')` 空 struct 守卫。当 AI 传入 `signalDimensions: {}` 时不再崩溃，而是返回 `passed=false, issue="signalDimensions missing input/output fields"`。

#### Bug #54 — Gate_SUBSYSTEM_CLOSURE 祖先豁免
`Gate_SUBSYSTEM_CLOSURE` 新增祖先豁免逻辑：若 `_prev_incomplete` 是当前目标子系统的祖先（路径前缀匹配），则不拦截。解决了父子系统 `ADRC_Controller → TD_X` 的死锁问题。

#### Bug #49 — frameworkFile 文件路径 🆕
`sl_framework_review` 和 `sl_framework_approve` 新增 `frameworkFile` 参数：
```json
// 旧方式: inline JSON (>50KB 构造困难)
{"macroFramework": {"subsystems": [...], ...}}
// 新方式: 文件路径回退
{"frameworkFile": "/path/to/framework.json"}
```
Bridge 自动从文件读取 JSON 作为 `macroFramework` 回退值。

### 验证结果
- Python compile 通过
- 服务启动: Bridge + Server + Engine 正常
- API 测试: 7/7 修复全部验证通过
- 验证报告: `matlab_agent_v15_bugfix_verification_report_2026-05-18.md`

---

## v18.3 Bugfix — Gate 绕过漏洞修复 (2026-05-20)

### 代码审查发现
系统性代码审查发现 Gate_SHELL_ONLY 存在 3 条绕过路径，sl_model_complete 排版强制执行有缺陷，framework_approve 违反 v18 外壳原则。

### B1+B2 [P0] Gate_SHELL_ONLY 绕过 — 短 subsystemPath/blockPath
**根因**: `_extract_target_subsystem()` 第 7816 行要求候选值包含 `'/'` 才被采纳。短名称 "Reference_Generator" 无 '/' → target="" → Gate 被静默跳过。

**修复**: 增加三级回退：
1. `'/'` 扫描失败后检查短 `subsystemPath` 和 `blockPath`（无需 '/'）
2. 短 target 无 '/' 时作为子系统名直接返回
3. 空 target 但有 `subsystemPath` key 存在时使用 model_name 作为回退

**改动**: `matlab_bridge.py` `_extract_target_subsystem()` +50 行

### B4 [P1] sl_model_complete 静默排版失败
**根因**: `sl_model_complete.m` 第 30 行 `try; sl_auto_layout; catch; end` 静默吞噬所有排版错误。

**修复**: try/catch 改为 warning 记录（非阻断），排版失败信息可见。

**改动**: `sl_model_complete.m` 3 行

### B5 [P1] framework_approve 批量创建所有深度外壳
**根因**: `_batch_create_all_shells` 递归创建所有深度外壳，违反 v18 "逐子系统创建原则"。

**修复**:
- `_batch_create_all_shells` 新增 `max_depth` 参数（默认 1），仅创建顶层外壳
- 新增 `_create_child_shells_for_subsystem` 函数，在 `sl_micro_design` 时懒创建子外壳

**改动**: `matlab_bridge.py` `_batch_create_all_shells()` + `_create_child_shells_for_subsystem()` + `sl_micro_design` 注入点 +60 行

### SKILL.md 同步更新
- 外壳/内部原则描述更新为 v18.3 二级创建模型
- 构建流程描述增加懒创建步骤
- 反模式表格更新

### 改动量
| 文件 | 改动 |
|------|------|
| `matlab_bridge.py` | ~+110 行 |
| `sl_model_complete.m` | 3 行 |
| `SKILL.md` | 4 处修改 + 新增 changelog |

### 审查报告
`matlab_agent_v18_code_review_bypass_report_2026-05-20.md`
- API 测试: 7/7 修复全部验证通过
- 验证报告: `matlab_agent_v15_bugfix_verification_report_2026-05-18.md`

---

## v30 更新 (2026-05-26) — sl_delete_block 全生命周期删除 API

### 新增 API

| API | MATLAB 文件 | 功能 |
|-----|-----------|------|
| `sl_delete_block` | `sl_delete_block.m` (~280行) | 核心删除 + 参数清理(signalLogging/callbacks/paramRegistry) + LineChildren递归 + preserveShell |
| `sl_delete_approval` | `sl_delete_approval.m` (~130行) | 子系统删除影响分析（子节点+下游依赖+连线统计） |
| `sl_retry_plan` | `sl_retry_plan.m` (~140行) | retryPlan 自动生成 + 断路器（3次同错误→升级） |

### Gate_RETRY 状态机

- **10轮/子系统上限**: 5轮实现修复 + 5轮设计回退 = 10 max
- **断路器**: 连续3次同类型失败 → 自动从 `implementation_error` 升级为 `design_suspect`
- `_SUBSYSTEM_STATES` 新增字段: `retry_count`, `design_count`, `max_impl_retries`(5), `max_design_retries`(5), `last_failure`, `repeated_failure_count`
- Gate 豁免: `retrying_impl` 时 Gate_APPROVE_NO_REVIEW 放行; `retrying_design` 时 Gate_MICRO_DESIGN_CLOSURE 放行
- Gate_CONNECTIVITY: `retrying_impl` 时阈值 5→15

### Gate_DELETE_APPROVAL

- 子系统级删除（2段路径）→ 返回 `pending_approval` + `approvalToken`
- AI 用 `AskUserQuestion` 展示影响报告 → 用户确认后携带 `approvalToken` 重试
- 内部块删除（3+段路径）→ 自动放行
- 令牌 120s 过期，一次性使用

### sl_model_complete 增强

- 新增 `failureType` 字段 (`implementation_error` | `design_suspect`)
- 新增 `failedChecks[]` per-port 详情（供 `sl_retry_plan` 定位）
- `paramAudit`/`blockPlan`/`compilation` 失败 → `design_suspect`

### 参数清理（实时生效）

- `sl_param_registry('remove', blockPath)` — 删除前清理注册表
- `DataLogging=off` — 信号日志配置清理
- Callback 清理（DeleteFcn/CopyFcn/PreDeleteFcn 等）

### LineChildren 递归

- `LookUnderMasks: 'all'` + `FindAll: 'on'` 穿透 Mask
- `LineChildren` 递归处理 bus-split 分支
- `SrcPortHandle < 0` → 悬空线删除

### 兼容性

- `sl_delete` → `sl_delete_safe.m`（旧 API 不变，转发到 `sl_delete_block`）
- `sl_delete` 保留在 ALLOWED_COMMANDS 白名单

### 改动量

| 文件 | 操作 | 行数 |
|------|:----:|:----:|
| `sl_delete_block.m` | 新建 | ~280 |
| `sl_delete_approval.m` | 新建 | ~130 |
| `sl_retry_plan.m` | 新建 | ~140 |
| `matlab_bridge.py` | 修改 | ~200 |
| `sl_model_complete.m` | 修改 | ~70 |
| `sl_param_registry.m` | 修改 | ~30 |
| `sl_delete_safe.m` | 修改 | ~10 (简化为转发) |
| `sl_subsystem_tree.m` | 修改 | ~5 (retry字段) |
| `index.ts` | 修改 | ~3 (白名单) |
| `SKILL.md` | 修改 | ~50 |

**总计**: 3 新文件 + 7 修改 = 10 文件, ~918 行