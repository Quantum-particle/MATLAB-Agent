# MATLAB Agent

> AI 驱动的 MATLAB/Simulink 开发助手 | 版本 2.0.0

打通 AI 智能体与 MATLAB 闭园开发环境的隔阂，让 AI 能像开发 Python、C 一样在 MATLAB 中高效工作。特别面向航空航天领域的动力学建模、控制律设计和信号处理。

## 架构

```
用户 (React 前端)
  │
  ├─ SSE ─→ Express Server (TypeScript)
  │            │
  │            ├─ CodeBuddy Agent SDK ─→ AI 模型 (Claude)
  │            │
  │            └─ spawn ─→ Python Bridge (matlab_bridge.py)
  │                          │
  │                          └─ MATLAB Engine API ─→ MATLAB R2023b
  │
  └─ REST API ─→ /api/matlab/* (直接调用 MATLAB)
```

## 快速开始

### 前置条件
- MATLAB R2023b（已安装 Python 支持组件）
- Python 3.9-3.11
- Node.js 18+
- CodeBuddy CLI（已登录）

### 安装

```bash
cd matlab-agent
npm install
```

### 安装 MATLAB Engine for Python

```bash
cd "D:\Program Files(x86)\MATLAB2023b\extern\engines\python"
python -m pip install matlabengine
```

### 启动

```bash
# 开发模式（前后端热重载）
npm run dev

# 仅后端
npm run server

# 生产构建
npm run build
```

### 测试

```bash
# 端到端测试（M 脚本执行）
npm run test:matlab
# 或
python ../test_agent_api.py

# Simulink 测试
python ../test_simulink_api.py
```

## API 参考

### 状态检查
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 安装状态（快速） |
| GET | `/api/matlab/status?quick=false` | MATLAB 完整检查（含 Engine） |

### 脚本执行
| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/matlab/execute` | 执行 .m 脚本 |
| POST | `/api/matlab/command` | 执行 MATLAB 命令 |
| GET | `/api/matlab/workspace` | 获取工作区变量 |

### Simulink
| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/matlab/simulink/create` | 创建 Simulink 模型 |
| POST | `/api/matlab/simulink/run` | 运行 Simulink 仿真 |

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
│   ├── index.ts              # Express 服务器入口
│   ├── matlab-controller.ts  # MATLAB 控制器（Node.js 端）
│   ├── system-prompts.ts     # AI 系统提示词（含踩坑知识）
│   ├── db.ts                 # SQLite 数据库
│   └── types.ts              # TypeScript 类型定义
├── matlab-bridge/
│   └── matlab_bridge.py      # Python-MATLAB 桥接脚本
├── client/                   # React 前端
│   ├── App.tsx
│   ├── components/
│   └── hooks/
├── TROUBLESHOOTING.md        # 故障排除指南
├── package.json
├── tsconfig.json
└── vite.config.ts
```

## 性能指标

| 操作 | 耗时 | 说明 |
|------|------|------|
| 服务器启动 | ~2.5s | Node.js + Express |
| M 脚本执行 | ~11s | 含 Engine 启动 ~8s |
| Simulink 完整链路 | ~30s | 含 Engine + 编译 + 仿真 |

## 已知限制

- MATLAB Engine 每次启动 ~8s（固有开销）
- 当前架构每次 API 调用新建 MATLAB 进程（无持久化）
- 中文路径不支持直接 run()（自动 cd 兜底）
- MATLAB 函数名不能以下划线开头

## 文档

- [故障排除指南](./TROUBLESHOOTING.md) — 所有已知问题及解决方案
- [性能优化设计](./docs/plans/2026-04-08-perf-optimization-design.md) — 持久化 Engine 方案

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine → MATLAB Engine API for Python
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
