# MATLAB Agent GitHub 仓库管理记录

> 最后更新: 2026-04-09

---

## 仓库信息

| 项目 | 值 |
|------|-----|
| **仓库名** | MATLAB-Agent |
| **地址** | https://github.com/Quantum-particle/MATLAB-Agent |
| **可见性** | Public |
| **默认分支** | main |
| **描述** | AI-driven MATLAB/Simulink development assistant with persistent bridge process |

## 认证信息

> ⚠️ 认证信息（Token、SSH key 等）不应提交到公开仓库。请使用 Git Credential Manager 或 SSH key 进行认证。

---

## 更新历史

### v4.1.0 — 2026-04-09 手动配置模式

- **核心改动**:
  - `matlab-controller.ts`: 移除 ~130 行自动检测代码（detectMATLABInstallations, autoDetectMATLAB），简化 getMATLABRoot() 为环境变量 > 配置文件 > 未配置
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
  - `matlab-controller.ts`: MATLAB_ROOT 不再硬编码，支持自动检测 + 环境变量 + API 配置
  - `matlab_bridge.py`: 新增 CLI 回退模式，支持 Engine API 不兼容的老版本 MATLAB
  - `matlab_bridge.py`: 新增 `_detect_connection_mode()` 自动检测 Engine 兼容性
  - `index.ts`: 新增配置相关 API，去掉所有硬编码
  - `system-prompts.ts`: 环境信息改为动态注入
  - `config.ts`: 去掉硬编码，新增 `fetchMATLABConfig()` 异步获取
  - `MATLABStatusBar.tsx`: 版本号动态显示，支持多版本信息
  - `useAgents.ts`: 去掉硬编码的 MATLAB R2023b 路径

### v1.0.0 — 2026-04-08 初始推送

- **提交**: `2bfe15a`
- **分支**: main
- **内容**: 45 个文件，16348 行
- **提交信息**: feat: MATLAB Agent v3.0 - AI-driven MATLAB/Simulink development assistant

### v3.0.1 — 2026-04-08 中文路径编码修复

- **提交**: `1ba1864`
- **修改**: matlab_bridge.py stdin 编码修复，set_project_dir 安全性，TROUBLESHOOTING 更新

---

## 待办 / 备注

- [ ] 考虑配置 SSH key 替代 Token 认证
- [ ] 考虑添加 GitHub Actions CI/CD
- [ ] 考虑添加 LICENSE 文件
