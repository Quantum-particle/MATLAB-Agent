# MATLAB Agent Skill

> **AI 是设计师，不是代码生成器。** Agent 提供底层门控和 API，但 Simulink 建模的子系统划分、信号流、方程离散化完全由 AI 自主完成。
>
> **架构**: Node.js Server → Python Bridge → MATLAB Engine，变量跨命令持久化。5 层 Gate（Python 硬编码）保护每一步正确性，不限制设计空间。
>
> **文件管理**: `.slx`/`.m` 在 workspace；中间文件（`.py`/`.json`/`slprj/`）自动隔离到 `workspace/.matlab_agent_tmp/`。

---

## 第一层：启动 → 初始化（开始任何工作前必须完成）

### Step A — 启动服务

```bash
bash app/ensure-running.sh              # 唯一方式: Git Bash。2s 服务 + 18-30s Engine 预热
```

验证: `curl localhost:3000/api/health` → `"matlab.ready":true`

⚠️ **禁止 CMD `start /B`**（控制台共享 → Engine 崩溃）| **Python Engine 必须匹配 MATLAB 版本**（`site-packages/matlab/` 来自 `dist/matlab/`）| 端口 3000 残留脚本自动清理。更多: `references/troubleshooting.md`

### Step B — 初始化工作环境（AI 不可绕过的 Python 层门控）

```bash
python app/setup_workspace.py "<用户工作目录>"   # workspace 由用户显式指定，无自动推断
```

跳过此步 → `run_code` / `create_simulink` 全部返回 `gate_blocked`。

自动完成: MATLAB `pwd`=workspace | `sl_toolbox` 挂载到 MATLAB path | `workspace/.matlab_agent_tmp/` 创建。中文路径通过临时文件 + `eng.workspace` 安全传递。

---

## 第二层：工作流全景

```
Step A: ensure-running.sh → Step B: setup_workspace.py (gate)
  │
  ├─ [M 脚本]  run_code → 直接执行 MATLAB 代码
  │
  └─ [Simulink]  framework_design → review → approve (Gate_5)
                   └─ micro_design × N → review → approve
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
                    │    → 5项 + 可选检查   │             │
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

### 3.1 5 层 Gate（Python bridge 硬编码）

| Gate | 触发点 | 作用 | 解锁 |
|------|--------|------|------|
| **PROJECT_DIR** | `run_code` / `create_simulink` | 未 setup 阻止一切 | `setup_workspace.py` |
| **Gate_2** | `add_block` / `add_line` | 框架未审批禁止搭建 | `sl_framework_design → review → approve` |
| **Gate_3** | `subsystem_create` / 结构修改 | 框架锁定后修改需审批 | `sl_framework_modify → approve` |
| **Gate_4** | `sl_sim_run` | 模型未完成禁止仿真 | `sl_model_complete('complete')` |
| **Gate_5** | `sl_framework_approve` 入口 | 检查端口完备性+信号闭环 | checkItems 全部 pass |

### 3.2 建模流程（Phase 0-6）

**Phase 0 — 审视**: `sl_inspect(modelName)` + `sl_get_model_issues(modelName)`。每次操作前检查，永远不盲写。

**Phase 1 — 大框架设计**: `sl_framework_design(taskDescription)` 返回 `designPrompt`。AI 结合领域知识自主设计子系统架构 + signalFlow + gotoFromPlan + physicsEquations。输出结构参考 `references/sl_toolbox_api_guide.md` §框架设计。**从第一性原理出发，不套模板。**

**Phase 2 — 审查审批**: `sl_framework_review(macroFramework)` 自检 5 项 → `sl_framework_approve(modelName, macroFramework)` Gate_5 门控 → 锁定。

**Phase 3 — 子系统迭代**: `sl_micro_design(subsys, task, parentContext)` → AI 设计内部架构（模块选型+连线+参数）→ `sl_micro_review` → `sl_micro_approve`。逐子系统重复。

**Phase 4 — 搭建**: `sl_add_block_safe` / `sl_add_line_safe` / `sl_set_param_safe` / `sl_config_set`。自动注入 `_verification`（block_exists / ports_connected），每 3 次 add 自动 `arrangeSystem(FullLayout=true)`。

**Phase 5 — 完成门控**: `sl_model_complete(modelName, 'action', 'complete')` → 强制 auto-layout + 12 项验证（unconnected=0 / GotoFrom 成对 / 无 orphaned）。`canProceed=true` 才解锁 Phase 6。

**Phase 6 — 仿真**: `sl_sim_run` / `sl_sim_batch` / `sl_sim_results` / `sl_baseline_test`。

### 3.3 设计自由度

`sl_framework_design` 和 `sl_micro_design` 只是 **Prompt 组装器 + 结果验证**。不存在预定义模板。AI 可用 Web Search、知识库等外部工具增强设计。

---

## 第四层：API & 约束速查

### 核心 API（49 函数，完整签名见 `references/sl_toolbox_api_guide.md`）

| 类别 | 函数 |
|------|------|
| 框架 | `sl_framework_design` `_review` `_approve` `_modify` |
| 子系统 | `sl_micro_design` `_review` `_approve` |
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
│   │   └── sl_toolbox/*.m                 ← 49 个 MATLAB 函数实现
│   └── server/
│       ├── index.ts                       ← Express 路由 + API 端点
│       ├── matlab-controller.ts           ← Bridge 进程管理与通信
│       └── system-prompts.ts              ← AI 系统提示词 + 门控规则
│
├── references/
│   ├── sl_toolbox_api_guide.md            ← 【建模前必读】49 API 完整签名/参数/返回值
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
