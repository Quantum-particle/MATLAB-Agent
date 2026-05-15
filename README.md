# MATLAB-Agent v11.9

<p align="center">
  <strong>AI 驱动的 MATLAB/Simulink 开发助手</strong><br>
  跨平台 · 跨 Agent 框架 · 8 层硬编码门控 · 72 个 MATLAB 函数 · 50+ REST API<br>
  支持 WorkBuddy / Claude Code / Codex / Cursor / Cline / Augment 及所有兼容 MCP/REST 的 AI 工具
</p>

<p align="center">
  <a href="#-matlab-python-版本适配"><img src="https://img.shields.io/badge/MATLAB-R2020a--R2026a-blue"></a>
  <a href="#-matlab-python-版本适配"><img src="https://img.shields.io/badge/Python-3.6--3.13-yellow"></a>
  <a href="#-matlab-python-版本适配"><img src="https://img.shields.io/badge/Node.js-18%2B-green"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-brightgreen"></a>
</p>

---

## 🎯 项目简介

**MATLAB-Agent** 是一个 AI 驱动的 MATLAB/Simulink 开发中间件。它通过常驻 Python 桥接进程 + MATLAB Engine API，让 AI 智能体可以：

- 🔧 在持久化工作区中执行 M 代码（变量跨命令保持）
- 🏗️ 从零构建 Simulink 模型：框架设计 → 审批 → 搭建 → 验证 → 仿真（6 步门控工作流）
- 🔧 在已有 Simulink 模型上继续开发：加载 → 理解 → 沙盒设计 → 修改审批 → 搭建 → 仿真
- 📊 读取 `.m` / `.mat` / `.slx` 文件，管理工作区变量
- 🔄 双模引擎自动切换：Engine API（推荐）+ CLI 回退（兼容老版本）

> **不再是"AI 写代码你复制粘贴"，而是 AI 直接坐在 MATLAB 命令行前。**

### 跨平台支持

MATLAB-Agent 通过标准 HTTP REST API 对外提供服务，可与**任何**支持 HTTP 调用的 AI Agent 框架或 CLI 工具集成：

| AI 工具 | 集成方式 | 说明 |
|---------|---------|------|
| **WorkBuddy** | Skill + REST API | 原生 Skill 集成 |
| **Claude Code** | REST API / MCP | 通过 HTTP 调用或 MCP Server |
| **Codex (OpenAI)** | REST API | HTTP 直接调用 |
| **Cursor** | REST API / MCP | 支持 MCP 和自定义命令 |
| **Cline (VS Code)** | REST API / MCP | MCP Server 模式 |
| **Augment Code** | REST API | 自定义工具调用 |
| **其他 Agent 框架** | REST API | 任何支持 HTTP 的工具均可集成 |

> **核心原则**: MATLAB-Agent 是一个**独立服务**，只要 AI 能发 HTTP 请求就能用。本文档中的"WorkBuddy"仅作为开发平台的示例，不构成平台限制。

---

## 🏗️ 系统架构

### 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                     AI 大模型 (LLM)                                  │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Layer 0: Skill 知识层 (按需加载)                                ││
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                       ││
│  │  │ 核心层    │ │ 场景层   │ │ 参考层   │                       ││
│  │  │ (始终加载)│ │ (按需加载)│ │ (查询加载)│                       ││
│  │  │ API索引  │ │ 建模场景 │ │ 完整注册表│                       ││
│  │  │ 反模式12条│ │ 仿真场景 │ │ 详细API  │                       ││
│  │  │ 工作流10步│ │ 测试场景 │ │ 踩坑经验 │                       ││
│  │  │ 8层Gate  │ │ 修改场景 │ │ 版本兼容 │                       ││
│  │  └──────────┘ └──────────┘ └──────────┘                       ││
│  ├─────────────────────────────────────────────────────────────────┤│
│  │ 优先: 调用 Simulink 中间件 API（结构化参数+结构化反馈）         ││
│  │ 兜底: run_code 直接写 MATLAB 代码（保留完全自由度）             ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ HTTP REST API
┌────────────────────────────────▼────────────────────────────────────┐
│                    Node.js Server (Express + TypeScript)             │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  50+ API 端点 (index.ts)                                       ││
│  │  · 模型编辑 (7) · 信号总线 (4) · 子系统 (3)                    ││
│  │  · 模型配置 (2) · 仿真控制 (4) · 验证诊断 (4)                  ││
│  │  · 布局导出 (2) · 测试性能 (3) · 场景确认 (2)                  ││
│  │  · 框架设计 (10) · 门控系统 (5) · 提示词 (3)                   ││
│  └─────────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  MATLAB Controller (matlab-controller.ts)                      ││
│  │  · 引擎进程生命周期管理 · 健康检查 · 配置管理 · 文件扫描        ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ JSON 行协议 (stdin/stdout)
┌────────────────────────────────▼────────────────────────────────────┐
│              Python Bridge (matlab_bridge.py, ~10,300 行)              │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  50+ 命令处理器 + 8 层硬编码 Gate + 反模式防护 + 版本检测       ││
│  │  Gate_S0 / Gate_2 / Gate_3 / Gate_4 / Gate_5 / PROJECT_DIR      ││
│  │  Gate_SHELL_ONLY / Gate_CONNECTIVITY / Gate_REVIEW_BUILD         ││
│  │  每个命令 → 调用对应 sl_*.m 工具函数 → 返回结构化 JSON          ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ eng.eval() / matlab -batch
┌────────────────────────────────▼────────────────────────────────────┐
│                   MATLAB Engine / CLI 回退                           │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  sl_toolbox/ (72 个 .m 函数)                                   ││
│  │  ┌──────────────┬──────────────┬──────────────┐                ││
│  │  │ 框架设计 (10) │ 子系统 (5)   │ 门控验证 (5) │                ││
│  │  │ 模型编辑 (8)  │ 信号总线 (4) │ 仿真控制 (4) │                ││
│  │  │ 验证诊断 (5)  │ 布局导出 (3) │ 测试性能 (3) │                ││
│  │  │ 场景确认 (2)  │ 基础设施 (6) │ 自我改进 (3) │                ││
│  │  └──────────────┴──────────────┴──────────────┘                ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

### 架构特征

| 特征 | 说明 |
|------|------|
| **三层架构** | Node.js Server → Python Bridge → MATLAB Engine，通过 JSON 行协议通信 |
| **持久化会话** | Engine 模式下 MATLAB 工作区变量跨命令保持，像真实 MATLAB 会话 |
| **双模引擎** | Engine API 优先（R2019a+），CLI 回退（`matlab -batch`）兼容老版本 |
| **自动版本检测** | 启动时自动检测 MATLAB 版本，现代 API 优先 + 旧 API 回退 |
| **工作空间隔离** | 中间文件自动隔离到 `.matlab_agent_tmp/`，用户项目目录保持干净 |
| **文件安全** | `.slx`/`.m` 在 workspace；中间文件（`.py`/`.json`/`slprj/`）自动隔离 |

---

## 🔒 8 层硬编码 Gate 门控系统

门控系统是 MATLAB-Agent 最核心的安全保障机制。所有 Gate 硬编码在 Python Bridge 层（非 LLM 提示词），AI **不可绕过**。

| Gate | 触发点 | 作用 | 解锁方式 |
|------|--------|------|----------|
| **Gate_S0** 🔴 | 所有 Simulink 操作 | 令牌门控 — 场景未确认拦截一切 | `sl_scene_detect` → 用户确认 → `sl_scene_confirm` |
| **PROJECT_DIR** | `run_code` / `create_simulink` | 工作区未初始化阻止一切 | `setup_workspace.py` |
| **Gate_RAW_CMD** 🔴 | `run_code` / `/api/matlab/command` | 原始命令二选一门控 | 令牌请求 → 用户确认 |
| **Gate_2** | `add_block` / `add_line` | 框架未审批禁止搭建 | `sl_framework_design → review → approve` |
| **Gate_3** | `subsystem_create` / 结构修改 | 框架锁定后修改需审批 | `sl_framework_modify → approve` |
| **Gate_4** | `sl_sim_run` | 模型未完成禁止仿真 | `sl_model_complete('complete')` |
| **Gate_5** | `sl_framework_approve` 入口 | 检查端口完备性+信号闭环 | checkItems 全部 pass |
| **Gate_SHELL_ONLY** | `add_block`/`add_line`/`set_param` | 子系统内部禁止批量操作 | `micro_design → review → approve` 逐个 |
| **Gate_CONNECTIVITY** | `add_block` | 连续添加超阈值拦截，强制连线 | `add_line` 连接已有块 |

### Gate 设计理念

- **Python 硬编码**: Gate 逻辑在 `matlab_bridge.py` 中，AI 无法通过提示词工程绕过
- **渐进解锁**: 必须先通过前面的 Gate 才能进入下一阶段
- **自动触发**: AI 不需要记住检查 Gate — Bridge 在每个命令入口自动检查
- **结构化反馈**: 被拦截时返回明确的 `gate_blocked` 状态 + 解锁指导

---

## 🔄 Simulink 建模工作流

### 完整建模流程（Phase -1 至 Phase 6）

```
┌────────────────────────────────────────────────────────────────────┐
│ Phase -1: 场景确认 (Gate_S0 — 最优先)                              │
│   sl_scene_detect(workspaceDir)                                     │
│   → 自动检测 .slx/.mdl → 返回 confirmationToken                    │
│   → 用户确认 → sl_scene_confirm(scene, modelName, token)           │
│   场景未确认前，所有 Simulink 操作被 Gate_S0 拦截                   │
├────────────────────────────────────────────────────────────────────┤
│ Phase 0: 模型创建 (Scene 1) / 模型加载 (Scene 2)                   │
│   sl_model_create(modelName) — Scene 1 创建空 .slx（强制执行）     │
│   sl_model_load(modelName) — Scene 2 加载已有模型                   │
├────────────────────────────────────────────────────────────────────┤
│ Phase 0.5: 审视                                                    │
│   sl_inspect(modelName) + sl_get_model_issues(modelName)            │
├────────────────────────────────────────────────────────────────────┤
│ Phase 1: 大框架设计                                                 │
│   sl_framework_design(taskDescription) → designPrompt               │
│   AI 从第一性原理自主设计子系统架构 + signalFlow + physicsEquations │
├────────────────────────────────────────────────────────────────────┤
│ Phase 2: 审查审批                                                   │
│   sl_framework_review(macroFramework) → 11 项自检                   │
│   sl_framework_approve(modelName) → Gate_5 门控 → 框架锁定          │
├────────────────────────────────────────────────────────────────────┤
│ Phase 3: 子系统迭代                                                 │
│   for each 子系统:                                                  │
│     sl_micro_design(subsys, task, parentContext, 'depth', N)        │
│     → sl_micro_review → sl_micro_approve (Gate_SHELL_ONLY)          │
├────────────────────────────────────────────────────────────────────┤
│ Phase 4: 骨架构建                                                   │
│   sl_subsystem_create('empty', inputPorts=N, outputPorts=M)         │
│   批量创建外壳+Inport/Outport（容器可批量，内部禁止批量）            │
├────────────────────────────────────────────────────────────────────┤
│ Phase 5: 递归构建 (Gate_SHELL_ONLY + Gate_CONNECTIVITY)             │
│   sl_add_block_safe / sl_add_line_safe / sl_set_param_safe          │
│   每 5 次 add_block 强制 auto_layout；每步自动注入 _verification    │
├────────────────────────────────────────────────────────────────────┤
│ Phase 6: 完成门控 + 仿真                                            │
│   sl_model_complete(modelName, 'action', 'complete')                │
│   → Gate_4: 12 项验证 + connectionScan + paramAudit                │
│   → sl_sim_run / sl_sim_batch                                       │
└────────────────────────────────────────────────────────────────────┘
```

### 双场景支持

| 场景 | 说明 | 工作流 |
|------|------|--------|
| **Scene 1** | 从零新建模型 | 场景确认 → 框架设计 → 搭建 → 验证 → 仿真 |
| **Scene 2** | 修改已有模型 | 场景确认 → 加载模型 → 理解结构 → 沙盒隔离修改 → 审批 → 搭建 → 验证 → 仿真 |

### 设计哲学

> **AI 是设计师，不是代码生成器。**

- `sl_framework_design` / `sl_micro_design` 是**纯 Prompt 组装器**，不存在预定义模板
- AI 从第一性原理（牛顿力学、拉格朗日方程、基尔霍夫定律等）推导物理方程
- 子系统划分、信号流设计、方程离散化完全由 AI 自主完成
- Gate 系统只验证**正确性**，不限制**设计空间**

---

## 🐍 MATLAB-Python 版本适配

> **MATLAB 不同版本支持的 Python 版本不同。请根据你的 MATLAB 版本安装对应的 Python！**

### 完整适配表（R2020a – R2026a）

| MATLAB 版本 | 支持 Python 版本 | 推荐 Python |
|:---:|:---|:---:|
| **R2026a** | 3.9, 3.10, 3.11, 3.12, 3.13 | **3.11** |
| **R2025b** | 3.9, 3.10, 3.11, 3.12 | **3.11** |
| **R2025a** | 3.9, 3.10, 3.11, 3.12 | **3.11** |
| **R2024b** | 3.9, 3.10, 3.11, 3.12 | **3.11** |
| **R2024a** | 3.9, 3.10, 3.11 | **3.11** |
| **R2023b** | 3.9, 3.10, 3.11 | **3.11** |
| **R2023a** | 3.8, 3.9, 3.10 | **3.10** |
| **R2022b** | 3.8, 3.9, 3.10 | **3.10** |
| **R2022a** | 3.8, 3.9 | **3.9** |
| **R2021b** | 3.7, 3.8, 3.9 | **3.9** |
| **R2021a** | 3.7, 3.8 | **3.8** |
| **R2020b** | 3.6, 3.7, 3.8 | **3.8** |
| **R2020a** | 3.6, 3.7 | **3.7** |

> **数据来源**: [MathWorks 官方兼容性页面](https://www.mathworks.com/support/requirements/python-compatibility.html)  
> **注意**: R2023a 起不再支持 Python 2.x。R2026a 新增 Python 3.13 支持。  
> **推荐原则**: 选择支持列表中**最新稳定**的 Python 版本；若多个 MATLAB 版本共存，选交集中最高的版本。

### Python 版本对应 MATLAB 版本速查

| Python 版本 | 兼容的 MATLAB 版本 |
|:---:|:---|
| **3.13** | R2026a |
| **3.12** | R2024b – R2026a |
| **3.11** | R2023b – R2026a |
| **3.10** | R2022b – R2026a |
| **3.9** | R2020b – R2026a |
| **3.8** | R2020a – R2023a |
| **3.7** | R2020a – R2021b |
| **3.6** | R2020a – R2020b |

> **提示**: 如果 `pip install matlabengine` 报 DLL 错误，请检查 Python 版本是否在 MATLAB 版本的支持列表中。

---

## 🚀 快速开始

### 前置条件

- **MATLAB** R2020a 或更新版本（首次启动需配置安装路径）
- **Python** 请根据上方的 MATLAB-Python 适配表安装对应版本
- **Node.js 18+** 和 **npm**
- **Git Bash**（Windows 下必需，CMD/PowerShell 启动可能导致 Engine 崩溃）

### 安装

```bash
# 1. 克隆仓库
git clone https://github.com/Quantum-particle/MATLAB-Agent.git
cd MATLAB-Agent/app

# 2. 安装 Node.js 依赖
npm install --production

# 3. 安装 Python 依赖
pip install matlabengine   # MATLAB Engine API for Python

# 4. 配置 MATLAB 路径
# 方式 A: 环境变量
export MATLAB_ROOT="C:/Program Files/MATLAB/R2023b"

# 方式 B: 首次启动后通过 API 配置
curl -X POST http://localhost:3000/api/matlab/config \
  -H "Content-Type: application/json" \
  -d '{"matlabRoot": "C:/Program Files/MATLAB/R2023b"}'
```

### 启动服务

```bash
# 唯一启动方式：Git Bash（禁止 CMD start /B）
bash app/ensure-running.sh
```

启动脚本自动完成：端口清理 → 依赖检查 → 后台启动 → 健康检查 → MATLAB Engine 预热（18-30s）

```bash
# 验证服务就绪
curl localhost:3000/api/health
# → {"status":"ok","matlab":{"ready":true,"version":"R2023b"}}
```

### 初始化工作环境

```bash
# 设置工作目录（AI 不可绕过 — 跳过此步则所有操作被 PROJECT_DIR Gate 拦截）
python app/setup_workspace.py "D:/my_matlab_project"
```

---

## 📡 API 参考

### 核心端点速查

| 方法 | 路径 | 说明 |
|------|------|------|
| **基础** | | |
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 引擎状态 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录 |
| POST | `/api/matlab/run` | 在工作区中执行 M 代码 |
| POST | `/api/matlab/execute` | 执行 .m 脚本文件 |
| **场景确认 (Gate_S0)** 🔴 | | |
| POST | `/api/matlab/simulink/scene_detect` | 场景自动检测 |
| POST | `/api/matlab/simulink/scene_confirm` | 场景确认（需令牌） |
| **框架设计** | | |
| POST | `/api/matlab/simulink/framework_design` | 大框架设计 |
| POST | `/api/matlab/simulink/framework_review` | 大框架审查 |
| POST | `/api/matlab/simulink/framework_approve` | 大框架审批 (Gate_5) |
| POST | `/api/matlab/simulink/framework_modify` | 框架修改审批 (Gate_3) |
| **子系统设计** | | |
| POST | `/api/matlab/simulink/micro_design` | 子系统小框架设计 |
| POST | `/api/matlab/simulink/micro_review` | 子系统审查 |
| POST | `/api/matlab/simulink/micro_approve` | 子系统审批 |
| **模型编辑** | | |
| POST | `/api/matlab/simulink/inspect` | 模型全景检查 |
| POST | `/api/matlab/simulink/add_block` | 安全添加模块 |
| POST | `/api/matlab/simulink/add_line` | 安全连线 |
| POST | `/api/matlab/simulink/set_param` | 安全设置参数 |
| POST | `/api/matlab/simulink/delete` | 安全删除模块 |
| POST | `/api/matlab/simulink/subsystem_create` | 创建子系统 |
| POST | `/api/matlab/simulink/replace_block` | 替换模块 |
| **门控系统** | | |
| POST | `/api/matlab/simulink/model_complete` | 模型完成门控 (Gate_4) |
| POST | `/api/matlab/simulink/model_issues` | 模型问题诊断 |
| POST | `/api/matlab/simulink/check_port_completeness` | 端口完备性检查 |
| POST | `/api/matlab/simulink/check_signal_closure` | 信号流闭环检查 |
| **仿真** | | |
| POST | `/api/matlab/simulink/sim_run` | 运行仿真 |
| POST | `/api/matlab/simulink/sim_batch` | 批量仿真 |
| POST | `/api/matlab/simulink/sim_results` | 获取仿真结果 |
| POST | `/api/matlab/simulink/validate` | 模型验证 |
| **提示词查询** | | |
| GET | `/api/matlab/simulink/prompt/list` | 列出可用场景/参考 |
| GET | `/api/matlab/simulink/prompt/scenario` | 获取场景提示词 |
| GET | `/api/matlab/simulink/prompt/reference` | 获取参考层内容 |

> 完整 68 个 sl_toolbox API 详细文档（含签名、参数、返回值、示例）见 [`references/sl_toolbox_api_guide.md`](references/sl_toolbox_api_guide.md) (v19.0)

---

## 📁 项目结构

```
matlab-agent/
├── README.md                           # 本文件 — 项目总览
├── SKILL.md                            # Agent 智能体完整描述（API 速查 + 踩坑经验）
├── PUBLISH.md                          # GitHub 发布流程与脱敏规则
├── GITHUB.md                           # 仓库管理记录
├── app/                                # 完整应用源码
│   ├── server/
│   │   ├── index.ts                    # Express 路由 + 50+ API 端点 (~1900 行)
│   │   ├── matlab-controller.ts        # MATLAB 控制器核心 (~1635 行)
│   │   ├── system-prompts.ts           # AI 系统提示词 + 门控规则 (~1154 行)
│   │   └── db.ts                       # SQLite 数据库管理
│   ├── matlab-bridge/
│   │   ├── matlab_bridge.py            # Python-MATLAB 桥接核心 (~10,322 行)
│   │   └── sl_toolbox/                 # MATLAB 工具箱（72 个 .m 函数）
│   │       ├── sl_framework_*.m        # 框架设计/审查/审批/修改 (10 个)
│   │       ├── sl_micro_*.m            # 子系统设计/审查/审批/提示词 (5 个)
│   │       ├── sl_model_complete.m     # 模型完成门控 (Gate_4)
│   │       ├── sl_scene_*.m            # 场景检测与确认 (Gate_S0)
│   │       ├── sl_add_*.m              # 安全添加模块/连线/参数 (8 个)
│   │       ├── sl_sim_*.m              # 仿真运行/批量/结果 (4 个)
│   │       ├── sl_validate_*.m         # 模型验证/问题诊断 (5 个)
│   │       ├── sl_check_*.m            # 端口完备性/信号闭环检查 (3 个)
│   │       ├── sl_bus_*.m              # 总线创建/检查/信号配置 (4 个)
│   │       ├── sl_auto_layout.m        # 自动排布
│   │       ├── sl_baseline_test.m      # 基线测试
│   │       ├── sl_block_registry.m     # 模块注册表 (核心基础设施)
│   │       └── sl_self_improve.m       # 自我改进引擎
│   ├── ensure-running.sh               # ⭐ 一键启动脚本（Git Bash，唯一方式）
│   ├── setup_workspace.py              # 工作环境初始化门控
│   ├── TROUBLESHOOTING.md              # 故障排除手册
│   ├── package.json                    # Node.js 依赖配置
│   └── src/                            # React 18 + TDesign + Vite 前端
└── references/                         # 参考文档
    ├── sl_toolbox_api_guide.md         # 🔴 72 个 API 完整签名文档 (v21.0)
    ├── pitfalls.md                     # 踩坑经验详录 (33 条)
    ├── pitfall-database.md             # 结构化踩坑数据库
    ├── block-param-registry.md         # 模块参数类型注册表
    └── troubleshooting.md              # 故障排除参考
```

### 代码规模

| 组件 | 规模 |
|------|------|
| `matlab_bridge.py` | ~10,322 行 Python |
| `sl_toolbox/*.m` | 72 个 MATLAB 函数 |
| `index.ts` | ~1,900 行 TypeScript |
| `matlab-controller.ts` | ~1,635 行 TypeScript |
| `system-prompts.ts` | ~1,154 行 TypeScript |
| `ensure-running.sh` | 218 行 Bash |
| **总计** | **~14,000+ 行源代码** |

---

## 🔧 技术栈

| 层级 | 技术 |
|------|------|
| 后端框架 | Express 4 + TypeScript 5 |
| MATLAB 控制 | Python `matlabengine` / `matlab -batch` CLI 回退 |
| 前端 | React 18 + TDesign + Vite 5 + Tailwind CSS |
| 数据库 | SQLite（better-sqlite3）|
| 通信协议 | HTTP REST + stdin/stdout JSON 行协议 |

---

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| **8 层硬编码 Gate** | Gate_S0 / Gate_2 / Gate_3 / Gate_4 / Gate_5 / PROJECT_DIR / Gate_SHELL_ONLY / Gate_CONNECTIVITY，全部在 Python Bridge 层硬编码 |
| **AI 完全设计自由度** | `sl_framework_design` / `sl_micro_design` 是纯 Prompt 组装器，无预定义模板 |
| **双场景工作流** | Scene 1: 从零建模 + Scene 2: 已有模型沙盒隔离修改 |
| **反模式主动防护** | 10 大禁止规则嵌入 .m 函数，违反时返回 warning + 替代方案 |
| **每次操作自动验证** | 每次 `add_block`/`add_line`/`set_param` 自动注入 `_verification` 字段 |
| **自动排版** | 每 5 次 add 自动触发 `arrangeSystem(FullLayout=true)`；model_complete 时强制排版 |
| **diary 输出捕获** | `diary()` + `eng.eval()` 替代 `evalc()`，彻底解决引号转义和中文路径乱码 |
| **常驻 Python 桥接** | Node.js ↔ Python ↔ MATLAB Engine，stdin/stdout JSON 行协议通信 |
| **一键启动** | `bash app/ensure-running.sh`，自动端口清理 + 引擎预热 |
| **配置自检 & 自修复** | 启动时自动检测目录配置冲突并迁移；Engine 版本自动检测和修复 |
| **工作空间隔离** | 中间文件自动隔离到 `.matlab_agent_tmp/`，用户目录保持干净 |
| **提示词三层架构** | 核心层 + 场景层 + 参考层，3 个查询 API 按需加载 |
| **变量持久化** | Engine 模式下变量跨命令保持，像真实 MATLAB 会话 |
| **UTF-8 输出** | `sys.stdout.buffer.write()` + UTF-8 编码，解决 Windows GBK 乱码 |
| **双模引擎** | Engine API（R2019a+，变量持久化）/ CLI 回退（老版本 MATLAB） |
| **版本兼容** | 自动检测 MATLAB 版本，现代 API 优先 + 旧 API 回退 |
| **R2016a 兼容** | `contains`→`strfind`, `newline`→`char(10)`, 禁止中文/emoji 在 .m 中 |

---

## ⚠️ 关键踩坑经验

项目在 Windows + MATLAB 环境下踩过的深坑，已全部固化到代码和文档中：

1. **端口 3000 残留进程**：启动前自动扫描、杀进程、等待端口释放
2. **evalc 引号双写**：用 `diary()` + `eng.eval()` 替代 `evalc()`
3. **Windows GBK 编码**：Python stdout 使用 `buffer.write()` + UTF-8
4. **Simulink SubSystem 默认连线冲突**：先 `delete_line` 再 `add_line`
5. **模型构建后自动排版**：必须调用 `arrangeSystem(FullLayout='true')`，前后 save
6. **CMD `start /B` 控制台共享导致 Engine 崩溃**：改为 Git Bash `bash ensure-running.sh` 唯一启动方式
7. **Python Engine 版本不匹配导致 DLL 崩溃**：Engine 自动检测+修复
8. **中间文件污染用户目录**：自动隔离到 `.matlab_agent_tmp/`
9. **struct() cell 展开导致崩溃**：必须分步赋值 `s=struct(); s.field=cell_val;`
10. **中文路径编码**：通过临时文件 + `eng.workspace` 安全传递
11. **R2016a 兼容**: `contains`→`strfind`, `newline`→`char(10)`, `.m` 禁止中文/emoji
12. **Gate_S0 令牌安全**: 双令牌机制（detectionToken + confirmationToken），防止 AI 绕过用户确认

> 完整踩坑记录（33 条）见 [`references/pitfalls.md`](references/pitfalls.md) + [`references/pitfall-database.md`](references/pitfall-database.md)

---

## 🚫 反模式速查

| 禁止操作 | 正确做法 |
|----------|---------|
| 跳过 inspection | 始终 `sl_inspect` 先 |
| `set_param` + `sim` 裸跑 | `SimulationInput` + `sim` |
| 跳过 `sl_model_complete` | 仿真前必须通过 Gate_4 |
| 用 `&` 的完整库路径 | block registry 简写 |
| `sl_*_safe` params 传字符串 | **必须 struct**: `struct('Gain','5')` |
| `.m` 中文/emoji | 纯 ASCII，用 `[OK]`/`[WARN]` |
| `Scope` 端口数 | `NumInputPorts` 不是 `NumPorts` |
| `arrangeSystem` 不加 FullLayout | `'FullLayout','true'`，前后 save |
| Goto/From 跨子系统 | Inport/Outport 标准接口 |
| 新增模块不更新注册表 | 四文件同步: registry.md + .m + bridge.py + api_guide |

---

## 📜 版本历史

| 版本 | 日期 | 核心改动 |
|------|------|---------|
| **v12** | 2026-05-15 | [计划中] Gate_CONTENT_DEPTH (Rigor Score) + 参数标准化 + Gate 体系加固 |
| v11.9 | 2026-05-14 | Phase 0-6 工作流 + Gate_SHELL_ONLY + Gate_REVIEW_BUILD + 5 个新 .m 文件 |
| v11.8.3 | 2026-05-12 | REST sl_* 门控路由 + Cell/Struct 安全索引 + 中文路径编码 (7 修复) |
| v11.8.1 | 2026-05-10 | Bug 修复: compute_tree_depth + dimensionality + REST string/char |
| v11.8 | 2026-05-09 | 递归层级系统: sl_subsystem_tree + sl_hierarchy_validate + build_order |
| v11.6.8 | 2026-05-07 | Bug Fix: struct 格式统一 + Gate 修复 + 中文路径编码 (10 个修复) |
| v11.6.7 | 2026-05-06 | Scene 1 端到端评估 + 令牌优化 + 孤儿线清理 |
| v11.6.6 | 2026-05-06 | 沙盒孤儿线扫描+删除 (force-clear outport auto-connect) |
| v11.6.2 | 2026-05-06 | Scene 1&2 工作流强制机制 + Gate_CONNECTIVITY 硬门控 |
| v11.5 | 2026-04-30 | Scene 2 已有模型修改工作流 + 双场景门控 + 8 个新 .m 函数 |
| v11.4 | 2026-04-29 | Gate_5 门控体系 + sl_check_port_completeness / sl_check_signal_closure |
| v11.3 | 2026-04-29 | Gate_4 模型完成门控 + sl_model_complete 12项验证 |
| v11.2 | 2026-04-29 | 架构翻转：框架设计从计算引擎改为 Prompt 组装器 |
| v11.1 | 2026-04-29 | 大框架三层迭代 + 子系统小框架 + 框架修改审批 |
| v11.0 | 2026-04-21 | 工作空间隔离 + API Guide v15.0 |
| v8.0 | 2026-04-18 | Simulink 中间件重构 + 提示词三层架构 + 反模式防护 |
| v7.0 | 2026-04-18 | Layer 5 源码级自我改进 + 动态规则引擎 |
| v6.0 | 2026-04-18 | 23 个 sl_toolbox API + 端到端测试 74/74 通过 |
| v5.4 | 2026-04-14 | 工作空间隔离（.matlab_agent_tmp/）|
| v5.0 | 2026-04-10 | diary 替代 evalc + quickstart API + UTF-8 修复 |
| v4.0 | 2026-04-09 | 通用化升级 + CLI 回退 + 注册表扫描 |
| v1.0 | 2026-04-08 | 初始推送 |

> 详细更新日志见 [GITHUB.md](./GITHUB.md)

---

## 📄 License

MIT

---

<p align="center">
  Made with ❤️ by <a href="https://github.com/Quantum-particle">Quantum-particle</a>
</p>
