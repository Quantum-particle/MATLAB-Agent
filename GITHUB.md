# MATLAB Agent GitHub 仓库管理记录

> 最后更新: 2026-04-09

---

## GitHub 账户信息

| 项目 | 值 |
|------|-----|
| **用户名** | Quantum-particle |
| **邮箱** | （已脱敏） |
| **个人主页** | https://github.com/Quantum-particle |
| **Gist** | https://gist.github.com/Quantum-particle |

## 仓库信息

| 项目 | 值 |
|------|-----|
| **仓库名** | MATLAB-Agent |
| **地址** | https://github.com/Quantum-particle/MATLAB-Agent |
| **可见性** | Public |
| **默认分支** | main |
| **描述** | AI-driven MATLAB/Simulink development assistant with persistent bridge process |
| **Git 全局配置** | user.name=Quantum-particle |

## 认证信息

| 项目 | 值 |
|------|-----|
| **Personal Access Token** | `（已脱敏 — 请使用 Git Credential Manager 或 SSH key）` |
| **权限范围** | `repo`（完整仓库访问） |
| **创建日期** | 2026-04-08 |
| **用途** | API 创建仓库、git push 认证 |

> ⚠️ Token 明文不应保存在可能被推送到公开仓库的文件中。
> 代理推送方式：`git -c http.proxy="" -c https.proxy="" push origin main`（绕过本地代理）

## 本地项目路径

| 路径 | 说明 |
|------|------|
| `C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent\` | Skill 智能体目录（唯一源码，含 .git） |

---

## 更新历史

### v4.1.0 — 2026-04-09 手动配置模式

- **核心改动**:
  - `matlab-controller.ts`: 移除 ~130 行自动检测代码，简化 getMATLABRoot() 为环境变量 > 配置文件 > 未配置
  - `index.ts`: 删除 /api/matlab/installations 和 /api/matlab/detect 端点，更新预热失败提示信息
  - `system-prompts.ts`: 动态环境信息注入（getMATLABSystemPrompt 函数）
  - `config.ts`: 去掉硬编码，新增 fetchMATLABConfig() 异步获取
  - `MATLABStatusBar.tsx`: 版本号动态显示
  - `useAgents.ts`: 去掉硬编码的 MATLAB R2023b 路径
  - `start-matlab-agent.ps1`: 一键启动脚本，含交互式 MATLAB 路径配置
  - `SKILL.md`: 更新为 v4.1 文档

- **关键设计**:
  - MATLAB_ROOT 优先级: 环境变量 > 配置文件(data/matlab-config.json) > 未配置（提示用户输入）
  - 连接模式: Engine API（R2019a+，变量持久化） vs CLI 回退（老版本，变量不保持）
  - 首次启动时交互式引导用户输入 MATLAB 安装路径

### v4.0.0 — 2026-04-09 通用化升级

- **核心改动**:
  - `matlab-controller.ts`: MATLAB_ROOT 不再硬编码，支持自动检测（注册表+常见路径）+ 环境变量 + API 配置
  - `matlab_bridge.py`: 新增 CLI 回退模式（`matlab -batch` / `matlab -r`），支持 Engine API 不兼容的老版本 MATLAB
  - `matlab_bridge.py`: 新增 Windows 注册表扫描（`winreg` + `KEY_WOW64_64KEY`）
  - `matlab_bridge.py`: 新增 `_detect_connection_mode()` 自动检测 Engine 兼容性
  - `matlab_bridge.py`: 新增 `get_config` 和 `set_matlab_root` 命令
  - `index.ts`: 新增 `/api/matlab/config`、`/api/matlab/installations`、`/api/matlab/detect` API
  - `index.ts`: 去掉所有硬编码的 MATLAB 版本和路径
  - `system-prompts.ts`: 环境信息改为动态注入（`getMATLABSystemPrompt()` 函数）
  - `config.ts`: 去掉硬编码，新增 `fetchMATLABConfig()` 异步获取
  - `MATLABStatusBar.tsx`: 版本号动态显示，支持多版本信息
  - `useAgents.ts`: 去掉硬编码的 MATLAB R2023b 路径
  - `SKILL.md`: 更新为 v4.0 文档

- **关键设计**:
  - MATLAB_ROOT 优先级: 环境变量 > API 配置 > 注册表扫描 > 常见路径 > 默认回退
  - 连接模式: Engine API（R2019a+，变量持久化） vs CLI 回退（老版本，变量不保持）
  - R2019a+ 使用 `matlab -batch`，旧版本使用 `matlab -r ... -nosplash -nodesktop -wait`
  - Python Bridge 和 Node.js Controller 各自独立检测 MATLAB，确保鲁棒性

### v1.0.0 — 2026-04-08 初始推送

- **提交**: `2bfe15a`
- **分支**: main
- **内容**: 45 个文件，16348 行
- **包含**:
  - `server/` — Express + TypeScript 后端（index.ts, matlab-controller.ts, system-prompts.ts, db.ts 等）
  - `matlab-bridge/` — Python 桥接脚本（matlab_bridge.py v3.0.1，常驻模式）
  - `src/` — React 18 + TDesign + Vite 前端（12 组件 + 5 hooks）
  - 根目录配置: package.json, tsconfig.json, vite.config.ts, tailwind.config.js
  - 文档: README.md, TROUBLESHOOTING.md
  - 配置: .env.example, .gitignore
- **提交信息**: feat: MATLAB Agent v3.0 - AI-driven MATLAB/Simulink development assistant

### v3.0.1 — 2026-04-08 中文路径编码修复

- **提交**: `1ba1864`
- **分支**: main
- **状态**: ⚠️ 本地已提交，GitHub 推送失败（443 端口连接被重置，网络问题）
- **修改文件**:
  - `matlab-bridge/matlab_bridge.py`:
    - server_mode() 改用 `sys.stdin.buffer` 二进制读取 + UTF-8 解码（修复中文路径 stdin 编码）
    - 添加 `sys.stdin.reconfigure(encoding='utf-8')` 作为第一道防线
    - set_project_dir() 不再尝试 makedirs，改为返回错误信息
  - `TROUBLESHOOTING.md`: 升级到 v3.0.1，新增 3 个问题条目（#13 stdin 编码、#14 set_project_dir 安全性、#15 node_modules 复用）
- **同步更新**:
  - `~/.workbuddy/skills/matlab-agent/SKILL.md`: 版本号改为 v3.0.1，新增 3 条踩坑经验
  - `~/.workbuddy/skills/matlab-agent/references/troubleshooting.md`: 同步 TROUBLESHOOTING.md
  - Skill 目录和项目源码的 matlab_bridge.py SHA256 一致（29EF3815...）

---

## 待办 / 备注

- [ ] 考虑配置 SSH key 替代 Token 认证
- [ ] 考虑添加 GitHub Actions CI/CD
- [ ] 考虑添加 LICENSE 文件
- [ ] Token 过期前需要续期或替换
