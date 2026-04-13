# MATLAB Agent

> AI 驱动的 MATLAB/Simulink 开发助手 | 版本 5.1.0

打通 AI 智能体与 MATLAB 闭园开发环境的隔阂，让 AI 能像开发 Python、C 一样在 MATLAB 中高效工作。特别面向航空航天领域的动力学建模、控制律设计和信号处理。

## v5.1 核心升级

### v5.1 — 启动防弹 + Simulink 建模深坑固化
- 🔴 **端口 3000 自动清理**: 启动前自动杀残留进程 → 等待端口释放 → 确认干净 → 再启动
- **一键启动脚本**: `start.bat` / `ensure-running.bat` 防弹级启动，AI Agent 一行命令搞定
- **Simulink 建模深坑固化**: 默认连线冲突、From/Goto 信号传递、自动排版等 6 大坑写入底层
- **模型构建后自动排版**: `Simulink.BlockDiagram.arrangeSystem()` 确保用户看到整齐布局

### v5.0 — diary 输出捕获 + 一键启动
- **diary 替代 evalc**: 彻底解决 Name-Value 参数引号双写、中文路径乱码、多行代码拼接三大顽疾
- **一键 quickstart API**: `POST /api/matlab/quickstart` 一步完成 MATLAB_ROOT + Engine 启动 + 项目目录
- **UTF-8 输出修复**: Python Bridge 使用 `sys.stdout.buffer.write()` + UTF-8，解决 Windows GBK 乱码
- **相对路径修复**: execute API 基于 `_cachedProjectDir` 解析，不再依赖 Node.js CWD

### v4.1 — 手动配置 + 踩坑固化
- 移除自动检测，改为手动配置 + 环境变量 + 配置文件优先级
- 踩坑经验固化到 SKILL.md、system-prompts.ts、TROUBLESHOOTING.md

### v4.0 — 通用化
- 双连接模式: Engine API（R2019a+）+ CLI 回退（老版本）
- Python Bridge 常驻进程 + JSON 行协议

## 架构

```
用户 (React 前端 / AI Agent)
  │
  ├─ SSE ─→ Express Server (TypeScript)
  │            │
  │            ├─ CodeBuddy Agent SDK ─→ AI 模型
  │            │
  │            └─ spawn ─→ Python Bridge (matlab_bridge.py --server)
  │                          │
  │                          ├─ Engine 模式: matlabengine → MATLAB Engine API
  │                          │   （变量持久化，R2019a+）
  │                          │
  │                          └─ CLI 回退模式: matlab -batch / matlab -r
  │                              （变量不持久，兼容老版本）
  │
  └─ REST API ─→ /api/matlab/* (直接调用 MATLAB)
```

## 快速开始

### 前置条件
- **MATLAB** 任意版本安装在系统上（首次启动时需手动输入安装路径）
- **Python 3.9+**（Engine API 模式需要，CLI 回退模式不要求）
- **Node.js 18+**（Windows 下 `npx.cmd` 必须在 PATH 中）
- **CodeBuddy CLI**（已登录）

### 安装

```bash
cd matlab-agent
npm install
```

### 安装 MATLAB Engine for Python（Engine 模式需要）

```bash
# 进入 MATLAB 安装目录下的引擎接口
cd "<你的MATLAB安装路径>/extern/engines/python"
python -m pip install matlabengine
```

> 如果 Python 版本与 MATLAB Engine 不兼容（如 MATLAB R2016a + Python 3.11），会自动回退到 CLI 模式，无需手动安装。

### 启动

> ⚠️ **绝对不能用** `npx tsx server/index.ts` 或 `npm run dev` 阻塞式启动！
> MATLAB Engine 预热需要 30-90 秒，阻塞式启动会导致超时卡死。

#### 方式 A：一键启动脚本（⭐ 强烈推荐）

```bash
# 一键启动（自动清理端口、安装依赖、后台启动、轮询健康检查）
cmd /c "start.bat"
```

#### 方式 B：AI Agent 专用 — ensure-running

```bash
# AI Agent 只需一行命令确保服务运行
cmd /c "ensure-running.bat"
# 返回码 0 = 服务可用
```

#### 方式 C：一键 quickstart API（v5.0 推荐）

```bash
# 一步完成 MATLAB_ROOT 配置 + Engine 启动 + 项目目录设置
# Windows 下用 PowerShell — 必须用 ConvertTo-Json 变量构造法，避免 $ 变量被展开吞噬
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\my_project'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"
```

### 配置 MATLAB 路径

首次启动时，一键脚本会自动交互式引导用户输入 MATLAB 安装路径。也可手动配置：

```bash
# 方法1: 环境变量
set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b

# 方法2: API 配置（路径会持久化到配置文件）— 必须用 ConvertTo-Json 变量构造法
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"

# 方法3: 一键快速启动（v5.0 推荐）— 必须用 ConvertTo-Json 变量构造法
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\my_project'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"
```

**优先级**: 环境变量 `MATLAB_ROOT` > 配置文件 `data/matlab-config.json` > 未配置（提示用户输入）

## API 参考

### 健康与状态
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查（含 MATLAB warmup 状态） |
| GET | `/api/matlab/status` | MATLAB 状态（快速） |
| GET | `/api/matlab/status?quick=false` | MATLAB 完整检查（含 Engine） |
| GET | `/api/matlab/config` | 获取 MATLAB 配置 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录（持久化） |
| **POST** | **`/api/matlab/quickstart`** | **一键快速启动（v5.0）** |

### 项目操作
| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/matlab/project/set` | 设置项目目录 |
| GET | `/api/matlab/project/scan?dir=...` | 扫描项目文件 |

### 文件读取
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/matlab/file/m?path=...` | 读取 .m 文件 |
| GET | `/api/matlab/file/mat?path=...` | 读取 .mat 变量 |
| GET | `/api/matlab/file/simulink?path=...` | 读取 Simulink 模型 |

### 代码执行
| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/matlab/run` | 持久化工作区执行代码（v5.0 diary 输出捕获） |
| POST | `/api/matlab/execute` | 执行 .m 脚本（v5.0 相对路径修复） |

### 工作区管理
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/matlab/workspace` | 获取工作区变量 |
| POST | `/api/matlab/workspace/save` | 保存工作区 |
| POST | `/api/matlab/workspace/load` | 加载工作区 |
| POST | `/api/matlab/workspace/clear` | 清空工作区 |

### Simulink
| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/matlab/simulink/create` | 创建 Simulink 模型 |
| POST | `/api/matlab/simulink/run` | 运行 Simulink 仿真 |
| POST | `/api/matlab/simulink/open` | 打开模型 |
| POST | `/api/matlab/simulink/workspace/set` | 设置模型工作区变量 |
| GET | `/api/matlab/simulink/workspace?modelName=...` | 获取模型工作区变量 |
| POST | `/api/matlab/simulink/workspace/clear` | 清空模型工作区 |

### 图形管理
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/matlab/figures` | 列出图形窗口 |
| POST | `/api/matlab/figures/close` | 关闭所有图形 |

### 会话管理
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/sessions` | 获取所有会话 |
| POST | `/api/sessions` | 创建会话 |
| DELETE | `/api/sessions/:id` | 删除会话 |
| POST | `/api/chat` | 发送消息（SSE 流式响应） |

## 预设 Agent

1. **MATLAB 开发** (`matlab-default`): M 语言开发，信号处理/控制律/数据分析
2. **Simulink 建模** (`simulink-default`): Simulink 模型构建和仿真（含深坑经验固化）
3. **通用助手** (`default`): 通用 AI 助手

## ⚠️ 关键踩坑经验（固化到 AI 底层）

### 启动踩坑
- 🔴 **端口 3000 被旧进程占用**: 启动前必须杀掉残留进程，确认端口干净再启动
- **node_modules 缺失**: 首次使用必须 `npm install --production`
- **npx 在 Windows 是 .cmd**: 必须用 `cmd /c "npx tsx ..."`
- **绝对不能阻塞式启动**: 必须 `start /B` 后台启动 + 轮询

### Simulink 建模踩坑（v5.1 固化）
- **新建 SubSystem 默认连线冲突**: 先 `delete_line` 清除默认连线，再 `add_line`
- **复杂模型用 From/Goto 传递信号**: 不是直接连线，在子系统内部用 From 模块获取信号
- **模型构建后必须排版**: `Simulink.BlockDiagram.arrangeSystem(modelName)`
- **中文路径用 dir()+fullfile()**: 不能在代码字符串中直接写中文路径
- **add_line 逐步执行**: 用 try-catch 包裹每个 `add_line`，避免连锁失败

### 输出捕获（v5.0 diary 替代 evalc）
- Name-Value 参数（如 `'LowerLimit'`）不再需要引号双写
- 中文路径和中文输出正常传递
- 多行代码无需手动拼接

## 项目结构

```
matlab-agent/
├── server/
│   ├── index.ts              # Express 服务器入口（含 quickstart API）
│   ├── matlab-controller.ts  # MATLAB 控制器（v5.0: diary + 相对路径修复）
│   ├── system-prompts.ts     # AI 系统提示词（v5.1: Simulink 建模经验固化）
│   ├── db.ts                 # SQLite 数据库
│   └── index.d.ts            # TypeScript 类型定义
├── matlab-bridge/
│   └── matlab_bridge.py      # Python-MATLAB 桥接（v5.0: diary + UTF-8 输出）
├── src/                      # React 前端
│   ├── App.tsx
│   ├── components/
│   │   ├── MATLABStatusBar.tsx    # 动态版本显示
│   │   └── ...
│   ├── hooks/
│   │   ├── useAgents.ts           # Agent 管理
│   │   └── ...
│   └── config.ts                  # 动态配置
├── data/                     # 运行时数据（git 忽略）
│   └── .gitkeep
├── start.bat                 # ⭐ 一键启动脚本（最可靠）
├── ensure-running.bat        # AI Agent 专用确保运行脚本
├── start-matlab-agent.ps1    # PowerShell 启动脚本
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## 性能指标

| 操作 | 耗时 | 说明 |
|------|------|------|
| 服务器启动 | ~2.5s | Node.js + Express |
| MATLAB Engine 首次启动 | ~8s | 固有开销（仅首次，Engine 模式） |
| 后续命令执行 | ~0.1s | Engine 已持久化 |
| CLI 模式执行 | ~5-15s | 每次启动 MATLAB 进程 |
| Simulink 模型构建 | ~25s | 含模型编译 |
| Simulink 仿真 | ~5-10s | 取决于模型复杂度 |

## 双连接模式

### Engine API 模式（推荐）
- **适用**: MATLAB R2019a+ 且 Python 版本兼容
- **优势**: 变量跨命令持久化，执行速度快
- **原理**: Python `matlabengine` → MATLAB Engine API for Python

### CLI 回退模式
- **适用**: Engine API 不兼容（如老版本 MATLAB 或 Python 版本不匹配）
- **原理**: `matlab -batch`（R2019a+）或 `matlab -r ... -nosplash -nodesktop -wait`（旧版本）
- **限制**: 变量不跨命令保持，每次执行独立

## 已知限制

- CLI 模式下变量不跨命令保持
- 中文路径需用 `dir()` + `fullfile()` 间接操作
- MATLAB 函数名不能以下划线开头
- Engine 首次启动 ~8s（固有开销）

## 文档

- [故障排除指南](./TROUBLESHOOTING.md) — 所有已知问题及解决方案（含 v5.1 Simulink 建模深坑）
- [二次开发指南](./DEVELOPMENT.md) — MATLAB Agent 架构与定制
- [GitHub 发布流程](../PUBLISH.md) — 从 Skill 目录同步到 GitHub

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine（Engine 模式） / matlab CLI（回退模式）
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
