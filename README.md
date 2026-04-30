# MATLAB-Agent v11.5

<p align="center">
  <strong>AI 驱动的 MATLAB/Simulink 开发助手</strong><br>
  让 AI 直接操控 MATLAB 引擎——执行脚本、读写变量、构建 Simulink 模型、运行仿真
</p>

---

## 🎯 项目简介

**MATLAB-Agent** 打通了 AI 智能体与 MATLAB 开发环境之间的隔阂。通过常驻 Python 桥接进程与 MATLAB Engine API，AI 可以：

- 🔧 在持久化工作区中执行 M 代码（变量跨命令保持）
- 🚁 从零构建 Simulink 模型：框架设计 → 审批 → 搭建 → 验证 → 仿真（6 步门控工作流）
- 🔧 在已有 Simulink 模型上继续开发：加载 → 理解 → 沙盒设计 → 修改审批 → 搭建 → 仿真
- 📊 读取 `.m` / `.mat` / `.slx` 文件，管理工作区变量
- 🔄 双模引擎自动切换：Engine API（推荐）+ CLI 回退（兼容老版本）

> 不再是"AI 写代码你复制粘贴"，而是 AI 直接坐在 MATLAB 命令行前。

## 🏗️ Simulink 建模中间件架构（v11.5）

v11.5 的架构核心是 **5 层硬编码 Gate（Python Bridge 级，AI 不可绕过）+ 双场景工作流（从零建模 / 已有模型修改）**，AI 拥有完全设计自由度。

### 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                     AI 大模型 (LLM)                                  │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Layer 0: Skill 知识层 (专家知识包，按需加载)                   ││
│  │  ┌───────────┐ ┌──────────────┐ ┌───────────────┐              ││
│  │  │ 核心层     │ │ 场景层       │ │ 参考层         │              ││
│  │  │ (始终加载) │ │ (按需加载)   │ │ (查询加载)     │              ││
│  │  │ API索引   │ │ 建模场景     │ │ 完整注册表     │              ││
│  │  │ 反模式10条│ │ 仿真场景     │ │ 详细API文档    │              ││
│  │  │ 工作流6步 │ │ 测试场景     │ │ 踩坑经验库     │              ││
│  │  │ 5层Gate  │ │ 修改场景     │ │ 版本兼容参考   │              ││
│  │  └───────────┘ └──────────────┘ └───────────────┘              ││
│  ├─────────────────────────────────────────────────────────────────┤│
│  │ 优先：调用 Simulink 中间件 API（结构化参数+结构化反馈）         ││
│  │ 兜底：run_code 直接写 MATLAB 代码（保留完全自由度）             ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ HTTP API
┌────────────────────────────────▼────────────────────────────────────┐
│                    Node.js Server (index.ts)                         │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  Simulink 中间件 API 路由 (48个端点):                           ││
│  │  【模型编辑层】(7) 【信号与总线层】(4) 【子系统与层次层】(3)    ││
│  │  【模型配置层】(2) 【仿真控制层】(4) 【验证与诊断层】(4)        ││
│  │  【布局与导出层】(2) 【测试与性能层】(3)                        ││
│  │  【框架设计层】(10) 【门控层】(5) 【自我改进层】(1)              ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ JSON 行协议 (stdin/stdout)
┌────────────────────────────────▼────────────────────────────────────┐
│                Python Bridge (matlab_bridge.py)                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  48个命令处理器 + 5层硬编码 Gate + 反模式防护 + 版本检测       ││
│  │  Gate_2/Gate_3/Gate_4/Gate_5/PROJECT_DIR — AI 不可绕过           ││
│  │  每个命令 → 调用对应 sl_*.m 工具函数 → 返回结构化 JSON          ││
│  └─────────────────────────────────────────────────────────────────┘│
└────────────────────────────────┬────────────────────────────────────┘
                                 │ eng.eval() / CLI
┌────────────────────────────────▼────────────────────────────────────┐
│                MATLAB Engine / CLI                                    │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  sl_toolbox/ (58个.m 函数)                                      ││
│  │  【框架设计】sl_framework_design / _review / _approve / _modify  ││
│  │  【子系统】sl_micro_design / _review / _approve / _expand        ││
│  │  【门控验证】sl_model_complete / sl_get_model_issues              ││
│  │  【设计检查】sl_check_port_completeness / sl_check_signal_closure││
│  │  【核心模块】sl_inspect_model / sl_add_block_safe / sl_add_line  ││
│  │  【信号总线】sl_bus_create / sl_bus_inspect / sl_signal_*        ││
│  │  【子系统】sl_subsystem_create / mask / expand                   ││
│  │  【仿真控制】sl_sim_run / sl_sim_results / sl_sim_batch          ││
│  │  【验证诊断】sl_validate_model / sl_parse_error                  ││
│  │  【布局导出】sl_block_position / sl_auto_layout / sl_snapshot    ││
│  │  【测试性能】sl_baseline_test / sl_profile_sim / sl_profile_*    ││
│  │  【基础设施】sl_block_registry / sl_jsonencode / sl_best_*       ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

### 重构核心：从"裸写代码"到"结构化 API + 硬编码门控"

| 维度 | 旧方式（v5 之前） | 新方式（v6.0+ 中间件） |
|------|------------------|----------------------|
| 建模方式 | AI 裸写 `add_block`/`add_line` 代码 | 调用结构化 API，参数+返回值均为 JSON |
| 模型感知 | `read_simulink_model()` 只返回块路径列表 | `sl_inspect_model` 返回模块/端口/连线/信号维度全量信息 |
| 错误处理 | 出错后泛泛建议 | `sl_parse_error` 精确解析 15+ 种错误类型 |
| 反馈闭环 | 无验证 | 每次操作自动预检+验证，返回 `_verification` 字段 |
| API 现代化 | 一律用旧 API | `connectBlocks` > `add_line`；`SimulationInput` > `set_param+sim` |
| 反模式防护 | 无 | 10 大禁止规则嵌入 .m 函数，违反时返回 warning + 替代方案 |
| 门控体系 | 无 | 5 层硬编码 Gate (Python Bridge C++级，AI 不可绕过) |
| 版本兼容 | 不处理 | 自动检测 MATLAB 版本，现代 API 优先 + 旧 API 回退 |
| 设计自由度 | 固定模板 | v11.2 架构翻转：AI 拥有完全子系统划分自由度，从第一性原理出发 |

### 设计原则

1. **中间件优先，裸码兜底** — AI 优先调用结构化 API；API 不够用时仍可 `run_code` 裸写
2. **每次操作后自动反馈** — `add_block` 返回模块状态 + `_verification`，`add_line` 返回连线状态
3. **操作前自动预检** — 连线前检查端口是否存在、是否已被占用
4. **AI 不可绕过门控** — 5 层 Gate 硬编码在 Python Bridge 中，AI 无法通过提示词绕过
5. **现代 API 优先 + 旧 API 回退** — 版本检测 + 双路径
6. **反模式主动防护** — 10 大禁止规则嵌入 .m 函数
7. **场景自动判断** — Gate_S0 检测 workspace 中是否有现有模型，自动区分 Scene 1/2
8. **沙盒隔离修改** — 已有模型的修改通过隔离沙盒子系统，防止误操作污染原有部分

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| **Simulink 建模中间件**（v6.0~v11.5） | 58 个 .m 函数 + 48 个 REST API 端点，覆盖建模→仿真→验证→门控→测试→性能分析全生命周期 |
| **5 层硬编码 Gate**（v11.0~v11.5） | Gate_2 (框架审批) / Gate_3 (锁定后修改) / Gate_4 (仿真前完成) / Gate_5 (设计完整性) / PROJECT_DIR (未初始化阻止)，全部在 Python Bridge 层 C++ 级别拦截 |
| **双场景工作流**（v11.5） | Scene 1: 从零建模（framework 设计→搭建→验证）+ Scene 2: 已有模型修改（加载→理解→沙盒→修改→验证） |
| **AI 完全设计自由度**（v11.2） | `sl_framework_design` / `sl_micro_design` 改为 Prompt 组装器，不存在通用模板，AI 从第一性原理自主设计 |
| **反模式防护** | 10 大禁止规则（Sum 块/To Workspace/裸 Position/跳过 Gate_4 等）嵌入 .m 函数，自动拦截 + 替代建议 |
| **diary 输出捕获** | `diary()` + `eng.eval()` 替代 `evalc()`，彻底解决引号双写、中文路径乱码 |
| **常驻 Python 桥接** | Node.js ↔ Python ↔ MATLAB Engine，stdin/stdout JSON 行协议通信 |
| **一键启动** | `bash app/ensure-running.sh` 唯一启动方式（Git Bash），2s 服务 + 18-30s Engine 预热 |
| **配置自检 & 自修复** | 启动时自动检测双目录配置冲突并迁移；Engine 版本自动检测和修复 |
| **工作空间隔离**（v5.4→v10.1） | 中间执行文件自动隔离到 `.matlab_agent_tmp/`，用户项目目录保持干净 |
| **提示词三层架构**（v8.0） | 核心层 + 场景层 + 参考层，3 个查询 API 支持按需加载 |
| **变量持久化** | Engine 模式下变量跨命令保持，像真实 MATLAB 会话一样逐步操作 |
| **UTF-8 输出** | `sys.stdout.buffer.write()` + UTF-8 编码，解决 Windows GBK 乱码 |
| **双模引擎** | Engine API（R2019a+，变量持久化）/ CLI 回退（老版本 MATLAB） |

## 📁 项目结构

```
matlab-agent/
├── README.md                    # 本文件
├── SKILL.md                     # Skill 智能体描述（含 API 速查、踩坑经验）
├── GITHUB.md                    # GitHub 仓库管理记录
├── PUBLISH.md                   # 发布流程与脱敏规则
├── app/                         # 完整应用源码
│   ├── server/
│   │   ├── index.ts             # Express 服务器入口
│   │   ├── matlab-controller.ts # MATLAB 控制器（核心逻辑）
│   │   ├── system-prompts.ts    # AI 系统提示词
│   │   └── db.ts                # SQLite 数据库
│   ├── matlab-bridge/
│   │   ├── matlab_bridge.py     # Python-MATLAB 桥接（常驻模式）
│   │   └── sl_toolbox/          # Simulink 工具箱（58 个 .m 函数）
│   │       ├── sl_framework_design.m     # 大框架设计 (Prompt 组装器)
│   │       ├── sl_framework_review.m     # 大框架自检
│   │       ├── sl_framework_approve.m    # 大框架审批 (Gate_5)
│   │       ├── sl_micro_design.m         # 子系统设计 (Prompt 组装器)
│   │       ├── sl_micro_review.m         # 子系统自检
│   │       ├── sl_micro_approve.m        # 子系统审批
│   │       ├── sl_model_complete.m       # 模型完成门控 (Gate_4)
│   │       ├── sl_get_model_issues.m     # 模型问题诊断
│   │       ├── sl_check_port_completeness.m  # 端口完备性检查
│   │       ├── sl_check_signal_closure.m     # 信号流闭环检查
│   │       ├── sl_inspect_model.m        # 模型全景检查
│   │       ├── sl_add_block_safe.m       # 安全添加模块（含反模式防护）
│   │       ├── sl_add_line_safe.m        # 安全连线（connectBlocks 优先）
│   │       ├── sl_sim_run.m              # 仿真运行（SimulationInput 优先）
│   │       ├── sl_subsystem_create.m     # 创建子系统（createSubsystem 优先）
│   │       └── ...                       # 共 58 个 .m 函数
│   ├── src/                     # React 18 + TDesign + Vite 前端
│   ├── ensure-running.sh        # ⭐ 一键启动脚本（Git Bash，唯一方式）
│   ├── setup_workspace.py       # 工作环境初始化门控
│   ├── TROUBLESHOOTING.md       # 故障排除手册
│   └── README.md                # 应用内说明文档
└── references/
    ├── sl_toolbox_api_guide.md      # 🔴 sl_toolbox API 说明书（58 个函数，v18.0）
    ├── pitfalls.md                  # 踩坑经验详录（33 条）
    ├── pitfall-database.md          # 踩坑数据库（结构化 Pattern-Key 索引）
    ├── block-param-registry.md      # 模块参数类型/枚举值速查
    ├── troubleshooting.md           # 故障排除参考
    └── matlab-bridge-api.md         # Python Bridge API 文档
```

## 🚀 快速开始

### 前置条件

- **MATLAB** 任意版本（首次启动需配置安装路径）
- **Python 3.9+**（Engine API 模式需要）
- **Node.js 18+**

### 启动服务

```bash
# 唯一方式：Git Bash（禁止 CMD start /B，控制台共享会导致 Engine 崩溃）
bash app/ensure-running.sh
```

启动脚本自动完成：端口清理 → 依赖检查 → 后台启动 → 健康检查 → MATLAB Engine 预热（18-30s）

### 一键快速启动（AI Agent 专用）

```bash
# 确保服务运行（幂等：已在运行则直接退出）
bash app/ensure-running.sh

# 验证服务就绪
curl localhost:3000/api/health
# → {"status":"ok","matlab":{"ready":true,"version":"R2023b"}}

# 初始化工作环境
python app/setup_workspace.py "D:\my_project"
```

## 📡 API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 状态 |
| POST | `/api/matlab/quickstart` | 一键快速启动 |
| GET | `/api/matlab/config` | 获取 MATLAB 配置 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录 |
| POST | `/api/matlab/project/set` | 设置项目目录 |
| GET | `/api/matlab/project/scan` | 扫描项目文件 |
| GET | `/api/matlab/file/m` | 读取 .m 文件 |
| GET | `/api/matlab/file/mat` | 读取 .mat 变量 |
| POST | `/api/matlab/run` | 持久化工作区执行代码 |
| POST | `/api/matlab/execute` | 执行 .m 脚本 |
| **v11.0+: 框架设计层** | | |
| POST | `/api/matlab/simulink/framework_design` | 大框架设计 |
| POST | `/api/matlab/simulink/framework_review` | 大框架自检 |
| POST | `/api/matlab/simulink/framework_approve` | 大框架审批 (Gate_5) |
| POST | `/api/matlab/simulink/micro_design` | 子系统设计 |
| POST | `/api/matlab/simulink/micro_review` | 子系统自检 |
| POST | `/api/matlab/simulink/micro_approve` | 子系统审批 |
| **v11.3+: 门控层** | | |
| POST | `/api/matlab/simulink/model_complete` | 模型完成门控 (Gate_4) |
| POST | `/api/matlab/simulink/model_issues` | 模型问题诊断 |
| POST | `/api/matlab/simulink/check_port_completeness` | 端口完备性检查 |
| POST | `/api/matlab/simulink/check_signal_closure` | 信号流闭环检查 |
| **v6.0+: 模型编辑** | | |
| POST | `/api/matlab/simulink/inspect` | 检查模型全景 |
| POST | `/api/matlab/simulink/add_block` | 安全添加模块 |
| POST | `/api/matlab/simulink/add_line` | 安全连线 |
| POST | `/api/matlab/simulink/set_param` | 安全设置参数 |
| POST | `/api/matlab/simulink/delete` | 安全删除 |
| POST | `/api/matlab/simulink/find_blocks` | 高级查找 |
| POST | `/api/matlab/simulink/bus_create` | 创建总线 |
| POST | `/api/matlab/simulink/subsystem_create` | 创建子系统 |
| POST | `/api/matlab/simulink/sim_run` | 运行仿真 |
| POST | `/api/matlab/simulink/sim_batch` | 批量仿真 |
| POST | `/api/matlab/simulink/validate` | 模型验证 |
| POST | `/api/matlab/simulink/auto_layout` | 自动排版 |
| **v8.0: 提示词 API** | | |
| GET | `/api/matlab/simulink/prompt/list` | 列出可用场景 |
| GET | `/api/matlab/simulink/prompt/scenario` | 获取场景提示词 |
| GET | `/api/matlab/simulink/prompt/reference` | 获取参考层提示词 |
| **v10.1: 工作空间隔离** | | |
| POST | `/api/matlab/workspace/isolation/init` | 初始化隔离目录 |
| POST | `/api/matlab/workspace/isolation/route` | 文件路径路由 |
| POST | `/api/matlab/workspace/isolation/cleanup` | 清理中间文件 |

> 完整 58 个 sl_toolbox API 文档见 `references/sl_toolbox_api_guide.md` (v18.0)

## 🔧 技术栈

| 层级 | 技术 |
|------|------|
| 后端 | Express 4 + TypeScript 5 |
| MATLAB 控制 | Python matlabengine / matlab CLI |
| 前端 | React 18 + TDesign + Vite 5 |
| 数据库 | SQLite (better-sqlite3) |
| 通信协议 | HTTP REST + stdin/stdout JSON |

## ⚠️ 关键踩坑经验

项目在 Windows + MATLAB 环境下踩过的深坑，已全部固化到代码和文档中：

1. **端口 3000 残留进程**：启动前自动扫描、杀进程、等待端口释放
2. **evalc 引号双写**：用 `diary()` + `eng.eval()` 替代 `evalc()`
3. **Windows GBK 编码**：Python stdout 使用 `buffer.write()` + UTF-8
4. **Simulink SubSystem 默认连线冲突**：先 `delete_line` 再 `add_line`
5. **复杂模型 From/Goto 信号传递**：不要强行连线，用广播标签
6. **模型构建后自动排版**：必须调用 `arrangeSystem(FullLayout='true')`，前后 save
7. **双 data/ 目录配置不同步**（v5.2 自动修复）：`ensureDataDirSync()` 启动自检 + 自动迁移
8. **CMD `start /B` 控制台共享导致 Engine 崩溃**（v11.4.1）：改为 Git Bash `bash ensure-running.sh` 唯一启动方式
9. **Python Engine 版本不匹配导致 DLL 崩溃**（v11.4.1）：Engine 自动检测+修复，`dist/matlab/` 覆盖 `site-packages`
10. **中间执行文件污染用户项目目录**（v5.4→v10.1）：自动隔离到 `.matlab_agent_tmp/`
11. **struct() cell 展开导致崩溃**（#1 最大坑）：必须分步赋值 `s=struct(); s.field=cell_val;`
12. **R2016a 兼容**: `contains`→`strfind`, `newline`→`char(10)`, `.m` 禁止中文/emoji

> 完整踩坑记录（33 条）见 `references/pitfalls.md` + `references/pitfall-database.md`

## 📜 版本历史

| 版本 | 日期 | 核心改动 |
|------|------|---------|
| v11.5 | 2026-04-30 | **Scene 2 开发计划**：双场景门控架构（Gate_S0 场景自动判断+用户确认）、已有模型修改工作流（加载→理解→沙盒设计→审批→搭建→仿真）、双通道修改（沙盒新增AI审批+已有修改用户确认）、8 个新 .m 函数+4 个新 Bridge Gate+9 个新 REST 端点 |
| v11.4 | 2026-04-29 | **Gate_5 门控体系**：sl_check_port_completeness / sl_check_signal_closure 设计阶段检查、sl_framework_verify_built 设计-模型对照、Engine 版本自动检测和修复、v11.4.1 Engine 暖机修复、setup 工程级门控(v11.4.4) |
| v11.3 | 2026-04-29 | **建模流程强制门控**：Gate_4 模型完成门控（unconnected=0）、sl_model_complete 12项验证、Goto/From 配对检查、孤立模块检测、sl_get_model_issues 精细诊断 |
| v11.2 | 2026-04-29 | **架构翻转**：sl_framework_design/sl_micro_design 从计算引擎改为 Prompt 组装器，AI 拥有完全设计自由度、无预定义模板 |
| v11.1 | 2026-04-29 | **v11.0 大框架三层迭代循环**：sl_framework_design→review→approve (Gate_2/3)、sl_micro_design→review→approve (Micro Gate)、sl_framework_modify 框架变更审批 |
| v11.0 | 2026-04-21 | **v10.1 强制文件隔离**：slprj/隔离到 .matlab_agent_tmp/、Bridge _run_code_via_diary 隔离、createMFile routeFilePathSync；**API Guide v15.0**：sl_model_status_snapshot、_verification/_auto_layout/_workflow 字段说明、35+ 章节；**v10.0 代码审查**：18 项修复 51/51 PASS |
| v8.0 | 2026-04-18 | Simulink 建模底层重构（中间件架构+反模式防护+反馈闭环）、提示词三层架构 |
| v7.0 | 2026-04-18 | Layer 5 源码级自我改进、动态规则引擎、patch_source 源码补丁、Python Bridge + Node.js REST 全量端点 |
| v6.0 | 2026-04-18 | 23 个 sl_toolbox API、端到端测试 74/74 通过、二阶倒立摆测试 35/35 通过 |
| v5.4 | 2026-04-14 | 工作空间隔离（.matlab_agent_tmp/）、中间文件自动清理、3 个新 API |
| v5.2 | 2026-04-14 | 4 Bug 修复（双目录同步/重定向报错/空 bat/PowerShell 慢）、ensureDataDirSync 自检、config diagnose API、DELETE config API |
| v5.1 | 2026-04-10 | 启动防弹、端口清理、Simulink 建模深坑固化、封装子系统解析规范 |
| v5.0 | 2026-04-10 | diary 替代 evalc、quickstart API、UTF-8 输出修复 |
| v4.1 | 2026-04-09 | 手动配置模式、动态环境信息注入 |
| v4.0 | 2026-04-09 | 通用化升级、CLI 回退模式、注册表扫描 |
| v1.0 | 2026-04-08 | 初始推送 |

> 详细更新日志见 [GITHUB.md](./GITHUB.md)

## 📄 License

MIT

---

<p align="center">
  Made with ❤️ by <a href="https://github.com/Quantum-particle">Quantum-particle</a>
</p>
