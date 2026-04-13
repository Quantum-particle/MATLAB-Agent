# MATLAB Agent GitHub 发布流程

> 本文档定义了从 Skill 目录全量同步到 GitHub 公开仓库的标准流程。
> **核心原则：GitHub 仓库文件与本地 Skill 目录完全相同，但推送前脱敏！**

---

## 目录结构

| 项目 | 路径 | 说明 |
|------|------|------|
| **Skill 目录**（唯一源码） | `C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\` | MATLAB Agent 智能体的原始目录 |
| **GitHub 仓库** | https://github.com/Quantum-particle/MATLAB-Agent | 公开源码仓库（文件全量相同，敏感字段脱敏） |
| **本地 git** | Skill 目录内 `.git/` | 直接在 Skill 目录初始化 git，关联远程仓库 |

---

## 🔴 核心原则

1. **全量同步**：本地有什么文件，GitHub 就有什么文件（除 .gitignore 排除的运行时文件外），`git add -A` 全量提交
2. **推送前脱敏**：包含敏感信息的文件（用户名、Token、邮箱等），推送前临时替换为占位符，推送后立即恢复本地版
3. **不搞选择性提交**：所有源码、文档、配置、脚本全部推送，不遗漏任何文件
4. **清仓重推**：如果发现 GitHub 上文件版本不一致，执行清仓重推（删除所有 git 追踪 → 全量重新 add → commit → push）

---

## 脱敏规则

### 🔴 推送前必须脱敏的字段

| 敏感字段 | 本地值 | GitHub 替换为 | 涉及文件 |
|----------|--------|---------------|----------|
| 用户名 | `<USERNAME>` | `<USERNAME>` | 所有含路径的文件 |
| Token | （本地保留） | `（已脱敏）` | GITHUB.md |
| 邮箱 | （本地保留） | `（已脱敏）` | GITHUB.md |

### 🟡 已用 `assume-unchanged` 保护的文件

以下文件包含用户名路径，本地保留原值，GitHub 上为脱敏值。
通过 `git update-index --assume-unchanged` 标记，日常 `git add -A` 不会误提交本地敏感信息。

```
PUBLISH.md
SKILL.md
app/TROUBLESHOOTING.md
app/ensure-running.bat
app/server/system-prompts.ts
references/troubleshooting.md
```

> ⚠️ 推送新版本时，需要先 `git update-index --no-assume-unchanged` 取消保护，
> 脱敏后 add+commit+push，然后恢复本地版并重新标记保护。

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

### 方式一：常规推送（日常更新用）

当只修改了部分文件，且修改文件不含敏感信息时：

```powershell
cd "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent"

# 1. 确认远程仓库关联
git remote -v

# 2. 拉取远程最新（网络不通可跳过）
git -c http.proxy="" -c https.proxy="" fetch origin

# 3. 暂存变更
git add -A

# 4. 检查暂存区（确认无敏感内容）
git status
git diff --cached --stat

# 5. 提交 + 推送
git commit -m "feat(vX.Y): 提交说明"
git -c http.proxy="" -c https.proxy="" push origin main
```

### 方式二：脱敏推送（修改了含敏感信息的文件时）

当修改了 assume-unchanged 保护的文件时：

```powershell
cd "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent"

# 1. 取消 assume-unchanged 保护
git update-index --no-assume-unchanged PUBLISH.md SKILL.md app/TROUBLESHOOTING.md app/ensure-running.bat app/server/system-prompts.ts references/troubleshooting.md

# 2. 脱敏：替换 "<USERNAME>" → "<USERNAME>"
#    （用脚本或手动替换所有受保护文件中的敏感字段）

# 3. 暂存 + 提交 + 推送
git add -A
git commit -m "feat(vX.Y): 提交说明"
git -c http.proxy="" -c https.proxy="" push origin main

# 4. 🔴 恢复本地敏感信息
#    将 "<USERNAME>" 替换回 "<USERNAME>"
#    （用脚本或手动恢复）

# 5. 🔴 重新标记 assume-unchanged
git update-index --assume-unchanged PUBLISH.md SKILL.md app/TROUBLESHOOTING.md app/ensure-running.bat app/server/system-prompts.ts references/troubleshooting.md
```

### 方式三：🔴 清仓重推（GitHub 文件版本不一致时）

当发现 GitHub 上的文件内容与本地不一致（如版本号停留在旧版）：

```powershell
cd "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent"

# 1. 取消所有 assume-unchanged 保护
git update-index --no-assume-unchanged PUBLISH.md SKILL.md app/TROUBLESHOOTING.md app/ensure-running.bat app/server/system-prompts.ts references/troubleshooting.md

# 2. 脱敏处理
#    替换所有受保护文件中的 "<USERNAME>" → "<USERNAME>"

# 3. 清空 git 索引（删除所有文件的追踪，但不删本地文件！）
git rm -r --cached .

# 4. 全量重新 add（确保每个文件都被重新追踪）
git add -A

# 5. 检查：确认所有文件都被追踪
git status
git diff --cached --stat

# 6. 提交 + 推送
git commit -m "feat(vX.Y): 清仓重推 — 全量同步到最新版本"
git -c http.proxy="" -c https.proxy="" push origin main

# 7. 🔴 恢复本地敏感信息
#    将 "<USERNAME>" 替换回 "<USERNAME>"

# 8. 🔴 重新标记 assume-unchanged
git update-index --assume-unchanged PUBLISH.md SKILL.md app/TROUBLESHOOTING.md app/ensure-running.bat app/server/system-prompts.ts references/troubleshooting.md
```

---

## 🔍 脱敏检查命令

推送前检查是否有遗漏的敏感信息：

```powershell
# 检查暂存区中是否有敏感内容
git diff --cached | Select-String "<USERNAME>|169663|ghp_"

# 如果有输出，说明还有未脱敏的内容，需要处理后再推送
# 如果无输出，说明脱敏完成，可以安全推送
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
- **PUBLISH.md 重写**：全量同步 + 推送前脱敏 + 清仓重推流程 + assume-unchanged 保护机制

### v5.0.0 — 2026-04-10 diary 输出捕获 + 一键启动

- diary() 替代 evalc()，彻底解决引号双写和中文路径乱码
- quickstart API 一键完成 MATLAB_ROOT + Engine 启动 + 项目目录
- UTF-8 输出修复
- 相对路径基于 _cachedProjectDir 解析

### v4.1.0 — 2026-04-09

- 移除 CherryStudio 旧目录引用
- 改为从 Skill 目录直接 git 操作
- 更新 .gitignore 路径（app/data/ 子目录结构）
