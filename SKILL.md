# MATLAB Agent Skill

> AI 驱动的 MATLAB/Simulink 开发助手，打通 AI 智能体与 MATLAB 闭园开发环境的隔阂。

## 触发条件

当用户提到以下关键词时自动加载：
- MATLAB、M 脚本、Simulink、控制律设计、动力学建模
- 信号处理、频域分析、Bode图、阶跃响应
- .m 文件、.mat 数据、.slx 模型
- MATLAB 工作区、MATLAB Engine、PID 调参

## 能力概述

### 核心架构 (v4.1)
- **手动配置 MATLAB 路径**: 首次启动时需用户提供 MATLAB 安装路径（交互式引导或 API 配置）
- **双连接模式**: Engine API 模式（变量持久化） + CLI 回退模式（兼容老版本 MATLAB）
- **常驻 Python 桥接进程**: Node.js 启动 `matlab_bridge.py --server`，通过 stdin/stdout JSON 行协议通信
- **持久化 MATLAB Engine**: Engine 在进程生命周期内保持，变量跨命令保持
- **实时可视化**: figure/plot 在 MATLAB 桌面实时显示
- **项目感知**: 扫描项目目录，读取 .m/.mat/.slx 文件

### 支持的操作
1. **项目操作**: 设置项目目录、扫描项目文件
2. **文件读取**: 读取 .m 文件内容、.mat 变量结构、Simulink 模型信息
3. **代码执行**: 在持久化工作区执行 MATLAB 代码、执行 .m 脚本
4. **工作区管理**: 获取/保存/加载/清空工作区变量
5. **Simulink**: 创建/打开/运行 Simulink 模型
6. **图形管理**: 列出/关闭图形窗口
7. **配置管理**: 获取/设置 MATLAB 路径，配置持久化

## 使用方式

### 1. 启动服务

> ⚠️ **绝对不能**用 `npx tsx server/index.ts` 或 `npm run dev` 阻塞式启动！
> MATLAB Engine 预热需要 30-90 秒，阻塞式启动会导致命令超时卡死。

**正确方式：后台启动 + 轮询健康检查**

#### 方式 A：PowerShell（Windows 推荐）

```powershell
# 1. 杀掉可能残留的旧进程（端口 3000）
$old = netstat -ano | Select-String ":3000" | Select-String "LISTENING"
if ($old) { $old -match '\d+$' | ForEach-Object { Stop-Process -Id $Matches[0] -Force } }

# 2. 后台启动服务器
cd "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app"
cmd /c "start /B npx tsx server/index.ts > $env:TEMP\matlab-agent-out.log 2>&1"

# 3. 轮询健康检查（预热超时不是致命错误，服务器仍可用）
$maxWait = 120; $elapsed = 0
while ($elapsed -lt $maxWait) {
  Start-Sleep -Seconds 5; $elapsed += 5
  try {
    $r = Invoke-WebRequest -Uri "http://localhost:3000/api/health" -UseBasicParsing -TimeoutSec 5
    $j = $r.Content | ConvertFrom-Json
    if ($j.matlab.ready -eq $true) { Write-Host "MATLAB Agent ready! ($elapsed s)"; break }
    Write-Host "Waiting... warmup=$($j.matlab.warmup) ($elapsed s)"
  } catch { Write-Host "Server not up yet... ($elapsed s)" }
}
# 预热超时不影响功能，跳过即可
```

#### 方式 B：使用启动脚本（一键启动）

```powershell
# 使用项目自带脚本（推荐）
& "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app\start-matlab-agent.ps1"
```

服务启动后访问 http://localhost:3000

### 2. 前置条件

- **MATLAB 任意版本** 安装在系统上（首次启动时需手动输入安装路径）
- **Python 3.9+**（Engine API 模式需要，CLI 回退模式不要求）
  - 如果 Python 版本与 MATLAB Engine API 兼容，自动使用 Engine 模式
  - 如果不兼容（如 MATLAB R2016a + Python 3.11），自动回退到 CLI 模式
- **Node.js 18+**
- **CodeBuddy CLI**（已登录）

### 配置 MATLAB 路径

首次启动时，一键脚本会自动交互式引导用户输入 MATLAB 安装路径。
也可以通过以下方式手动配置：

```bash
# 方法1: 环境变量
set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b

# 方法2: API 配置（路径会持久化到配置文件）
curl -X POST http://localhost:3000/api/matlab/config -H "Content-Type: application/json" -d "{\"matlabRoot\":\"D:\\\\Program Files\\\\MATLAB\\\\R2023b\"}"
```

### 3. API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 状态（快速） |
| GET | `/api/matlab/status?quick=false` | MATLAB 完整检查（含 Engine） |
| GET | `/api/matlab/config` | 获取 MATLAB 配置 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录 |
| POST | `/api/matlab/project/set` | 设置项目目录 |
| GET | `/api/matlab/project/scan?dir=...` | 扫描项目文件 |
| GET | `/api/matlab/file/m?path=...` | 读取 .m 文件 |
| GET | `/api/matlab/file/mat?path=...` | 读取 .mat 变量 |
| GET | `/api/matlab/file/simulink?path=...` | 读取 Simulink 模型 |
| POST | `/api/matlab/run` | 持久化工作区执行代码 |
| POST | `/api/matlab/execute` | 执行 .m 脚本 |
| GET | `/api/matlab/workspace` | 获取工作区变量 |
| POST | `/api/matlab/workspace/save` | 保存工作区 |
| POST | `/api/matlab/workspace/load` | 加载工作区 |
| POST | `/api/matlab/workspace/clear` | 清空工作区 |
| POST | `/api/matlab/simulink/create` | 创建 Simulink 模型 |
| POST | `/api/matlab/simulink/run` | 运行仿真 |
| POST | `/api/matlab/simulink/open` | 打开模型 |
| POST | `/api/matlab/simulink/workspace/set` | 设置模型工作区变量 |
| GET | `/api/matlab/simulink/workspace?modelName=...` | 获取模型工作区变量 |
| POST | `/api/matlab/simulink/workspace/clear` | 清空模型工作区 |
| GET | `/api/matlab/figures` | 列出图形 |
| POST | `/api/matlab/figures/close` | 关闭所有图形 |

### 4. 预设 Agent

1. **MATLAB 开发** (`matlab-default`): M 语言开发，信号处理/控制律/数据分析
2. **Simulink 建模** (`simulink-default`): Simulink 模型构建和仿真
3. **通用助手** (`default`): 通用 AI 助手

## ⚠️ 关键踩坑经验

### 1. MATLAB Engine 输出捕获
- **问题**: eval() nargout=0 时，disp/fprintf 输出泄漏到 Python stdout
- **修复**: 使用 evalc + nargout=1，将所有输出捕获到字符串返回值
- **引号规则**: Python `"evalc('cd(''path'');')"` → MATLAB 看到 `evalc('cd('path');')`

### 2. 中文路径不支持
- **问题**: MATLAB run() 不支持中文路径
- **修复**: 先 cd() 到脚本目录，再 run('filename')（不含路径前缀）

### 3. GBK 编码问题
- **修复**: 子进程环境变量 PYTHONIOENCODING=utf-8，Python 端 sys.stdout.reconfigure(encoding='utf-8')

### 4. Windows stdin 中文编码 (v3.0.1)
- **问题**: Windows 下 Python stdin 默认 GBK 编码，`for line in sys.stdin` 无法正确读取 UTF-8 中文路径
- **根因**: `sys.stdin.reconfigure(encoding='utf-8')` 在某些情况下不生效（buffer 已创建）
- **修复**: server_mode() 中改用 `for raw_line in sys.stdin.buffer` + 手动 `raw_line.decode('utf-8')`
- **文件**: `matlab_bridge.py` server_mode() 函数
- **同时**: 添加 `sys.stdin.reconfigure(encoding='utf-8')` 作为第一道防线

### 5. set_project_dir 安全性 (v3.0.1)
- **问题**: 路径不存在时 `os.makedirs()` 在中文路径编码异常时可能报 WinError 123
- **修复**: 改为检查路径存在性，不存在时直接返回错误信息，不尝试创建
- **文件**: `matlab_bridge.py` set_project_dir() 函数

### 6. node_modules 复用 (v3.0.1)
- **问题**: Skill 目录的 app/ 没有 node_modules，每次需要 npm install（~30s）
- **修复**: 用 `mklink /J` 创建 junction 链接，共享项目目录的 node_modules
- **命令**: `cmd /c mklink /J "skill_dir/app/node_modules" "project_dir/node_modules"`
- **注意**: Junction 不需要管理员权限（区别于 SymbolicLink）

### 7. Simulink 模型遮蔽警告
- **修复**: 创建前 close_system + bdclose，warning('off', 'Simulink:Engine:MdlFileShadowing')，正则清理 HTML 标签

### 8. timeseries API 兼容性
- **修复**: 使用 isprop() 检查 Values 属性是否存在

### 9. 函数命名限制
- 函数名不能以下划线开头，必须以字母开头

### 10. Simulink Position 格式
- `[left, bottom, right, top]` 不是 `[x, y, width, height]`

### 11. shareEngine 不可靠
- 不使用 shareEngine，每次启动独立 Engine 实例
- 常驻模式下 Engine 在进程生命周期内保持，不需要 shareEngine

### 12. Python Engine 版本不兼容 (v4.0 新增)
- **问题**: MATLAB R2016a 的 Python Engine 只支持 Python 2.7/3.3-3.5，但系统是 Python 3.11
- **根因**: `matlabengine` 严格版本绑定，R2023b engine 无法连接 R2016a
- **修复**: v4.0 新增 CLI 回退模式，自动检测 Engine 兼容性，不兼容时切换到 `matlab -batch`（R2019a+）或 `matlab -r`（旧版本）
- **限制**: CLI 模式下变量不跨命令保持，每次执行独立

### 13. MATLAB 路径配置 (v4.1)
- **方式**: 首次启动时交互式引导用户手动输入 MATLAB 安装路径，或通过 API/环境变量配置
- **持久化**: 通过 API 设置的路径保存到 `data/matlab-config.json`，下次启动自动加载
- **优先级**: 环境变量 MATLAB_ROOT > 配置文件 > 未配置（提示用户输入）
- **Node.js 端**: `matlab-controller.ts` 通过环境变量传递 MATLAB_ROOT 给 Python Bridge
- **Python 端**: `matlab_bridge.py` 也独立读取 MATLAB_ROOT 环境变量

### 14. 绝对不能阻塞式启动服务器！(v4.0 血泪教训)
- **问题**: 用 `npx tsx server/index.ts` 或 `npm run dev` 直接运行，MATLAB Engine 预热需要 30-90 秒，命令会超时卡死
- **根因**: Agent 循环的命令执行有超时限制，而 MATLAB Engine 初始化（Python 启动 + import matlab.engine + start_matlab + warmup）是 CPU+IO 密集型操作
- **正确做法**: 后台启动服务器 → 轮询 `/api/health` → 检查 `warmup` 字段是否为 `"ready"`
- **Windows 后台启动**: `cmd /c "start /B npx tsx server/index.ts > %TEMP%\matlab-agent-out.log 2>&1"`
- **健康检查**: GET `/api/health`，关键字段 `warmup`：`"warming_bridge"` → `"warming_engine"` → `"ready"`，`"failed"` 表示未配置或启动失败
- **轮询策略**: 每 5 秒一次，最长等 120 秒（通常 30-90 秒完成）
- **端口冲突**: 启动前先 `netstat -ano | findstr ":3000" | findstr "LISTENING"` 检查，有则 kill
- **一键脚本**: `start-matlab-agent.ps1` 封装了完整流程

### 15. 预热超时可安全跳过 (v4.1 经验)
- **现象**: MATLAB Engine 预热偶尔卡在 `warming_engine` 超过 90 秒仍未 `ready`
- **根因**: Engine 启动受系统负载、MATLAB 版本、Python 兼容性等影响，预热时间不可控
- **策略**: 预热超时后**不退出脚本**（exit 0），服务器仍在运行，功能请求会触发延迟初始化
- **启动脚本**: `start-matlab-agent.ps1` 预热超时后输出黄色警告，但 `exit 0`
- **API 层**: Node.js `index.ts` 预热超时标记 `warmupStatus = 'failed'`，但服务器继续运行
- **Python 层**: `matlab_bridge.py` 的 `get_engine()` 带线程超时，超时自动切换到 CLI 回退模式
- **结论**: 预热卡住不影响智能体正常功能，最差情况自动降级到 CLI 模式

### 16. evalc 内层引号必须双写 (v4.1 血泪教训)
- **问题**: `evalc('get_param('model', 'ModelWorkspace')')` 导致 MATLAB 语法错误
- **根因**: Python `evalc('...')` 中内层 MATLAB 单引号会被 Python 识别为字符串结束，导致引号嵌套冲突
- **修复**: 内层所有 MATLAB 单引号必须双写 `''`
  - ❌ 错误：`evalc('get_param('model', 'ModelWorkspace')')`
  - ✅ 正确：`evalc('get_param(''model'', ''ModelWorkspace'')')`
  - Python 看到的是 `evalc('get_param(''model'', ''ModelWorkspace'')')`
  - MATLAB 看到的是 `get_param('model', 'ModelWorkspace')`
- **影响范围**: 所有使用 evalc 包裹的 MATLAB 命令，特别是 Simulink 模型工作区 API
- **防御性处理**: model_name 中可能包含单引号的情况也需要双写：`mn = model_name.replace("'", "''")`

### 17. POST /api/matlab/config 不能阻塞式重启桥接 (v4.1 修复)
- **问题**: 二次调用 `POST /api/matlab/config` 同一路径返回 500
- **根因**: `restartBridge()` 被直接 `await`，Engine 已在运行时重启耗时 30+ 秒，导致 HTTP 响应超时
- **修复**: `restartBridge()` 改为后台异步 `.catch()`，不阻塞 HTTP 响应
  - ❌ 旧代码：`await matlab.restartBridge();`
  - ✅ 新代码：`matlab.restartBridge().catch(err => console.warn(...))`
- **注意**: `restartBridge()` 为后台异步操作，二次调用同一路径不会重启（因为路径未变）

### 18. PowerShell 向 API 发送中文路径需 UTF-8 编码 (v4.1 注意点)
- **问题**: PowerShell `Invoke-RestMethod` 默认编码可能导致中文路径乱码
- **修复**: 使用 `[System.Text.Encoding]::UTF8.GetBytes($json)` 发送 body
- **路径含括号**: `D:\Program Files(x86)\...` 中 `(x86)` 可能被 PowerShell 解释为表达式，需用引号包裹

## 性能指标

| 操作 | 耗时 | 说明 |
|------|------|------|
| 服务器启动 | ~2.5s | Node.js + Express |
| MATLAB Engine 首次启动 | ~8s | 固有开销（仅首次，Engine 模式） |
| 后续命令执行 | ~0.1s | Engine 已持久化 |
| CLI 模式执行 | ~5-15s | 每次启动 MATLAB 进程 |
| Simulink 模型构建 | ~25s | 含模型编译 |
| Simulink 仿真 | ~5-10s | 取决于模型复杂度 |

## 文件结构

```
matlab-agent/
├── SKILL.md                    # 本文件 — Skill 描述
├── app/                        # 完整应用源码
│   ├── server/
│   │   ├── index.ts            # Express 服务器入口（含 v4.0 config API）
│   │   ├── matlab-controller.ts # MATLAB 控制器（手动配置 + 常驻桥接 + 命令队列）
│   │   ├── system-prompts.ts   # AI 系统提示词（动态环境信息 + Simulink 工作区指导）
│   │   └── db.ts               # SQLite 数据库
│   ├── matlab-bridge/
│   │   └── matlab_bridge.py    # Python-MATLAB 桥接（Engine + CLI 双模式）
│   ├── src/                    # React 前端
│   │   ├── App.tsx
│   │   ├── components/
│   │   │   └── MATLABStatusBar.tsx  # 动态版本显示
│   │   ├── hooks/
│   │   │   └── useAgents.ts    # Agent 管理（无硬编码路径）
│   │   └── config.ts           # 动态配置（运行时获取 MATLAB 信息）
│   ├── package.json
│   ├── start-matlab-agent.ps1  # 一键启动脚本（后台+轮询+首次引导配置）
│   ├── TROUBLESHOOTING.md      # 故障排除指南
│   └── README.md
└── references/
    ├── troubleshooting.md      # 完整故障排除参考
    └── matlab-bridge-api.md    # Python 桥接 API 详解
```

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine（Engine 模式） / matlab CLI（回退模式）
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
