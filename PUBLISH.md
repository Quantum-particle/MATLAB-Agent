# MATLAB Agent GitHub 发布流程

> 本文档定义了从 Skill 目录全量同步到 GitHub 公开仓库的标准流程。
> **核心原则：GitHub 仓库文件与本地 Skill 目录完全相同，但推送前脱敏！**

---

## 目录结构

| 项目 | 路径 | 说明 |
|------|------|------|
| **Skill 目录**（唯一源码） | `C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent\` | MATLAB Agent 智能体的原始目录 |
| **GitHub 仓库** | https://github.com/Quantum-particle/MATLAB-Agent | 公开源码仓库（文件全量相同，敏感字段脱敏） |
| **本地 git** | Skill 目录内 `.git/` | 直接在 Skill 目录初始化 git，关联远程仓库 |

---

## 🔴 核心原则

1. **全量同步**：本地有什么文件，GitHub 就有什么文件（除 .gitignore 排除的运行时文件外），`git add -A` 全量提交
2. **推送前脱敏**：包含敏感信息的文件（Token、邮箱、本地路径等），推送前临时替换为占位符，推送后立即恢复本地版
3. **不搞选择性提交**：所有源码、文档、配置、脚本全部推送，不遗漏任何文件

---

## 脱敏规则

### 🔴 推送前必须脱敏的文件

| 文件 | 脱敏字段 | 本地保留 | GitHub 替换为 |
|------|----------|----------|---------------|
| `GITHUB.md` | Personal Access Token | （本地保留） | `（已脱敏）` |
| `GITHUB.md` | 邮箱 | （本地保留） | `（已脱敏）` |
| `GITHUB.md` | 本地用户路径 | `C:\Users\<你的用户名>\...` | `C:\Users\<你的用户名>\...` |

### 🟢 无需脱敏的文件（直接提交）

所有其他文件均无需脱敏，直接提交：
- `app/server/*.ts` — 后端源码
- `app/matlab-bridge/*.py` — Python 桥接源码
- `app/src/**/*.tsx` / `app/src/**/*.ts` — 前端源码
- `references/` — 参考文档
- `app/package.json` / `app/tsconfig.json` 等 — 项目配置
- `app/start.bat` / `app/ensure-running.bat` — 启动脚本
- `SKILL.md` / `app/README.md` / `app/TROUBLESHOOTING.md` — 文档
- `PUBLISH.md` — 本文件

### 🔴 不进仓库的文件（.gitignore 控制）

| 文件/目录 | 原因 |
|---|---|
| `app/data/chat.db*` | 用户聊天记录数据库 |
| `app/data/matlab-config.json` | 本地 MATLAB 安装路径 |
| `app/data/*.log` | 运行日志 |
| `node_modules/` | 依赖 |
| `app/dist/` | 构建产物 |
| `.env` / `app/.env` | 本地环境变量 |
| `app/matlab-bridge/*.slx` | Simulink 模型文件（二进制，体积大） |
| `app/matlab-bridge/*.mat` | MATLAB 工作区文件 |

---

## 发布步骤

### 全量推送流程（AI 助手用）

当用户要求"同步到 GitHub"或"推送更新"时，按以下流程执行：

```powershell
# ===== 在 Skill 目录直接操作 =====
cd "C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent"

# 0. 确认远程仓库关联
git remote -v
# 应显示: origin https://github.com/Quantum-particle/MATLAB-Agent.git

# 1. 拉取远程最新（如果网络不通可跳过）
git -c http.proxy="" -c https.proxy="" fetch origin

# 2. 全量暂存所有变更（包括未修改的文件）
git add -A

# 3. 检查暂存区
git status
git diff --cached --stat

# 4. 🔴 脱敏处理（仅对 GITHUB.md）
#    将 Token 替换为 "（已脱敏）"
#    将邮箱替换为 "（已脱敏）"
#    将本地用户路径替换为通用占位符
#    ⚠️ 这是临时脱敏！推送后必须恢复！

# 5. 提交（全量）
git commit -m "feat(vX.Y): 提交说明"

# 6. 推送（绕过代理）
git -c http.proxy="" -c https.proxy="" push origin main

# 7. 🔴 恢复 GITHUB.md 本地版（如果之前脱敏了）
#    git checkout -- GITHUB.md（恢复到本地完整版）
#    或手动恢复完整版内容
```

---

## .gitignore（Skill 目录根级）

```gitignore
# Dependencies
node_modules/

# Build output
dist/
app/dist/

# Runtime data (local only)
app/data/*.db
app/data/*.db-shm
app/data/*.db-wal
app/data/*.json
app/data/logs/

# Keep data directory structure
!app/data/.gitkeep

# Environment variables
.env
app/.env

# OS files
Thumbs.db
.DS_Store

# IDE
.vscode/
.idea/

# Logs
*.log

# Python cache
__pycache__/
*.pyc

# MATLAB runtime files (large binary)
app/matlab-bridge/*.slx
app/matlab-bridge/*.mat
```

---

## 版本历史

### v5.1.0 — 2026-04-10 启动防弹 + Simulink 建模深坑固化

- 新增 `start.bat` / `ensure-running.bat` 防弹级一键启动（端口自动清理 + 等待释放）
- 6 大 Simulink 建模深坑写入底层（默认连线冲突、From/Goto 信号、自动排版等）
- 端口清理流程写入所有关键文件
- 模型构建后自动排版 `arrangeSystem` 规则写入所有文档
- **PUBLISH.md 原则更新**：全量同步 + 推送前脱敏

### v5.0.0 — 2026-04-10 diary 输出捕获 + 一键启动

- diary() 替代 evalc()，彻底解决引号双写和中文路径乱码
- quickstart API 一键完成 MATLAB_ROOT + Engine 启动 + 项目目录
- UTF-8 输出修复
- 相对路径基于 _cachedProjectDir 解析

### v4.1.0 — 2026-04-09

- 移除 CherryStudio 旧目录引用
- 改为从 Skill 目录直接 git 操作
- 更新 .gitignore 路径（app/data/ 子目录结构）
