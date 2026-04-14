# MATLAB Agent 故障排除指南

> 版本: 5.1.0 | 最后更新: 2026-04-10

本文档汇总了 MATLAB Agent 开发和运行中遇到的所有问题及其解决方案。

---

## 目录

0. [**Windows 启动踩坑大全（最优先！）**](#0-windows-启动踩坑大全)
1. [MATLAB Engine 输出泄漏](#1-matlab-engine-输出泄漏)
2. [JSON 解析失败](#2-json-解析失败)
3. [中文乱码 (GBK)](#3-中文乱码-gbk)
4. [中文路径不支持](#4-中文路径不支持)
5. [MATLAB Engine 启动慢](#5-matlab-engine-启动慢)
6. [Simulink 模型遮蔽警告](#6-simulink-模型遮蔽警告)
7. [timeseries API 兼容性](#7-timeseries-api-兼容性)
8. [函数命名错误](#8-函数命名错误)
9. [MATLAB 引号转义](#9-matlab-引号转义)
10. [端口被占用](#10-端口被占用)
11. [Python 找不到](#11-python-找不到)
12. [超时问题](#12-超时问题)
13. [Windows stdin 中文编码](#13-windows-stdin-中文编码)
14. [中文路径 set_project_dir 报错](#14-中文路径-set_project_dir-报错)
15. [Skill 目录缺少 node_modules](#15-skill-目录缺少-node_modules)
16. [Python Engine 版本不兼容](#16-python-engine-版本不兼容)
17. [MATLAB 路径未配置](#17-matlab-路径未配置)
18. [阻塞式启动导致超时](#18-阻塞式启动导致超时)
19. [evalc 内层引号未双写导致语法错误](#19-evalc-内层引号未双写导致语法错误)
20. [预热超时但不影响功能](#20-预热超时但不影响功能)
21. [POST /api/matlab/config 二次调用返回 500](#21-post-apimatlabconfig-二次调用返回-500)
22. [PowerShell POST 请求 $ 变量展开吞噬问题](#22-powershell-post-请求--变量展开吞噬问题)
23. [Simulink 建模深坑大全](#23-simulink-建模深坑大全-v51-任务4-实测总结)
24. [封装子系统（Masked Subsystem）内部结构无法读取](#24-封装子系统masked-subsystem内部结构无法读取-v51-黑鹰模型实测)

---

## 0. Windows 启动踩坑大全

> **启动不了就什么都干不了！这一节最优先！**

### 0.1 node_modules 缺失导致启动失败

**症状**: `npx tsx server/index.ts` 报 `Error: Cannot find module 'express'` 或直接静默退出无输出。

**根因**: Skill 目录的 `app/node_modules/` 可能不存在（首次部署、git clone 后、清理后等）。

**解决方案**: 启动前必须检查并安装：
```bash
cd "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app"
if not exist "node_modules" npm install --production
```
一键脚本 `start.bat` 和 `ensure-running.bat` 已自动处理此步骤。

### 0.2 Windows 下 npx 不是可执行文件

**症状**: PowerShell 中 `Start-Process -FilePath "npx"` 报 "npx is not a valid Win32 application"。

**根因**: Windows 下 `npx` 实际是 `npx.cmd` 批处理脚本，不是 .exe。`Start-Process` 不能直接执行 .cmd。

**解决方案**: 
- 在 `cmd /c` 中执行：`cmd /c "start /B npx tsx server/index.ts"`
- 或用 PowerShell：`Start-Process cmd -ArgumentList "/c npx tsx server/index.ts" -WindowStyle Hidden`

### 0.3 阻塞式启动导致 AI agent 超时

**症状**: AI agent 执行 `npx tsx server/index.ts` 后命令永远不返回，超时卡死。

**根因**: MATLAB Engine 预热需要 30-90 秒，在此期间 Node.js 进程阻塞终端。

**解决方案**: 必须后台启动 + 轮询健康检查：
```bash
# 后台启动
start /B cmd /c "npx tsx server/index.ts > %TEMP%\matlab-agent-out.log 2>&1"

# 轮询等待（用 PowerShell 替代 curl，避免 Windows 输入重定向问题）
:wait
powershell -Command "try { Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -UseBasicParsing -TimeoutSec 3; exit 0 } catch { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 timeout /t 2 >nul & goto wait
```

### 0.4 🔴 旧进程残留占端口 3000（启动失败首要原因！）

> **这是启动失败最常见的原因！启动前必须确保端口 3000 干净无残留！**

**症状**: 启动时 `EADDRINUSE: address already in use :::3000`，服务器启动失败。

**根因**: 上次 MATLAB Agent 服务未正常关闭，Node.js 进程残留在端口 3000 上。Windows 的 TIME_WAIT 机制也会导致即使杀掉进程后端口仍暂时不可用。

**完整解决方案**（启动前必须执行）：
```cmd
REM Step 1: 查找占用端口 3000 的所有进程
netstat -ano | findstr ":3000" | findstr "LISTENING"

REM Step 2: 逐个杀掉对应 PID
for /f "tokens=5" %a in ('netstat -ano ^| findstr ":3000 " ^| findstr "LISTENING"') do taskkill /F /PID %a

REM Step 3: ⚠️ 等待 2-3 秒确认端口释放（关键！不能省！）
timeout /t 3

REM Step 4: 再次确认端口已干净
netstat -ano | findstr ":3000" | findstr "LISTENING"
REM 如果仍有输出，说明端口尚未完全释放，再等几秒

REM Step 5: 确认端口干净后再启动服务
start /B cmd /c "npx tsx server/index.ts > %TEMP%\matlab-agent-out.log 2>&1"
```

**PowerShell 版本**：
```powershell
# 查找并杀掉端口 3000 的进程
$old = netstat -ano | Select-String ":3000" | Select-String "LISTENING"
if ($old) {
    $old | ForEach-Object {
        if ($_ -match '\d+$') { Stop-Process -Id $Matches[0] -Force -ErrorAction SilentlyContinue }
    }
    # ⚠️ 必须等待端口释放！
    Start-Sleep -Seconds 3
    # 确认端口已干净
    $check = netstat -ano | Select-String ":3000" | Select-String "LISTENING"
    if ($check) { Write-Warning "端口 3000 仍被占用！请等待后再试" }
}
```

**⚠️ 关键提醒**：
- 杀掉进程后 **不要立即启动新服务**！必须等待 2-3 秒让操作系统完全释放端口
- Windows 的 TIME_WAIT 状态默认持续 2 分钟，但 LISTENING 端口杀掉进程后通常 1-3 秒即可释放
- 如果多次杀进程后端口仍被占用，可能是系统级 TIME_WAIT，等待 30 秒后重试
- **一键脚本已自动处理**: `start.bat` 和 `ensure-running.bat` 会自动杀进程 → 等待端口释放 → 确认干净 → 再启动

### 0.5 含中文/空格/括号的路径问题

**症状**: 路径如 `C:\Users\<USERNAME>\` 或 `D:\Program Files(x86)\MATLAB2023b` 导致脚本失败。

**解决方案**: 
- CMD 脚本中用引号包裹路径：`cd /d "%~dp0"`（`%~dp0` 自动含引号处理）
- PowerShell 中用 `Push-Location` / `Pop-Location`
- API 调用中用 UTF-8 编码：`[System.Text.Encoding]::UTF8.GetBytes($json)`

### 0.6 Python Bridge spawn 失败

**症状**: `spawn('python', [...]) Error: spawn python ENOENT`。

**根因**: Python 不在系统 PATH 中，或 Python 命令名不是 `python`。

**解决方案**:
- 确保 `python` 在 PATH 中：`where python`
- 如果只有 `python3`，创建符号链接或添加 PATH
- Node.js 端 `matlab-controller.ts` 使用 `spawn('python', ...)` — 需 `python` 在 PATH

### 0.7 AI Agent 标准启动流程

```
0. 🔴 端口清理（最优先！启动前必须确保环境干净！）:
   - ensure-running.bat 已自动处理（杀进程 → 等端口释放 → 确认干净 → 再启动）
   - 手动: netstat -ano | findstr ":3000" | findstr "LISTENING" → taskkill /F /PID <pid> → 等2-3秒
1. 检查服务是否已运行: powershell -Command "try { Invoke-RestMethod -Uri 'http://localhost:3000/api/health' -TimeoutSec 5 } catch { Write-Host 'FAIL' }"
2. 如已运行 → 直接使用 quickstart API
3. 如未运行 → 执行: cmd /c "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
4. 等待 ensure-running 返回退出码 0
5. 使用 quickstart API: POST /api/matlab/quickstart
   （必须用 ConvertTo-Json 变量构造法）
   $b = @{matlabRoot='D:\Program Files(x86)\MATLAB2023b';projectDir='D:\your_project'} | ConvertTo-Json -Compress
   Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

---

## 1. MATLAB Engine 输出泄漏

### 症状
Node.js 端收到混合了 MATLAB 输出的 JSON，解析失败。
```
42
0.5000
{"status":"ok","stdout":"..."}  <- JSON 被非 JSON 内容污染
```

### 根因
使用 `eng.eval(cmd, nargout=0)` 时，MATLAB 的 `disp()`/`fprintf()` 输出直接泄漏到 Python stdout，与 JSON 响应混在一起。

### 解决方案
使用 `evalc` + `nargout=1` 捕获所有输出到字符串返回值：
```python
# 错误（输出泄漏）
self.eng.eval("run('script');", nargout=0)

# 正确（输出捕获到变量）
output = self.eng.eval("evalc('run(''script'');')", nargout=1)
```

---

## 2. JSON 解析失败

### 症状
```
SyntaxError: Unexpected token 4 in JSON at position 0
```
或
```
桥接脚本未返回有效 JSON
```

### 根因
同 [问题1](#1-matlab-engine-输出泄漏)，stdout 不纯净。

### 解决方案
1. 确保 `matlab_bridge.py` 使用 `evalc + nargout=1`
2. 确保脚本中没有多余的 `print()` 语句
3. Node.js 端已添加回退正则提取作为兜底

---

## 3. 中文乱码 (GBK)

### 症状
MATLAB 输出中的中文显示为乱码：`鎴愬姛` 或 `UnicodeDecodeError`

### 根因
Windows 默认使用 GBK 编码，MATLAB 输出为 UTF-8，subprocess 捕获时编码不匹配。

### 解决方案
**Node.js 端** (matlab-controller.ts):
```typescript
env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUNBUFFERED: '1' }
```

**Python 端** (matlab_bridge.py):
```python
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
```

---

## 4. 中文路径不支持

### 症状
```
Error using run
File "脚本.m" not found.
```

### 根因
MATLAB `run()` 函数不支持包含中文字符的路径。

### 解决方案
先 `cd()` 到脚本所在目录，再 `run('filename')`:
```matlab
cd('D:/MATLAB_Workspace');  % 只含英文的路径
run('myscript');             % 只传文件名，不含路径
```

Python 桥接脚本已自动处理此逻辑。

---

## 5. MATLAB Engine 启动慢

### 症状
Engine API 模式首次命令需要 8+ 秒。

### 原因
MATLAB Engine 每次启动一个完整的 MATLAB 实例，约 8 秒（固有开销，无法优化）。

### 当前方案
常驻模式下 Engine 在进程生命周期内保持，首次启动后后续命令仅 ~0.1s。

---

## 6. Simulink 模型遮蔽警告

### 症状
evalc 捕获的输出中包含大量 HTML 标签：
```html
<div class="warning">模型 'xxx' 已被遮蔽...</div>
```

### 解决方案
```matlab
% 创建前清理
close_system(modelName, 0);
bdclose(modelName);

% 抑制警告
warning('off', 'Simulink:Engine:MdlFileShadowing');
warning('off', 'Simulink:LoadSave:MaskedSystemWarning');

% Python 端用正则清理残留
import re
output = re.sub(r'<[^>]+>', '', output)
```

---

## 7. timeseries API 兼容性

### 症状
```
Error using .Values
No public property 'Values' for class 'timeseries'.
```

### 根因
不同 MATLAB 版本中 `timeseries` 对象属性不同。

### 解决方案
```matlab
simoutData = simOut.get('simout');
if isprop(simoutData, 'Values')
    y = simoutData.Values.Data;
else
    y = simoutData.Data;
end
```

---

## 8. 函数命名错误

### 症状
```
Error: Function name '_helper' is not valid.
```

### 根因
MATLAB 函数名不能以下划线 `_` 开头。

### 规则
- 必须以字母开头
- 可包含字母、数字、下划线
- 文件名必须与函数名一致

---

## 9. MATLAB 引号转义

### 症状
```
Error: Unexpected MATLAB expression
```

### 规则
从 Python 调用 MATLAB Engine `eval()` 时的引号规则：

| Python 字符串 | MATLAB 实际看到 |
|---|---|
| `"evalc('disp(42)')"` | `evalc('disp(42)')` |
| `"evalc('cd(''path'')')"` | `evalc('cd('path')')` |
| `"evalc(['disp(42);'])"` | ❌ 方括号+引号混合不工作 |

**核心规则**: Python 双引号包裹，MATLAB 内部单引号用 `''` 转义。

---

## 10. 端口被占用

### 症状
```
Error: listen EADDRINUSE: address already in use :::3000
```

> ⚠️ 这是启动失败最常见的原因！完整解决方案见 [0.4 旧进程残留占端口 3000](#04-🔴-旧进程残留占端口-3000启动失败首要原因)

### 快速解决方案
```powershell
# 查找占用进程
netstat -ano | findstr ":3000" | findstr "LISTENING"

# 杀死进程
taskkill /PID <PID> /F

# ⚠️ 杀完后等 2-3 秒再启动！
```

---

## 11. Python 找不到

### 症状
```
Error: spawn python ENOENT
```

### 解决方案
确保 Python 已安装并添加到系统 PATH：
```powershell
python --version
```

> CLI 回退模式不要求 Python，但 Engine 模式必须安装 Python 和 matlabengine。

---

## 12. 超时问题

### 症状
```
MATLAB 桥接执行超时（120秒）
```

### 当前超时配置
| 操作 | 超时 |
|------|------|
| M 脚本执行 | 120s |
| Simulink 创建 | 120s |
| Simulink 仿真 | 300s |
| 安装检查 | 60s |

### 解决方案
- 简单脚本: 检查是否有死循环或长时间计算
- Simulink 仿真: 复杂模型可能需要更长时间，考虑简化模型
- Engine 启动: 首次调用含 ~8s Engine 启动，属正常范围

---

## 13. Windows stdin 中文编码

### 症状
```json
{"status":"error","message":"[WinError 123] 文件名、目录名或卷标语法不正确。: 'D:\\RL\\xxx\\xxx_ptp_final_??'"}
```
路径中的中文变成 `??`。

### 根因
Windows 下 Python 的 `sys.stdin` 默认使用 GBK 编码。`for line in sys.stdin` 迭代时，行内容被 GBK 解码导致 UTF-8 中文乱码。

### 解决方案
在 `matlab_bridge.py` 的 `server_mode()` 中，改用二进制模式读取 stdin：
```python
# 替代: for line in sys.stdin:
stdin_buffer = sys.stdin.buffer
for raw_line in stdin_buffer:
    try:
        line = raw_line.decode('utf-8').strip()
    except UnicodeDecodeError:
        line = raw_line.decode('gbk', errors='replace').strip()
```

同时在文件开头添加 stdin reconfigure 作为第一道防线：
```python
if sys.stdin.encoding != 'utf-8':
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
```

---

## 14. 中文路径 set_project_dir 报错

### 症状
设置含中文的项目目录时，即使路径存在也报错 `WinError 123`。

### 根因
`set_project_dir()` 在路径不存在时调用 `os.makedirs()`，当路径含中文且 stdin 编码异常时，传入的路径字符串已损坏。

### 解决方案
不再尝试创建目录，改为检查后返回错误：
```python
def set_project_dir(dir_path):
    dir_path = os.path.abspath(dir_path)
    if not os.path.exists(dir_path):
        return {"status": "error", "message": f"目录不存在: {dir_path}"}
    _project_dir = dir_path
```

---

## 15. Skill 目录缺少 node_modules

### 症状
从 Skill 目录启动 `npm run dev` 报 `concurrently is not recognized`。

### 根因
Skill 打包时排除了 `node_modules`。

### 解决方案
在 `app/` 目录下运行 `npm install`，或用 Windows Junction 链接共享已有 node_modules：
```powershell
cmd /c mklink /J "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\node_modules" "<项目目录>\node_modules"
```
Junction 不需要管理员权限。

---

## 16. Python Engine 版本不兼容 (v4.0 新增)

### 症状
```
ImportError: No module named matlab.engine
```
或
```
matlabengine 与 MATLAB 版本不匹配
```

### 根因
`matlabengine` 严格版本绑定，例如 R2016a 的 Engine 只支持 Python 2.7/3.3-3.5。

### 解决方案
v4.0 新增 CLI 回退模式，自动检测 Engine 兼容性，不兼容时切换到：
- `matlab -batch`（R2019a+）
- `matlab -r ... -nosplash -nodesktop -wait`（旧版本）

**限制**: CLI 模式下变量不跨命令保持，每次执行独立。

---

## 17. MATLAB 路径未配置 (v4.1 新增)

### 症状
启动脚本提示：
```
⚠️ MATLAB 路径未配置！warmup 状态: failed
请输入 MATLAB 安装根目录（例如 D:\Program Files\MATLAB\R2023b）：
```

### 根因
首次使用，既没有环境变量 `MATLAB_ROOT`，也没有配置文件。

### 解决方案
任选以下方式之一：

1. **交互式输入**：启动脚本会引导你输入
2. **环境变量**：`set MATLAB_ROOT=D:\Program Files\MATLAB\R2023b`
3. **API 配置**（必须用 ConvertTo-Json 变量构造法，避免 $ 变量被展开）：
   ```powershell
   $b = @{matlabRoot='D:\Program Files\MATLAB\R2023b'} | ConvertTo-Json -Compress
   Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
   ```

**优先级**: 环境变量 > 配置文件(`data/matlab-config.json`) > 交互式输入

---

## 18. 阻塞式启动导致超时 (v4.0 血泪教训)

### 症状
使用 `npx tsx server/index.ts` 或 `npm run dev` 直接运行后，命令卡住不返回。

### 根因
MATLAB Engine 预热需要 30-90 秒，阻塞式启动会导致命令执行超时卡死。

### 解决方案
**必须后台启动 + 轮询健康检查**：

```powershell
# 后台启动
cmd /c "start /B npx tsx server/index.ts"

# 轮询健康检查
# GET /api/health 返回的 warmup 字段：
#   warming_bridge → warming_engine → ready / failed
```

**一键脚本**：`start-matlab-agent.ps1` 封装了完整流程。

---

## 快速诊断清单

遇到问题时按此顺序排查：

1. 🔴 **端口 3000 是否被占用？**（最优先！`netstat -ano | findstr ":3000"`，如有则先杀进程并等待端口释放）
2. ✅ MATLAB 是否已安装？（通过 `/api/matlab/config` 检查配置路径）
3. ✅ Python 是否可用？（`python --version`，CLI 模式不要求）
4. ✅ MATLAB Engine API 是否已安装？（`python -c "import matlab.engine"`）
5. ✅ 是否用阻塞式启动？（必须后台启动 + 轮询）
6. ✅ 脚本文件路径是否含中文？
7. ✅ 函数名是否以下划线开头？
8. ✅ 查看 `/api/health` 中 `warmup` 字段是否为 `ready`
9. ✅ Simulink 建模：模块是否已排版？端口连线是否冲突？信号是否通过 From/Goto 传递？

---

## 19. evalc 内层引号未双写导致语法错误 (v4.1 血泪教训)

### 症状
```json
{"status":"error","message":"MATLAB 执行错误: Error: Expected end of expression."}
```
Simulink 模型工作区 API（get/set/clear）调用返回 MATLAB 语法错误。

### 根因
Python `evalc('...')` 中，内层 MATLAB 单引号会被 Python 识别为字符串结束符，导致引号嵌套冲突。
- ❌ 错误：`evalc('get_param('model', 'ModelWorkspace')')` → MATLAB 看到引号提前闭合
- ✅ 正确：`evalc('get_param(''model'', ''ModelWorkspace'')')` → MATLAB 看到 `get_param('model', 'ModelWorkspace')`

### 解决方案
在 `matlab_bridge.py` 中，所有 evalc 包裹的命令，内层单引号必须双写 `''`：
- model_name 中可能包含单引号时也需要双写：`mn = model_name.replace("'", "''")`
- 字符串字面量如 `'ModelWorkspace'` 写成 `''ModelWorkspace''`

### 影响
v4.1 的 Simulink 模型工作区 API（`get_simulink_workspace_vars`、`set_simulink_workspace_var`）已修复此问题。

---

## 20. 预热超时但不影响功能 (v4.1 经验)

### 症状
启动脚本显示 `⚠️ Warmup timeout after 120s`，但 `warmup` 状态仍为 `warming_engine`。

### 根因
MATLAB Engine 启动受系统负载、MATLAB 版本、Python 兼容性等影响，预热时间不可控。

### 解决方案
- **预热超时不是致命错误**：服务器仍在运行，功能请求会触发延迟初始化
- **启动脚本**：`start-matlab-agent.ps1` 预热超时后输出黄色警告，`exit 0`
- **API 层**：Node.js 预热超时标记 `warmupStatus = 'failed'`，但服务器继续运行
- **Python 层**：`get_engine()` 带线程超时，超时自动切换到 CLI 回退模式
- **最差情况**：自动降级到 CLI 模式（变量不跨命令保持）

---

## 21. POST /api/matlab/config 二次调用返回 500 (v4.1 修复)

### 症状
首次调用 `POST /api/matlab/config` 成功，但再次调用同一路径返回 500 错误。

### 根因
`restartBridge()` 被直接 `await`，Engine 已在运行时重启耗时 30+ 秒，导致 HTTP 响应超时。

### 解决方案
`restartBridge()` 改为后台异步 `.catch()`，不阻塞 HTTP 响应：
```typescript
// ❌ 旧代码
await matlab.restartBridge();
// ✅ 新代码
matlab.restartBridge().catch(err => console.warn(...));
```

### 注意
二次调用同一路径不会重启桥接（因为路径未变），restartBridge 是幂等的。

---

## 22. 🔴 PowerShell POST 请求 $ 变量展开吞噬问题 (v5.1 升级为通用规范)

### 症状
通过 PowerShell `Invoke-RestMethod` 发送 POST 请求时，JSON Body 中的 `$` 开头的变量名（如 `$matlabRoot`、`$projectDir`）被 PowerShell 当作变量展开，导致：
- 变量值变成空字符串（未定义的 PowerShell 变量默认为 `$null`，字符串化为空）
- API 收到的 JSON 缺失字段或值为空
- 中文路径和特殊字符（如 `(x86)`）乱码

### 根因
PowerShell 双引号字符串中，`$` 是变量前缀。当 JSON Body 用双引号包裹并内联在 `-Body` 参数中时：
```powershell
# ❌ 这行代码中 "matlabRoot" 前面没有 $，看起来安全
# 但如果有 $matlabRoot 或 $projectDir 等变量名就会被展开
-Body '{"matlabRoot":"D:\Program Files\MATLAB\R2023b"}'
# 在某些上下文中 PowerShell 仍可能展开 $ 符号
```

更严重的是，当通过 `powershell -Command "..."` 传递时，外层双引号和内层引号的交互使得转义极其不可靠。

### 通用解决方案：ConvertTo-Json 变量构造法

**核心规则：绝对不要在 -Body 参数中直接内联 JSON 字符串！**

```powershell
# ✅ 正确：用哈希表构造 + ConvertTo-Json — 值在单引号内，$ 不会被展开
$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\my_project'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

### 各 POST API 安全调用模板

**POST /api/matlab/config**:
```powershell
$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/quickstart**:
```powershell
$b = @{matlabRoot='D:\Program Files\MATLAB\R2023b';projectDir='D:\my_project'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/run**:
```powershell
$b = @{code='x = 1:10; plot(x)';showOutput=$true} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/run' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/execute**:
```powershell
$b = @{scriptPath='D:\my_project\test.m'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/execute' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/project/set**:
```powershell
$b = @{dirPath='D:\my_project'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/project/set' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/workspace/save**:
```powershell
$b = @{path='D:\my_project\data.mat'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/workspace/save' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

**POST /api/matlab/workspace/load**:
```powershell
$b = @{path='D:\my_project\data.mat'} | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/workspace/load' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
```

### 关键要点
- Body 必须用 `@{key='value'} | ConvertTo-Json -Compress` 构造，再传给 `-Body`
- 用 `[System.Text.Encoding]::UTF8.GetBytes($b)` 编码，确保中文路径正确
- 哈希表中的值用**单引号**包裹，防止 `$` 被展开
- **绝对不要**在 -Body 中直接写字符串 JSON
- 路径含 `(x86)` 时需注意 PowerShell 可能将括号解释为表达式，确保路径用引号包裹

---

## 23. 🔴 Simulink 建模深坑大全 (v5.1 任务4 实测总结)

> **Simulink 建模不是拿出模块库中已经封装好的模块并连接这么简单！**
> **必须组成子系统，子系统再组成系统，注意模块输入输出端口的管理！**

### 23.1 新建 SubSystem 的默认连线冲突

**症状**: `add_line` 报 "目标端口已有信号线连接"

**根因**: 新建 SubSystem 时，Simulink 自动在内部连接 In1→Out1，形成默认直通。外层 `add_line` 尝试连接子系统端口时，发现内部端口已有连线。

**解决方案**: 先 `delete_line` 清除默认连线，再 `add_line`
```matlab
subsysPath = [modelName, '/MySubsystem'];
delete_line(subsysPath, 'In1/1', 'Out1/1');  % 清除默认连线
add_line(subsysPath, 'In1/1', 'MyBlock/1');  % 再添加自己的连线
```

### 23.2 复杂模型用 From/Goto 传递信号，不是直接连线

**症状**: 尝试从 Inport 连线到子系统内部模块时失败，或信号无法到达目标

**根因**: RL 训练模型等复杂模型中，子系统间通过 Goto/From 模块对广播信号，而不是通过 Inport 直接连线传递。

**解决方案**: 在子系统内部添加 From 模块，通过 GotoTag 获取已有信号
```matlab
% 在子系统内部用 From 模块获取信号
add_block('simulink/Signal Routing/From', [subsysPath, '/From_e_angle']);
set_param([subsysPath, '/From_e_angle'], 'GotoTag', 'e_angle_t');

% 输出信号用 Goto 模块广播
add_block('simulink/Signal Routing/Goto', [subsysPath, '/Goto_reward']);
set_param([subsysPath, '/Goto_reward'], 'GotoTag', 'Reward_exponential');
```

### 23.3 add_line 逐步执行，避免连锁失败

**症状**: 多个 add_line 一次性执行时，中间某行失败导致后续全部不执行

**解决方案**: 用 try-catch 包裹每个 `add_line`
```matlab
lines = {'obs_inner/1', 'MySubsystem/1'; 'MySubsystem/1', 'Goto1/1'};
for i = 1:size(lines, 1)
    try
        add_line(modelName, lines{i,1}, lines{i,2});
        fprintf('OK: %s -> %s\n', lines{i,1}, lines{i,2});
    catch e
        fprintf('FAIL: %s -> %s: %s\n', lines{i,1}, lines{i,2}, e.message);
    end
end
```

### 23.4 中文路径下 Simulink 操作必须用 dir()+fullfile()

**症状**: `load_system('D:\RL\UH-60_contoller\UH-60_contoller_ptp_final_整理\model.slx')` 因中文乱码失败

**解决方案**: 先 cd 到不含中文的父目录，用 dir() 找索引，再用 fullfile() 构建
```matlab
cd('D:\RL\UH-60_contoller');
dirs = dir;
targetDir = fullfile('D:\RL\UH-60_contoller', dirs(6).name);  % 用索引避开中文
cd(targetDir);
load_system('model_name');  % 用相对路径，无中文问题
```

### 23.5 🔴 模型构建完成后必须自动排版

**症状**: 脚本化建模后用户打开模型，所有模块叠在一起，无法看清

**解决方案**: 所有模块和连线完成后，调用 Simulink 自动排版
```matlab
% 排版顶层模型
Simulink.BlockDiagram.arrangeSystem(modelName);

% 排版所有子系统
subs = find_system(modelName, 'LookUnderMasks', 'all', 'BlockType', 'SubSystem');
for i = 1:length(subs)
    try
        Simulink.BlockDiagram.arrangeSystem(subs{i});
    catch
        % 某些子系统可能无法排版（如库链接），跳过
    end
end

save_system(modelName);
```

---

## 24. 🔴 封装子系统（Masked Subsystem）内部结构无法读取 (v5.1 黑鹰模型实测)

### 症状

- `find_system(path)` 对某个 SubSystem 只返回自身1个块，无法看到内部内容
- `get_param(block, 'Children')` 报错："SubSystem block (mask) 没有名为 'Children' 的参数"
- 直接用绝对路径访问内部块报错："在系统中找不到模块"
- `get_param(block, 'LinkStatus')` 返回 'none'，不是库链接

### 根因

Simulink 模型中存在**多层嵌套的封装子系统（Masked Subsystem）**。封装子系统是一种特殊的子系统，它通过 Mask 机制隐藏了内部实现细节，只暴露参数化接口。

`find_system` 默认行为对封装子系统只返回自身而不深入内部，需要显式指定 `SearchDepth` 逐层深入。

### 解决方案：逐层 find_system + SearchDepth=1

**完整解析流程**：

**步骤1：检查封装属性**
```matlab
get_param(blockPath, 'Mask')          % 返回 'on' 确认是封装模块
get_param(blockPath, 'MaskType')      % 封装类型名
get_param(blockPath, 'MaskPrompts')   % 封装参数提示文字
get_param(blockPath, 'MaskVariables') % 封装变量名（如 Omega=@1;R=@2;...）
```

**步骤2：逐层用 find_system 深入**
```matlab
% 第一层：父容器的直接子块
blks1 = find_system('Rotor  Model', 'SearchDepth', 1);
% 结果：发现内部嵌套了一个 "Rotor Model" 子系统

% 第二层：继续深入嵌套子系统
blks2 = find_system('Rotor  Model/Rotor Model', 'SearchDepth', 1);
% 结果：成功读到 34 个内部块！包括 Blade Aeroloads Model1, NRFlap Model_NB4 等

% 第三层：进入 Blade Aeroloads Model1
blks3 = find_system('Rotor  Model/Rotor Model/Blade Aeroloads Model1', 'SearchDepth', 1);
% 结果：939 个块！完全展开
```

**步骤3：读取封装参数值**
```matlab
% 通过 MaskVariables 中定义的变量名读取封装参数值
% 例如 MaskVariables: Omega=@1;R=@2;R_vec=@3;...
get_param(blockPath, 'MaskValues')     % 获取所有封装参数的值
get_param(blockPath, 'MaskEnables')    % 哪些参数启用
```

**通用递归解析函数**：
```matlab
function parseMaskedSubsystem(path, depth)
    indent = repmat('  ', 1, depth);
    fprintf('%s[%s]\n', indent, path);
    
    % 检查是否是封装模块
    isMasked = strcmp(get_param(path, 'Mask'), 'on');
    if isMasked
        maskType = get_param(path, 'MaskType');
        maskVars = get_param(path, 'MaskVariables');
        fprintf('%s  Mask: %s, Vars: %s\n', indent, maskType, maskVars);
    end
    
    % 获取一层子块
    blks = find_system(path, 'SearchDepth', 1);
    for i = 2:length(blks)  % 跳过自身（第一个元素）
        blkType = get_param(blks{i}, 'BlockType');
        if strcmp(blkType, 'SubSystem')
            parseMaskedSubsystem(blks{i}, depth + 1);  % 递归深入
        else
            fprintf('%s  - %s (%s)\n', indent, blks{i}, blkType);
        end
    end
end
```

### 关键 API 速查

| API | 说明 | 返回值示例 |
|-----|------|-----------|
| `get_param(path, 'Mask')` | 检查是否有封装 | `'on'` 或数值 `111`/`110` |
| `get_param(path, 'MaskType')` | 封装类型名 | `'Rotor Model'` |
| `get_param(path, 'MaskPrompts')` | 封装参数提示文字 | `{'Omega','R','R_vec'}` |
| `get_param(path, 'MaskVariables')` | 封装变量名和序号 | `'Omega=@1;R=@2;R_vec=@3'` |
| `get_param(path, 'MaskValues')` | 封装参数当前值 | `{'27','26.83','[1 0.5 0.3]'}` |
| `get_param(path, 'MaskEnables')` | 哪些参数启用 | `{'on','on','on'}` |
| `find_system(path, 'SearchDepth', 1)` | 只看一层子块 | cell 数组 |

### 避坑清单

| ❌ 错误方法 | 原因 |
|------------|------|
| `get_param(path, 'Children')` | 封装子系统无 Children 属性，会报错 |
| 直接拼绝对路径访问内部块 | 未先 find_system 打开层级，会报错找不到 |
| `find_system(path)` 不带 SearchDepth | 对封装子系统只返回自身1个块 |
| `get_param(path, 'LinkStatus')` | 返回 'none'，不是库链接问题 |

| ✅ 正确方法 | 说明 |
|------------|------|
| `find_system(path, 'SearchDepth', 1)` 逐层深入 | 标准做法 |
| 先检查 `get_param(path, 'Mask')` | 确认是封装模块 |
| 读取 `MaskVariables` 中的 `@数字` | 表示参数序号，如 `Omega=@1` = 第1个参数 |
