# MATLAB Agent Skill

> AI 驱动的 MATLAB/Simulink 开发助手，打通 AI 智能体与 MATLAB 闭园开发环境的隔阂。

## 🎯 一句话介绍

**MATLAB-Agent** 是一个让 AI 直接操控 MATLAB 引擎的智能体——它能执行 M 脚本、读写工作区变量、构建和运行 Simulink 模型，就像你坐在 MATLAB 命令行前一样。通过常驻 Python 桥接进程 + MATLAB Engine API，实现代码执行、变量持久化、仿真控制全链路打通，告别"AI 写代码你复制粘贴"的割裂体验。

## ✨ 核心亮点

- 🔄 **MATLAB 工作区直连**：执行代码后变量持久保留，像真实 MATLAB 会话一样逐步操作
- 🚁 **Simulink 建模**：从零创建模型、添加模块、连线、排版、运行仿真，全流程自动化
- 📊 **数据交互**：读取 .m/.mat/.slx 文件，管理工作区变量，导出分析结果
- 🔧 **双模引擎**：Engine API（推荐）+ CLI 回退（兼容老版本 MATLAB），自动检测切换
- ⚡ **一键启动**：`quickstart` API 一步完成环境配置 + Engine 启动 + 项目目录设定

## 触发条件

当用户提到以下关键词时自动加载：
- MATLAB、M 脚本、Simulink、控制律设计、动力学建模
- 信号处理、频域分析、Bode图、阶跃响应
- .m 文件、.mat 数据、.slx 模型
- MATLAB 工作区、MATLAB Engine、PID 调参
- 模块扩展、新增模块、模块支持、模块修改、模块纠正、模块修复、block registry

## 🔴🔴🔴 Simulink 模块四文件同步规则（强制！）

> **⛔ STOP — 当涉及 Simulink 支持模块的更新或修改时，必须同时更新以下四个文件！**
> **这是 P0 级强制规则，遗漏任何一项都会导致参数类型推断失败或模块路径错误！**

### 触发条件（满足任一即触发）

当涉及以下任务时**立即触发**本规则：
- 新增 Simulink 模块支持
- 修改模块路径或参数定义
- 移除/禁用已有模块
- 更新模块参数类型或枚举值
- 扩展模块库覆盖范围

### 必须同步更新的四个文件

| 文件 | 路径 | 作用 |
|------|------|------|
| **sl_block_registry.m** | `skills/matlab-agent/app/matlab-bridge/sl_toolbox/sl_block_registry.m` | 模块路径注册表 |
| **matlab_bridge.py** | `skills/matlab-agent/app/matlab-bridge/matlab_bridge.py` | 参数类型推断引擎 |
| **block-param-registry.md** | `skills/matlab-agent/references/block-param-registry.md` | 模块参数参考文档 |
| **sl_toolbox_api_guide.md** | `skills/matlab-agent/references/sl_toolbox_api_guide.md` | API 说明书 |

### 同步内容对照表

| block-param-registry.md 新增内容 | sl_block_registry.m | matlab_bridge.py | sl_toolbox_api_guide.md |
|-------------------------------|---------------------|------------------|------------------------|
| 模块路径 `simulink/xxx/BlockName` | `registry('BlockName') = 'simulink/xxx/BlockName'` | — | 更新"已支持模块"表格 |
| 模块参数 `(BlockName, ParamName)` | — | `block_param[(BlockName, ParamName)] = param_type` | — |
| enum 参数枚举值 | — | `_PARAM_ENUM_VALUES[(BlockName, ParamName)] = [values]` | — |
| 精确参数类型映射 | — | `exact[ParamName] = param_type` | — |

### 示例：新增 `Saturation` 模块

```matlab
% 1. block-param-registry.md 添加:
### Saturation（饱和）
| UpperLimit | scalar | 上限 |
| LowerLimit | scalar | 下限 |

% 2. sl_block_registry.m 添加:
registry('Saturation') = 'simulink/Discontinuities/Saturation';

% 3. matlab_bridge.py 添加:
# _MATRIX_PARAM_PATTERNS['block_param']:
('Saturation', 'UpperLimit'): 'scalar',
('Saturation', 'LowerLimit'): 'scalar',

% 4. sl_toolbox_api_guide.md 更新:
| Saturation | ✅ | % 在"已支持模块"表格中添加
```

### 示例：移除不存在的模块（如 R2023b 中不可用的模块）

```matlab
% 1. sl_block_registry.m — 注释掉并标注版本:
% [REMOVED v10.4.1] Weighted Sample Time Math 在 R2023b 中不可用
% registry('Weighted Sample Time Math') = 'simulink/Additional Math & Discrete/Weighted Sample Time Math';

% 2. matlab_bridge.py — 注释掉参数映射:
# [REMOVED v10.4.1] Weighted Sample Time Math 在 R2023b 中不可用
# ('Weighted Sample Time Math', 'Operation'): 'enum',

% 3. block-param-registry.md — 标记为已移除:
## Additional Math & Discrete（附加数学与离散库）- [REMOVED v10.4.1]
> **注意**: R2023b 中 `simulink/Additional Math & Discrete` 路径不存在...

% 4. sl_toolbox_api_guide.md — 标记为已移除:
### Additional Math & Discrete（附加数学与离散库）- [REMOVED v10.4.1]
```

### 强制检查清单

完成模块更新后，逐项确认：

- [ ] `sl_block_registry.m` — 模块路径已添加/移除/注释
- [ ] `matlab_bridge.py` — `_MATRIX_PARAM_PATTERNS['block_param']` 已更新
- [ ] `matlab_bridge.py` — `_PARAM_ENUM_VALUES` 已更新（如有 enum 参数）
- [ ] `block-param-registry.md` — 参数参考文档已更新
- [ ] `sl_toolbox_api_guide.md` — "已支持模块"表格已更新
- [ ] 用 MATLAB R2023b 验证模块路径正确性

### 常见错误

- ❌ 只更新 `sl_block_registry.m`，忘记 `matlab_bridge.py` → 参数类型推断失败
- ❌ 只更新 `block-param-registry.md`，忘记其他三个 → 文档与实际不同步
- ❌ 新增模块未在 `sl_toolbox_api_guide.md` 的模块表格中注册 → AI 不知道模块已支持

---

## 🔴🔴🔴 sl_toolbox API 说明书（Simulink 建模前必读！）

> **⛔ STOP — 在执行任何 Simulink 建模脚本之前，你必须先读取 API 说明书！**
> **如果不先读说明书，你写的 MATLAB 脚本几乎一定会因为 API 语法错误而失败！**

### 说明书位置（任选一个可用的）

| 优先级 | 路径 | 说明 |
|--------|------|------|
| **首选** | `C:\Users\泰坦\.workbuddy\skills\matlab-agent\references\sl_toolbox_api_guide.md` | Skill 目录内，随 skill 加载始终可用 |
| 备选 | 项目根目录 `sl_toolbox_api_guide.md` | 仅当工作区为 MATLAB_Agent 开发项目时可用 |

### 强制规则

1. **每次用户请求 Simulink 建模操作（创建模型、添加模块、连线、仿真等），必须先 read_file 读取 API 说明书**
2. 说明书包含 **23 个 .m 函数** 的精确签名、参数说明、返回结构、⚠️关键注意事项
3. **绝对不要凭记忆或通用知识写 Simulink 建模脚本！** 以下是历史踩坑中最常见的致命错误：
   - ❌ `sl_set_param_safe('MyModel/Kp', 'Gain', '5')` — params 必须是 struct！
   - ✅ `sl_set_param_safe('MyModel/Kp', struct('Gain', '5'))`
   - ❌ `sl_config_set('MyModel', 'StopTime', '50')` — config 必须是 struct！
   - ✅ `sl_config_set('MyModel', struct('StopTime', '50'))`
   - ❌ `sl_block_registry()` — 无参调用会报错！
   - ✅ `sl_block_registry('Gain')`
   - ❌ `result.blockCount` — blockCount 在 result.model 下！
   - ✅ `result.model.blockCount`
   - ❌ `result.blocks{i}` — sl_find_blocks 的 blocks 是 cell 数组（这是对的），但 sl_validate_model 的 checks 是 struct 数组要用 `(i)`
   - ❌ `sl_sim_batch('MyModel', 'paramSets', {struct('Gain',2)})` — 模式2 的 paramSets 是第2个位置参数！
   - ✅ `sl_sim_batch('MyModel', {struct('Gain',2)}, 'stopTime', '10')`
4. **API 变更后必须同步更新说明书**（P0 级强制规则，见设计文档）

### 快速参考：哪些函数需要 struct 参数？

| 函数 | 需 struct 的参数 | ❌ 错误写法 | ✅ 正确写法 |
|------|-----------------|------------|------------|
| `sl_set_param_safe` | 第2个 `params` | `('path', 'Gain', '5')` | `('path', struct('Gain','5'))` |
| `sl_config_set` | 第2个 `config` | `('model', 'StopTime', '50')` | `('model', struct('StopTime','50'))` |
| `sl_add_block_safe` | `'params'` NV对 | `'params', 'Gain', '2.5'` | `'params', struct('Gain','2.5')` |
| `sl_signal_config` | 第4个 `config` | `(..., 'dataType', 'single')` | `(..., struct('dataType','single'))` |
| `sl_bus_create` | 第2个 `elements` | `{'a','b'}` | `[struct('name','a'); struct('name','b')]` |
| `sl_sim_batch` 模式2 | 第2个 `paramSets` | `'paramSets', {struct(...)}` | `{struct('Gain',2), struct('Gain',5)}` |

### 快速参考：返回值数据类型陷阱

| 函数 | 字段 | 实际类型 | 正确访问 |
|------|------|---------|---------|
| `sl_find_blocks` | `blocks` | **cell{struct}** | `result.blocks{i}` |
| `sl_bus_inspect` | `elements` | **cell{struct}** | `result.bus.elements{i}` |
| `sl_inspect_model` | `blocks` | **cell{struct}** | `result.model.blocks{i}` |
| `sl_validate_model` | `checks` | **struct 数组** | `result.checks(i)` |
| `sl_best_practices` | `antiPatterns` | **cell{struct}** | `result.antiPatterns{i}` |
| `sl_sim_batch` | `results` | **cell{struct}** | `result.simBatch.results{i}` |

## 能力概述

### 核心架构 (v5.2)
- **diary 输出捕获**: 用 `diary()` + `eng.eval()` 替代 `evalc()`，彻底解决引号双写、中文路径乱码问题
- **一键启动**: quickstart API 一步完成 MATLAB_ROOT 配置 + Engine 启动 + 项目目录设置
- **手动配置 MATLAB 路径**: 首次启动时需用户提供 MATLAB 安装路径（交互式引导或 API 配置）
- **配置数据自动迁移**: v5.2 `ensureDataDirSync()` 自动检测并迁移旧数据目录，新用户不再踩坑
- **双连接模式**: Engine API 模式（变量持久化） + CLI 回退模式（兼容老版本 MATLAB）
- **常驻 Python 桥接进程**: Node.js 启动 `matlab_bridge.py --server`，通过 stdin/stdout JSON 行协议通信
- **持久化 MATLAB Engine**: Engine 在进程生命周期内保持，变量跨命令保持
- **实时可视化**: figure/plot 在 MATLAB 桌面实时显示
- **项目感知**: 扫描项目目录，读取 .m/.mat/.slx 文件
- **UTF-8 输出**: Python Bridge 使用 `sys.stdout.buffer.write()` + UTF-8 编码，解决 Windows GBK 乱码

### 支持的操作
1. **项目操作**: 设置项目目录、扫描项目文件
2. **文件读取**: 读取 .m 文件内容、.mat 变量结构、Simulink 模型信息
3. **代码执行**: 在持久化工作区执行 MATLAB 代码、执行 .m 脚本
4. **工作区管理**: 获取/保存/加载/清空工作区变量
5. **Simulink**: 创建/打开/运行 Simulink 模型，子系统端口管理
6. **图形管理**: 列出/关闭图形窗口
7. **配置管理**: 获取/设置 MATLAB 路径，配置持久化
8. **一键启动**: quickstart API 快速进入 MATLAB 开发状态

## 使用方式

### 1. 启动服务

> ⚠️ **绝对不能**用 `npx tsx server/index.ts` 或 `npm run dev` 阻塞式启动！
> MATLAB Engine 预热需要 30-90 秒，阻塞式启动会导致命令超时卡死。

#### 方式 A：一键启动脚本（⭐ 强烈推荐，最可靠）

```bash
# 双击运行或在命令行执行：
cmd /c "C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\start.bat"
```

此脚本自动完成：
1. 检查 Node.js / Python 可用性
2. 自动安装 node_modules（如缺失）
3. 🔴 彻底杀掉端口 3000 旧进程并等待确认端口释放
4. 后台启动服务器
5. 轮询等待服务就绪
6. 检查 MATLAB 配置状态
7. 等待 Engine 预热

#### 方式 B：AI Agent 专用 — ensure-running（最简洁）

```bash
# AI agent 只需一行命令确保服务运行：
cmd /c "C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
# 返回码 0 = 服务可用, 1 = 不可用
```

#### 方式 C：PowerShell 手动启动（调试用）

```powershell
# 1. 杀掉可能残留的旧进程（端口 3000）
$old = netstat -ano | Select-String ":3000" | Select-String "LISTENING"
if ($old) { $old -match '\d+$' | ForEach-Object { Stop-Process -Id $Matches[0] -Force } }

# 2. 后台启动服务器
cd "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app"

# ⚠️ Windows 关键坑：必须先确保 node_modules 存在！
if (-not (Test-Path "node_modules")) { npm install --production }

# ⚠️ Windows 关键坑：用 cmd /c "start /B npx tsx ..." 后台启动，不能直接 npx！
cmd /c "start /B npx tsx server/index.ts > $env:TEMP\matlab-agent-out.log 2>&1"

# 3. 轮询健康检查
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
```

服务启动后访问 http://localhost:3000

### 2. 前置条件

- **MATLAB 任意版本** 安装在系统上（首次启动时需手动输入安装路径）
- **Python 3.9+**（Engine API 模式需要，CLI 回退模式不要求）
  - 如果 Python 版本与 MATLAB Engine API 兼容，自动使用 Engine 模式
  - 如果不兼容（如 MATLAB R2016a + Python 3.11），自动回退到 CLI 模式
- **Node.js 18+**（Windows 下 `npx.cmd` 必须在 PATH 中）
- **CodeBuddy CLI**（已登录）

### 配置 MATLAB 路径

首次启动时，**AI Agent 会自动检测** MATLAB 是否已配置。如果未配置，会直接在对话中询问用户的 MATLAB 安装路径（适用于所有 AI Agent 平台），用户输入后自动持久化保存。

也可以通过以下方式手动配置：

```bash
# 方法1: 环境变量
set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b

# 方法2: API 配置（路径会持久化到配置文件）— 用 PowerShell 变量构造法避免 $ 变量展开和转义地狱
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"

# 方法3: 一键快速启动（v5.0 推荐，AI agent 专用）
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\RL\my_project'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"
```

**首次配置流程（自动对话，所有平台通用）**：
1. AI Agent 启动服务后，调用 `GET /api/matlab/config` 检查配置
2. 如果 `matlab_root_source` 为 `"none"` 或 `matlab_root` 为空 → 直接在对话中询问用户输入 MATLAB 安装路径
3. 用户在对话中回复路径后，Agent 调用 `POST /api/matlab/config` 保存
4. 路径持久化到 `data/matlab-config.json`，后续启动自动加载，不再询问

### 3. API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 状态（快速） |
| GET | `/api/matlab/status?quick=false` | MATLAB 完整检查（含 Engine） |
| GET | `/api/matlab/config` | 获取 MATLAB 配置（含 `matlab_root_source` 用于首次检测） |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录（自动持久化 + 自动重启 bridge） |
| DELETE | `/api/matlab/config` | 重置 MATLAB 配置（清除缓存 + 备份删除配置文件） |
| GET | `/api/matlab/config/diagnose` | 配置自检（v5.1.1，诊断配置同步问题） |
| **POST** | **`/api/matlab/quickstart`** | **一键快速启动（v5.0）** |
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
| **v7.0: sl_* 工具箱 API** | | |
| POST | `/api/matlab/simulink/inspect` | 检查模型全景 |
| POST | `/api/matlab/simulink/add_block` | 安全添加模块 |
| POST | `/api/matlab/simulink/add_line` | 安全连线 |
| POST | `/api/matlab/simulink/set_param` | 安全设置参数 |
| POST | `/api/matlab/simulink/delete` | 安全删除模块 |
| POST | `/api/matlab/simulink/find_blocks` | 高级查找模块 |
| POST | `/api/matlab/simulink/replace_block` | 替换模块 |
| POST | `/api/matlab/simulink/bus_create` | 创建总线 |
| POST | `/api/matlab/simulink/bus_inspect` | 检查总线 |
| POST | `/api/matlab/simulink/signal_config` | 信号配置 |
| POST | `/api/matlab/simulink/signal_logging` | 信号记录 |
| POST | `/api/matlab/simulink/subsystem_create` | 创建子系统 |
| POST | `/api/matlab/simulink/subsystem_mask` | 子系统 Mask |
| POST | `/api/matlab/simulink/subsystem_expand` | 展开子系统 |
| POST | `/api/matlab/simulink/config_get` | 获取模型配置 |
| POST | `/api/matlab/simulink/config_set` | 设置模型配置 |
| POST | `/api/matlab/simulink/sim_run` | 运行仿真 (sl_toolbox) |
| POST | `/api/matlab/simulink/sim_results` | 获取仿真结果 |
| POST | `/api/matlab/simulink/callback_set` | 设置回调 |
| POST | `/api/matlab/simulink/sim_batch` | 批量仿真 |
| POST | `/api/matlab/simulink/validate` | 模型验证 |
| POST | `/api/matlab/simulink/parse_error` | 错误解析 |
| POST | `/api/matlab/simulink/block_position` | 模块位置 |
| POST | `/api/matlab/simulink/auto_layout` | 自动排版 |
| POST | `/api/matlab/simulink/snapshot` | 模型快照 |
| POST | `/api/matlab/simulink/baseline_test` | 基线测试 |
| POST | `/api/matlab/simulink/profile_sim` | 仿真性能分析 |
| POST | `/api/matlab/simulink/profile_solver` | 求解器性能分析 |
| POST | `/api/matlab/simulink/best_practices` | 最佳实践查询 |
| POST | `/api/matlab/simulink/self_improve` | **v7.0: Layer 5 源码级自我改进** |
| POST | `/api/matlab/simulink/workspace/clear` | 清空模型工作区 |
| **v8.0: 提示词分层 API (Part 8)** | | |
| GET | `/api/matlab/simulink/prompt/list` | 列出可用场景和参考主题 |
| GET | `/api/matlab/simulink/prompt/scenario?scenario=<name>` | 获取场景提示词（核心层+场景层） |
| GET | `/api/matlab/simulink/prompt/reference?topic=<name>` | 获取参考层提示词 |
| GET | `/api/matlab/figures` | 列出图形 |
| POST | `/api/matlab/figures/close` | 关闭所有图形 |

### 4. 预设 Agent

1. **MATLAB 开发** (`matlab-default`): M 语言开发，信号处理/控制律/数据分析
2. **Simulink 建模** (`simulink-default`): Simulink 模型构建和仿真
3. **通用助手** (`default`): 通用 AI 助手

## ⚠️ 关键踩坑经验

### 0. Windows 启动踩坑大全（v5.1 固化，最优先！）

> **这是最关键的坑，因为启动不了就什么都干不了！**
> **🔴 第一优先级：启动前必须杀掉端口 3000 残留进程，确保环境干净！**

- **🔴 坑0: 端口 3000 被旧进程占用（最常见、最致命！）**
  - 症状：`EADDRINUSE: address already in use :::3000`，服务器启动失败
  - 原因：上次服务未正常关闭，进程残留在端口 3000 上
  - 修复：**启动前必须先杀掉残留进程，确认端口干净再启动！**
    ```cmd
    :: 1. 查找占用端口 3000 的进程
    netstat -ano | findstr ":3000" | findstr "LISTENING"
    :: 2. 杀掉对应 PID
    taskkill /F /PID <pid>
    :: 3. 等待 2-3 秒确认端口释放
    timeout /t 3
    :: 4. 再确认一次端口已释放
    netstat -ano | findstr ":3000" | findstr "LISTENING"
    ```
  - **一键脚本已自动处理**: start.bat 和 ensure-running.bat 会自动扫描、杀进程、等待端口释放、确认干净后再启动
  - **⚠️ 杀完进程后不要立即启动！** 必须等 2-3 秒让端口完全释放（TIME_WAIT 状态消失），否则新进程仍会 EADDRINUSE

- **坑1: node_modules 缺失导致 `npx tsx` 失败**
  - 症状：`Error: Cannot find module 'xxx'` 或直接静默退出
  - 修复：启动前必须检查 `node_modules/` 是否存在，不存在则 `npm install --production`
  - **一键脚本已自动处理**

- **坑2: Windows 下 `npx` 不是可执行文件**
  - 症状：PowerShell 中 `Start-Process -FilePath "npx"` 报 "npx is not a valid Win32 application"
  - 原因：Windows 下 `npx` 是 `npx.cmd` 批处理文件，不是 exe
  - 修复：在 `cmd /c` 中执行 `npx tsx ...`，或在 PowerShell 中用 `cmd /c "start /B npx tsx ..."`

- **坑3: 阻塞式启动导致 AI agent 超时卡死**
  - 症状：直接 `npx tsx server/index.ts` 会占用终端，AI agent 的命令执行超时
  - 修复：必须后台启动 `start /B`，然后轮询 `/api/health`

- **坑4: 旧进程残留占端口 3000（已合并到坑0）**
  - 见上方 **坑0**

- **坑5: 含中文/空格/括号的路径（用户目录 `泰坦`、`Program Files(x86)`）**
  - 症状：PowerShell 中 `cd` 到含中文路径可能失败
  - 修复：用 `cmd /c` 包裹命令，或用 `Push-Location`/`Pop-Location`

- **🔴 坑5.5: PowerShell Invoke-RestMethod 传含中文/非ASCII内容的 JSON 必须用 UTF8 编码**
  - 症状：POST 请求体中含中文路径（如 `C:\Users\泰坦\...`）时，Bridge 收到乱码路径，导致安全检查失败、路径匹配失败等
  - 原因：PowerShell 的 `Invoke-RestMethod -Body $jsonString` 默认使用系统编码（Windows 下为 GBK），JSON 中的中文被 GBK 编码后 Bridge 端 UTF8 解码出错
  - **🔴 强制规则：所有 PowerShell Invoke-RestMethod 调用，必须用 UTF8 编码传 Body！**
  - 正确写法（变量构造法，推荐）：
    ```powershell
    # 构造 body 对象 → JSON → UTF8 字节 → 传输
    $body = @{action="patch_source"; file_path="C:\Users\泰坦\..."} | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri "http://localhost:3000/api/..." -Method POST -ContentType "application/json; charset=utf-8" -Body $bytes
    ```
  - 错误写法（中文会乱码！）：
    ```powershell
    # ❌ 直接传字符串，PowerShell 用 GBK 编码，中文乱码！
    Invoke-RestMethod -Uri "..." -Method POST -ContentType "application/json" -Body '{"file_path":"C:\Users\泰坦\..."}'
    ```
  - **适用范围**: 任何 Body 中可能含中文、Unicode 字符的 API 调用（配置路径、patch_source、quickstart 等），一律使用 UTF8 编码
  - **简单 Body 无中文时**: 纯 ASCII 的 Body 可以直接传字符串，但为统一和防错，建议**全部使用 UTF8 编码**

- **坑6: Python Bridge spawn 失败**
  - 症状：`spawn('python', ...) Error: spawn python ENOENT`
  - 修复：确保 Python 在 PATH 中，或 Node.js 端用 `python.exe` 完整路径

- **坑7: 日志无处可查**
  - 修复：后台启动时重定向到 `%TEMP%\matlab-agent-out.log`

### 0.5 AI Agent 启动标准流程（固化到智能体底层）

```
0. 🔴 端口清理（最优先！启动前必须确保环境干净！）:
   - ensure-running.bat 已自动处理（杀进程 → 等端口释放 → 确认干净 → 再启动）
   - 手动: netstat -ano | findstr ":3000" | findstr "LISTENING" → taskkill /F /PID <pid> → 等2-3秒
1. 检查服务: powershell -Command "try { Invoke-RestMethod -Uri 'http://localhost:3000/api/health' -TimeoutSec 5; Write-Host 'OK' } catch { Write-Host 'FAIL' }"
2. 如已运行 → 直接使用
3. 如未运行 → 执行: cmd /c "C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
4. 等待 ensure-running 返回 0
5. 使用 quickstart API 一步到位: POST /api/matlab/quickstart
```

### 0.5 [CRITICAL] matlab_bridge.py 与 block-param-registry.md 强制绑定更新规则（v10.4 新增）

> **新增模块时，四个文件必须同时更新，否则参数类型推断会失败！**

**必须同步更新的四个文件**：
1. `block-param-registry.md` — 模块参数参考文档（用户/AI 查阅）
2. `sl_block_registry.m` — 模块路径注册表（`build_registry()` 函数）
3. `matlab_bridge.py` — 参数类型推断引擎（`_MATRIX_PARAM_PATTERNS` + `_PARAM_ENUM_VALUES`）
4. `sl_toolbox_api_guide.md` — API 说明书（更新"当前已支持的模块"表格）

**同步内容对照表**：
| block-param-registry.md 新增内容 | sl_block_registry.m | matlab_bridge.py | sl_toolbox_api_guide.md |
|-------------------------------|---------------------|------------------|------------------------|
| 模块路径 `simulink/xxx/BlockName` | `registry('BlockName') = 'simulink/xxx/BlockName'` | — | 更新已支持模块表格 |
| 模块参数 `(BlockName, ParamName)` | — | `block_param[(BlockName, ParamName)] = param_type` | — |
| enum 参数枚举值 | — | `_PARAM_ENUM_VALUES[(BlockName, ParamName)] = [values]` | — |
| 精确参数类型映射 | — | `exact[ParamName] = param_type` | — |

**示例**：新增 `Saturation` 模块
```matlab
% 1. block-param-registry.md 添加:
### Saturation（饱和）
| UpperLimit | scalar | 上限 |
| LowerLimit | scalar | 下限 |

% 2. sl_block_registry.m 添加:
registry('Saturation') = 'simulink/Discontinuities/Saturation';

% 3. matlab_bridge.py 添加:
# _MATRIX_PARAM_PATTERNS['block_param']:
('Saturation', 'UpperLimit'): 'scalar',
('Saturation', 'LowerLimit'): 'scalar',

% 4. sl_toolbox_api_guide.md 更新:
| Saturation | ✅ | % 在已支持模块表格中添加
```

**触发条件**：任何涉及新增 Simulink 模块的工作，必须同时检查并更新上述四个文件。

### 1. diary 输出捕获替代 evalc（v5.0 核心改造）
- **问题**: `evalc()` 要求将 MATLAB 代码作为字符串参数传递，导致所有单引号必须双写
- **后果**: Name-Value 参数如 `'LowerLimit'` 被双写为 `''LowerLimit''`，语法错误
- **后果**: 中文路径通过 evalc 字符串传递时编码乱码
- **后果**: 多行代码需要手动拼接，容易出错
- **v5.0 修复**: 使用 `diary()` + `eng.eval()` 替代 `evalc()`
  - 代码直接通过 `eng.eval(code, nargout=0)` 执行，无需引号转义
  - 输出通过 `diary(filename)` 捕获到临时文件，然后读取
  - 完美支持中文路径、Name-Value 参数、多行代码
  - **不要回退到 evalc！**

### 2. Windows stdout 中文编码（v5.0 修复）
- **问题**: Python `sys.stdout.write()` 在 Windows 下使用 GBK 编码
- **后果**: JSON 响应中的中文（如 "整理"）被编码为 "鏁寸悊"
- **v5.0 修复**: 使用 `sys.stdout.buffer.write(json.dumps(...).encode('utf-8'))` + `sys.stdout.buffer.flush()`

### 3. 中文路径处理（v5.0 大幅改善）
- **改善**: diary 执行方式不再需要引号转义，中文路径在 `eng.eval()` 中可以正常传递
- **仍需注意**: Simulink 的 `load_system`/`save_system` 对中文路径仍有问题
- **Workaround**: 用 `dir()` + `fullfile()` 通过变量间接操作中文路径

### 4. SubSystem 端口管理（v5.1 固化经验）
- **坑点**: 新建 SubSystem 自动包含 In1/Out1，直接删除后重新添加会导致端口编号混乱
- **正确做法**: 用 `set_param` 重命名默认端口，不要用 `delete_block` 删除
- **端口编号**: 从 1 开始，按添加顺序递增
- **连线格式**: `'SubSystemName/PortNum'`
- **🔴 重要**: 新建 SubSystem 后，默认的 In1/Out1 端口已被系统自动连线到内部 Out1/In1。如果需要从外部 `add_line` 到这些端口，必须先 `delete_line` 清除默认连线，再 `add_line` 重新连接
- **🔴 重要**: 复杂模型中（如 RL 训练模型），子系统间常通过 **From/Goto 模块** 传递信号，而非直接连线。新添加的子系统应使用 From 模块获取已有 Goto 标签的信号，而不是从 Inport 连线

### 4.5 🔴 Simulink 模型自动排版（v5.1 固化 — 必须遵守！）
- **规则**: 所有模块构建和连线完成后，**必须调用 `Simulink.BlockDiagram.arrangeSystem` 排版！**
- **原因**: 脚本化建模时模块位置是手动指定的，用户打开模型看到的是一堆叠在一起的方块，根本没法看
- **排版命令**: `Simulink.BlockDiagram.arrangeSystem(modelName)` — Simulink 自动布局所有模块和线
- **适用范围**: 顶层模型和每个子系统都需要排版
- **完整流程**:
  ```matlab
  % ====== 构建完成后必须排版 ======
  % 1. 排版顶层模型
  Simulink.BlockDiagram.arrangeSystem(modelName);
  
  % 2. 排版所有子系统
  subs = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'SubSystem');
  for i = 1:length(subs)
      try
          Simulink.BlockDiagram.arrangeSystem(subs{i});
      catch
          % 某些子系统可能无法排版（如库链接），跳过
      end
  end
  
  % 3. 保存
  save_system(modelName);
  ```
- **⚠️ 注意**: 排版后再保存，确保用户打开模型时看到的是整齐的布局

### 5. 相对路径解析（v5.0 修复）
- **问题**: `executeMATLABScript` 中 `fs.existsSync(scriptPath)` 检查 Node.js CWD 而非项目目录
- **v5.0 修复**: 相对路径自动基于 `_cachedProjectDir` 解析

### 6. MATLAB Engine 输出捕获（历史）
- **v4.x**: 使用 evalc + nargout=1，需要引号双写
- **v5.0**: 使用 diary + eng.eval，无需引号转义

### 7. GBK 编码问题
- **修复**: 子进程环境变量 PYTHONIOENCODING=utf-8，Python 端 sys.stdout.reconfigure(encoding='utf-8')
- **v5.0 加强**: stdout 输出使用 buffer.write + UTF-8 编码

### 8. Windows stdin 中文编码
- **修复**: server_mode() 中改用 `for raw_line in sys.stdin.buffer` + 手动 `raw_line.decode('utf-8')`

### 9. set_project_dir 安全性
- **修复**: 检查路径存在性，不存在时直接返回错误，不尝试创建

### 10. node_modules 复用
- **修复**: 用 `mklink /J` 创建 junction 链接，共享项目目录的 node_modules

### 11. Simulink 模型遮蔽警告
- **修复**: 创建前 close_system + bdclose，warning('off', 'Simulink:Engine:MdlFileShadowing')

### 12. timeseries API 兼容性
- **修复**: 使用 isprop() 检查 Values 属性是否存在

### 13. 函数命名限制
- 函数名不能以下划线开头，必须以字母开头

### 14. Simulink Position 格式
- `[left, bottom, right, top]` 不是 `[x, y, width, height]`

### 15. shareEngine 不可靠
- 不使用 shareEngine，每次启动独立 Engine 实例

### 16. Python Engine 版本不兼容
- **修复**: v4.0 新增 CLI 回退模式，自动检测 Engine 兼容性

### 17. MATLAB 路径配置
- **持久化**: 通过 API 设置的路径保存到 `data/matlab-config.json`
- **优先级**: 环境变量 MATLAB_ROOT > 配置文件 > 未配置
- **⚠️ 配置文件路径**: 运行时使用的配置文件路径是 `skills/matlab-agent/data/matlab-config.json`（注意：不是 `app/data/`！）
- **⚠️ 配置同步**: 通过 POST /api/matlab/config 设置路径后，bridge 进程会自动重启以加载新路径
- **配置自检**: GET /api/matlab/config/diagnose 可诊断配置问题

### 17.5 🔴 MATLAB 路径配置踩坑大全（v5.2 固化，已自动修复！）

> **配置不对，MATLAB 就用不了！** 但 v5.2 已将大部分坑自动修复。

- **坑A: 双 `data/` 目录歧义（v5.2 已自动修复！）**
  - 历史问题: 存在 `skills/matlab-agent/data/` 和 `app/data/` 两个数据目录，配置文件可能散落两处
  - **v5.2 自动修复**: `ensureDataDirSync()` 在服务启动时自动检测 `app/data/` 下的配置并迁移到 `data/`
  - 迁移后自动清空 `app/data/matlab-config.json` 为 `{}`，避免后续混淆
  - **新用户无需关心此问题，系统自动处理**
  - 如需手动操作配置文件，正确路径是: `skills/matlab-agent/data/matlab-config.json`

- **坑B: 配置路径无效（matlab.exe 不存在）**
  - **症状**: API 返回 `matlab_root_source: "config"` 但 `matlab_available: false`
  - **原因**: 用户输入了错误的路径，或 MATLAB 已卸载/移动
  - **修复**: v5.1.1 `loadConfigFromFile` 自动检测路径有效性，无效路径会被清除并备份
  - **自检**: 调用 GET /api/matlab/config/diagnose 诊断配置问题

- **坑C: 设置新路径后 bridge 未重启**
  - **症状**: POST /api/matlab/config 成功，但 MATLAB 仍使用旧路径
  - **原因**: bridge 进程的环境变量 MATLAB_ROOT 在 spawn 时设定，运行中不会更新
  - **修复**: v5.1.1 `POST /api/matlab/config` 会自动调用 `restartBridge()` 重启 bridge
  - **⚠️ restartBridge 的 stop 命令已加 5 秒超时**，避免卡住

- **坑D: bat 脚本路径含 `(x86)` 被误解析**
  - **症状**: `D:\Program Files(x86)\MATLAB2023b was unexpected at this time`
  - **原因**: cmd 中括号 `()` 是特殊字符，被当作子命令执行
  - **修复**: v5.1.1 已在 start.bat 中转义为 `^(x86^)`

- **坑E: `cmd /c` 调用 bat 时 PowerShell 健康检查报 `Input redirection is not supported`**
  - **症状**: ensure-running.bat 在 `cmd /c` 方式调用时卡住或报错
  - **原因**: bat 中 `>nul 2>&1` 重定向与 `cmd /c` 嵌套冲突
  - **修复**: v5.2 将 `>nul 2>&1` 改为 `2>nul`，并添加 `-NoProfile` 加速 PowerShell 启动

### 18. 绝对不能阻塞式启动服务器！
- **正确做法**: 后台启动服务器 → 轮询 `/api/health` → 检查 `warmup` 字段

### 19. 预热超时可安全跳过
- 预热卡住不影响智能体正常功能，最差情况自动降级到 CLI 模式

### 20. POST /api/matlab/config 不能阻塞式重启桥接
- **修复**: `restartBridge()` 改为后台异步 `.catch()`

### 21. 🔴 PowerShell 向 API 发送 POST 请求必须用 ConvertTo-Json 变量构造法
- **根因**: PowerShell 双引号字符串中 `$` 是变量前缀，内联 JSON 中的 `$matlabRoot` 等会被展开为空字符串
- **绝对不要在 -Body 参数中直接内联 JSON 字符串！**
- **正确做法**: 用哈希表构造 + `ConvertTo-Json -Compress` + `[System.Text.Encoding]::UTF8.GetBytes()`
- 详细模板见 TROUBLESHOOTING.md §22

### 22. 🔴 Simulink 建模深坑大全（v5.1 固化 — 任务4 实测总结）

> **Simulink 建模不是拿出模块库中已经封装好的模块并连接这么简单！**
> **必须组成子系统，子系统再组成系统，注意模块输入输出端口的管理！**

- **坑A: 新建 SubSystem 的默认连线冲突**
  - 症状：`add_line` 报 "目标端口已有信号线连接"
  - 原因：原生 `add_block('simulink/Ports & Subsystems/SubSystem', ...)` 创建的 SubSystem 默认包含 In1→Out1 连线
  - 修复：先 `delete_line` 清除默认连线，再 `add_line`
  - **⚠️ 重要区别**: `sl_subsystem_create(modelName, name, 'empty')` 创建的子系统**没有**默认 In1→Out1 连线，不需要 delete_line！
    - 原生 add_block SubSystem → 有默认连线，需要 delete_line
    - sl_subsystem_create empty 模式 → 无默认连线，直接 add_line
  ```matlab
  % 原生方式（有默认连线）：
  add_block('simulink/Ports & Subsystems/SubSystem', [modelName, '/MySubsystem']);
  delete_line([modelName, '/MySubsystem'], 'In1/1', 'Out1/1');  % 必须先删除
  add_line([modelName, '/MySubsystem'], 'In1/1', 'MyBlock/1');
  
  % sl_subsystem_create empty 方式（无默认连线）：
  sl_subsystem_create(modelName, 'MySubsystem', 'empty');
  % 直接添加模块和连线，不需要 delete_line
  sl_add_block_safe([modelName, '/MySubsystem'], 'Gain', 'destPath', [modelName, '/MySubsystem/Kp']);
  ```

- **坑B: 复杂模型用 From/Goto 传递信号，不是直接连线**
  - RL 训练模型等复杂模型中，子系统间通过 Goto/From 模块对广播信号
  - 新添加的子系统**不要尝试从 Inport 连线获取信号**，而应：
    1. 在子系统内部添加 `From` 模块
    2. 设置 `GotoTag` 参数为已有的 Goto 标签名
  ```matlab
  % 在子系统内部用 From 模块获取信号
  add_block('simulink/Signal Routing/From', [subsysPath, '/From_e_angle']);
  set_param([subsysPath, '/From_e_angle'], 'GotoTag', 'e_angle_t');
  ```

- **坑C: 子系统端口与内部模块的对应关系**
  - SubSystem 的 In1 端口在外层和内层是同一个对象
  - 内部 Inport 模块的连线状态会影响外层 `add_line` 的结果
  - 如果内部 Inport 已有连线，从外层 `add_line` 到子系统端口可能冲突
  - **推荐做法**: 先检查内部连线状态，必要时 `delete_line` 清理

- **坑D: add_line 逐步执行，避免连锁失败**
  - 多个 `add_line` 一次性执行时，如果中间某行失败，后续全部不执行
  - **推荐做法**: 用 try-catch 包裹每个 `add_line`，记录失败原因
  ```matlab
  lines = {  % {src, dst} 列表
      'obs_inner/1', 'Reward_exponential/1';
      'Reward_exponential/1', 'Goto_reward/1';
  };
  for i = 1:size(lines, 1)
      try
          add_line(modelName, lines{i,1}, lines{i,2});
          fprintf('OK: %s -> %s\n', lines{i,1}, lines{i,2});
      catch e
          fprintf('FAIL: %s -> %s: %s\n', lines{i,1}, lines{i,2}, e.message);
      end
  end
  ```

- **坑E: 中文路径下 Simulink 模型操作必须用 dir()+fullfile()**
  - `load_system('D:\RL\UH-60_contoller\UH-60_contoller_ptp_final_整理\model.slx')` 会因中文乱码失败
  - **正确做法**: 先 cd 到不含中文的父目录，用 `dir()` 找到中文子目录索引，再用 `fullfile()` 构建
  ```matlab
  cd('D:\RL\UH-60_contoller');
  dirs = dir;  % 列出所有子目录
  targetDir = fullfile('D:\RL\UH-60_contoller', dirs(6).name);  % 用索引避开中文
  cd(targetDir);
  load_system('Train_UH60_RL_controller_inner');  % 用相对路径，无中文问题
  ```

- **坑F: 模型构建完成后必须自动排版**
  - 脚本化建模时，所有模块按 Position 参数放置，如果不精心计算位置，模块会叠在一起
  - **必须在所有模块和连线完成后调用排版**: `Simulink.BlockDiagram.arrangeSystem(modelName)`
  - 顶层模型和每个子系统都需要排版（见 4.5 节）

### 23. 🔴 封装子系统（Masked Subsystem）解析规范（v5.1 固化 — 黑鹰模型实测总结）

> **遇到 `find_system` 只返回自身1个块的 SubSystem？这多半是封装模块！**

**问题本质**：Simulink 模型中存在多层嵌套的封装子系统，其特点是：
- `find_system(path)` 不带 SearchDepth 时对封装子系统只返回自身
- `get_param(block, 'Mask')` 返回 `on`（数值可能是 111 或 110）
- 不能用 `get_param(block, 'Children')` —— 会报错"SubSystem block (mask) 没有名为 'Children' 的参数"
- 不能直接用绝对路径访问内部块 —— 会报错"在系统中找不到模块"

**解析流程**：
1. 检查 Mask 属性确认是封装模块：`get_param(path, 'Mask')`
2. 读取 MaskPrompts 和 MaskVariables 了解封装参数语义
3. 用 `find_system(blockPath, 'SearchDepth', 1)` 逐层深入
4. 对每层重复上述步骤直到没有嵌套 SubSystem
5. 读取 MaskValues 获取参数值

```matlab
% ====== 封装子系统逐层解析标准流程 ======

% 步骤1：检查封装属性
get_param(blockPath, 'Mask')          % 返回 'on' 确认是封装模块
get_param(blockPath, 'MaskType')      % 封装类型名
get_param(blockPath, 'MaskPrompts')   % 封装参数提示文字
get_param(blockPath, 'MaskVariables') % 封装变量名（如 Omega=@1;R=@2;...）

% 步骤2：逐层用 find_system 深入
% 第一层：父容器的直接子块
blks1 = find_system('Rotor  Model', 'SearchDepth', 1);

% 第二层：继续深入嵌套子系统
blks2 = find_system('Rotor  Model/Rotor Model', 'SearchDepth', 1);
% 结果：成功读到 34 个内部块！

% 第三层：进入更深的子系统
blks3 = find_system('Rotor  Model/Rotor Model/Blade Aeroloads Model1', 'SearchDepth', 1);
% 结果：939 个块！完全展开

% 步骤3：读取封装参数值
get_param(blockPath, 'MaskValues')     % 获取所有封装参数的值
get_param(blockPath, 'MaskEnables')    % 哪些参数启用
```

**关键 API**：
- `get_param(path, 'Mask')` — 检查是否有封装（返回 'on' 或数值 111/110）
- `get_param(path, 'MaskType')` — 封装类型名（如 'Rotor Model'）
- `get_param(path, 'MaskPrompts')` — 封装参数的中文/英文提示
- `get_param(path, 'MaskVariables')` — 封装变量名和序号（如 `Omega=@1;R=@2`）
- `get_param(path, 'MaskValues')` — 封装参数当前值
- `find_system(path, 'SearchDepth', 1)` — 只看一层子块

**避坑**：
- ❌ 不要用 `get_param(path, 'Children')` — 封装子系统无此属性，会报错
- ❌ 不要直接拼绝对路径访问内部块 — 会报错找不到模块
- ❌ `find_system(path)` 不带 SearchDepth — 对封装子系统只返回自身
- ✅ 必须逐层用 `find_system` + `SearchDepth=1` 深入
- ✅ 封装变量名中的 `@数字` 表示参数序号，如 `Omega=@1` 表示第1个参数

### 24. [CRITICAL] MATLAB .m 文件编码与命名规则（v6.0 固化 — Part 5 实测总结）

> **.m 文件写入后 MATLAB 解析报"文本字符无效"？多半是编码或命名问题！**

- **坑A: .m 文件中禁止使用 4 字节 UTF-8 emoji**
  - 症状：MATLAB 报错"文本字符无效。请检查不受支持的符号、不可见的字符或非 ASCII 字符的粘贴"
  - 原因：emoji 如 🔴✅❌⚠️ 是 4 字节 UTF-8 编码（`\xf0\x9f...`），MATLAB 解析器不支持
  - **修复**：所有 .m 文件中的 emoji 必须替换为 ASCII 标记
  - 替换对照：🔴→`[CRITICAL]`/`[FIX]`，✅→`[OK]`，❌→`[X]`/`[FAIL]`，⚠️→`[WARN]`

- **坑B: MATLAB struct 字段名不能以下划线 `_` 开头**
  - 症状：同上"文本字符无效"，行号指向 `obj._fieldName` 语句
  - 原因：MATLAB 标识符不能以 `_` 开头，`diagnostics._warning` 是非法字段名
  - **修复**：用 `warningInfo`/`warningMsg` 等合法命名代替 `_warning`/`_msg`

- **坑C: `struct('field', {})` 空 cell 导致 1x0 struct 展开问题（#16 的延伸）**
  - 症状：`diagnostics.zeroCrossings.count` 报"当只允许单一值时，点索引表达式生成包含 0 个值的以逗号分隔的列表"
  - 原因：`struct('count', 0, 'locations', {}, 'suggestion', '')` 中 `{}` 导致 struct 展开为空数组
  - **修复**：和踩坑 #16 同理，**所有 struct 构造必须分步赋值**：
  ```matlab
  % 错误写法：
  s = struct('count', 0, 'locations', {}, 'suggestion', '');
  % 正确写法：
  s = struct();
  s.count = 0;
  s.locations = {};
  s.suggestion = '';
  ```

- **坑D: 修改 .m 文件后必须 `clear functions` 刷新 MATLAB 缓存**
  - 症状：修改了 .m 文件但 MATLAB 仍报旧的错误行号
  - 原因：MATLAB 缓存了旧版函数定义
  - **修复**：执行 `clear functions; rehash toolboxcache;` 刷新缓存

### 25. [CRITICAL] 自我改进触发规则（v7.0 五层智能体自我进化机制）

> **matlab-agent 会随着你的使用不断进化，不仅能学习，还能自主修改自己的源码。**

**自动触发**:
- 当 sl_* 命令执行失败 → Bridge 记录错误上下文到 `.learnings/ERRORS.md`
- 当用户纠正你的 API 用法 → 记录到 `.learnings/LEARNINGS.md`
- 当同一错误出现 >=3 次 → 自动在 SKILL.md 中新增踩坑经验条目
- 当检测到已知反模式 → 主动警告并建议替代方案
- Bridge 层参数格式错误 → `_auto_fix_args()` 尝试自动修正
- API 调用统计 → 识别高频失败 API → 优化提示词优先级
- **[v7.0] 同类错误重复出现 → 自动生成修复规则 → 注入动态规则引擎**
- **[v7.0] AI 可以通过 `sl_self_improve` API 直接修改 .m/.py/.ts 源码**

**用户触发**:
- "记住这个教训" → 记录到 LEARNINGS.md (priority: high)
- "这个 API 改了" → 更新 API 说明书 + 标注弃用
- "总结你的经验" → 输出踩坑经验 Top 10
- "检查有没有过时经验" → 触发定期蒸馏流程
- "能不能/有没有办法..." → 记录到 FEATURE_REQUESTS.md
- **[v7.0] "修复这个 Bug" → AI 通过 `patch_source` 直接修改源码**
- **[v7.0] "添加自动修复规则" → 通过 `add_rule` 注入动态规则引擎**
- **[v7.0] "自动学习" → `auto_learn` 从 ERRORS.md 推断新规则**

**五层自我改进体系**:
```
Layer 1: 被动学习（用户纠正 → 经验沉淀）
  - 用户纠正时自动记录到 .learnings/LEARNINGS.md
  - 纠正3次以上 → 自动提升到 SKILL.md 踩坑经验节
  - 纠正涉及 API 签名 → 自动标注 API 说明书弃用标记

Layer 2: 主动学习（错误分析 → 自动修复）
  - sl_* 命令执行失败 → Bridge 记录完整错误上下文
  - 重复失败(3次) → 自动添加到 ERRORS.md + 生成修复建议
  - 参数格式错误 → _auto_fix_args() 尝试自动修正（5条硬编码+动态规则）
  - Bridge 异常崩溃 → 自动重启 + 记录崩溃上下文

Layer 3: 预测学习（模式识别 → 提前预防）
  - 踩坑模式匹配：新代码命中已知反模式 → 主动提示
  - 版本兼容预检：检测到 R2016a → 自动切换兼容 API
  - 用户习惯学习：用户总是先 inspect 再操作 → 自动预加载
  - 场景感知：检测到仿真任务 → 自动建议 SimulationInput 优先

Layer 4: 系统进化（跨会话 → 持久优化）
  - 踩坑数据库定期蒸馏 → 提取通用规则到 SKILL.md
  - API 调用统计 → 识别高频 API → 优化提示词优先级
  - 常见工作流抽象 → 生成一键工作流模板
  - 退化规则检测 → 过时踩坑经验自动归档

Layer 5: 源码级自我改进（v7.0 新增 — 自由度最高的进化层）
  - 动态规则引擎：运行时可添加/删除/更新自动修复规则（JSON 持久化）
  - 源码补丁：AI 通过 patch_source API 直接修改 .m/.py/.ts 文件
  - 自动学习：从 ERRORS.md 历史自动推断修复规则并注入引擎
  - 规则测试：新规则可先 test_rule 验证再 add_rule 生效
  - 安全保护：只允许修改 skill 目录内文件、只允许白名单扩展名、修改前自动备份
  - 命中统计：每条规则记录 hit_count + last_hit，可查看哪些规则最活跃
```

**Layer 5 核心 API**: `POST /api/matlab/simulink/self_improve`

| action | 说明 | 参数 |
|--------|------|------|
| `list_rules` | 列出所有动态修复规则 | - |
| `add_rule` | 添加新规则 | `rule: {command, field, detect_pattern, fix_action, ...}` |
| `remove_rule` | 删除规则 | `rule_id` |
| `update_rule` | 更新规则 | `rule_id, updates: {...}` |
| `test_rule` | 测试规则（不实际应用） | `rule, test_params` |
| `patch_source` | 直接修改源码文件 | `file_path, old_content, new_content, description` |
| `get_errors` | 获取错误历史 | - |
| `auto_learn` | 自动从 ERRORS.md 学习新规则 | - |
| `stats` | 获取自我改进统计 | - |

**动态规则格式**:
```json
{
  "id": "RULE-001",
  "command": "sl_bus_create",
  "field": "elements",
  "detect_pattern": "list_of_str",
  "fix_action": "convert_to_dict",
  "source": "auto_learned",
  "created_at": "2026-04-18T20:00:00",
  "hit_count": 3,
  "last_hit": "2026-04-18T20:30:00"
}
```

**detect_pattern 可选值**: `list_of_str` | `dict_instead_of_str` | `missing_prefix` | `wrong_type_bool` | `missing_field` | `custom`

**fix_action 可选值**: `convert_to_dict` | `prepend_model` | `set_default` | `bool_to_dict` | `custom`

**知识库文件位置**:
```
skills/matlab-agent/
├── .learnings/                      # 自我改进知识库
│   ├── LEARNINGS.md                 # 学习记录（纠正/知识盲区/最佳实践）
│   ├── ERRORS.md                    # 错误记录（命令失败/异常/Bridge 崩溃）
│   ├── FEATURE_REQUESTS.md          # 用户需求记录
│   └── auto_fix_rules.json          # [v7.0] 动态修复规则库（Layer 5 持久化）
├── references/
│   ├── sl_toolbox_api_guide.md      # API 说明书（含弃用标注）
│   └── pitfall-database.md          # 踩坑数据库（结构化，可查询）
└── SKILL.md                         # 智能体提示词（含沉淀的踩坑经验）
```

**自动提升规则**:
- 同一 Pattern-Key 的记录 >=3 条，跨越至少 2 个不同会话，30天内仍有新记录 → 提升到 SKILL.md §22/§24
- 踩坑类 → SKILL.md §22/§24 踩坑大全（新增编号条目）
- API 签名类 → sl_toolbox_api_guide.md 标注 [DEPRECATED] + 替代方案
- 用户偏好类 → SKILL.md 工作流节
- 版本兼容类 → sl_best_practices.m 版本相关清单
- 提升后原始 LEARNINGS.md 条目 Status → promoted
- **[v7.0] 重复错误 >=3 次 → 自动通过 `auto_learn` 生成动态修复规则**
- **[v7.0] 动态规则命中 >=10 次 → 考虑硬编码到 _auto_fix_args 并移除动态规则**

### 26. [CRITICAL] 踩坑经验自动沉淀流程（v6.1）

> **每次踩坑都是一次学习机会。以下流程确保经验不丢失。**

### 27. [CRITICAL] 强制验证-执行循环（v8.0 — 解决 AI 建模不检查结果的核心问题）

> **AI 大模型每步建模操作后不检查模型状态，模型没建完整就汇报完成。v8.0 从底层强制注入验证。**

**问题本质**：AI 调用 `sl_add_block` / `sl_add_line` 等写操作后，只能看到 API 返回的截断 JSON，无法确认：
- 模块是否真正存在于模型中
- 端口是否已连接
- 模型是否有未连接端口
- goto/from 是否配对
- 子系统是否有接口

**v8.0 解决方案 — Bridge 层自动验证（不可绕过）**：

1. **底层自动注入**：每个写操作（sl_add_block, sl_add_line, sl_set_param, sl_delete, sl_replace_block, sl_subsystem_create, sl_subsystem_mask, sl_config_set, sl_bus_create, sl_block_position, sl_auto_layout, sl_signal_config, sl_signal_logging, sl_callback_set）在 Bridge 层执行成功后，自动调用 `sl_model_status_snapshot` 获取模型状态，注入 `_verification` 字段
2. **AI 不可绕过**：验证结果由 Bridge 层自动注入，AI 无法跳过或禁用
3. **Controller 层转换**：`executeBridgeCommandWithVerify` 将 `_verification` 转为 AI 可读的 `reportComment` 文本
4. **验证结果格式**：

```
%% -- Auto Verification --
%% [VERIFIED] 3/4 checks passed
%%   [PASS] block_exists: model/Gain exists (Type: Gain)
%%   [PASS] block_exists: model/Sum exists (Type: Sum)
%%   [FAIL] all_ports_connected: 2 unconnected port(s) on model/Sum
%%   [PASS] model_unconnected_ports: 0 unconnected port(s) in model
%% [WARNING] model/Sum Port-1(input) is UNCONNECTED
%% [ACTION] Add signal line to connect model/Sum input port 1
```

**AI 建模强制流程（v8.0 必须遵守！）**：

```
1. 每个写操作返回后，必须检查 _verification 字段或 reportComment
2. 如果 verifyStatus === 'ISSUES_FOUND'：
   a. 读取 warnings 和 suggestions
   b. 根据建议修复问题（如添加缺失连线）
   c. 修复后再次检查验证结果
3. 不允许在有未连接端口时声明建模完成
4. 使用 GET /api/matlab/simulink/model_status?modelName=xxx 主动查询模型状态
5. 建模完成后必须调用 sl_model_status_snapshot 确认：
   - 所有端口已连接
   - 无 goto/from 配对错误
   - 子系统有完整接口
```

**验证检查项说明**：

| 操作类型 | 自动检查项 |
|----------|-----------|
| sl_add_block / sl_replace_block / sl_bus_create / sl_block_position | 模块存在性、端口连接状态、模型未连接端口总数 |
| sl_add_line | 源端口已连接、目标端口已连接、连线完整性 |
| sl_set_param / sl_signal_config / sl_signal_logging / sl_callback_set / sl_config_set | 参数是否生效 |
| sl_subsystem_create / sl_subsystem_mask | 子系统存在性、接口完整性（In1/Out1） |
| sl_delete | 模块确实已删除 |
| sl_auto_layout | 模型完整性（块数不变、线数不变） |

**手动查询 API**：
- `POST /api/matlab/simulink/model_status` — 获取模型完整状态快照
- `GET /api/matlab/simulink/model_status?modelName=xxx&format=comment` — 轻量查询（AI 可解析注释格式）
- `GET /api/matlab/simulink/model_status?modelName=xxx&depth=0` — 全深度扫描（含子系统内部）

**错误发生时（自动）**:
1. `_handle_sl_command()` 执行失败 → 调用 `_log_error_context()` 记录到 `.learnings/ERRORS.md`
2. Bridge 检测到参数格式常见错误 → `_auto_fix_args()` 尝试自动修正
3. 修正成功 → 在返回结果中注入 `autoFixes` 字段，告知 AI 修正了什么
4. 修正失败 → 原样返回错误，让 AI 根据错误信息自行处理

**用户纠正时（AI 行为指引）**:
1. 识别纠正信号关键词："不对/错了/应该是/记住/下次别犯/总是..."
2. 提取纠正内容：哪个 API 用错了？正确做法是什么？
3. 生成 Pattern-Key（如 `pitfall.struct_expand`、`pitfall.r2016a_compat`）
4. 追加记录到 `.learnings/LEARNINGS.md`
5. 如果同一 Pattern-Key 已存在，更新 Recurrence-Count + Last-Seen
6. 如果 Recurrence-Count >= 3，触发提升流程

**定期蒸馏（用户触发或每月）**:
1. 扫描 `.learnings/LEARNINGS.md` 中 Status=pending 的条目
2. 评估：出现次数 >=3 且30天内仍有记录 → 提升到 SKILL.md
3. 30天无新记录 → 标记 stale
4. 90天无新记录 → 归档到 `references/pitfall-database.md` COLD 区
5. 扫描 SKILL.md 踩坑节：90天内未被引用 → 标记待归档
6. 已有自动修复机制 → 标注 [AUTO-FIXED]

**参数自动修正规则（`_auto_fix_args()` 已实现的修正）**:

| 错误类型 | 检测方式 | 自动修正 |
|---------|---------|---------|
| params 是 Name-Value 对 | `params` 含奇数个字符串元素 | 自动 `struct('k1','v1','k2','v2')` 转换 |
| config 是 Name-Value 对 | `config` 含奇数个字符串元素 | 同上 |
| sl_add_line srcBlock+srcPort | 传入 srcBlock 和 srcPort 分离 | 自动合并为 'srcBlock/srcPort' |
| sl_best_practices 缺参数 | 无参数调用 | 自动设置 shortName='' |
| blockPath 缺模型前缀 | 路径不含 '/' | 从 modelName 自动补全 |

### 28. [CRITICAL] 标准化建模工作流（v9.0 — 代码底层强制执行）

> **v8.0 解决了"每步操作后不检查"的问题，v9.0 解决了"不知道下一步该做什么"和"忘记排版"的问题。**

**三层迭代建模**：

一、建立大框架（顶层 In/Out、子系统占位、总线信号占位）
   - 迭代：建模块→[AUTO]检查→设参数→[AUTO]检查→连线→[AUTO]检查→[AUTO]In/Out检查→[AUTO]Goto/From检查→[AUTO]排布

二、填充每个子系统（内部模块和连线）
   - 迭代：同上（在子系统内部执行）

三、总体检查→设仿真参数→运行仿真→检查结果→（不符合则回到一）

**代码强制机制（不可绕过）**：
1. **自动排版**：连续 3 次 add 操作后自动触发 arrangeSystem（5 秒防抖）
2. **工作流状态**：每次操作返回 `_workflow` 字段，告知 AI 当前阶段和建议下一步
3. **阶段检测**：Bridge 自动检测 framework→subsystem→simulation 的阶段转换
4. **排布验证**：排版后自动验证模型完整性（块数不变）
5. **子系统队列**：自动检测空子系统，生成 subsystemQueue 引导 AI 按序填充

**API 返回新增字段**：
- `_auto_layout`: `{ arranged, phase, integrityOk, message, reason }` — 自动排版状态
- `_workflow`: `{ model, phase, phaseStep, nextSuggestedAction, subsystemQueue, subsystemDone, checksRemaining }` — 工作流状态

**AI 必须遵守**：
- 必须遵循 `_workflow.nextSuggestedAction` 的建议
- 不允许在有未连接端口时声明建模完成
- 排版由代码自动触发，AI 不需要主动调用 sl_auto_layout
- 子系统必须先建空壳（第一层），再填充内容（第二层）

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
│   │   ├── index.ts            # Express 服务器入口（含 v5.0 quickstart API）
│   │   ├── matlab-controller.ts # MATLAB 控制器（v9.0: 工作流状态 + 自动排版摘要）
│   │   ├── system-prompts.ts   # AI 系统提示词（v9.0: 三层迭代标准化建模工作流）
│   │   └── db.ts               # SQLite 数据库
│   ├── matlab-bridge/
│   │   └── matlab_bridge.py    # Python-MATLAB 桥接（v9.0: 工作流状态机 + 自动排版 + 阶段追踪）
│   ├── src/                    # React 前端
│   │   ├── App.tsx
│   │   ├── components/
│   │   │   └── MATLABStatusBar.tsx
│   │   ├── hooks/
│   │   │   └── useAgents.ts
│   │   └── config.ts
│   ├── package.json
│   ├── start.bat                # ⭐ 一键启动（最可靠）
│   ├── ensure-running.bat       # AI Agent 专用确保运行脚本
│   ├── start-matlab-agent.ps1   # PowerShell 启动脚本
│   ├── quick-start.bat          # CMD 快速启动
│   ├── quick-start.ps1          # PowerShell 快速启动
│   ├── TROUBLESHOOTING.md
│   └── README.md
└── references/
    ├── sl_toolbox_api_guide.md   # 🔴 sl_toolbox API 说明书（23 个函数完整参考）
    ├── troubleshooting.md
    └── matlab-bridge-api.md
```

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine（Engine 模式） / matlab CLI（回退模式）
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
