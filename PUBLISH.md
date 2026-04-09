# MATLAB Agent GitHub 发布流程

> 本文档定义了从 Skill 目录直接同步代码到 GitHub 公开仓库的标准流程。
> 核心原则：**本地保留一切，公开仓库剥离隐私。**

---

## 目录结构

| 项目 | 路径 | 说明 |
|------|------|------|
| **Skill 目录**（唯一源码） | `C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent\` | MATLAB Agent 智能体的原始目录 |
| **GitHub 仓库** | https://github.com/Quantum-particle/MATLAB-Agent | 公开源码仓库 |
| **本地 git** | Skill 目录内 `.git/` | 直接在 Skill 目录初始化 git，关联远程仓库 |

> ⚠️ 旧的 CherryStudio 目录已废弃！所有操作直接在 Skill 目录进行。

---

## 发布前隐私剥离清单

以下内容在本地 Skill 目录中**必须保留**，但推送到 GitHub 前**必须剥离/替换**：

### 🔴 必须排除（不进仓库，由 .gitignore 控制）

| 文件/目录 | 原因 |
|---|---|
| `app/data/chat.db` / `chat.db-shm` / `chat.db-wal` | 用户聊天记录数据库 |
| `app/data/matlab-config.json` | 本地 MATLAB 安装路径（含用户名路径） |
| `app/data/*.log` | 运行日志（可能含本地路径） |
| `node_modules/` | 依赖（用户自行 npm install） |
| `app/dist/` | 构建产物（用户自行 build） |
| `.env` / `app/.env` | 本地环境变量 |

### 🟡 必须替换（脱敏处理）

| 文件 | 本地保留 | GitHub 替换为 |
|---|---|---|
| `GITHUB.md` | 完整个人信息（用户名/邮箱/Token/本地路径） | 只保留仓库名/地址，移除 Token、邮箱、本地路径 |
| 任何含 `C:\Users\<你的用户名>\` 的文件 | 本地保留原样 | 替换为通用路径如 `C:\Users\<你的用户名>\` |

### 🟢 直接提交（无需处理）

| 内容 | 说明 |
|---|---|
| `app/server/*.ts` | 后端源码 |
| `app/matlab-bridge/*.py` | Python 桥接源码 |
| `app/src/**/*.tsx` / `app/src/**/*.ts` | 前端源码 |
| `references/` | 参考文档 |
| `app/package.json` / `app/tsconfig.json` 等 | 项目配置 |
| `app/start-matlab-agent.ps1` | 启动脚本 |
| `SKILL.md` / `app/README.md` / `app/TROUBLESHOOTING.md` | 文档 |
| `PUBLISH.md` | 本文件 |

---

## 发布步骤

### 一键发布脚本（AI 助手用）

当用户要求"同步到 GitHub"时，按以下流程执行：

```powershell
# ===== 在 Skill 目录直接操作 =====
cd "C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent"

# 1. 确认远程仓库关联
git remote -v
# 应显示: origin https://github.com/Quantum-particle/MATLAB-Agent.git

# 2. 拉取远程最新（如果网络不通可跳过）
git -c http.proxy="" -c https.proxy="" fetch origin

# 3. 确认 .gitignore 生效（排除运行时数据和隐私文件）
git status

# 4. 脱敏检查：确认不会被提交的敏感内容
#    - data/*.db, data/*.json 已在 .gitignore
#    - GITHUB.md 中的 Token/邮箱 需要在提交前脱敏

# 5. 临时脱敏 GITHUB.md（如果包含隐私信息）
#    - 将 Token 行替换为 "（已脱敏）"
#    - 将邮箱替换为通用占位符
#    - 记住：这是临时脱敏，不要保存脱敏版到本地！

# 6. 暂存所有变更
git add -A

# 7. 检查暂存区，确认无敏感文件
git status
git diff --cached --stat

# 8. 提交
git commit -m "feat(vX.Y): 提交说明"

# 9. 推送（绕过代理）
git -c http.proxy="" -c https.proxy="" push origin main

# 10. 恢复 GITHUB.md 本地版（如果之前脱敏了）
#     git checkout -- GITHUB.md  （或手动恢复完整版）
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
```

---

## GITHUB.md 本地版 vs 公开版对照

### 本地版（Skill 目录，完整保留）

```markdown
## GitHub 账户信息
| **用户名** | Quantum-particle |
| **邮箱** | 1696636393@qq.com |
| **Personal Access Token** | `ghp_xxxxx` |

## 本地项目路径
| Skill 目录 | `C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent\` |
```

### 公开版（GitHub 仓库，脱敏后）

```markdown
## 仓库信息
| **仓库名** | MATLAB-Agent |
| **地址** | https://github.com/Quantum-particle/MATLAB-Agent |

## 认证信息
> ⚠️ 认证信息不应提交到公开仓库。请使用 Git Credential Manager 或 SSH key。

## 本地路径
> （不记录个人本地路径）
```

---

## 版本历史

### v4.1.0 — 2026-04-09

- 移除 CherryStudio 旧目录引用
- 改为从 Skill 目录直接 git 操作
- 更新 .gitignore 路径（app/data/ 子目录结构）
- 更新发布流程为直接在 Skill 目录 commit + push
