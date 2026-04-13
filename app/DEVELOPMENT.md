# MATLAB Agent 二次开发指南

> 版本: 5.1.0 | 最后更新: 2026-04-10

本文档面向希望在 MATLAB Agent 基础上进行二次开发的开发者，涵盖架构详解、核心模块、定制场景和调试技巧。

---

## 目录

- [项目架构](#项目架构)
- [核心模块详解](#核心模块详解)
- [定制场景](#定制场景)
- [调试技巧](#调试技巧)
- [贡献指南](#贡献指南)

---

## 项目架构

### 技术栈

**后端**
- Node.js + Express (RESTful API + SSE 流式响应)
- TypeScript 5
- @tencent-ai/agent-sdk (CodeBuddy Agent SDK)
- better-sqlite3 (SQLite 数据库)

**MATLAB 桥接**
- Python 3.9+ (`matlabengine` / CLI 回退)
- stdin/stdout JSON 行协议通信
- 常驻进程模式（变量持久化）

**前端**
- React 18 + TypeScript
- TDesign React (UI 组件库)
- Vite 5 (构建工具)

### 目录结构

```
matlab-agent/
├── server/                          # 后端服务
│   ├── index.ts                     # Express 服务器入口 + quickstart API
│   ├── matlab-controller.ts         # MATLAB 控制器（v5.0: diary + 相对路径修复）
│   ├── system-prompts.ts            # AI 系统提示词（v5.1: Simulink 建模经验固化）
│   ├── db.ts                        # SQLite 数据库操作
│   └── index.d.ts                   # TypeScript 类型定义
├── matlab-bridge/
│   └── matlab_bridge.py             # Python-MATLAB 桥接（v5.0: diary + UTF-8 输出）
├── src/                             # React 前端
│   ├── components/                  # React 组件
│   │   ├── MATLABStatusBar.tsx      # MATLAB 状态栏（动态版本显示）
│   │   ├── ChatMessages.tsx         # 消息列表
│   │   ├── ChatInput.tsx            # 输入框
│   │   └── ...
│   ├── hooks/                       # 自定义 Hooks
│   │   ├── useChat.ts              # 聊天逻辑（SSE 流式处理）
│   │   ├── useAgents.ts            # Agent 管理
│   │   └── ...
│   ├── types.ts                     # TypeScript 类型定义
│   ├── config.ts                    # 动态配置
│   ├── App.tsx                      # 应用入口
│   └── main.tsx                     # React 入口
├── data/                            # 运行时数据（git 忽略）
│   └── .gitkeep
├── start.bat                        # ⭐ 一键启动脚本（最可靠）
├── ensure-running.bat               # AI Agent 专用确保运行脚本
├── start-matlab-agent.ps1           # PowerShell 启动脚本
├── package.json
├── tsconfig.json
├── vite.config.ts
└── tailwind.config.js
```

### 数据流

```
用户输入 → React 前端 → POST /api/chat → Express Server
                                              │
                                              ├─→ Agent SDK → AI 模型 (Claude)
                                              │       │
                                              │       └─→ 工具调用 → MATLAB API
                                              │
                                              └─→ MATLAB API → spawn Python Bridge
                                                                      │
                                                                      ├─→ Engine 模式: matlabengine API
                                                                      └─→ CLI 模式: matlab -batch
                                              
SSE 流式响应 ← Express Server ← Agent SDK / MATLAB API ← Python Bridge
```

---

## 核心模块详解

### 1. MATLAB 控制器 (`server/matlab-controller.ts`)

负责管理 MATLAB 桥接进程的生命周期和所有 MATLAB 相关 API。

**关键设计**:
- **手动配置模式**: `getMATLABRoot()` 按优先级获取 MATLAB 路径：环境变量 > 配置文件 > 未配置
- **常驻桥接进程**: 启动 `matlab_bridge.py --server`，通过 stdin/stdout JSON 行协议通信
- **双连接模式**: 自动检测 Engine 兼容性，不兼容时回退到 CLI
- **预热机制**: Engine 初始化需要 30-90 秒，`/api/health` 的 `warmup` 字段反映状态

**配置 API**:
```typescript
// 获取 MATLAB 配置
GET /api/matlab/config → { matlabRoot, connectionMode, matlabVersion }

// 设置 MATLAB 根目录（持久化到 data/matlab-config.json）
POST /api/matlab/config { matlabRoot } → { success, matlabRoot }
```

### 2. Python 桥接 (`matlab-bridge/matlab_bridge.py`)

核心桥接脚本，支持两种连接模式。

**Engine API 模式**:
```python
import matlab.engine
eng = matlab.engine.start_matlab()
# 变量跨命令持久化
output = eng.eval("evalc('your_command')", nargout=1)
```

**CLI 回退模式**:
```python
# R2019a+
subprocess.run(["matlab", "-batch", "your_command"])
# 旧版本
subprocess.run(["matlab", "-r", "your_command; exit", "-nosplash", "-nodesktop", "-wait"])
```

**server_mode() 通信协议**:
- 输入: stdin JSON 行 `{"command": "run", "code": "..."}`
- 输出: stdout JSON 行 `{"status": "ok", "output": "..."}`
- 编码: UTF-8（通过 `sys.stdin.buffer` 二进制读取避免 GBK 编码问题）

### 3. 系统提示词 (`server/system-prompts.ts`)

**动态环境信息注入** (`getMATLABSystemPrompt()`):
- 运行时获取 MATLAB 版本、连接模式、项目目录
- 注入到 AI 系统提示词中，让 AI 了解当前环境
- 包含踩坑知识库（引号转义、中文路径、函数命名等）

### 4. 前端配置 (`src/config.ts`)

**动态获取 MATLAB 配置** (`fetchMATLABConfig()`):
- 不硬编码 MATLAB 版本和路径
- 从 `/api/matlab/config` 获取运行时信息
- `MATLABStatusBar` 组件动态显示版本号

---

## 定制场景

### 场景 1: 添加新的 MATLAB API 端点

1. 在 `matlab_bridge.py` 中添加命令处理：
```python
def your_new_command(args):
    # 实现 MATLAB 操作逻辑
    return {"status": "ok", "result": "..."}
```

2. 在 `matlab-controller.ts` 中添加路由：
```typescript
app.post("/api/matlab/your-endpoint", async (req, res) => {
  const result = await sendToBridge({ command: "your_command", ...req.body });
  res.json(result);
});
```

3. 在 `system-prompts.ts` 中更新 AI 知识库，让 AI 知道新端点的存在。

### 场景 2: 自定义 Agent 预设

编辑 `src/hooks/useAgents.ts` 的默认 Agent 列表：
```typescript
const customAgent: CustomAgent = {
  id: 'control-design',
  name: '控制律设计',
  description: '专注于 PID/LQR/H∞ 控制器设计',
  systemPrompt: '你是一个专业的控制律设计助手...',
  icon: 'CodeIcon',
  color: '#00a870',
  permissionMode: 'acceptEdits',
  createdAt: new Date(),
  updatedAt: new Date(),
};
```

### 场景 3: 修改 MATLAB 路径配置策略

编辑 `server/matlab-controller.ts` 的 `getMATLABRoot()` 函数，调整优先级或添加新的检测方式。

当前优先级：
1. 环境变量 `MATLAB_ROOT`
2. 配置文件 `data/matlab-config.json`
3. 未配置（返回错误提示）

### 场景 4: 添加新的 Simulink 操作

1. 在 `matlab_bridge.py` 的 `simulink_create()` / `simulink_run()` 中扩展
2. 注意 Simulink Position 格式: `[left, bottom, right, top]`（不是 width/height）
3. 创建前必须 `close_system + bdclose` 避免遮蔽警告
4. v5.0 用 diary 替代 evalc，输出通过 `diary(filename)` 捕获
5. **v5.1 新增**: 模型构建完成后必须调用 `Simulink.BlockDiagram.arrangeSystem(modelName)` 自动排版
6. **v5.1 新增**: 新建 SubSystem 时注意默认连线冲突，先 `delete_line` 再 `add_line`
7. **v5.1 新增**: 复杂模型用 From/Goto 传递信号，不是直接连线

### 场景 5: 修改前端主题

编辑 `src/index.css`:
```css
:root {
  --primary-color: #0052d9;     /* 主色调 */
  --success-color: #00a870;     /* 成功色 */
  --warning-color: #ed7b2f;     /* 警告色 */
  --error-color: #e34d59;       /* 错误色 */
}
```

### 场景 6: 修改权限模式

支持四种权限模式（`src/types.ts`）：
- `'default'` — 每次工具调用都需要确认
- `'acceptEdits'` — 自动接受编辑类操作
- `'plan'` — 计划模式，只读
- `'bypassPermissions'` — 跳过所有权限检查

---

## 调试技巧

### 1. 查看 Agent SDK 日志

在 `server/index.ts` 中添加详细日志:
```typescript
for await (const msg of stream) {
  console.log("[Stream] Message:", JSON.stringify(msg, null, 2));
}
```

### 2. 查看 Python Bridge 通信

在 `matlab-controller.ts` 的 `sendToBridge()` 中添加日志:
```typescript
console.log("[Bridge] Sending:", JSON.stringify(command));
console.log("[Bridge] Received:", result);
```

### 3. 健康检查

```bash
# Windows 下用 PowerShell 替代 curl（避免输入重定向问题）
powershell -Command "Invoke-RestMethod -Uri 'http://localhost:3000/api/health' -TimeoutSec 5"
# 返回: { matlab: { warmup: "ready"|"warming_*"|"failed", ready: true/false } }
```

### 4. 查看 MATLAB 配置

```bash
powershell -Command "Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -TimeoutSec 5"
# 返回: { matlabRoot: "...", connectionMode: "engine"|"cli", matlabVersion: "R2023b" }
```

### 5. 前端调试

在浏览器控制台中查看状态，或在 `useChat.ts` 中添加 `console.log` 跟踪 SSE 事件。

---

## 贡献指南

1. Fork 仓库: https://github.com/Quantum-particle/MATLAB-Agent
2. 创建功能分支
3. 确保所有修改兼容双连接模式（Engine + CLI）
4. 更新相关文档（README.md, TROUBLESHOOTING.md）
5. 提交 Pull Request

## License

MIT
