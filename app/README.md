# MATLAB Agent

> AI 驱动的 MATLAB/Simulink 开发助手 | 版本 4.1.0

打通 AI 智能体与 MATLAB 闭园开发环境的隔阂，让 AI 能像开发 Python、C 一样在 MATLAB 中高效工作。特别面向航空航天领域的动力学建模、控制律设计和信号处理。

## 架构

```
用户 (React 前端)
  │
  ├─ SSE ─→ Express Server (TypeScript)
  │            │
  │            ├─ CodeBuddy Agent SDK ─→ AI 模型 (Claude)
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
- **Node.js 18+**
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

**正确方式：后台启动 + 轮询健康检查**

#### 方式 A：使用启动脚本（推荐）

```powershell
& "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app\start-matlab-agent.ps1"
```

#### 方式 B：手动后台启动

```powershell
# 1. 检查端口冲突
netstat -ano | findstr ":3000" | findstr "LISTENING"

# 2. 后台启动
cmd /c "start /B npx tsx server/index.ts"

# 3. 轮询健康检查（最多等 120 秒）
while ($true) {
  try {
    $r = Invoke-WebRequest -Uri "http://localhost:3000/api/health" -UseBasicParsing -TimeoutSec 5
    $j = $r.Content | ConvertFrom-Json
    if ($j.matlab.ready -eq $true) { Write-Host "Ready!"; break }
    Write-Host "Waiting... warmup=$($j.matlab.warmup)"
  } catch { Write-Host "Server not up yet..." }
  Start-Sleep -Seconds 5
}
```

### 配置 MATLAB 路径

首次启动时，一键脚本会自动交互式引导用户输入 MATLAB 安装路径。也可手动配置：

```bash
# 方法1: 环境变量
set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b

# 方法2: API 配置（路径会持久化到配置文件）
curl -X POST http://localhost:3000/api/matlab/config -H "Content-Type: application/json" -d "{\"matlabRoot\":\"D:\\\\Program Files\\\\MATLAB\\\\R2023b\"}"
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
| POST | `/api/matlab/run` | 持久化工作区执行代码（Engine 模式） |
| POST | `/api/matlab/execute` | 执行 .m 脚本 |

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
2. **Simulink 建模** (`simulink-default`): Simulink 模型构建和仿真
3. **通用助手** (`default`): 通用 AI 助手

## 项目结构

```
matlab-agent/
├── server/
│   ├── index.ts              # Express 服务器入口（含 config API）
│   ├── matlab-controller.ts  # MATLAB 控制器（手动配置 + 常驻桥接）
│   ├── system-prompts.ts     # AI 系统提示词（动态环境信息注入）
│   ├── db.ts                 # SQLite 数据库
│   └── index.d.ts            # TypeScript 类型定义
├── matlab-bridge/
│   └── matlab_bridge.py      # Python-MATLAB 桥接（Engine + CLI 双模式）
├── src/                      # React 前端
│   ├── App.tsx
│   ├── components/
│   │   ├── MATLABStatusBar.tsx    # 动态版本显示
│   │   ├── ChatInput.tsx
│   │   ├── ChatMessages.tsx
│   │   └── ...
│   ├── hooks/
│   │   ├── useAgents.ts           # Agent 管理（无硬编码路径）
│   │   ├── useChat.ts
│   │   └── ...
│   ├── config.ts                  # 动态配置（运行时获取 MATLAB 信息）
│   └── types.ts
├── data/                     # 运行时数据（git 忽略）
│   └── .gitkeep
├── start-matlab-agent.ps1    # 一键启动脚本（后台+轮询+首次引导配置）
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
- 中文路径不支持 MATLAB `run()`（自动 cd 兜底）
- MATLAB 函数名不能以下划线开头
- Engine 首次启动 ~8s（固有开销）

## 文档

- [故障排除指南](./TROUBLESHOOTING.md) — 所有已知问题及解决方案
- [二次开发指南](./DEVELOPMENT.md) — MATLAB Agent 架构与定制
- [GitHub 发布流程](../PUBLISH.md) — 从 Skill 目录同步到 GitHub

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine（Engine 模式） / matlab CLI（回退模式）
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
