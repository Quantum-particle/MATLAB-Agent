# MATLAB Agent Skill

> AI 驱动的 MATLAB/Simulink 开发助手，打通 AI 智能体与 MATLAB 闭园开发环境的隔阂。

## 触发条件

当用户提到以下关键词时自动加载：
- MATLAB、M 脚本、Simulink、控制律设计、动力学建模
- 信号处理、频域分析、Bode图、阶跃响应
- .m 文件、.mat 数据、.slx 模型
- MATLAB 工作区、MATLAB Engine、PID 调参

## 能力概述

### 核心架构 (v5.0)
- **diary 输出捕获**: 用 `diary()` + `eng.eval()` 替代 `evalc()`，彻底解决引号双写、中文路径乱码问题
- **一键启动**: quickstart API 一步完成 MATLAB_ROOT 配置 + Engine 启动 + 项目目录设置
- **手动配置 MATLAB 路径**: 首次启动时需用户提供 MATLAB 安装路径（交互式引导或 API 配置）
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
cmd /c "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\start.bat"
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
cmd /c "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
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

首次启动时，一键脚本会自动交互式引导用户输入 MATLAB 安装路径。
也可以通过以下方式手动配置：

```bash
# 方法1: 环境变量
set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b

# 方法2: API 配置（路径会持久化到配置文件）— 用 PowerShell 变量构造法避免 $ 变量展开和转义地狱
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"

# 方法3: 一键快速启动（v5.0 推荐，AI agent 专用）
powershell -Command "$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\RL\my_project'} | ConvertTo-Json -Compress; Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))"
```

### 3. API 速查

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/health` | 服务器健康检查 |
| GET | `/api/matlab/status` | MATLAB 状态（快速） |
| GET | `/api/matlab/status?quick=false` | MATLAB 完整检查（含 Engine） |
| GET | `/api/matlab/config` | 获取 MATLAB 配置 |
| POST | `/api/matlab/config` | 设置 MATLAB 根目录 |
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
| POST | `/api/matlab/simulink/workspace/clear` | 清空模型工作区 |
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

- **坑5: 含中文/空格/括号的路径（用户目录 `<USERNAME>`、`Program Files(x86)`）**
  - 症状：PowerShell 中 `cd` 到含中文路径可能失败
  - 修复：用 `cmd /c` 包裹命令，或用 `Push-Location`/`Pop-Location`

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
3. 如未运行 → 执行: cmd /c "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
4. 等待 ensure-running 返回 0
5. 使用 quickstart API 一步到位: POST /api/matlab/quickstart
```

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
  - 原因：新建 SubSystem 时，默认的 In1→内部Out1、内部In1→Out1 已被系统自动连线
  - 修复：先 `delete_line` 清除默认连线，再 `add_line`
  ```matlab
  % 删除子系统内部的默认连线
  subsysPath = [modelName, '/MySubsystem'];
  delete_line(subsysPath, 'In1/1', 'Out1/1');  % 清除默认 In1→Out1 连线
  % 然后再添加自己的连线
  add_line(subsysPath, 'In1/1', 'MyBlock/1');
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
│   │   ├── matlab-controller.ts # MATLAB 控制器（v5.0: diary + 相对路径修复 + quickstart）
│   │   ├── system-prompts.ts   # AI 系统提示词（v5.0: Simulink 建模经验固化）
│   │   └── db.ts               # SQLite 数据库
│   ├── matlab-bridge/
│   │   └── matlab_bridge.py    # Python-MATLAB 桥接（v5.0: diary 替代 evalc + UTF-8 输出）
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
    ├── troubleshooting.md
    └── matlab-bridge-api.md
```

## 技术栈

- **后端**: Express 4 + TypeScript 5 + CodeBuddy Agent SDK
- **MATLAB 控制**: Python matlabengine（Engine 模式） / matlab CLI（回退模式）
- **前端**: React 18 + TDesign + Vite 5 + TypeScript
- **数据库**: SQLite (better-sqlite3)
