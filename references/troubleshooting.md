# MATLAB Agent 故障排除指南

> 版本: 4.1.0 | 最后更新: 2026-04-09

本文档汇总了 MATLAB Agent 开发和运行中遇到的所有问题及其解决方案。

---

## 目录

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

### 解决方案
```powershell
# 查找占用进程
netstat -ano | findstr ":3000" | findstr "LISTENING"

# 杀死进程
taskkill /PID <PID> /F
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
cmd /c mklink /J "C:\Users\<你的用户名>\.workbuddy\skills\matlab-agent\app\node_modules" "<项目目录>\node_modules"
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
3. **API 配置**：
   ```bash
   curl -X POST http://localhost:3000/api/matlab/config -H "Content-Type: application/json" -d "{\"matlabRoot\":\"D:\\\\Program Files\\\\MATLAB\\\\R2023b\"}"
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

1. ✅ MATLAB 是否已安装？（通过 `/api/matlab/config` 检查配置路径）
2. ✅ Python 是否可用？（`python --version`，CLI 模式不要求）
3. ✅ MATLAB Engine API 是否已安装？（`python -c "import matlab.engine"`）
4. ✅ 端口 3000 是否被占用？（`netstat -ano | findstr ":3000"`）
5. ✅ 是否用阻塞式启动？（必须后台启动 + 轮询）
6. ✅ 脚本文件路径是否含中文？
7. ✅ 函数名是否以下划线开头？
8. ✅ 查看 `/api/health` 中 `warmup` 字段是否为 `ready`
