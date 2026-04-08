# MATLAB Agent 故障排除指南

> 版本: 2.0.0 | 最后更新: 2026-04-08

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

### 验证
```bash
cd d:\CherryStudio\coder\MATLAB_agent
python test_agent_api.py
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
每次 API 调用需要 8+ 秒。

### 原因
MATLAB Engine 每次启动一个完整的 MATLAB 实例，约 8 秒（固有开销，无法优化）。

### 当前方案
接受此开销。每次 API 调用 = 新子进程 + 新 Engine。

### 优化方向
参见 `docs/plans/2026-04-08-perf-optimization-design.md` — 持久化 MATLAB Engine TCP Server。

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
MATLAB 2023b 中 `timeseries` 对象不一定有 `.Values` 属性。

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
netstat -ano | findstr :3000

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

## 快速诊断清单

遇到问题时按此顺序排查：

1. ✅ MATLAB 是否已安装？（检查 `D:\Program Files(x86)\MATLAB2023b`）
2. ✅ Python 是否可用？（`python --version`）
3. ✅ MATLAB Engine API 是否已安装？（`python -c "import matlab.engine"`）
4. ✅ 端口 3000 是否被占用？（`netstat -ano | findstr :3000`）
5. ✅ 桥接脚本是否存在？（`matlab-agent/matlab-bridge/matlab_bridge.py`）
6. ✅ 脚本文件路径是否含中文？
7. ✅ 函数名是否以下划线开头？
8. ✅ 查看 stderr 输出中的具体错误信息
