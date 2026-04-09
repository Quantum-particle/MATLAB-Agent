# MATLAB Bridge API 参考

> 版本: 4.1.0 | 文件: matlab_bridge.py

## 运行模式

### 常驻模式（推荐）
```bash
python matlab_bridge.py --server
```
- Engine 在进程生命周期内持久化
- 变量跨命令保持
- 通过 stdin/stdout JSON 行协议通信
- 输入: 每行一个 JSON 命令
- 输出: 每行一个 JSON 结果

### 单次模式
```bash
echo '{"action":"check","params":{}}' | python matlab_bridge.py
```
- Engine 不跨命令持久化
- 仅用于调试

## 命令协议

### 请求格式
```json
{
  "action": "命令名",
  "params": { ... }
}
```

### 响应格式
```json
{
  "status": "ok" | "error" | "warning",
  "message": "可选描述",
  ...
}
```

## 命令列表

### 基础操作

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `check` | `{}` | 安装检查结果 | 检查 MATLAB 和 Engine 状态 |
| `start` | `{}` | `{status:"ok", message:..., connection_mode:...}` | 启动/获取 MATLAB Engine |
| `stop` | `{}` | `{status:"ok", message:...}` | 停止 Engine 并释放资源 |

### 配置管理（v4.1 新增/变更）

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `get_config` | `{}` | `{matlab_root, matlab_exe, connection_mode, ...}` | 获取当前 MATLAB 配置 |
| `set_matlab_root` | `{root: string}` | `{status:"ok", matlab_root:...}` | 动态设置 MATLAB_ROOT 并重置连接 |

> ⚠️ v4.1 已移除 `detect_installations` 命令。MATLAB_ROOT 仅从环境变量读取，不再自动扫描注册表和常见路径。

### 项目操作

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `set_project` | `{dir: string}` | `{status:"ok", project_dir:...}` | 设置项目目录并 cd |
| `scan_project` | `{dir?: string}` | `{files:{scripts,data,models,...}, summary:...}` | 扫描项目文件 |

### 文件读取

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `read_m_file` | `{path: string}` | `{content: string}` | 读取 .m 文件内容 |
| `read_mat_file` | `{path: string}` | `{variables: [{name,class,size}]}` | 读取 .mat 变量结构 |
| `read_simulink` | `{path: string}` | `{model_name, block_count, blocks}` | 读取 Simulink 模型信息 |

### 代码执行

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `run_code` | `{code: string, show_output?: bool}` | `{stdout, open_figures}` | **核心**: 持久化工作区执行代码 |
| `execute_script` | `{script_path: string, output_dir?: string}` | `{stdout, open_figures}` | 执行 .m 脚本文件 |

### 工作区管理

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `get_workspace` | `{}` | `{variables: [{name,size,class,preview}]}` | 获取工作区变量 |
| `save_workspace` | `{path?: string}` | `{path: string}` | 保存工作区为 .mat |
| `load_workspace` | `{path: string}` | `{status:"ok"}` | 加载 .mat 到工作区 |
| `clear_workspace` | `{}` | `{status:"ok"}` | 清空工作区 |

### Simulink

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `create_simulink` | `{model_name: string, model_path?: string}` | `{model_path}` | 创建 Simulink 模型 |
| `run_simulink` | `{model_name: string, stop_time?: string}` | `{stdout, open_figures}` | 运行仿真并自动绘图 |
| `open_simulink` | `{model_name: string}` | `{status:"ok"}` | 打开 Simulink 模型 |

### Simulink 模型工作区（v4.1 新增）

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `set_simulink_workspace` | `{model_name, var_name, var_value}` | `{status:"ok", message:...}` | 设置模型工作区变量（同时写入基础工作区） |
| `get_simulink_workspace` | `{model_name}` | `{variables: [{name,class,size}], model_name}` | 获取模型工作区变量列表 |
| `clear_simulink_workspace` | `{model_name}` | `{status:"ok", message:...}` | 清空模型工作区 |

> **参数化建模工作流**:
> 1. 在 MATLAB 基础工作区定义参数 → `run_code` 设置变量
> 2. 在 Simulink 模型工作区设置模型专属参数 → `set_simulink_workspace`
> 3. 模块参数直接引用变量名（如 Gain 参数填 `Kp`）
> 4. 优先级：模型工作区 > 掩码工作区 > 基础工作区

### 图形管理

| Action | Params | 返回 | 说明 |
|--------|--------|------|------|
| `list_figures` | `{}` | `{figures: [string]}` | 列出打开的图形窗口 |
| `close_figures` | `{}` | `{status:"ok"}` | 关闭所有图形 |

## 引号转义规则

从 Python 调用 MATLAB Engine eval() 时的引号规则：

| Python 字符串 | MATLAB 看到 |
|---|---|
| `"evalc('disp(42)')"` | `evalc('disp(42)')` |
| `"evalc('cd(''path'');')"` | `evalc('cd('path');')` |

**核心规则**: Python 外层双引号，MATLAB 内部单引号用 `''` 转义。

## 错误处理

所有错误通过返回 JSON 的 `status: "error"` 和 `message` 字段传达，不会抛出异常到 stdout。

常见错误:
- `文件不存在: ...` — 文件路径无效
- `函数名不能以下划线开头` — MATLAB 命名规则
- `MATLAB 执行错误: ...` — 代码运行时错误
- `JSON 解析失败: ...` — 输入格式错误
- `MATLAB 不可用。请先通过 /api/matlab/config 设置 MATLAB_ROOT。` — 未配置 MATLAB 路径
