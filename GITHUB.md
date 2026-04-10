# MATLAB Agent GitHub 仓库管理记录

> 最后更新: 2026-04-10

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

### v5.1.0 — 2026-04-10 启动防弹 + Simulink 建模深坑固化

- **核心改动**:
  - `start.bat`: 增强端口清理 — 杀进程后轮询确认端口释放（最多10秒），二次确认干净再启动
  - `ensure-running.bat`: 同步增强端口清理逻辑
  - `system-prompts.ts`: 启动流程新增第0步"端口清理（最优先！）"，Simulink 建模深坑6条固化
  - `SKILL.md`: 新增坑0"端口 3000 被旧进程占用"、§4.5"自动排版"、§22"Simulink 建模深坑大全"
  - `TROUBLESHOOTING.md`: 0.4 章节大幅增强、新增 §23"Simulink 建模深坑大全"

- **Bug 修复**:
  - 端口 3000 残留进程导致启动失败 → 启动前自动清理 + 等待端口释放
  - Simulink 新建 SubSystem 默认连线冲突 → delete_line 清除后再 add_line
  - 复杂模型信号获取失败 → 使用 From/Goto 模式传递信号
  - 模型构建后排版混乱 → 自动调用 arrangeSystem 排版

- **踩坑经验固化**:
  - 6 大 Simulink 建模深坑写入 SKILL.md + system-prompts.ts + troubleshooting.md
  - 端口清理流程写入 start.bat + ensure-running.bat + system-prompts.ts + SKILL.md
  - 自动排版规则写入所有文档

### v5.0.0 — 2026-04-10 diary 输出捕获 + 一键启动

- **核心改动**:
  - `matlab_bridge.py`: diary() + eng.eval() 替代 evalc()，彻底解决引号双写、中文路径乱码
  - `matlab-controller.ts`: 新增 quickstart API，相对路径基于 _cachedProjectDir 解析
  - `index.ts`: 新增 POST /api/matlab/quickstart 端点
  - `system-prompts.ts`: v5.0 系统提示词，大幅增强 Simulink 建模经验

- **Bug 修复**:
  - evalc 内层引号双写 → diary 替代 evalc，无需引号转义
  - Name-Value 参数引号双写 → diary 替代 evalc
  - 多行代码 evalc 报错 → eng.eval() 直接执行多行代码
  - 中文路径编码乱码 → diary + UTF-8 stdout buffer
  - execute API 相对路径错误 → 基于 _cachedProjectDir 解析
  - 项目扫描中文乱码 → UTF-8 输出修复
  - copyfile 中文路径失败 → diary 方式不再转义中文
  - delete_block 默认端口报错 → set_param 重命名而非删除

- **关键设计**:
  - diary 输出捕获: diary(filename) → eng.eval(code) → 读取临时文件 → 返回输出
  - quickstart API: 一步完成 MATLAB_ROOT + Engine 启动 + 项目目录
  - UTF-8 输出: sys.stdout.buffer.write() + UTF-8 编码

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

- **Bug 修复**:
  - `matlab_bridge.py`: evalc 内层 MATLAB 单引号必须双写 `''`，修复 Simulink 模型工作区 API 语法错误
  - `index.ts`: POST /api/matlab/config 的 restartBridge 改为后台异步 `.catch()`，不再阻塞 HTTP 响应
  - `start-matlab-agent.ps1`: 预热超时后不再 `exit 1`，服务器继续运行

- **踩坑经验固化**:
  - SKILL.md 新增 #15 预热超时跳过策略、#16 evalc 引号规则、#17 config API 不阻塞、#18 PowerShell UTF-8 编码
  - system-prompts.ts 新增 #11 evalc 引号规则、#12 预热跳过策略
  - TROUBLESHOOTING.md 新增 #19-#22 四个故障排除条目

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
