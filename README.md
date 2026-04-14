# MATLAB-Agent v5.2

<p align="center">
  <strong>AI 驱动的 MATLAB/Simulink 开发助手</strong><br>
  让 AI 直接操控 MATLAB 引擎——执行脚本、读写变量、构建 Simulink 模型、运行仿真
</p>

---

## 🎯 项目简介

**MATLAB-Agent** 打通了 AI 智能体与 MATLAB 开发环境之间的隔阂。通过常驻 Python 桥接进程与 MATLAB Engine API，AI 可以：

- 🔧 在持久化工作区中执行 M 代码（变量跨命令保持）
- 🚁 从零构建 Simulink 模型：添加模块 → 连线 → 排版 → 运行仿真
- 📊 读取 `.m` / `.mat` / `.slx` 文件，管理工作区变量
- 🔄 双模引擎自动切换：Engine API（推荐）+ CLI 回退（兼容老版本）

> 不再是"AI 写代码你复制粘贴"，而是 AI 直接坐在 MATLAB 命令行前。

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| **diary 输出捕获** | `diary()` + `eng.eval()` 替代 `evalc()`，彻底解决引号双写、中文路径乱码 |
| **常驻 Python 桥接** | Node.js ↔ Python ↔ MATLAB Engine，stdin/stdout JSON 行协议通信 |
| **一键启动** | `quickstart` API 一步完成环境配置 + Engine 启动 + 项目目录设定 |
| **配置自检 & 自修复** | 启动时自动检测双目录配置冲突并迁移；`/api/matlab/config/diagnose` 诊断配置状态 |
| **变量持久化** | Engine 模式下变量跨命令保持，像真实 MATLAB 会话一样逐步操作 |
| **UTF-8 输出** | `sys.stdout.buffer.write()` + UTF-8 编码，解决 Windows GBK 乱码 |
| **Simulink 全流程** | 创建模型、添加模块/子系统、连线、自动排版、运行仿真 |
| **双模引擎** | Engine API（R2019a+，变量持久化）/ CLI 回退（老版本 MATLAB） |

## 🏗️ 架构概览

```
┌─────────────┐    HTTP/REST     ┌──────────────┐   stdin/stdout   ┌──────────────┐
│  AI Agent   │ ──────────────→  │  Node.js     │ ──────────────→  │  Python      │
│  (前端/UI)   │ ←──────────────  │  Express     │ ←──────────────  │  Bridge      │
└─────────────┘    JSON 响应      │  Server      │   JSON 行协议    │  (常驻进程)   │
                                  └──────────────┘                  └──────┬───────┘
                                                                         │ MATLAB Engine API
                                                                         ▼
                                                                  ┌──────────────┐
                                                                  │  MATLAB      │
                                                                  │  Engine      │
                                                                  └──────────────┘
```

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
│   │   └── matlab_bridge.py     # Python-MATLAB 桥接（常驻模式）
│   ├── src/                     # React 18 + TDesign + Vite 前端
│   ├── start.bat                # ⭐ 一键启动脚本（Windows）
│   ├── ensure-running.bat       # AI Agent 专用确保运行脚本
│   ├── quick-start.bat / .ps1   # 快速启动脚本
│   ├── TROUBLESHOOTING.md       # 故障排除手册
│   └── README.md                # 应用内说明文档
└── references/
    ├── troubleshooting.md       # 故障排除参考
    └── matlab-bridge-api.md     # Python Bridge API 文档
```

## 🚀 快速开始

### 前置条件

- **MATLAB** 任意版本（首次启动需配置安装路径）
- **Python 3.9+**（Engine API 模式需要）
- **Node.js 18+**

### 启动服务

```cmd
:: 双击运行或命令行执行（最推荐）
cmd /c "app\start.bat"
```

启动脚本自动完成：端口清理 → 依赖检查 → 后台启动 → 健康检查 → MATLAB 预热

### 一键快速启动（AI Agent 专用）

```cmd
:: 确保服务运行
cmd /c "app\ensure-running.bat"

:: 一步完成环境配置 + Engine 启动 + 项目设定
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\my_project'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"
```

## 📡 API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 状态 |
| POST | `/api/matlab/quickstart` | ⭐ 一键快速启动 |
| GET | `/api/matlab/config` | 获取 MATLAB 配置 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录 |
| DELETE | `/api/matlab/config` | 重置 MATLAB 配置（v5.2 新增） |
| GET | `/api/matlab/config/diagnose` | 配置自检诊断（v5.2 新增） |
| POST | `/api/matlab/project/set` | 设置项目目录 |
| GET | `/api/matlab/project/scan` | 扫描项目文件 |
| GET | `/api/matlab/file/m` | 读取 .m 文件 |
| GET | `/api/matlab/file/mat` | 读取 .mat 变量 |
| POST | `/api/matlab/run` | 持久化工作区执行代码 |
| POST | `/api/matlab/execute` | 执行 .m 脚本 |
| GET | `/api/matlab/workspace` | 获取工作区变量 |
| POST | `/api/matlab/simulink/create` | 创建 Simulink 模型 |
| POST | `/api/matlab/simulink/run` | 运行仿真 |

> 完整 API 列表见 [SKILL.md](./SKILL.md)

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
6. **模型构建后自动排版**：必须调用 `Simulink.BlockDiagram.arrangeSystem`
7. **双 data/ 目录配置不同步**（v5.2 自动修复）：`ensureDataDirSync()` 启动自检 + 自动迁移
8. **`>nul 2>&1` 在 `cmd /c` 嵌套调用报错**（v5.2 修复）：改用 `2>nul` + `-NoProfile`
9. **bat 路径含括号 `(x86)` 导致脚本中断**（v5.2 修复）：用 `^(` `^)` 转义

> 详细踩坑记录见 [SKILL.md](./SKILL.md) 和 [app/TROUBLESHOOTING.md](./app/TROUBLESHOOTING.md)

## 📜 版本历史

| 版本 | 日期 | 核心改动 |
|------|------|---------|
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
