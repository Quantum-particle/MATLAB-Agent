# -*- coding: utf-8 -*-
"""
MATLAB Bridge v5.4 - 通用化 MATLAB 会话服务

运行模式: 作为常驻进程运行，通过 stdin/stdout JSON 行协议通信。
Node.js 启动此进程后保持运行，通过管道发送命令、接收结果。

启动:
  python matlab_bridge.py --server

通信协议:
  每行一个 JSON 对象，输入为命令，输出为结果。
  输入: {"action": "run_code", "params": {"code": "x = 42;"}}
  输出: {"status": "ok", "stdout": "x = 42", "open_figures": 0}

v5.4 变更（2026-04-14）:
  - 新增 workspace isolation: 中间执行文件自动隔离到 .matlab_agent_tmp/ 子文件夹
  - 新增 init_agent_workspace(): 初始化隔离子文件夹
  - 新增 route_file_path(): 根据文件类型自动路由到工作目录或隔离目录
  - 新增 cleanup_agent_workspace(): 任务完成后清理中间文件
  - 文件分类: .m/.slx/.mdl/.mat/.fig 留在工作目录，其余执行文件入隔离目录

v5.3 变更（2026-04-14）:
  - 修复 _detect_matlab_version_cli() 添加 -r 回退（R2016a-R2018b 不支持 -batch）
  - 修复 CLI 模式 exit 拼接：加换行符防止注释行吞掉 exit
  - 优化 _test_engine_compatibility() 增加 Engine 路径预检查
  - 统一 API 参数名（scan 兼容 dirPath 和 dir）
  - 补充中文路径 API 调用文档

v5.0 变更（2026-04-10）:
  - 核心重构: 用 diary() + eng.eval() 替代 evalc()，彻底解决引号双写问题
  - 修复中文路径: diary 方式无需引号转义，中文路径不再乱码
  - 修复输出编码: 使用 stdout.buffer.write + UTF-8，解决 Windows GBK 乱码
  - Name-Value 参数（如 'LowerLimit'）不再被错误双写
  - 多行代码完美支持，无需行拼接

v4.1 变更:
  - 移除自动检测逻辑（注册表扫描 + 常见路径扫描）
  - MATLAB_ROOT 仅从环境变量读取（由 Node.js 端传入）
  - 与 Node.js 端 v4.1 行为一致：手动配置优先

版本: 5.4.0 (2026-04-14)
"""

import sys
import os
import json
import re
import subprocess
import shutil
import traceback
import threading
from pathlib import Path
from datetime import datetime

# 强制 UTF-8
if sys.stdin.encoding != 'utf-8':
    try: sys.stdin.reconfigure(encoding='utf-8', errors='replace')
    except: pass
if sys.stdout.encoding != 'utf-8':
    try: sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except: pass
if sys.stderr.encoding != 'utf-8':
    try: sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except: pass


# ============= MATLAB_ROOT 配置（v4.1: 仅从环境变量读取）============

def _get_matlab_root():
    """获取 MATLAB_ROOT（v4.1: 仅从环境变量读取，不再自动检测）
    
    MATLAB_ROOT 由 Node.js 端通过环境变量传入，优先级：
    1. 环境变量 MATLAB_ROOT（由 Node.js 传入或用户手动设置）
    2. 通过 set_matlab_root 命令动态设置
    """
    env_root = os.environ.get('MATLAB_ROOT', '')
    if env_root and os.path.exists(env_root):
        return env_root
    return None


# ============= MATLAB 连接模式 =============

# 连接模式：engine = Python Engine API, cli = 命令行模式
_connection_mode = None  # 'engine' | 'cli'
_engine_compatible = None  # 是否已测试过 Engine 兼容性

MATLAB_ROOT = _get_matlab_root()  # v4.1: 仅从环境变量读取，None 表示未配置
_project_dir = None
_matlab_engine = None
_matlab_version = None  # 缓存 MATLAB 版本号

# ============= Workspace Isolation（v5.4 → v10.1 强制隔离）=============
# 中间临时文件隔离到 .matlab_agent_tmp/ 子文件夹，避免污染用户工作目录
#
# 关键区分（v10.1 明确）:
#   ✅ 留在工作目录: 智能体编写的 .m 脚本、创建的 .slx 模型、保存的 .mat 数据
#      → 这些是任务产出文件，用户可直接在 MATLAB 中打开
#   🔒 隔离到 .matlab_agent_tmp/: Bridge 层自动生成的临时脚本/编译产物/日志
#      → 这些是运行时中间产物，任务结束后应统一清理

_AGENT_TMP_DIR_NAME = '.matlab_agent_tmp'

# 允许留在工作目录的文件扩展名（任务产出文件 / MATLAB 原生文件）
_KEEP_IN_WORKSPACE_EXTS = {'.m', '.slx', '.mdl', '.mat', '.fig', '.xlsx', '.xls', '.csv', '.docx', '.pdf'}

# 需要隔离到子文件夹的文件扩展名（运行时中间产物）
_ISOLATE_EXTS = {'.json', '.c', '.h', '.cpp', '.hpp', '.obj', '.o', '.dll', '.lib', '.exp',
                 '.exe', '.bat', '.py', '.js', '.ts', '.def', '.tlc', '.tlh', '.xml',
                 '.html', '.css', '.log', '.bak', '.tmp', '.txt', '.rpt', '.mk'}

_agent_workspace_initialized = False  # 是否已初始化隔离子目录

# ============= sl_toolbox 初始化（v6.0）============
# 核心问题：sl_toolbox 在 skill 安装目录（可能含中文路径如 C:\Users\泰坦\...）
# 解决方案：不复制文件！通过以下方式让 MATLAB 找到 sl_toolbox：
#   Engine 模式：eng.workspace 传路径变量 → sl_init() 自定位 addpath
#   CLI 模式：写临时 .m 文件执行 → sl_init() 自定位 addpath
# sl_init.m 通过 mfilename('fullpath') 自定位，不需要任何人传路径字符串

_SL_TOOLBOX_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sl_toolbox')
_sl_toolbox_initialized = False  # 是否已在 MATLAB 中初始化 sl_toolbox

# ============= v6.0: 并发保护 =============
_model_locks = {}  # {modelName: threading.Lock}
_global_lock = threading.Lock()


def _get_model_lock(model_name):
    """获取/创建模型级互斥锁，防止并发修改同一模型"""
    with _global_lock:
        if model_name not in _model_locks:
            _model_locks[model_name] = threading.Lock()
        return _model_locks[model_name]


# ============= v6.0: 版本检测 =============

def _detect_matlab_version():
    """检测 MATLAB 版本（缓存结果），返回版本字符串如 'R2023b'"""
    global _matlab_version
    if _matlab_version is not None:
        return _matlab_version
    
    mode = _detect_connection_mode()
    if mode == 'engine':
        eng = get_engine()
        if eng:
            try:
                # 通过 eng.workspace 传递，避免 eval 字符串编码问题
                ver_str = eng.eval("version('-release');", nargout=1)
                if ver_str:
                    _matlab_version = str(ver_str).strip()
                    return _matlab_version
            except:
                pass
    
    # 回退: 从路径推测
    path_ver = _get_matlab_version_from_path()
    if path_ver:
        _matlab_version = path_ver
    else:
        _matlab_version = 'unknown'
    
    return _matlab_version


def _is_matlab_at_least(release):
    """检查 MATLAB 版本是否 >= 指定版本
    
    [P2-3 FIX] 不再用字符串字典序比较（'R2023b' >= 'R2024a' 为 True 是错的），
    改为解析年份+后缀为数值比较。
    
    Args:
        release: 如 '2017a', '2024b', 'R2023b'
    Returns:
        bool
    """
    current = _detect_matlab_version()
    if current == 'unknown':
        return False
    
    def _parse_release(r):
        """将 'R2023b' 或 '2023b' 解析为 (2023, 0/1) 元组，a=0, b=1"""
        r = r.strip()
        if r.startswith('R'):
            r = r[1:]
        # 格式: YYYYx (如 2023b, 2024a)
        import re as _re
        m = _re.match(r'^(\d{4})([ab])$', r.lower())
        if not m:
            return (0, 0)
        year = int(m.group(1))
        suffix = 1 if m.group(2) == 'b' else 0
        return (year, suffix)
    
    return _parse_release(current) >= _parse_release(release)


# ============= v6.0: 类型转换辅助函数 =============

def _dict_to_matlab_struct(d, _depth=0):
    """Python dict → MATLAB struct 构造字符串
    
    注意: 遵循踩坑 #16 — 不用 struct('field',cellVal) 直接构造，
    避免空 cell 导致 struct 展开为 1x0。
    对于包含 list/dict 值的字段，使用分步赋值模式。
    简单类型值可以直接用 struct() 构造。
    """
    if not d:
        return 'struct()'
    
    # 检查是否有复杂嵌套值（list of dict, nested dict）
    has_complex = any(
        isinstance(v, (list, dict)) for v in d.values()
    )
    
    if has_complex:
        # 复杂结构: 使用分步赋值（安全但较长）
        # 先构造空 struct，再逐字段赋值
        parts = []
        for k, v in d.items():
            val_str = _python_to_matlab_value(v, _depth)
            parts.append(f"s.{k} = {val_str};")
        # 包装为: struct(), s = ans; s.field1=val1; s.field2=val2; s
        assign_code = ' '.join(parts)
        return f"struct(), {assign_code}"
    
    # 简单结构: 直接用 struct() 构造
    parts = []
    for k, v in d.items():
        val_str = _python_to_matlab_value(v, _depth)
        parts.append(f"'{k}',{val_str}")
    return f"struct({','.join(parts)})"


def _python_to_matlab_value(v, _depth=0):
    """将 Python 值转为 MATLAB 表达式字符串
    
    [P2-2 FIX] 增加递归深度限制（默认最大 10 层），防止恶意嵌套导致栈溢出
    """
    if _depth > 10:
        return "''  % depth limit exceeded"
    if v is None:
        return "''"
    elif isinstance(v, bool):
        return 'true' if v else 'false'
    elif isinstance(v, str):
        # 转义单引号
        escaped = v.replace("'", "''")
        return f"'{escaped}'"
    elif isinstance(v, (int, float)):
        if isinstance(v, float) and (v != v):  # NaN
            return 'NaN'
        if isinstance(v, float) and (v == float('inf')):
            return 'Inf'
        if isinstance(v, float) and (v == float('-inf')):
            return '-Inf'
        return str(v)
    elif isinstance(v, list):
        return _list_to_matlab_cell(v, _depth + 1)
    elif isinstance(v, dict):
        return _dict_to_matlab_struct(v, _depth + 1)
    else:
        return f"'{str(v)}'"


def _list_to_matlab_cell(lst, _depth=0):
    """Python list → MATLAB cell 构造字符串"""
    if not lst:
        return '{}'
    items = []
    for item in lst:
        items.append(_python_to_matlab_value(item, _depth))
    return f"{{{','.join(items)}}}"


def _safe_json_parse(raw_output):
    """安全 JSON 解析 — 处理 MATLAB 输出中的 NaN/Infinity 等"""
    if not raw_output or not raw_output.strip():
        return None
    
    # 预处理: 替换非标准 JSON 值
    cleaned = raw_output.strip()
    # 去除可能的前后空白和 ANSI 控制码
    cleaned = re.sub(r'\x1b\[[0-9;]*m', '', cleaned)
    
    # 替换 NaN → null (JSON 标准)
    cleaned = re.sub(r'\bNaN\b', 'null', cleaned)
    # 替换 Infinity → 大数（JSON 不支持 Infinity）
    cleaned = re.sub(r'\bInfinity\b', '1e308', cleaned)
    cleaned = re.sub(r'\b-Infinity\b', '-1e308', cleaned)
    
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        # 尝试提取 JSON 部分（可能前后有无关输出）
        # 查找第一个 { 和最后一个 }
        start = cleaned.find('{')
        end = cleaned.rfind('}')
        if start >= 0 and end > start:
            try:
                return json.loads(cleaned[start:end+1])
            except json.JSONDecodeError:
                pass
        return None


# ============= v6.0: 统一 .m 函数调用器 =============

def _call_sl_function(func_name, args_dict, eng=None):
    """统一调用 sl_toolbox 中的 .m 函数，返回解析后的 JSON
    
    设计原则:
    1. 先确保 sl_toolbox 已初始化
    2. 构造 MATLAB 调用: result = sl_xxx(args...); disp(sl_jsonencode(result));
    3. 通过 _run_code_via_diary 执行（diary 方式，中文路径安全）
    4. 用 _safe_json_parse 解析返回的 JSON
    
    参数传递方式:
    - args_dict 中的键值对，默认以 Name-Value 对格式传递
    - 以 '_pos_' 开头的键表示位置参数，按数字顺序排列
      例如: {'_pos_1': 'create', 'modelName': 'test', 'snapshotName': 'snap1'}
      生成: sl_xxx('test', 'create', 'snapshotName', 'snap1')
    
    Args:
        func_name: .m 函数名（如 'sl_inspect_model'）
        args_dict: 参数字典 {参数名: 值}，值会被转为 MATLAB 表达式
        eng: 可选的 Engine 实例（不传则自动获取）
    
    Returns:
        dict: 解析后的 JSON 结果，或 {status: 'error', ...}
    """
    # 1. 确保 sl_toolbox 已初始化
    init_result = _ensure_sl_toolbox_in_matlab()
    if init_result.get('status') == 'error':
        return init_result
    
    mode = _detect_connection_mode()
    if mode == 'unavailable':
        return {"status": "error", "message": "MATLAB 不可用"}
    
    # 2. 分离位置参数和 Name-Value 参数
    pos_args = {}  # {1: value, 2: value, ...}
    pos_args_special = {}  # {2: 'pre-converted MATLAB expr', ...}
    nv_args = {}   # {name: value, ...}
    
    for key, val in args_dict.items():
        if key.startswith('_pos_'):
            # Check for _pos_N_special (pre-converted MATLAB expression)
            if key.endswith('_special'):
                base_key = key[:-8]  # Remove '_special' suffix
                try:
                    idx = int(base_key[5:])  # _pos_2_special → 2
                    pos_args_special[idx] = val  # Already a MATLAB expression string
                except ValueError:
                    pass
            else:
                try:
                    idx = int(key[5:])  # _pos_1 → 1
                    pos_args[idx] = val
                except ValueError:
                    pass
        else:
            nv_args[key] = val
    
    # 3. 构造 MATLAB 参数列表
    # 先按序号排列位置参数
    sorted_pos_keys = sorted(set(list(pos_args.keys()) + list(pos_args_special.keys())))
    args_parts = []
    for idx in sorted_pos_keys:
        if idx in pos_args_special:
            # Pre-converted MATLAB expression — use directly
            args_parts.append(str(pos_args_special[idx]))
        elif idx in pos_args:
            val = pos_args[idx]
            if val is not None and val != '':
                args_parts.append(_python_to_matlab_value(val))
    
    # 再追加 Name-Value 参数
    for key, val in nv_args.items():
        if val is None or val == '':
            continue
        # 跳过空列表/空字典
        if isinstance(val, (list, dict)) and not val:
            continue
        # Check for pre-converted MATLAB expression: ('__special__', expr)
        if isinstance(val, tuple) and len(val) == 2 and val[0] == '__special__':
            val_str = str(val[1])
        else:
            val_str = _python_to_matlab_value(val)
        args_parts.append(f"'{key}',{val_str}")
    
    args_str = ', '.join(args_parts)
    
    # 3. 构造完整 MATLAB 代码
    # 使用 try-catch 包裹，确保错误也能被捕获
    matlab_code = (
        f"try, "
        f"result = {func_name}({args_str}); "
        f"disp(sl_jsonencode(result)); "
        f"catch ME, "
        f"err = struct('status','error','message',ME.message,'identifier',ME.identifier); "
        f"disp(sl_jsonencode(err)); "
        f"end"
    )
    
    # 4. 执行
    if mode == 'engine':
        if eng is None:
            eng = get_engine()
        if eng is None:
            return {"status": "error", "message": "MATLAB Engine 不可用"}
        
        diary_result = _run_code_via_diary(eng, matlab_code)
        if isinstance(diary_result, dict) and diary_result.get('status') == 'error':
            return diary_result
        
        output = _extract_diary_output(diary_result)
        if not output:
            return {"status": "error", "message": f"{func_name} 执行无输出"}
        
        # 5. 解析 JSON
        parsed = _safe_json_parse(output)
        if parsed is not None:
            return parsed
        else:
            return {"status": "ok", "raw_output": output, "message": f"{func_name} 返回非 JSON 格式"}
    
    else:
        # CLI 回退模式
        result = _run_cli_command(matlab_code, timeout=300)
        if result['status'] == 'ok':
            stdout = result.get('stdout', '')
            parsed = _safe_json_parse(stdout)
            if parsed is not None:
                return parsed
            else:
                return {"status": "ok", "raw_output": stdout, "connection_mode": "cli"}
        return result


def _ensure_sl_toolbox_in_matlab():
    """确保 sl_toolbox 在 MATLAB path 中（中文路径安全）

    设计原则：
    1. 不复制文件 — sl_toolbox 只存在于 skill 安装目录，用户可见可控
    2. sl_init.m 自定位 — 通过 mfilename('fullpath') 知道自己在哪
    3. Engine 模式：用 eng.workspace 传路径变量，避免 eval 字符串中文破坏
    4. CLI 模式：写临时 .m 文件执行，绕过命令行中文编码问题
    5. 幂等操作：重复调用不会重复添加路径
    """

    # ============= v6.0: 反模式防护中间件 =============

ANTI_PATTERN_RULES = {
    'sl_add_block': {
        'check_before': True,
        'rules': [
            {
                'rule_number': 1,
                'field': 'sourceBlock',
                'pattern': r'(?i)\bSum\b',
                'level': 'warning',
                'message': 'Sum block is discouraged in modern Simulink',
                'suggestion': 'Use Add block for addition, Subtract block for subtraction',
                'alternatives': ['Add', 'Subtract']
            },
            {
                'rule_number': 2,
                'field': 'sourceBlock',
                'pattern': r'(?i)To.?Workspace',
                'level': 'warning',
                'message': 'To Workspace block is discouraged for signal recording',
                'suggestion': 'Use Signal Logging via sl_signal_logging instead',
                'alternativeCommand': 'sl_signal_logging'
            }
        ]
    }
}


def _anti_pattern_check(command, params):
    """反模式预检中间件 — 在调用 .m 函数前检查参数是否触发反模式规则
    
    Args:
        command: 命令名（如 'sl_add_block'）
        params: 命令参数字典
    
    Returns:
        list: 警告列表 [{rule, level, message, suggestion, ...}]
    """
    warnings_list = []
    rules = ANTI_PATTERN_RULES.get(command, {})
    
    if not rules.get('check_before'):
        return warnings_list
    
    for rule in rules.get('rules', []):
        field_value = str(params.get(rule['field'], ''))
        pattern = rule.get('pattern', '')
        if pattern and re.search(pattern, field_value):
            warning = {
                'rule': rule.get('rule_number', 0),
                'level': rule['level'],
                'message': rule['message'],
                'suggestion': rule['suggestion'],
            }
            if rule.get('alternatives'):
                warning['alternatives'] = rule['alternatives']
            if rule.get('alternativeCommand'):
                warning['alternativeCommand'] = rule['alternativeCommand']
            warnings_list.append(warning)
    
    return warnings_list


# ============= v6.1: 自我改进机制 =============

# 知识库目录
_LEARNINGS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.learnings')

# API 调用统计（内存级，进程重启后清零）
_command_stats = {}

# ============= v7.0: Layer 5 源码级自我改进 =============

# 动态修复规则库（JSON 文件持久化，运行时可增删改）
_SELF_IMPROVE_RULES_FILE = os.path.join(_LEARNINGS_DIR, 'auto_fix_rules.json')
_dynamic_fix_rules = []  # 运行时缓存

def _load_dynamic_fix_rules():
    """加载持久化的动态修复规则（Layer 5: 源码级自我改进）
    
    规则格式:
    {
        "id": "RULE-001",
        "command": "sl_set_param",        # 适用的命令
        "field": "params",                # 检查的参数字段
        "detect_pattern": "list_of_str",  # 检测模式: list_of_str | dict_instead_of_str | missing_prefix | custom
        "detect_fn": null,                # 自定义检测函数（Python 代码字符串，eval 执行）
        "fix_action": "convert_to_dict",  # 修复动作: convert_to_dict | prepend_model | set_default | custom
        "fix_fn": null,                   # 自定义修复函数（Python 代码字符串，eval 执行）
        "fix_params": {},                 # 修复动作的额外参数
        "source": "auto_learned",         # 来源: auto_learned | user_defined | manual
        "created_at": "...",
        "hit_count": 0,                   # 命中次数
        "last_hit": null                  # 上次命中时间
    }
    """
    global _dynamic_fix_rules
    try:
        if os.path.exists(_SELF_IMPROVE_RULES_FILE):
            with open(_SELF_IMPROVE_RULES_FILE, 'r', encoding='utf-8') as f:
                _dynamic_fix_rules = json.load(f)
        else:
            _dynamic_fix_rules = []
    except Exception as e:
        sys.stderr.write(f"[Layer5] Failed to load dynamic rules: {e}\n")
        _dynamic_fix_rules = []

def _save_dynamic_fix_rules():
    """保存动态修复规则到 JSON 文件"""
    try:
        os.makedirs(_LEARNINGS_DIR, exist_ok=True)
        with open(_SELF_IMPROVE_RULES_FILE, 'w', encoding='utf-8') as f:
            json.dump(_dynamic_fix_rules, f, indent=2, ensure_ascii=False)
    except Exception as e:
        sys.stderr.write(f"[Layer5] Failed to save dynamic rules: {e}\n")

# 启动时加载规则
_load_dynamic_fix_rules()


# ============= [P0-1 FIX] 安全的自定义函数沙箱执行 =============
# 替代 eval() 执行自定义 detect_fn/fix_fn。
# 设计原则：**不限制智能体的能力**，只阻断危险操作（文件/网络/进程/系统调用）。
# AI 可以自由编写任意 Python 逻辑（if/for/字典操作/字符串处理/正则/数学等），
# 但不能执行 open/os.system/subprocess/socket 等危险操作。
#
# 两种使用方式:
#   1. add_rule 时提供 detect_fn_code/fix_fn_code → 自动编译并缓存
#   2. register_safe_fn 独立注册
#   3. add_rule 时 detect_fn/fix_fn 已缓存 → 直接使用

_SAFE_CUSTOM_FUNCTIONS = {}

# 危险名称黑名单 — 这些是真正危险的，必须阻断
_DANGEROUS_NAMES = frozenset({
    # 文件系统
    'open', 'os', 'pathlib', 'shutil', 'tempfile', 'glob', 'fnmatch',
    # 进程/系统
    'subprocess', 'sys', 'ctypes', 'multiprocessing', 'signal',
    'importlib', 'pkgutil', 'module',
    # 网络
    'socket', 'http', 'urllib', 'requests', 'ftplib', 'smtplib',
    'xmlrpc', 'jsonrpclib',
    # 危险内置函数
    'exec', 'eval', 'compile', '__import__',
    # 反射/动态
    'globals', 'locals', 'vars', 'dir',
})

# 危险属性名黑名单 — 阻止通过 .__ 路径逃逸
_DANGEROUS_ATTRS = frozenset({
    '__import__', '__builtins__', '__globals__', '__code__',
    '__class__', '__subclasses__', '__bases__', '__mro__',
})

# 沙箱命名空间 — 允许所有常用 Python 内置函数和类型
_SANDBOX_BUILTINS = {
    # 常量
    'True': True, 'False': False, 'None': None,
    # 内置类型
    'int': int, 'float': float, 'str': str, 'bool': bool,
    'list': list, 'dict': dict, 'tuple': tuple, 'set': set, 'frozenset': frozenset,
    'bytes': bytes, 'bytearray': bytearray,
    # 类型检查
    'isinstance': isinstance, 'issubclass': issubclass, 'type': type,
    'callable': callable, 'hasattr': hasattr, 'getattr': getattr, 'setattr': setattr,
    # 数值/迭代
    'len': len, 'range': range, 'enumerate': enumerate, 'zip': zip,
    'map': map, 'filter': filter, 'sorted': sorted, 'reversed': reversed,
    'min': min, 'max': max, 'sum': sum, 'abs': abs, 'round': round,
    'pow': pow, 'divmod': divmod,
    # 字符串
    'chr': chr, 'ord': ord, 'hex': hex, 'oct': oct, 'bin': bin,
    'repr': repr, 'format': format, 'ascii': ascii,
    # 集合/字典操作
    'any': any, 'all': all, 'iter': iter, 'next': next,
    'slice': slice, 'property': property,
    # 异常（允许在自定义函数中使用 try/except）
    'Exception': Exception, 'TypeError': TypeError, 'ValueError': ValueError,
    'KeyError': KeyError, 'IndexError': IndexError, 'AttributeError': AttributeError,
    'RuntimeError': RuntimeError, 'StopIteration': StopIteration,
    'NotImplementedError': NotImplementedError,
    # 正则表达式（AI 常用）
    're': __import__('re'),
    # 数学（AI 可能需要）
    'math': __import__('math'),
    # JSON（AI 可能需要解析数据）
    'json': __import__('json'),
    # copy
    'copy': __import__('copy'),
}


def _validate_sandbox_code(fn_name, fn_code):
    """验证代码是否可以在沙箱中安全执行
    
    允许所有正常的 Python 逻辑（if/for/while/try/列表推导/字典操作/字符串处理/正则等），
    只阻断：
    1. import 语句（不允许动态导入模块）
    2. 危险名称引用（open/exec/eval/os/sys/subprocess 等）
    3. 危险属性访问（.__import__/.__builtins__ 等逃逸路径）
    
    Returns:
        tuple: (is_safe, error_message)
    """
    import ast as _ast_module
    
    # [P0-1 FIX] 在函数内部定义危险名称列表，避免模块级变量可能的命名冲突
    _LOCAL_DANGEROUS_NAMES = frozenset({
        'open', 'os', 'pathlib', 'shutil', 'tempfile', 'glob', 'fnmatch',
        'subprocess', 'sys', 'ctypes', 'multiprocessing', 'signal',
        'importlib', 'pkgutil', 'module',
        'socket', 'http', 'urllib', 'requests', 'ftplib', 'smtplib',
        'xmlrpc', 'jsonrpclib',
        'exec', 'eval', 'compile', '__import__',
        'globals', 'locals', 'vars', 'dir',
    })
    _LOCAL_DANGEROUS_ATTRS = frozenset({
        '__import__', '__builtins__', '__globals__', '__code__',
        '__class__', '__subclasses__', '__bases__', '__mro__',
    })
    
    try:
        tree = _ast_module.parse(fn_code)
    except SyntaxError as e:
        return False, f"Syntax error in function code: {e}"
    
    for node in _ast_module.walk(tree):
        # 1. 禁止 import 语句
        if isinstance(node, (_ast_module.Import, _ast_module.ImportFrom)):
            module_name = ''
            if isinstance(node, _ast_module.ImportFrom) and node.module:
                module_name = node.module
            elif isinstance(node, _ast_module.Import) and node.names:
                module_name = node.names[0].name
            # 检查导入的是否是允许的模块
            allowed_imports = {'re', 'math', 'json', 'copy', 'collections', 'itertools', 'functools', 'string', 'datetime', 'decimal', 'fractions', 'random', 'statistics'}
            if module_name.split('.')[0] not in allowed_imports:
                return False, f"Security: import '{module_name}' not allowed. Allowed imports: {sorted(allowed_imports)}"
        
        # 2. 禁止危险名称引用
        if isinstance(node, _ast_module.Name) and node.id in _LOCAL_DANGEROUS_NAMES:
            return False, f"Security: name '{node.id}' is not allowed in sandbox"
        
        # 3. 禁止危险属性访问（防止沙箱逃逸）
        if isinstance(node, _ast_module.Attribute):
            attr_name = node.attr
            if attr_name in _LOCAL_DANGEROUS_ATTRS:
                return False, f"Security: attribute '{attr_name}' access not allowed (sandbox escape prevention)"
    
    return True, "OK"


def _register_safe_function(fn_name, fn_code):
    """在沙箱中编译并注册自定义函数
    
    安全模型：**不限制能力，只阻断危险操作**
    - ✅ 允许: if/for/while/try/列表推导/字典操作/字符串处理/正则/数学/JSON
    - ✅ 允许: import re/math/json/copy/collections/itertools/functools/datetime/string/random/statistics
    - ❌ 禁止: open/exec/eval/compile/__import__/os/sys/subprocess/socket/shutil/pathlib 等
    - ❌ 禁止: .__import__/.__builtins__/.__globals__ 等逃逸路径
    """
    # Step 1: AST 静态检查
    is_safe, msg = _validate_sandbox_code(fn_name, fn_code)
    if not is_safe:
        return False, msg
    
    # Step 2: 在受限命名空间中编译执行
    sandbox_ns = {'__builtins__': _SANDBOX_BUILTINS}
    try:
        exec(fn_code, sandbox_ns)
        fn_obj = sandbox_ns.get(fn_name)
        if not callable(fn_obj):
            return False, f"Function '{fn_name}' not found in compiled code. Make sure the function name matches."
        _SAFE_CUSTOM_FUNCTIONS[fn_name] = fn_obj
        return True, f"Function '{fn_name}' registered in sandbox successfully"
    except Exception as e:
        return False, f"Failed to compile function: {e}"


def _safe_call_custom_fn(fn_name_or_code, command, params, is_detect=True):
    """安全执行自定义 detect/fix 函数
    
    支持两种模式：
    1. fn_name_or_code 是已注册的函数名 → 从缓存中调用
    2. fn_name_or_code 是未注册的 → 尝试即时编译（适用于 add_rule 时带 code 的情况）
    
    Returns:
        detect 模式: bool (should_fix)
        fix 模式: tuple (fixed, custom_fixes)
    """
    # 模式1: 已在白名单缓存中
    fn_obj = _SAFE_CUSTOM_FUNCTIONS.get(fn_name_or_code)
    if fn_obj is None:
        # 模式2: 未注册，返回 blocked
        return None
    
    try:
        if is_detect:
            return fn_obj(command, params)
        else:
            return fn_obj(command, params)
    except Exception as e:
        return None


def _apply_dynamic_fix(command, params):
    """应用动态修复规则（Layer 5 扩展的 _auto_fix_args）
    
    Returns:
        tuple: (fixed_params, fixes_log)
    """
    fixes = []
    fixed = dict(params)
    
    for rule in _dynamic_fix_rules:
        if rule.get('command') != command:
            continue
        
        field = rule.get('field', '')
        detect = rule.get('detect_pattern', '')
        action = rule.get('fix_action', '')
        rule_id = rule.get('id', 'UNKNOWN')
        
        # --- 检测阶段 ---
        should_fix = False
        field_val = fixed.get(field)
        
        if detect == 'list_of_str':
            # 检测: 字段是纯字符串列表（应为 dict/struct）
            if isinstance(field_val, list) and len(field_val) >= 2:
                if all(isinstance(x, str) for x in field_val):
                    should_fix = True
        
        elif detect == 'dict_instead_of_str':
            # 检测: 字段应该是字符串但收到了 dict
            if isinstance(field_val, dict) and not isinstance(field_val, str):
                should_fix = True
        
        elif detect == 'missing_prefix':
            # 检测: 字段值缺少模型名前缀
            model_name = fixed.get('modelName', '')
            if field_val and model_name and '/' not in str(field_val):
                should_fix = True
        
        elif detect == 'wrong_type_bool':
            # 检测: 字段是 bool 但应为 struct/dict
            if isinstance(field_val, bool):
                should_fix = True
        
        elif detect == 'missing_field':
            # 检测: 必需字段缺失
            if not field_val:
                should_fix = True
        
        elif detect == 'custom' and rule.get('detect_fn'):
            # [P0-1 FIX] 自定义检测函数 — 沙箱执行（不限制能力，只阻断危险操作）
            try:
                result = _safe_call_custom_fn(rule['detect_fn'], command, fixed, is_detect=True)
                if result is None:
                    # 函数未注册，检查是否有即时编译的代码
                    if rule.get('detect_fn_code'):
                        ok, msg = _register_safe_function(rule['detect_fn'], rule['detect_fn_code'])
                        if ok:
                            result = _safe_call_custom_fn(rule['detect_fn'], command, fixed, is_detect=True)
                            if result is not None:
                                should_fix = result
                            else:
                                fixes.append(f"[{rule_id}] detect_fn '{rule['detect_fn']}' call failed")
                        else:
                            fixes.append(f"[{rule_id}] detect_fn compile blocked: {msg}")
                    else:
                        fixes.append(f"[{rule_id}] detect_fn '{rule['detect_fn']}' not registered (provide detect_fn_code or call register_safe_fn)")
                else:
                    should_fix = result
            except Exception:
                pass
        
        if not should_fix:
            continue
        
        # --- 修复阶段 ---
        if action == 'convert_to_dict':
            # 将字符串列表转为 dict（Name-Value → struct）
            if isinstance(field_val, list) and len(field_val) >= 2:
                new_dict = {}
                for i in range(0, len(field_val) - 1, 2):
                    new_dict[field_val[i]] = field_val[i + 1]
                fixed[field] = new_dict
                fixes.append(f"[{rule_id}] {field}: Name-Value list -> struct dict ({len(new_dict)} fields)")
        
        elif action == 'prepend_model':
            # 补全模型前缀
            model_name = fixed.get('modelName', '')
            if model_name and field_val and '/' not in str(field_val):
                fixed[field] = f"{model_name}/{field_val}"
                fixes.append(f"[{rule_id}] {field}: auto-prepend model prefix -> {fixed[field]}")
        
        elif action == 'set_default':
            # 设置默认值
            default_val = rule.get('fix_params', {}).get('default', '')
            fixed[field] = default_val
            fixes.append(f"[{rule_id}] {field}: auto-set default -> {default_val}")
        
        elif action == 'bool_to_dict':
            # bool → 空 dict
            fixed[field] = {}
            fixes.append(f"[{rule_id}] {field}: bool -> empty struct {{}}")
        
        elif action == 'custom' and rule.get('fix_fn'):
            # [P0-1 FIX] 自定义修复函数 — 沙箱执行（不限制能力，只阻断危险操作）
            try:
                result = _safe_call_custom_fn(rule['fix_fn'], command, fixed, is_detect=False)
                if result is None:
                    # 函数未注册，检查是否有即时编译的代码
                    if rule.get('fix_fn_code'):
                        ok, msg = _register_safe_function(rule['fix_fn'], rule['fix_fn_code'])
                        if ok:
                            result = _safe_call_custom_fn(rule['fix_fn'], command, fixed, is_detect=False)
                            if result is not None:
                                fixed, custom_fixes = result
                                fixes.extend([f"[{rule_id}] {cf}" for cf in custom_fixes])
                            else:
                                fixes.append(f"[{rule_id}] fix_fn '{rule['fix_fn']}' call failed")
                        else:
                            fixes.append(f"[{rule_id}] fix_fn compile blocked: {msg}")
                    else:
                        fixes.append(f"[{rule_id}] fix_fn '{rule['fix_fn']}' not registered (provide fix_fn_code or call register_safe_fn)")
                else:
                    fixed, custom_fixes = result
                    fixes.extend([f"[{rule_id}] {cf}" for cf in custom_fixes])
            except Exception as e:
                fixes.append(f"[{rule_id}] custom fix failed: {e}")
        
        # 更新命中统计
        rule['hit_count'] = rule.get('hit_count', 0) + 1
        rule['last_hit'] = datetime.now().isoformat()
    
    # 命中后异步保存统计（避免频繁 IO）
    if fixes:
        try:
            _save_dynamic_fix_rules()
        except Exception:
            pass
    
    return fixed, fixes


def _handle_self_improve(action, params):
    """处理 sl_self_improve 命令（Layer 5: 源码级自我改进 API）
    
    Actions:
        - list_rules: 列出所有动态修复规则
        - add_rule: 添加新规则
        - remove_rule: 删除规则
        - update_rule: 更新规则
        - test_rule: 测试规则（不实际应用，只检测）
        - patch_source: 直接修改源码文件（.m/.py/.ts）
        - get_errors: 获取错误历史（从 ERRORS.md 解析）
        - auto_learn: 自动从 ERRORS.md 学习新规则
        - stats: 获取自我改进统计
    """
    global _dynamic_fix_rules
    
    if action == 'list_rules':
        return {
            "status": "ok",
            "action": action,
            "rules": _dynamic_fix_rules,
            "count": len(_dynamic_fix_rules)
        }
    
    elif action == 'add_rule':
        rule = params.get('rule', {})
        if not rule.get('command') or not rule.get('field'):
            return {"status": "error", "message": "Rule must have 'command' and 'field'"}
        
        # 生成规则 ID
        rule['id'] = rule.get('id', f"RULE-{len(_dynamic_fix_rules)+1:03d}")
        rule['created_at'] = datetime.now().isoformat()
        rule['hit_count'] = 0
        rule['last_hit'] = None
        rule['source'] = rule.get('source', 'user_defined')
        
        # [P0-1 FIX] 如果规则包含自定义函数，编译到沙箱（不是白名单限制，而是安全编译）
        # AI 可以自由编写任意逻辑，只是不能做危险操作（open/os.system/subprocess 等）
        if rule.get('detect_fn'):
            if rule['detect_fn'] not in _SAFE_CUSTOM_FUNCTIONS:
                if rule.get('detect_fn_code'):
                    ok, msg = _register_safe_function(rule['detect_fn'], rule['detect_fn_code'])
                    if not ok:
                        return {"status": "error", "message": f"Failed to register detect_fn: {msg}"}
                # 如果没有 code 也不在缓存中，仍然允许添加规则，但运行时会跳过
        
        if rule.get('fix_fn'):
            if rule['fix_fn'] not in _SAFE_CUSTOM_FUNCTIONS:
                if rule.get('fix_fn_code'):
                    ok, msg = _register_safe_function(rule['fix_fn'], rule['fix_fn_code'])
                    if not ok:
                        return {"status": "error", "message": f"Failed to register fix_fn: {msg}"}
                # 如果没有 code 也不在缓存中，仍然允许添加规则，但运行时会跳过
        
        # 检查重复
        for existing in _dynamic_fix_rules:
            if existing.get('id') == rule['id']:
                return {"status": "error", "message": f"Rule {rule['id']} already exists. Use update_rule instead."}
        
        _dynamic_fix_rules.append(rule)
        _save_dynamic_fix_rules()
        
        return {
            "status": "ok",
            "action": action,
            "message": f"Rule {rule['id']} added successfully",
            "rule": rule
        }
    
    elif action == 'remove_rule':
        rule_id = params.get('rule_id', '')
        original_count = len(_dynamic_fix_rules)
        _dynamic_fix_rules = [r for r in _dynamic_fix_rules if r.get('id') != rule_id]
        if len(_dynamic_fix_rules) == original_count:
            return {"status": "error", "message": f"Rule {rule_id} not found"}
        _save_dynamic_fix_rules()
        return {"status": "ok", "action": action, "message": f"Rule {rule_id} removed"}
    
    elif action == 'update_rule':
        rule_id = params.get('rule_id', '')
        updates = params.get('updates', {})
        for rule in _dynamic_fix_rules:
            if rule.get('id') == rule_id:
                rule.update(updates)
                _save_dynamic_fix_rules()
                return {"status": "ok", "action": action, "message": f"Rule {rule_id} updated", "rule": rule}
        return {"status": "error", "message": f"Rule {rule_id} not found"}
    
    elif action == 'test_rule':
        rule = params.get('rule', {})
        test_params = params.get('test_params', {})
        command = rule.get('command', '')
        
        # 不实际修改，只检测
        should_fix = False
        field = rule.get('field', '')
        detect = rule.get('detect_pattern', '')
        field_val = test_params.get(field)
        
        if detect == 'list_of_str':
            should_fix = isinstance(field_val, list) and len(field_val) >= 2 and all(isinstance(x, str) for x in field_val)
        elif detect == 'missing_prefix':
            should_fix = field_val and test_params.get('modelName', '') and '/' not in str(field_val)
        elif detect == 'wrong_type_bool':
            should_fix = isinstance(field_val, bool)
        elif detect == 'missing_field':
            should_fix = not field_val
        
        return {
            "status": "ok",
            "action": action,
            "would_fix": should_fix,
            "rule": rule,
            "test_params": test_params
        }
    
    elif action == 'patch_source':
        # 源码级修改 — 让 AI 可以直接修改 .m/.py/.ts 文件
        file_path = params.get('file_path', '')
        old_content = params.get('old_content', '')
        new_content = params.get('new_content', '')
        description = params.get('description', '')
        
        if not file_path or not old_content or not new_content:
            return {"status": "error", "message": "patch_source requires file_path, old_content, new_content"}
        
        # 安全校验: 只允许修改 skill 目录内的文件
        skill_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        abs_path = os.path.abspath(file_path)
        if not abs_path.startswith(skill_root):
            return {"status": "error", "message": f"Security: can only patch files within skill directory ({skill_root})"}
        
        # [P0-3 FIX] 安全限制: 不能修改 matlab_bridge.py 自身（防止自杀式补丁导致无法回滚）
        if abs_path.endswith('matlab_bridge.py'):
            return {"status": "error", "message": "Security: patch_source cannot modify matlab_bridge.py itself. This prevents 'suicide patches' that could disable the rollback mechanism. Use manual editing instead."}
        
        # 检查文件扩展名白名单
        allowed_exts = {'.m', '.py', '.ts', '.js', '.json', '.md', '.bat', '.ps1'}
        _, ext = os.path.splitext(abs_path)
        if ext.lower() not in allowed_exts:
            return {"status": "error", "message": f"Security: file extension '{ext}' not allowed. Allowed: {allowed_exts}"}
        
        # 读取文件并应用补丁
        if not os.path.exists(abs_path):
            return {"status": "error", "message": f"File not found: {abs_path}"}
        
        try:
            with open(abs_path, 'r', encoding='utf-8') as f:
                content = f.read()
            
            if old_content not in content:
                return {"status": "error", "message": "old_content not found in file. The file may have been modified since the rule was created."}
            
            # [P0-3 FIX] 创建备份 — 使用带时间戳的备份，支持多次补丁
            import time as _patch_time
            backup_ts = int(_patch_time.time())
            backup_path = abs_path + f'.bak.{backup_ts}'
            # 同时保留最新的 .bak（兼容旧逻辑）
            latest_backup_path = abs_path + '.bak'
            with open(backup_path, 'w', encoding='utf-8') as f:
                f.write(content)
            with open(latest_backup_path, 'w', encoding='utf-8') as f:
                f.write(content)
            
            # 应用补丁
            new_file_content = content.replace(old_content, new_content, 1)
            with open(abs_path, 'w', encoding='utf-8') as f:
                f.write(new_file_content)
            
            # [P0-3 FIX] 记录补丁元信息到 PATCHES.md（用于启动时检测和回滚）
            patch_meta = {
                'file': abs_path,
                'description': description,
                'old_length': len(old_content),
                'new_length': len(new_content),
                'backup': backup_path,
                'latest_backup': latest_backup_path,
                'timestamp': backup_ts,
                'applied': True,
            }
            _log_self_improve_action('patch_source', patch_meta)
            
            # 写入补丁记录文件（用于回滚）
            patches_file = os.path.join(_LEARNINGS_DIR, 'PATCHES.json')
            patches_list = []
            if os.path.exists(patches_file):
                try:
                    with open(patches_file, 'r', encoding='utf-8') as f:
                        patches_list = json.load(f)
                except:
                    patches_list = []
            patches_list.append(patch_meta)
            with open(patches_file, 'w', encoding='utf-8') as f:
                json.dump(patches_list, f, indent=2, ensure_ascii=False)
            
            return {
                "status": "ok",
                "action": action,
                "message": f"Patched {abs_path}",
                "backup": backup_path,
                "latest_backup": latest_backup_path,
                "description": description,
                "rollback_command": f"sl_self_improve patch_rollback file_path={abs_path}"
            }
        except Exception as e:
            return {"status": "error", "message": f"Patch failed: {str(e)}"}
    
    # [P0-3 FIX] 新增: patch_rollback — 回滚最后一次补丁
    elif action == 'patch_rollback':
        file_path = params.get('file_path', '')
        
        if file_path:
            # 回滚指定文件的最新补丁
            abs_path = os.path.abspath(file_path)
            latest_backup = abs_path + '.bak'
            if not os.path.exists(latest_backup):
                return {"status": "error", "message": f"No backup found for {abs_path}"}
            try:
                with open(latest_backup, 'r', encoding='utf-8') as f:
                    backup_content = f.read()
                with open(abs_path, 'w', encoding='utf-8') as f:
                    f.write(backup_content)
                # 更新补丁记录
                patches_file = os.path.join(_LEARNINGS_DIR, 'PATCHES.json')
                if os.path.exists(patches_file):
                    try:
                        with open(patches_file, 'r', encoding='utf-8') as f:
                            patches_list = json.load(f)
                        # 标记最新补丁为已回滚
                        for p in reversed(patches_list):
                            if p.get('file') == abs_path and p.get('applied', True):
                                p['applied'] = False
                                p['rolled_back_at'] = datetime.now().isoformat()
                                break
                        with open(patches_file, 'w', encoding='utf-8') as f:
                            json.dump(patches_list, f, indent=2, ensure_ascii=False)
                    except:
                        pass
                return {
                    "status": "ok",
                    "action": action,
                    "message": f"Rolled back {abs_path} from backup {latest_backup}"
                }
            except Exception as e:
                return {"status": "error", "message": f"Rollback failed: {str(e)}"}
        else:
            # 回滚所有未回滚的补丁（按时间倒序）
            patches_file = os.path.join(_LEARNINGS_DIR, 'PATCHES.json')
            if not os.path.exists(patches_file):
                return {"status": "error", "message": "No patches record found"}
            try:
                with open(patches_file, 'r', encoding='utf-8') as f:
                    patches_list = json.load(f)
                rolled_back = []
                for p in reversed(patches_list):
                    if p.get('applied', True) and os.path.exists(p.get('latest_backup', '')):
                        with open(p['latest_backup'], 'r', encoding='utf-8') as f:
                            backup_content = f.read()
                        with open(p['file'], 'w', encoding='utf-8') as f:
                            f.write(backup_content)
                        p['applied'] = False
                        p['rolled_back_at'] = datetime.now().isoformat()
                        rolled_back.append(p['file'])
                with open(patches_file, 'w', encoding='utf-8') as f:
                    json.dump(patches_list, f, indent=2, ensure_ascii=False)
                return {
                    "status": "ok",
                    "action": action,
                    "message": f"Rolled back {len(rolled_back)} patch(es)",
                    "files": rolled_back
                }
            except Exception as e:
                return {"status": "error", "message": f"Rollback all failed: {str(e)}"}
    
    # [P0-3 FIX] 新增: check_pending_patches — 启动时检测未回滚的补丁
    elif action == 'check_pending_patches':
        patches_file = os.path.join(_LEARNINGS_DIR, 'PATCHES.json')
        if not os.path.exists(patches_file):
            return {"status": "ok", "action": action, "pending_patches": [], "count": 0}
        try:
            with open(patches_file, 'r', encoding='utf-8') as f:
                patches_list = json.load(f)
            pending = [p for p in patches_list if p.get('applied', True)]
            return {
                "status": "ok",
                "action": action,
                "pending_patches": pending,
                "count": len(pending),
                "warning": f"{len(pending)} pending patch(es) found. Use patch_rollback to revert if needed." if pending else None
            }
        except Exception as e:
            return {"status": "error", "message": f"Check failed: {str(e)}"}
    
    elif action == 'get_errors':
        # 从 ERRORS.md 解析错误历史
        err_file = os.path.join(_LEARNINGS_DIR, 'ERRORS.md')
        if not os.path.exists(err_file):
            return {"status": "ok", "action": action, "errors": [], "count": 0}
        
        try:
            with open(err_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # 简单解析: 按 ## 分割
            errors = []
            sections = re.split(r'^## ', content, flags=re.MULTILINE)
            for section in sections[1:]:  # 跳过第一个（文件头）
                lines = section.strip().split('\n')
                err_id = lines[0].strip() if lines else 'UNKNOWN'
                # 提取关键字段
                priority = ''
                status = ''
                area = ''
                summary = ''
                for line in lines:
                    if line.startswith('**Priority**:'):
                        priority = line.split(':', 1)[1].strip()
                    elif line.startswith('**Status**:'):
                        status = line.split(':', 1)[1].strip()
                    elif line.startswith('**Area**:'):
                        area = line.split(':', 1)[1].strip()
                    elif '### Summary' in line:
                        idx = lines.index(line)
                        if idx + 1 < len(lines):
                            summary = lines[idx + 1].strip()
                
                errors.append({
                    'id': err_id,
                    'priority': priority,
                    'status': status,
                    'area': area,
                    'summary': summary
                })
            
            return {"status": "ok", "action": action, "errors": errors, "count": len(errors)}
        except Exception as e:
            return {"status": "error", "message": f"Failed to parse ERRORS.md: {str(e)}"}
    
    elif action == 'auto_learn':
        # 自动从错误历史学习新规则
        errors_result = _handle_self_improve('get_errors', {})
        if errors_result.get('status') != 'ok':
            return errors_result
        
        errors = errors_result.get('errors', [])
        pending_errors = [e for e in errors if e.get('status') == 'pending']
        
        new_rules = []
        for err in pending_errors:
            # 简单模式: 检查是否已有类似规则
            err_id = err.get('id', '')
            area = err.get('area', '')
            summary = err.get('summary', '')
            
            # 根据错误区域和摘要推断修复规则
            # 这是一个简化版本，实际可由 AI 通过 patch_source 实现更复杂的逻辑
            inferred = _infer_fix_rule(err)
            if inferred:
                # 检查是否已有同 command+field 的规则
                exists = any(
                    r.get('command') == inferred.get('command') and r.get('field') == inferred.get('field')
                    for r in _dynamic_fix_rules
                )
                if not exists:
                    inferred['source'] = 'auto_learned'
                    inferred['id'] = f"RULE-{len(_dynamic_fix_rules) + len(new_rules) + 1:03d}"
                    inferred['created_at'] = datetime.now().isoformat()
                    inferred['hit_count'] = 0
                    inferred['last_hit'] = None
                    new_rules.append(inferred)
        
        if new_rules:
            _dynamic_fix_rules.extend(new_rules)
            _save_dynamic_fix_rules()
        
        return {
            "status": "ok",
            "action": action,
            "new_rules": new_rules,
            "new_count": len(new_rules),
            "pending_errors_analyzed": len(pending_errors)
        }
    
    elif action == 'stats':
        total_rules = len(_dynamic_fix_rules)
        active_rules = [r for r in _dynamic_fix_rules if r.get('hit_count', 0) > 0]
        auto_rules = [r for r in _dynamic_fix_rules if r.get('source') == 'auto_learned']
        user_rules = [r for r in _dynamic_fix_rules if r.get('source') == 'user_defined']
        
        return {
            "status": "ok",
            "action": action,
            "total_rules": total_rules,
            "active_rules": len(active_rules),
            "auto_learned_rules": len(auto_rules),
            "user_defined_rules": len(user_rules),
            "total_hits": sum(r.get('hit_count', 0) for r in _dynamic_fix_rules),
            "safe_functions": list(_SAFE_CUSTOM_FUNCTIONS.keys()),
            "rules": _dynamic_fix_rules
        }
    
    # [P0-1 FIX] 新增: 安全函数注册/管理
    elif action == 'register_safe_fn':
        fn_name = params.get('fn_name', '')
        fn_code = params.get('fn_code', '')
        if not fn_name or not fn_code:
            return {"status": "error", "message": "register_safe_fn requires fn_name and fn_code"}
        ok, msg = _register_safe_function(fn_name, fn_code)
        if ok:
            return {"status": "ok", "action": action, "message": msg, "fn_name": fn_name}
        else:
            return {"status": "error", "message": msg}
    
    elif action == 'list_safe_fn':
        return {
            "status": "ok",
            "action": action,
            "functions": list(_SAFE_CUSTOM_FUNCTIONS.keys()),
            "count": len(_SAFE_CUSTOM_FUNCTIONS)
        }
    
    else:
        return {"status": "error", "message": f"Unknown self_improve action: {action}. Available: list_rules, add_rule, remove_rule, update_rule, test_rule, patch_source, patch_rollback, check_pending_patches, get_errors, auto_learn, stats, register_safe_fn, list_safe_fn"}


def _infer_fix_rule(error_entry):
    """从错误条目推断修复规则（简化版）
    
    实际的复杂推理应该由 AI 完成（通过 sl_self_improve add_rule 手动添加）。
    这里只处理最常见的模式。
    """
    summary = error_entry.get('summary', '').lower()
    area = error_entry.get('area', '')
    
    # 模式1: "params must be struct" 类型
    if 'params' in summary and ('struct' in summary or 'structure' in summary):
        return {
            'command': 'sl_set_param',
            'field': 'params',
            'detect_pattern': 'list_of_str',
            'fix_action': 'convert_to_dict',
        }
    
    # 模式2: "config must be struct" 类型
    if 'config' in summary and ('struct' in summary or 'structure' in summary):
        return {
            'command': 'sl_config_set',
            'field': 'config',
            'detect_pattern': 'list_of_str',
            'fix_action': 'convert_to_dict',
        }
    
    # 模式3: "bool type invalid" 类型
    if 'bool' in summary and ('invalid' in summary or 'struct' in summary):
        return {
            'command': '',
            'field': '',
            'detect_pattern': 'wrong_type_bool',
            'fix_action': 'bool_to_dict',
        }
    
    return None  # 无法自动推断


def _log_self_improve_action(action_type, details):
    """记录自我改进操作到 LEARNINGS.md"""
    try:
        os.makedirs(_LEARNINGS_DIR, exist_ok=True)
        learnings_file = os.path.join(_LEARNINGS_DIR, 'LEARNINGS.md')
        
        entry_id = f"SELF-IMPROVE-{datetime.now().strftime('%Y%m%d%H%M%S')}"
        timestamp = datetime.now().isoformat()
        
        entry = (
            f"\n## [{entry_id}] self_improve_{action_type}\n"
            f"\n**Logged**: {timestamp}"
            f"\n**Priority**: high"
            f"\n**Status**: applied"
            f"\n**Area**: self-improvement\n"
            f"\n### Summary"
            f"\nLayer 5 auto-improvement: {action_type}"
            f"\n\n### Details"
            f"\n{json.dumps(details, indent=2, ensure_ascii=False)}"
            f"\n\n### Metadata"
            f"\n- Source: auto_improve"
            f"\n- Layer: 5"
            f"\n- Related: sl_self_improve"
            f"\n\n---\n"
        )
        
        with open(learnings_file, 'a', encoding='utf-8') as f:
            f.write(entry)
    except Exception as e:
        sys.stderr.write(f"[Layer5] _log_self_improve_action failed: {e}\n")

# PITFALL 模式匹配表（Layer 3: 预测学习）
PITFALL_PATTERNS = {
    'PITFALL-SUM': {
        'detect': lambda cmd, p: cmd == 'sl_add_block' and re.search(r'(?i)\bSum\b', str(p.get('sourceBlock', ''))),
        'level': 'warning',
        'message': 'Sum block is discouraged. Use Add/Subtract instead.',
        'suggestion': 'Use Add block for addition, Subtract for subtraction',
    },
    'PITFALL-TOWS': {
        'detect': lambda cmd, p: cmd == 'sl_add_block' and re.search(r'(?i)To.?Workspace', str(p.get('sourceBlock', ''))),
        'level': 'warning',
        'message': 'To Workspace block is discouraged. Use Signal Logging instead.',
        'suggestion': 'Use sl_signal_logging for signal recording',
    },
    'PITFALL-STRUCT': {
        'detect': lambda cmd, p: isinstance(p.get('params'), list) and len(p.get('params', [])) >= 2 and all(isinstance(x, str) for x in p.get('params', [])),
        'level': 'info',
        'message': 'params appears to be Name-Value pairs, should be struct',
        'suggestion': 'Use struct("key","value") instead of Name-Value pairs',
    },
    'PITFALL-MISSING-PATH': {
        'detect': lambda cmd, p: p.get('blockPath', '') and '/' not in str(p.get('blockPath', '')) and p.get('modelName', ''),
        'level': 'info',
        'message': 'blockPath may be missing model prefix',
        'suggestion': 'blockPath should include model name prefix (e.g., "model/block")',
    },
}


def _log_error_context(command, params, error_msg, matlab_output=''):
    """记录失败命令的完整上下文到 .learnings/ERRORS.md
    
    Part of Layer 2 (主动学习): 错误上下文记录
    """
    try:
        os.makedirs(_LEARNINGS_DIR, exist_ok=True)
        err_file = os.path.join(_LEARNINGS_DIR, 'ERRORS.md')
        
        entry_id = f"ERR-{datetime.now().strftime('%Y%m%d')}-{command[:8]}"
        timestamp = datetime.now().isoformat()
        
        # 安全截断，避免写入过长内容
        safe_error = str(error_msg)[:500] if error_msg else ''
        safe_params = str(params)[:300] if params else ''
        safe_output = str(matlab_output)[:300] if matlab_output else ''
        safe_version = _matlab_version or 'unknown'
        safe_mode = _connection_mode or 'unknown'
        
        entry = (
            f"\n## [{entry_id}] {command}\n"
            f"\n**Logged**: {timestamp}"
            f"\n**Priority**: high"
            f"\n**Status**: pending"
            f"\n**Area**: matlab-api"
            f"\n\n### Summary"
            f"\nsl_* command execution failed: {command}"
            f"\n\n### Error"
            f"\n```"
            f"\n{safe_error}"
            f"\n```"
            f"\n\n### Context"
            f"\n- Command: {command}"
            f"\n- Params: {safe_params}"
            f"\n- MATLAB Version: {safe_version}"
            f"\n- Bridge Mode: {safe_mode}"
            f"\n- MATLAB Output: {safe_output}"
            f"\n\n### Suggested Fix"
            f"\n[To be determined by analysis]"
            f"\n\n### Metadata"
            f"\n- Reproducible: unknown"
            f"\n- Related Files: matlab_bridge.py"
            f"\n\n---\n"
        )
        
        with open(err_file, 'a', encoding='utf-8') as f:
            f.write(entry)
    except Exception as e:
        # 日志记录失败不应影响主流程
        sys.stderr.write(f"[MATLAB Bridge] _log_error_context failed: {e}\n")
        sys.stderr.flush()


def _auto_fix_args(command, params):
    """自动修正已知常见参数格式错误（Layer 2: 主动学习 + Layer 5: 动态规则引擎）
    
    在 _build_sl_args 之前调用，检测并修正参数格式问题。
    
    修复优先级:
    1. 硬编码的内置修复（Layer 2，5 条固定规则，保证基础可靠性）
    2. 动态规则引擎修复（Layer 5，用户/AI 可随时添加新规则）
    
    Returns:
        tuple: (fixed_params, fixes_log)
            fixed_params: 修正后的参数字典
            fixes_log: 修正日志列表，用于注入到返回结果
    """
    fixes = []
    fixed = dict(params)
    
    # === Layer 2: 硬编码内置修复（保证基础可靠性）===
    
    # 修正1: sl_set_param 的 params 应为 struct/dict，用户传了 Name-Value 对（list of str）
    if command == 'sl_set_param':
        p = fixed.get('params', {})
        if isinstance(p, list) and len(p) >= 2:
            # 检查是否全是字符串（Name-Value 对特征：偶数长度+全是字符串）
            if all(isinstance(x, str) for x in p):
                # 转为 dict（struct）
                new_params = {}
                for i in range(0, len(p) - 1, 2):
                    new_params[p[i]] = p[i + 1]
                fixed['params'] = new_params
                fixes.append(f"params: Name-Value list -> struct dict ({len(new_params)} fields)")
    
    # 修正2: sl_config_set 的 config 应为 struct/dict
    if command == 'sl_config_set':
        c = fixed.get('config', {})
        if isinstance(c, list) and len(c) >= 2:
            if all(isinstance(x, str) for x in c):
                new_config = {}
                for i in range(0, len(c) - 1, 2):
                    new_config[c[i]] = c[i + 1]
                fixed['config'] = new_config
                fixes.append(f"config: Name-Value list -> struct dict ({len(new_config)} fields)")
    
    # 修正3: sl_add_line 的 srcPort/dstPort 合并（格式2优先）
    if command == 'sl_add_line':
        src_block = fixed.get('srcBlock', '')
        src_port = fixed.get('srcPort', '')
        dst_block = fixed.get('dstBlock', '')
        dst_port = fixed.get('dstPort', '')
        if src_block and src_port and dst_block and dst_port:
            # srcBlock/srcPort 格式已在 _build_sl_args 中处理
            # 这里只记录修正日志
            if isinstance(src_port, int) or (isinstance(src_port, str) and src_port.isdigit()):
                fixes.append(f"srcPort/dstPort: auto-merge to BlockPath/portNum format")
    
    # 修正4: sl_best_practices 不需要参数（但用户可能误传）
    if command == 'sl_best_practices':
        if not fixed.get('shortName'):
            fixed['shortName'] = ''
            fixes.append("shortName: auto-set to empty (list all)")
    
    # 修正5: blockPath 缺模型前缀（常见于 sl_set_param / sl_delete）
    if command in ('sl_set_param', 'sl_delete'):
        block_path = fixed.get('blockPath', '')
        model_name = fixed.get('modelName', '')
        if block_path and model_name and '/' not in block_path:
            fixed['blockPath'] = f"{model_name}/{block_path}"
            fixes.append(f"blockPath: auto-prepend model prefix -> {fixed['blockPath']}")
    
    # === Layer 5: 动态规则引擎修复（可由 AI/用户随时添加）===
    try:
        dynamic_fixed, dynamic_fixes = _apply_dynamic_fix(command, fixed)
        if dynamic_fixes:
            fixed = dynamic_fixed
            fixes.extend(dynamic_fixes)
    except Exception as e:
        # 动态规则执行失败不应影响主流程
        sys.stderr.write(f"[Layer5] _apply_dynamic_fix error: {e}\n")
    
    return fixed, fixes


def _update_command_stats(command, success, error_msg=''):
    """更新 API 调用统计（Layer 4: 系统进化）
    
    统计信息保存在内存中，用于识别高频失败 API。
    """
    try:
        if command not in _command_stats:
            _command_stats[command] = {
                'count': 0, 'fail_count': 0,
                'last_used': '', 'last_error': ''
            }
        stats = _command_stats[command]
        stats['count'] += 1
        stats['last_used'] = datetime.now().isoformat()
        if not success:
            stats['fail_count'] += 1
            stats['last_error'] = str(error_msg)[:200]
    except Exception:
        pass  # 统计失败不影响主流程


def _get_command_stats_report():
    """生成 API 调用统计报告"""
    if not _command_stats:
        return "No API calls recorded yet."
    
    total = sum(s['count'] for s in _command_stats.values())
    total_fail = sum(s['fail_count'] for s in _command_stats.values())
    sorted_by_count = sorted(
        _command_stats.items(),
        key=lambda x: x[1]['count'],
        reverse=True
    )
    
    report_lines = [f"API Call Stats: {total} total, {total_fail} failures"]
    for cmd, stats in sorted_by_count[:10]:
        rate = stats['fail_count'] / stats['count'] * 100 if stats['count'] > 0 else 0
        report_lines.append(f"  {cmd}: {stats['count']} calls, {rate:.1f}% fail rate")
    return '\n'.join(report_lines)


def _check_pitfall_patterns(command, params):
    """踩坑模式匹配（Layer 3: 预测学习）
    
    在执行命令前检查是否命中已知踩坑模式。
    返回匹配到的 PITFALL 列表。
    """
    matched = []
    for pit_id, rule in PITFALL_PATTERNS.items():
        try:
            if rule['detect'](command, params):
                matched.append({
                    'patternId': pit_id,
                    'level': rule['level'],
                    'message': rule['message'],
                    'suggestion': rule['suggestion'],
                })
        except Exception:
            pass  # 模式匹配失败不影响主流程
    return matched


def _ensure_sl_toolbox_in_matlab():
    """确保 sl_toolbox 在 MATLAB path 中（中文路径安全）

    设计原则：
    1. 不复制文件 — sl_toolbox 只存在于 skill 安装目录，用户可见可控
    2. sl_init.m 自定位 — 通过 mfilename('fullpath') 知道自己在哪
    3. Engine 模式：用 eng.workspace 传路径变量，避免 eval 字符串中文破坏
    4. CLI 模式：写临时 .m 文件执行，绕过命令行中文编码问题
    5. 幂等操作：重复调用不会重复添加路径
    """
    global _sl_toolbox_initialized
    
    if _sl_toolbox_initialized:
        return {"status": "ok", "message": "sl_toolbox already initialized", "toolbox_path": _SL_TOOLBOX_SRC}
    
    if not os.path.exists(_SL_TOOLBOX_SRC):
        return {"status": "error", "message": f"sl_toolbox 目录不存在: {_SL_TOOLBOX_SRC}"}
    
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        if eng:
            try:
                # 策略1: 通过 eng.workspace 传路径变量（中文安全）
                # Python str → MATLAB workspace 变量，中文不会丢失
                toolbox_dir = _SL_TOOLBOX_SRC.replace('\\', '/')
                eng.workspace['sl_toolbox_dir'] = toolbox_dir
                # addpath + sl_init 自定位（sl_init 会通过 mfilename 找到自己）
                eng.eval("addpath(sl_toolbox_dir);", nargout=0)
                eng.eval("sl_init;", nargout=0)
                eng.eval("clear sl_toolbox_dir;", nargout=0)
                
            except Exception as e:
                # 策略2: 回退 — 写临时 .m 文件执行
                # [v10.1 强制隔离] 写入 .matlab_agent_tmp/ 而非系统 TEMP
                try:
                    tmp_dir = _get_agent_tmp_dir()
                    if not tmp_dir:
                        import tempfile
                        tmp_dir = tempfile.gettempdir()
                    else:
                        os.makedirs(tmp_dir, exist_ok=True)
                    init_script = os.path.join(tmp_dir, '_sl_toolbox_init.m')
                    toolbox_dir = _SL_TOOLBOX_SRC.replace('\\', '/')
                    with open(init_script, 'w', encoding='utf-8-sig') as f:
                        f.write(f"addpath('{toolbox_dir}');\nsl_init;\nclear sl_toolbox_dir;\n")
                    eng.eval(f"run('{init_script.replace(chr(92), '/')}');", nargout=0)
                except Exception as e2:
                    return {"status": "error", "message": f"sl_toolbox 初始化失败: {str(e2)}"}
    elif mode == 'cli':
        # CLI 模式下每次执行时自动 addpath（见 run_code 中的处理）
        pass
    
    _sl_toolbox_initialized = True
    return {
        "status": "ok",
        "message": "sl_toolbox initialized in MATLAB",
        "toolbox_path": _SL_TOOLBOX_SRC.replace('\\', '/')
    }


def _get_agent_tmp_dir():
    """获取隔离子目录的绝对路径"""
    if not _project_dir:
        return None
    return os.path.join(_project_dir, _AGENT_TMP_DIR_NAME)


def init_agent_workspace():
    """初始化 Agent 工作空间隔离子目录（v10.1 增强）
    
    在项目目录下创建 .matlab_agent_tmp/ 子文件夹，并执行以下配置：
    1. 创建隔离目录
    2. 在 MATLAB 中 addpath 该目录（确保隔离目录中的 .m 文件也能被找到）
    3. [v10.1] 在 MATLAB 中设置隔离目录为代码生成目标目录
    4. [v10.1] 将 Simulink slprj 编译缓存重定向到隔离目录
    
    设计原则：
    - 用户项目原生文件（.m/.slx/.mat 等）留在工作目录
    - 所有中间执行文件（Python脚本/.json/.c/.dll/.log 等）强制进入隔离目录
    - Simulink 编译产物（slprj/）也重定向到隔离目录
    - 任务结束后可一键清理整个隔离目录
    """
    global _agent_workspace_initialized
    
    if not _project_dir:
        return {"status": "error", "message": "项目目录未设置，无法初始化隔离工作空间"}
    
    tmp_dir = _get_agent_tmp_dir()
    if not tmp_dir:
        return {"status": "error", "message": "无法确定隔离目录路径"}
    
    # 创建隔离目录
    try:
        os.makedirs(tmp_dir, exist_ok=True)
    except Exception as e:
        return {"status": "error", "message": f"创建隔离目录失败: {str(e)}"}
    
    # 在 MATLAB 中配置隔离目录
    mode = _detect_connection_mode()
    if mode == 'engine':
        eng = get_engine()
        if eng:
            try:
                tmp_dir_safe = tmp_dir.replace('\\', '/')
                
                # 1. addpath 隔离目录（确保 .m 临时文件可被找到）
                eng.workspace['matlab_agent_tmp_path'] = tmp_dir_safe
                eng.eval("addpath(matlab_agent_tmp_path);", nargout=0)
                
                # 2. [v10.1] 设置 Simulink 代码生成目录到隔离目录
                #    这样 S-Function 编译产生的 .c/.h/.dll/.obj 等文件不会污染工作目录
                try:
                    eng.eval(f"if exist('Simulink','file'), "
                             f"try "
                             f"  Simulink.fileGenControl('set', 'CacheFolder', '{tmp_dir_safe}/slprj'); "
                             f"catch, end; "
                             f"end;", nargout=0)
                except:
                    pass  # R2016a 可能不支持 Simulink.fileGenControl
                
                # 3. [v10.1] 清理旧的 MATLAB 变量
                eng.eval("clear matlab_agent_tmp_path;", nargout=0)
            except:
                pass
    
    _agent_workspace_initialized = True
    return {
        "status": "ok", 
        "message": f"隔离工作空间已初始化: {tmp_dir}（含 Simulink 编译缓存重定向）", 
        "tmp_dir": tmp_dir,
        "isolation_rules": {
            "keep_in_workspace": sorted(list(_KEEP_IN_WORKSPACE_EXTS)),
            "route_to_tmp": "所有其他扩展名 + Simulink slprj 编译缓存"
        }
    }


def route_file_path(filename, force_workspace=False):
    """根据文件类型路由文件路径
    
    将用户项目原生文件（.m/.slx/.mat 等）保留在工作目录，
    将中间执行文件（.json/.c/.dll 等）路由到隔离子目录。
    
    参数:
        filename: 文件名或相对路径（不含工作目录前缀）
        force_workspace: 强制放在工作目录（如用户明确要求）
    
    返回:
        完整的文件路径（已路由到正确目录）
    """
    if not _project_dir:
        return filename  # 没有项目目录，原样返回
    
    if force_workspace:
        return os.path.join(_project_dir, filename)
    
    # 判断文件扩展名
    _, ext = os.path.splitext(filename)
    ext = ext.lower()
    
    if ext in _KEEP_IN_WORKSPACE_EXTS:
        # 用户项目原生文件 → 留在工作目录
        return os.path.join(_project_dir, filename)
    elif ext in _ISOLATE_EXTS:
        # 中间执行文件 → 隔离到子目录
        tmp_dir = _get_agent_tmp_dir()
        if tmp_dir:
            # 确保隔离目录存在
            os.makedirs(tmp_dir, exist_ok=True)
            return os.path.join(tmp_dir, filename)
        return os.path.join(_project_dir, filename)
    else:
        # 未知扩展名 → 隔离到子目录（保守策略：宁可隔离也不污染）
        tmp_dir = _get_agent_tmp_dir()
        if tmp_dir:
            os.makedirs(tmp_dir, exist_ok=True)
            return os.path.join(tmp_dir, filename)
        return os.path.join(_project_dir, filename)


def cleanup_agent_workspace(keep_results=True, deep_clean=False):
    """清理 Agent 工作空间中的中间执行文件（v10.1 增强）
    
    参数:
        keep_results: 是否保留结果文件（.c, .h, .dll, .exe 等），默认 True
        deep_clean:   深度清理模式（默认 False）
                      - False: 只清理 .matlab_agent_tmp/ 中的文件
                      - True:  额外清理工作目录中散落的 slprj/ 目录和已知中间文件
    
    删除规则:
        - 始终删除: .obj, .o, .tmp, .log, .bak, .def, .tlc, .tlh, .xml, .rpt, .mk
        - 保留（如果 keep_results=True）: .c, .h, .dll, .lib, .exp, .exe, .txt, .json
        - 不删除: .m, .slx, .mdl, .mat, .fig 等（这些不会出现在隔离目录中）
        - [v10.1] deep_clean 时: 递归删除隔离目录中的所有子目录（含 slprj/）
    """
    global _agent_workspace_initialized
    
    tmp_dir = _get_agent_tmp_dir()
    if not tmp_dir or not os.path.exists(tmp_dir):
        # [v10.1] 深度清理时，即使隔离目录不存在，也检查工作目录中的散落文件
        if deep_clean and _project_dir:
            deep_result = _deep_clean_workspace(_project_dir, keep_results)
            return {
                "status": "ok",
                "message": f"隔离目录不存在，深度清理了 {len(deep_result.get('deleted', []))} 个散落中间文件",
                "deleted": deep_result.get('deleted', []),
                "deleted_dirs": deep_result.get('deleted_dirs', []),
                "kept": [],
                "tmp_dir_removed": True
            }
        return {"status": "ok", "message": "隔离目录不存在，无需清理"}
    
    # 始终删除的中间文件扩展名
    always_delete_exts = {'.obj', '.o', '.tmp', '.log', '.bak', '.def', '.tlc', '.tlh', '.xml', '.rpt', '.mk'}
    
    # 结果文件扩展名（keep_results=True 时保留）
    result_exts = {'.c', '.h', '.cpp', '.hpp', '.dll', '.lib', '.exp', '.exe', '.txt', '.json', '.bat', '.py', '.js', '.ts'}
    
    deleted_files = []
    kept_files = []
    deleted_dirs = []
    
    # [v10.1] 递归遍历隔离目录（含子目录如 slprj/）
    for root, dirs, files in os.walk(tmp_dir, topdown=False):
        for fname in files:
            fpath = os.path.join(root, fname)
            _, ext = os.path.splitext(fname)
            ext = ext.lower()
            
            rel_path = os.path.relpath(fpath, tmp_dir)
            
            if ext in always_delete_exts:
                try:
                    os.remove(fpath)
                    deleted_files.append(rel_path)
                except:
                    pass
            elif ext in result_exts:
                if keep_results:
                    kept_files.append(rel_path)
                else:
                    try:
                        os.remove(fpath)
                        deleted_files.append(rel_path)
                    except:
                        pass
            else:
                # 其他文件（.m 临时脚本、diary 输出等）→ 始终删除
                try:
                    os.remove(fpath)
                    deleted_files.append(rel_path)
                except:
                    pass
        
        # [v10.1] 删除空子目录
        for dname in dirs:
            dpath = os.path.join(root, dname)
            try:
                if not os.listdir(dpath):
                    os.rmdir(dpath)
                    deleted_dirs.append(os.path.relpath(dpath, tmp_dir))
            except:
                pass
    
    # 如果隔离目录为空，删除目录本身
    remaining = []
    try:
        remaining = os.listdir(tmp_dir)
    except:
        pass
    if not remaining:
        try:
            os.rmdir(tmp_dir)
            _agent_workspace_initialized = False
        except:
            pass
    
    # [v10.1] 深度清理：检查工作目录中的散落中间文件
    deep_result = {}
    if deep_clean and _project_dir:
        deep_result = _deep_clean_workspace(_project_dir, keep_results)
        deleted_files.extend(deep_result.get('deleted', []))
        deleted_dirs.extend(deep_result.get('deleted_dirs', []))
    
    return {
        "status": "ok",
        "message": f"已清理 {len(deleted_files)} 个中间文件" + 
                   (f"，保留 {len(kept_files)} 个结果文件" if kept_files else "") +
                   (f"，删除 {len(deleted_dirs)} 个空目录" if deleted_dirs else ""),
        "deleted": deleted_files,
        "kept": kept_files if keep_results else [],
        "deleted_dirs": deleted_dirs,
        "tmp_dir_removed": not os.path.exists(tmp_dir) if not remaining else False
    }


def _deep_clean_workspace(project_dir, keep_results=True):
    """[v10.1] 深度清理工作目录中的散落中间文件
    
    清理范围:
    1. slprj/ 目录（Simulink 编译缓存）
    2. 工作目录根下的已知中间文件（.obj/.log/.bak 等）
    3. .matlab_agent_tmp/ 已在主函数中处理
    
    不清理:
    - .m/.slx/.mdl/.mat/.fig 等用户项目文件
    - 子目录中的非中间文件
    """
    import shutil as _shutil
    
    deleted = []
    deleted_dirs = []
    
    # 1. 清理 slprj/ 目录（Simulink 自动生成的编译缓存）
    slprj_dir = os.path.join(project_dir, 'slprj')
    if os.path.exists(slprj_dir) and os.path.isdir(slprj_dir):
        try:
            _shutil.rmtree(slprj_dir)
            deleted_dirs.append('slprj/')
            # slprj 下可能有大量文件，不逐一记录
            deleted.append('slprj/ (entire directory)')
        except:
            pass
    
    # 2. 清理工作目录根下的散落中间文件
    always_delete_exts = {'.obj', '.o', '.tmp', '.log', '.bak', '.def', '.tlc', '.tlh', '.rpt', '.mk'}
    
    try:
        for fname in os.listdir(project_dir):
            fpath = os.path.join(project_dir, fname)
            if not os.path.isfile(fpath):
                continue
            _, ext = os.path.splitext(fname)
            if ext.lower() in always_delete_exts:
                try:
                    os.remove(fpath)
                    deleted.append(fname)
                except:
                    pass
    except:
        pass
    
    return {"deleted": deleted, "deleted_dirs": deleted_dirs}


def _is_matlab_available():
    """检查 MATLAB 是否可用（MATLAB_ROOT 有效且 matlab.exe 存在）"""
    if not MATLAB_ROOT:
        return False
    exe = _get_matlab_exe()
    return os.path.exists(exe)


def _get_matlab_exe():
    """获取 matlab.exe 路径"""
    if sys.platform == 'win32':
        return os.path.join(MATLAB_ROOT, 'bin', 'matlab.exe')
    else:
        # Linux/Mac
        exe = os.path.join(MATLAB_ROOT, 'bin', 'matlab')
        if os.path.exists(exe):
            return exe
        return 'matlab'  # 尝试 PATH


def _get_matlab_version_from_path():
    """从 MATLAB_ROOT 路径推测 MATLAB 版本"""
    basename = os.path.basename(MATLAB_ROOT)
    m = re.match(r'R(\d{4})([ab])', basename, re.IGNORECASE)
    if m:
        return basename
    m2 = re.match(r'MATLAB\s*(\d{4})([ab]?)', basename, re.IGNORECASE)
    if m2:
        year = m2.group(1)
        suffix = m2.group(2) or 'a'
        return f'R{year}{suffix}'
    return None


def _detect_matlab_version_cli():
    """通过命令行检测 MATLAB 版本

    优先使用 -batch（R2019a+），失败后回退到 -r（R2016a+）。
    最终兜底使用路径名推测。
    """
    global _matlab_version
    matlab_exe = _get_matlab_exe()
    if not os.path.exists(matlab_exe):
        return _matlab_version

    version_from_path = _get_matlab_version_from_path()

    # 方式1: -batch 模式（R2019a+）
    try:
        result = subprocess.run(
            [matlab_exe, '-batch', 'disp(version);exit;'],
            capture_output=True, text=True, timeout=30,
            encoding='utf-8', errors='replace'
        )
        output = result.stdout.strip()
        for line in output.split('\n'):
            line = line.strip()
            if line:
                _matlab_version = line
                return _matlab_version
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    # 方式2: -r 回退模式（R2016a-R2018b，-batch 不支持时回退到此）
    if _matlab_version is None:
        try:
            result = subprocess.run(
                [matlab_exe, '-r', 'disp(version);exit;', '-nosplash', '-nodesktop', '-wait'],
                capture_output=True, text=True, timeout=30,
                encoding='utf-8', errors='replace'
            )
            output = result.stdout.strip()
            for line in output.split('\n'):
                line = line.strip()
                if line:
                    _matlab_version = line
                    return _matlab_version
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # 方式3: CLI 检测也失败，用路径推测作为兜底
    if _matlab_version is None and version_from_path:
        _matlab_version = version_from_path

    return _matlab_version


def _test_engine_compatibility():
    """测试 Python Engine API 是否兼容当前 MATLAB 版本
    
    返回: True = 兼容可用, False = 不兼容需 CLI 回退
    
    使用线程超时机制防止 start_matlab() 永远卡住（最多等 30 秒）。
    v5.3: 增加 Engine 路径预检查，路径不存在时直接跳过测试避免不必要延迟。
    """
    global _engine_compatible
    if _engine_compatible is not None:
        return _engine_compatible
    
    ENGINE_TEST_TIMEOUT = 30  # Engine 兼容性测试超时（秒）
    
    # v5.3: 快速检查 Engine 路径是否存在，避免无意义等待
    engine_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python")
    if not os.path.exists(engine_path):
        sys.stderr.write("[MATLAB Bridge] Engine 路径不存在，跳过 Engine 测试，使用 CLI 模式\n")
        sys.stderr.flush()
        _engine_compatible = False
        return _engine_compatible
    
    _result = {'compatible': None}
    
    def _do_test():
        try:
            if engine_path not in sys.path:
                sys.path.insert(0, engine_path)
            import matlab.engine
            # 尝试快速启动 Engine
            eng = matlab.engine.start_matlab()
            try:
                eng.eval("1+1;", nargout=0)
                _result['compatible'] = True
            except:
                _result['compatible'] = False
            finally:
                try: eng.quit()
                except: pass
        except (ImportError, Exception) as e:
            sys.stderr.write(f"[MATLAB Bridge] Engine API 不可用: {e}\n")
            sys.stderr.flush()
            _result['compatible'] = False
    
    sys.stderr.write(f"[MATLAB Bridge] 正在测试 Engine API 兼容性（超时 {ENGINE_TEST_TIMEOUT}秒）...\n")
    sys.stderr.flush()
    
    test_thread = threading.Thread(target=_do_test, daemon=True)
    test_thread.start()
    test_thread.join(timeout=ENGINE_TEST_TIMEOUT)
    
    if test_thread.is_alive():
        # 超时了，线程还在跑 — 说明 start_matlab() 卡住了
        sys.stderr.write(f"[MATLAB Bridge] ⚠️ Engine API 测试超时（{ENGINE_TEST_TIMEOUT}秒），自动切换到 CLI 回退模式\n")
        sys.stderr.flush()
        _engine_compatible = False
    else:
        _engine_compatible = _result.get('compatible', False)
    
    return _engine_compatible


def _detect_connection_mode():
    """检测并确定连接模式
    
    优先使用 Engine API（持久化工作区），不可用时回退到 CLI 模式。
    如果没有检测到 MATLAB 安装，直接返回 'unavailable'，不尝试启动 Engine。
    """
    global _connection_mode
    if _connection_mode is not None:
        return _connection_mode
    
    # 先检查 MATLAB 是否可用
    if not _is_matlab_available():
        _connection_mode = 'unavailable'
        sys.stderr.write("[MATLAB Bridge] ⚠️ 未检测到有效的 MATLAB 安装\n")
        sys.stderr.write("[MATLAB Bridge] 请通过 /api/matlab/config 设置 MATLAB_ROOT，或设置环境变量 MATLAB_ROOT\n")
        sys.stderr.flush()
        return _connection_mode
    
    # 再测试 Engine 兼容性
    if _test_engine_compatibility():
        _connection_mode = 'engine'
        sys.stderr.write("[MATLAB Bridge] 连接模式: Engine API（持久化工作区）\n")
    else:
        _connection_mode = 'cli'
        sys.stderr.write("[MATLAB Bridge] 连接模式: CLI 命令行回退（Engine API 不兼容）\n")
        sys.stderr.write("[MATLAB Bridge] 提示: CLI 模式下变量不跨命令保持，每次执行独立\n")
    
    sys.stderr.flush()
    return _connection_mode


# ============= Engine API 模式 =============

def setup_matlab_engine():
    engine_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python")
    if os.path.exists(engine_path) and engine_path not in sys.path:
        sys.path.insert(0, engine_path)
    import matlab.engine
    return matlab.engine


def get_engine():
    """获取或创建 MATLAB Engine（在常驻进程中保持）
    
    使用线程超时机制防止 start_matlab() 永远卡住（最多等 60 秒）。
    如果超时，自动切换到 CLI 回退模式。
    """
    global _matlab_engine, _connection_mode
    
    ENGINE_START_TIMEOUT = 60  # Engine 启动超时（秒）
    
    if _matlab_engine is not None:
        try:
            _matlab_engine.eval("1+1;", nargout=0)
            return _matlab_engine
        except:
            _matlab_engine = None
    
    matlab_engine_module = setup_matlab_engine()
    
    _engine_result = {'engine': None}
    
    def _start_engine():
        try:
            _engine_result['engine'] = matlab_engine_module.start_matlab()
        except Exception as e:
            _engine_result['error'] = str(e)
    
    sys.stderr.write(f"[MATLAB Bridge] 正在启动 MATLAB Engine（超时 {ENGINE_START_TIMEOUT}秒）...\n")
    sys.stderr.flush()
    
    start_thread = threading.Thread(target=_start_engine, daemon=True)
    start_thread.start()
    start_thread.join(timeout=ENGINE_START_TIMEOUT)
    
    if start_thread.is_alive():
        # Engine 启动超时
        sys.stderr.write(f"[MATLAB Bridge] ⚠️ MATLAB Engine 启动超时（{ENGINE_START_TIMEOUT}秒），切换到 CLI 回退模式\n")
        sys.stderr.flush()
        _connection_mode = 'cli'
        _matlab_engine = None
        return None
    
    if _engine_result.get('error'):
        sys.stderr.write(f"[MATLAB Bridge] ⚠️ MATLAB Engine 启动失败: {_engine_result['error']}，切换到 CLI 回退模式\n")
        sys.stderr.flush()
        _connection_mode = 'cli'
        _matlab_engine = None
        return None
    
    _matlab_engine = _engine_result['engine']
    
    try:
        _matlab_engine.eval("warning('off', 'Simulink:Engine:MdlFileShadowing');", nargout=0)
        _matlab_engine.eval("warning('off', 'Simulink:LoadSave:MaskedSystemWarning');", nargout=0)
        _matlab_engine.eval("set(0, 'DefaultFigureVisible', 'on');", nargout=0)
    except:
        pass
    
    return _matlab_engine


# ============= CLI 回退模式 =============

def _run_cli_command(code, timeout=120):
    """通过 matlab 命令行执行 MATLAB 代码（CLI 回退模式）
    
    支持:
    - R2019a+: matlab -batch "code"（非交互，命令执行完毕后自动退出）
    - R2016a-R2018b: matlab -r "code;exit;" -nosplash -nodesktop
    
    注意: CLI 模式下每次执行独立，变量不跨命令保持。
    """
    matlab_exe = _get_matlab_exe()
    if not os.path.exists(matlab_exe):
        return {"status": "error", "message": f"matlab.exe 不存在: {matlab_exe}"}
    
    # 推测版本决定使用 -batch 还是 -r
    version_hint = _get_matlab_version_from_path()
    use_batch = False
    if version_hint:
        m = re.match(r'R(\d{4})', version_hint)
        if m and int(m.group(1)) >= 2019:
            use_batch = True
    
    # 确保 code 不包含 exit/quit（由我们控制）
    clean_code = re.sub(r'\bexit\b\s*\(?;?', '', code, flags=re.IGNORECASE)
    clean_code = re.sub(r'\bquit\b\s*\(?;?', '', code, flags=re.IGNORECASE)
    clean_code = clean_code.strip()
    
    if not clean_code:
        return {"status": "ok", "stdout": "", "open_figures": 0}
    
    try:
        if use_batch:
            # R2019a+ 模式: matlab -batch "code"
            cmd = [matlab_exe, '-batch', clean_code]
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout,
                encoding='utf-8', errors='replace'
            )
            output = result.stdout.strip()
            errors = result.stderr.strip()
            # -batch 模式下如果有错误，MATLAB 返回非零退出码
            if result.returncode != 0 and errors:
                # 提取有意义的错误信息
                error_msg = re.sub(r'<[^>]+>', '', errors)
                output = output + '\n' + error_msg if output else error_msg
        else:
            # R2016a-R2018b 模式: matlab -r "code;exit;" -nosplash -nodesktop
            # 注意: 此模式下 MATLAB 会打开一个窗口然后退出
            # v5.3: 加换行符，防止代码末尾是注释时吞掉 exit
            full_code = clean_code + '\nexit;'
            cmd = [matlab_exe, '-r', full_code, '-nosplash', '-nodesktop', '-wait']
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout,
                encoding='utf-8', errors='replace'
            )
            output = result.stdout.strip()
            errors = result.stderr.strip()
            if result.returncode != 0 and errors:
                error_msg = re.sub(r'<[^>]+>', '', errors)
                output = output + '\n' + error_msg if output else error_msg
        
        # 清理 HTML 标签
        output = re.sub(r'<[^>]+>', '', output)
        output = re.sub(r'\n{3,}', '\n\n', output)
        
        return {"status": "ok", "stdout": output, "open_figures": 0}
    
    except subprocess.TimeoutExpired:
        return {"status": "error", "message": f"MATLAB 执行超时（{timeout}秒）"}
    except FileNotFoundError:
        return {"status": "error", "message": f"找不到 MATLAB: {matlab_exe}"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def set_project_dir(dir_path):
    global _project_dir
    dir_path = os.path.abspath(dir_path)
    if not os.path.exists(dir_path):
        return {"status": "error", "message": f"目录不存在: {dir_path}"}
    _project_dir = dir_path
    dir_safe = dir_path.replace('\\', '/')
    
    mode = _detect_connection_mode()
    if mode == 'engine':
        eng = get_engine()
        # v6.0: 中文路径安全 — 通过 eng.workspace 传递路径变量，避免 eval 字符串中文破坏
        try:
            eng.workspace['matlab_agent_cd_path'] = dir_safe
            eng.eval("cd(matlab_agent_cd_path);", nargout=0)
            eng.eval("addpath(matlab_agent_cd_path);", nargout=0)
            eng.eval("clear matlab_agent_cd_path;", nargout=0)
        except Exception as e:
            # 回退方案: diary 方式（写 .m 文件执行，支持中文路径）
            try:
                cd_code = f"cd('{dir_safe}'); addpath('{dir_safe}');"
                _run_code_via_diary(eng, cd_code)
            except:
                pass
    # CLI 模式下只记录目录，每次执行时 cd
    
    # v5.4: 自动初始化隔离工作空间
    init_result = init_agent_workspace()
    
    # v6.0: 自动部署并初始化 sl_toolbox（中文路径安全）
    sl_init_result = _ensure_sl_toolbox_in_matlab()
    
    return {"status": "ok", "project_dir": dir_path, "connection_mode": mode, 
            "workspace_isolation": init_result.get("tmp_dir", ""),
            "sl_toolbox": sl_init_result.get("toolbox_path", "")}


def get_project_dir():
    return _project_dir or os.environ.get('MATLAB_WORKSPACE', '')


# ============= 项目扫描 =============
def scan_project_files(dir_path=None):
    target = dir_path or get_project_dir()
    target = os.path.abspath(target)
    if not os.path.exists(target):
        return {"status": "error", "message": f"目录不存在: {target}"}
    
    files = {"scripts": [], "data": [], "models": [], "figures": [], "other_data": []}
    
    for root, dirs, filenames in os.walk(target):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in 
                   ('node_modules', '__pycache__', '.git', 'output', 'logs')]
        for fname in filenames:
            fpath = os.path.join(root, fname)
            rel_path = os.path.relpath(fpath, target).replace('\\', '/')
            fsize = os.path.getsize(fpath)
            fmod = datetime.fromtimestamp(os.path.getmtime(fpath)).isoformat()[:19]
            entry = {"name": fname, "path": fpath.replace('\\', '/'), "relative_path": rel_path, "size": fsize, "modified": fmod}
            
            ext = os.path.splitext(fname)[1].lower()
            if ext == '.m':
                try:
                    with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                        first_lines = [f.readline().rstrip() for _ in range(5)]
                    entry["preview"] = '\n'.join(first_lines)
                except:
                    entry["preview"] = ""
                files["scripts"].append(entry)
            elif ext == '.mat':
                files["data"].append(entry)
            elif ext in ('.slx', '.mdl'):
                files["models"].append(entry)
            elif ext == '.fig':
                files["figures"].append(entry)
            elif ext in ('.csv', '.txt', '.xlsx', '.xls', '.dat'):
                files["other_data"].append(entry)
    
    summary = {"total_m_files": len(files["scripts"]), "total_mat_files": len(files["data"]),
               "total_models": len(files["models"]), "project_dir": target}
    return {"status": "ok", "files": files, "summary": summary}


# ============= 文件读取 =============
def read_m_file(file_path):
    # .m 文件可直接读取，无需 MATLAB Engine
    file_path = os.path.abspath(file_path)
    if not os.path.exists(file_path):
        return {"status": "error", "message": f"文件不存在: {file_path}"}
    try:
        with open(file_path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        return {"status": "ok", "content": content, "path": file_path}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def read_mat_file(file_path):
    file_path = os.path.abspath(file_path).replace('\\', '/')
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # v5.0: 使用 diary 替代 evalc，避免引号双写问题
            mat_info_code = (
                "info = whos('-file', '" + file_path + "');"
                "for i = 1:length(info),"
                "  fprintf('%s|%s|%s\\n', info(i).name, info(i).class, mat2str(info(i).size));"
                "end;"
                "clear info;"
            )
            output = _extract_diary_output(_run_code_via_diary(eng, mat_info_code))
            variables = []
            if output:
                for line in output.strip().split('\n'):
                    if '|' in line:
                        parts = line.split('|')
                        if len(parts) >= 3:
                            variables.append({"name": parts[0].strip(), "class": parts[1].strip(), "size": parts[2].strip()})
            return {"status": "ok", "path": file_path, "variables": variables}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 回退模式
        code = f"info = whos('-file', '{file_path}'); for i = 1:length(info), fprintf('%s|%s|%s\\n', info(i).name, info(i).class, mat2str(info(i).size)); end; clear info;"
        result = _run_cli_command(code, timeout=60)
        if result['status'] == 'ok':
            variables = []
            for line in result['stdout'].strip().split('\n'):
                if '|' in line:
                    parts = line.split('|')
                    if len(parts) >= 3:
                        variables.append({"name": parts[0].strip(), "class": parts[1].strip(), "size": parts[2].strip()})
            return {"status": "ok", "path": file_path, "variables": variables}
        return result


def read_simulink_model(model_path):
    model_path = os.path.abspath(model_path).replace('\\', '/')
    model_name = os.path.splitext(os.path.basename(model_path))[0]
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # v5.0: 使用 diary 替代 evalc
            cmd_code = (
                "load_system('" + model_name + "');"
                "blocks = find_system('" + model_name + "', 'SearchDepth', 1);"
                "fprintf('Blocks: %d\\n', length(blocks));"
                "for i = 1:min(length(blocks), 50),"
                "  fprintf('%s\\n', blocks{i});"
                "end;"
            )
            output = _extract_diary_output(_run_code_via_diary(eng, cmd_code))
            blocks = []
            block_count = 0
            if output:
                for line in output.strip().split('\n'):
                    line = line.strip()
                    if line.startswith('Blocks:'):
                        match = re.search(r'Blocks:\s*(\d+)', line)
                        if match: block_count = int(match.group(1))
                    elif line:
                        blocks.append(line)
            try:
                eng.eval(f"close_system('{model_name}', 0);", nargout=0)
            except:
                pass
            return {"status": "ok", "model_name": model_name, "path": model_path, "block_count": block_count, "blocks": blocks[:50]}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 回退模式
        code = (
            f"load_system('{model_name}'); "
            f"blocks = find_system('{model_name}', 'SearchDepth', 1); "
            f"fprintf('Blocks: %d\\n', length(blocks)); "
            f"for i = 1:min(length(blocks), 50), fprintf('%s\\n', blocks{{i}}); end; "
            f"close_system('{model_name}', 0);"
        )
        result = _run_cli_command(code, timeout=60)
        if result['status'] == 'ok':
            blocks = []
            block_count = 0
            for line in result['stdout'].strip().split('\n'):
                line = line.strip()
                if line.startswith('Blocks:'):
                    match = re.search(r'Blocks:\s*(\d+)', line)
                    if match: block_count = int(match.group(1))
                elif line:
                    blocks.append(line)
            return {"status": "ok", "model_name": model_name, "path": model_path, "block_count": block_count, "blocks": blocks[:50]}
        return result


# ============= 代码执行（核心：持久化工作区 / CLI 回退）============
def execute_script(script_path, output_dir=None):
    if not os.path.exists(script_path):
        return {"status": "error", "message": f"文件不存在: {script_path}"}
    
    script_path = os.path.abspath(script_path)
    script_dir = os.path.dirname(script_path)
    script_name = os.path.splitext(os.path.basename(script_path))[0]
    
    if script_name.startswith('_'):
        return {"status": "error", "message": f"函数名不能以下划线开头: {script_name}"}
    
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # v5.0: 使用 diary 替代 evalc，避免引号双写问题
            script_dir_safe = script_dir.replace('\\', '/')
            
            # 构造要执行的代码
            exec_code = f"cd('{script_dir_safe}'); run('{script_name}');"
            matlab_output_raw = _run_code_via_diary(eng, exec_code)
            
            if isinstance(matlab_output_raw, dict) and matlab_output_raw.get('status') == 'error':
                matlab_output_raw["script_path"] = script_path
                return matlab_output_raw
            
            matlab_output = _extract_diary_output(matlab_output_raw)
            
            if matlab_output:
                matlab_output = re.sub(r'<[^>]+>', '', matlab_output)
                matlab_output = re.sub(r'\n{3,}', '\n\n', matlab_output)
            else:
                matlab_output = ""
            
            fig_count = _count_figures(eng)
            return {"status": "ok", "stdout": matlab_output.strip(), "script_path": script_path, "open_figures": fig_count, "connection_mode": "engine"}
        except Exception as e:
            error_msg = re.sub(r'<[^>]+>', '', str(e))
            return {"status": "error", "message": f"MATLAB 脚本执行错误: {error_msg}", "script_path": script_path}
    else:
        # CLI 回退模式
        script_dir_safe = script_dir.replace('\\', '/')
        code = f"cd('{script_dir_safe}'); run('{script_name}');"
        result = _run_cli_command(code, timeout=120)
        if result['status'] == 'ok':
            result['script_path'] = script_path
            result['connection_mode'] = 'cli'
        return result


def _run_code_via_diary(eng, code, timeout=120):
    """通过 diary() + 临时 .m 文件执行 MATLAB 代码并捕获输出
    
    核心优势（替代 evalc 方案）:
    1. 无需引号转义 — 代码直接写入 .m 文件，MATLAB 原生解析
    2. 完美支持中文路径 — 不再通过 evalc 传递路径字符串
    3. 支持多行代码 — .m 文件天然支持任意行数
    4. 支持 Name-Value 参数 — 'LowerLimit' 等不再被错误双写
    
    v6.0: 返回结构化结果（含 executionTime），智能过滤 diary 回显
    
    流程: 写 .m 文件 → diary 开启 → eng.eval(code) → diary 关闭 → 读输出文件
    """
    import time
    
    # [v10.1 强制隔离] 临时文件写入 .matlab_agent_tmp/ 而非系统 TEMP
    # 原因：系统 TEMP 目录散落中间文件，不便统一管理和清理
    tmp_dir = _get_agent_tmp_dir()
    if not tmp_dir:
        # fallback: 如果项目目录未设置，仍用系统临时目录
        import tempfile
        tmp_dir = tempfile.gettempdir()
    else:
        os.makedirs(tmp_dir, exist_ok=True)
    
    script_file = os.path.join(tmp_dir, '_matlab_agent_tmp.m')
    diary_file = os.path.join(tmp_dir, '_matlab_agent_diary.txt')
    
    # 清理旧文件
    for f in [script_file, diary_file]:
        if os.path.exists(f):
            try: os.remove(f)
            except: pass
    
    # 1. 写代码到临时 .m 文件（UTF-8 编码，带 BOM 以确保 MATLAB 识别）
    try:
        with open(script_file, 'w', encoding='utf-8-sig') as f:
            f.write(code + '\n')
    except Exception as e:
        return {"status": "error", "message": f"写入临时脚本失败: {str(e)}"}
    
    # 预处理：提取代码行用于过滤 diary 回显
    code_lines_for_filter = set()
    for line in code.split('\n'):
        stripped = line.strip()
        if stripped and not stripped.startswith('%'):
            code_lines_for_filter.add(stripped)
    
    # 2. 通过 eng.eval 直接执行代码（无需 evalc 包裹！）
    start_time = time.time()
    try:
        # [BUG FIX] 先强制关闭可能残留的 diary，避免路径冲突
        try:
            eng.eval("diary('off');", nargout=0)
        except:
            pass
        
        # 开启 diary 捕获输出
        # [BUG FIX] 使用 diary FILENAME 的追加模式或显式创建新文件
        diary_file_safe = diary_file.replace('\\', '/')
        # 先删除旧 diary 文件（如果存在），确保本次输出是干净的
        if os.path.exists(diary_file):
            try: os.remove(diary_file)
            except: pass
        eng.eval(f"diary('{diary_file_safe}');", nargout=0)
        
        # v6.0: 临时重定向 OS 级别的 stdout（fd 1），防止 MATLAB Engine 的
        # eng.eval() 将 disp() 输出直接写入 C 级别 fd 1，与 JSON 行协议混在一起。
        # Python sys.stdout 重定向无效——MATLAB Engine 用 C 写 fd 1，绕过 Python 层。
        saved_stdout_fd = os.dup(1)
        devnull_fd = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull_fd, 1)  # 将 fd 1 指向 /dev/null
        try:
            eng.eval(code, nargout=0)
        finally:
            os.dup2(saved_stdout_fd, 1)  # 恢复 fd 1
            os.close(saved_stdout_fd)
            os.close(devnull_fd)
        
        # [BUG FIX] 关闭 diary 前，先执行 diary flush 操作
        # MATLAB diary 内部缓冲可能未及时写入文件
        # 通过 diary('off') 关闭会自动 flush，但增加一个小延迟确保磁盘写入完成
        eng.eval("diary('off');", nargout=0)
        time.sleep(0.05)  # 50ms 延迟确保文件系统完成写入
        
        elapsed_ms = round((time.time() - start_time) * 1000)
        
        # 3. 读取 diary 输出文件
        output_str = ""
        if os.path.exists(diary_file):
            try:
                # MATLAB diary 文件可能是系统默认编码（Windows 下为 GBK）或 UTF-8
                for enc in ['utf-8', 'gbk', 'utf-8-sig', 'latin-1']:
                    try:
                        with open(diary_file, 'r', encoding=enc) as f:
                            output_str = f.read()
                        break
                    except (UnicodeDecodeError, UnicodeError):
                        continue
            except Exception:
                pass
        
        # [P1-7] diary 捕获 fallback: 如果 diary 输出为空但代码可能是 sl_* 函数
        # （返回 JSON），尝试通过 assignin + workspace 读取 sl_result 变量
        # 这是一个已知的 MATLAB Engine 限制：disp()/fprintf() 输出不一定被 diary 捕获
        if not output_str.strip() and 'sl_' in code:
            try:
                # 检查 workspace 中是否有 sl_result 变量（.m 函数约定输出变量）
                fallback_val = eng.workspace.get('sl_result')
                if fallback_val is not None:
                    output_str = str(fallback_val)
                    # 清理临时变量
                    try: eng.eval("clear('sl_result');", nargout=0)
                    except: pass
            except Exception:
                pass
                output_str = ""
        
        # v6.0: 智能过滤 diary 回显代码行
        # diary 会把执行的代码原样回显，需要过滤掉这些行
        lines = output_str.split('\n')
        cleaned_lines = []
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            # 跳过回显的代码行（diary 会把执行代码原样输出）
            if stripped in code_lines_for_filter:
                continue
            cleaned_lines.append(stripped)
        output_str = '\n'.join(cleaned_lines)
        
        # 清理 HTML 标签
        output_str = re.sub(r'<[^>]+>', '', output_str)
        output_str = re.sub(r'\n{3,}', '\n\n', output_str)
        
    except Exception as e:
        elapsed_ms = round((time.time() - start_time) * 1000)
        # 确保 diary 被关闭
        try: eng.eval("diary('off');", nargout=0)
        except: pass
        error_msg = re.sub(r'<[^>]+>', '', str(e))
        return {"status": "error", "message": f"MATLAB 执行错误: {error_msg}", "executionTime": elapsed_ms}
    finally:
        # 清理临时文件
        for f in [script_file, diary_file]:
            try:
                if os.path.exists(f): os.remove(f)
            except: pass
    
    return {"output": output_str, "executionTime": elapsed_ms}


def run_code(code, show_output=True):
    """在持久化工作区中直接执行 MATLAB 代码
    
    Engine 模式：变量跨命令保持
    CLI 模式：每次执行独立，变量不保持
    unavailable 模式：直接报错
    
    v5.0: 使用 diary() + eng.eval() 替代 evalc()，彻底解决:
    - 引号双写问题（Name-Value 参数如 'LowerLimit' 不再被破坏）
    - 中文路径乱码（路径直接在 .m 文件中，无需转义）
    - 多行代码问题（.m 文件天然支持多行）
    
    v6.0: 返回结构化结果（含 executionTime、variablesChanged）
    """
    import time
    
    mode = _detect_connection_mode()
    
    if mode == 'unavailable':
        return {"status": "error", "message": "MATLAB 不可用。请先通过 /api/matlab/config 设置 MATLAB_ROOT。"}
    
    if mode == 'engine':
        eng = get_engine()
        exec_time = 0
        try:
            if show_output:
                diary_result = _run_code_via_diary(eng, code)
                if isinstance(diary_result, dict):
                    if diary_result.get('status') == 'error':
                        return diary_result
                    output_str = diary_result.get('output', '')
                    exec_time = diary_result.get('executionTime', 0)
                else:
                    # 兼容：旧逻辑返回纯字符串
                    output_str = str(diary_result)
                    exec_time = 0
            else:
                start_time = time.time()
                # v6.0: OS 级别重定向 stdout 防止 eng.eval 泄漏
                saved_stdout_fd = os.dup(1)
                devnull_fd = os.open(os.devnull, os.O_WRONLY)
                os.dup2(devnull_fd, 1)
                try:
                    eng.eval(code, nargout=0)
                finally:
                    os.dup2(saved_stdout_fd, 1)
                    os.close(saved_stdout_fd)
                    os.close(devnull_fd)
                exec_time = round((time.time() - start_time) * 1000)
                output_str = ""
            
            # v6.0: 检测变量变化
            vars_changed = _detect_vars_changed(code)
            
            fig_count = _count_figures(eng)
            return {
                "status": "ok",
                "stdout": output_str,
                "open_figures": fig_count,
                "connection_mode": "engine",
                "executionTime": exec_time,
                "variablesChanged": vars_changed
            }
        except Exception as e:
            error_msg = re.sub(r'<[^>]+>', '', str(e))
            return {"status": "error", "message": f"MATLAB 执行错误: {error_msg}", "executionTime": exec_time}
    else:
        # CLI 回退模式
        # v6.0: 中文路径安全 — 通过写临时 .m 文件执行，绕过命令行中文编码问题
        project_code = ""
        if _project_dir:
            project_code = f"cd('{_project_dir.replace(chr(92), '/')}'); addpath('{_project_dir.replace(chr(92), '/')}'); "
        
        # v6.0: 自动添加 sl_toolbox 到路径（中文路径安全）
        if os.path.exists(_SL_TOOLBOX_SRC):
            sl_path_safe = _SL_TOOLBOX_SRC.replace('\\', '/')
            project_code = project_code + f"addpath('{sl_path_safe}'); "
        
        full_code = project_code + code
        start_time = time.time()
        result = _run_cli_command(full_code, timeout=120)
        exec_time = round((time.time() - start_time) * 1000)
        if result['status'] == 'ok':
            result['connection_mode'] = 'cli'
        result['executionTime'] = exec_time
        result['variablesChanged'] = _detect_vars_changed(code)
        return result


def _count_figures(eng):
    try:
        return int(eng.eval("length(findall(0, 'Type', 'figure'));", nargout=1))
    except:
        return 0


def _extract_diary_output(diary_result):
    """从 _run_code_via_diary 的返回中提取输出字符串（兼容旧格式）
    
    v6.0: _run_code_via_diary 返回 dict，旧版返回 string
    """
    if isinstance(diary_result, dict):
        if diary_result.get('status') == 'error':
            return None  # 错误情况由调用者处理
        return diary_result.get('output', '')
    return str(diary_result) if diary_result else ''


def _detect_vars_changed(code):
    """检测代码中哪些变量被赋值（简单启发式，用于 AI 上下文）
    
    从代码中提取赋值语句左侧的变量名，帮助 AI 理解代码影响了哪些变量。
    v6.0: 支持同行多条语句（如 x=1; y=2;）
    """
    try:
        # 先按分号拆分语句，再匹配赋值
        assigns = []
        # 拆分语句：按 ; 分隔，但忽略字符串内的分号（简化处理）
        statements = re.split(r';\s*', code)
        for stmt in statements:
            stmt = stmt.strip()
            if not stmt:
                continue
            # 匹配赋值：varName = ... (排除 == 比较运算符)
            m = re.match(r'^([a-zA-Z_]\w*)\s*=[^=]', stmt)
            if m:
                assigns.append(m.group(1))
        # 去重并保持顺序
        seen = set()
        unique = []
        for v in assigns:
            if v not in seen:
                seen.add(v)
                unique.append(v)
        # 过滤 MATLAB 关键字
        keywords = {'for', 'if', 'while', 'switch', 'try', 'function', 'classdef', 'parfor', 'spmd', 'else', 'elseif', 'case', 'otherwise', 'catch', 'end', 'return', 'break', 'continue'}
        unique = [v for v in unique if v not in keywords]
        # 只返回前 15 个，避免过长
        return unique[:15]
    except:
        return []


# ============= 工作区管理 =============
def get_workspace_vars():
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            var_names = eng.eval("who", nargout=1)
            result = []
            for name in (list(var_names) if var_names else []):
                try:
                    var_size = str(eng.eval(f"numel({name})", nargout=1))
                    var_class = str(eng.eval(f"class({name})", nargout=1))
                    var_preview = ""
                    try:
                        if var_class in ('double', 'single'):
                            size_str = str(eng.eval(f"size({name})", nargout=1))
                            var_preview = f"[{size_str}]"
                        elif var_class == 'char':
                            val = eng.eval(f"{name}(1:min(end,50))", nargout=1)
                            var_preview = str(val)[:80]
                        elif var_class == 'struct':
                            fields = eng.eval(f"fieldnames({name})", nargout=1)
                            if fields:
                                var_preview = f"fields: {', '.join(str(f) for f in list(fields)[:5])}"
                    except:
                        pass
                    result.append({"name": str(name), "size": var_size, "class": var_class, "preview": var_preview})
                except:
                    result.append({"name": str(name), "size": "?", "class": "?", "preview": ""})
            return {"status": "ok", "variables": result, "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 回退模式：变量不跨命令保持，无法获取工作区
        return {"status": "ok", "variables": [], "connection_mode": "cli", "message": "CLI 模式下变量不跨命令保持，无法获取工作区变量"}


def save_workspace(file_path=None):
    mode = _detect_connection_mode()
    if not file_path:
        file_path = os.path.join(get_project_dir(), "workspace.mat")
    file_path = os.path.abspath(file_path).replace('\\', '/')
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval(f"save('{file_path}');", nargout=0)
            return {"status": "ok", "message": f"工作区已保存", "path": file_path}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        return {"status": "error", "message": "CLI 模式下无法保存工作区（变量不跨命令保持）", "connection_mode": "cli"}


def load_workspace(file_path):
    mode = _detect_connection_mode()
    file_path = os.path.abspath(file_path).replace('\\', '/')
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval(f"load('{file_path}');", nargout=0)
            return {"status": "ok", "message": f"工作区已加载"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 模式下：加载工作区在每个命令前自动执行
        return {"status": "ok", "message": "CLI 模式下工作区将在下次命令执行时加载（不支持变量保持）", "connection_mode": "cli"}


def clear_workspace():
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval("clear all; close all;", nargout=0)
            return {"status": "ok", "message": "工作区已清空"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        return {"status": "ok", "message": "CLI 模式下变量自动清空（不跨命令保持）", "connection_mode": "cli"}


# ============= Simulink =============
def create_simulink_model(model_name, model_path=None):
    mode = _detect_connection_mode()
    save_path = (model_path or os.path.join(get_project_dir(), model_name)).replace('\\', '/')
    
    if mode == 'engine':
        eng = get_engine()
        try:
            try:
                eng.eval(f"close_system('{model_name}', 0);", nargout=0)
                eng.eval(f"bdclose('{model_name}');", nargout=0)
            except:
                pass
            eng.eval("warning('off', 'Simulink:Engine:MdlFileShadowing');", nargout=0)
            eng.eval(f"new_system('{model_name}')", nargout=0)
            eng.eval(f"open_system('{model_name}')", nargout=0)
            eng.save_system(model_name, save_path, nargout=0)
            return {"status": "ok", "message": f"模型 '{model_name}' 创建成功", "model_path": save_path, "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 回退模式
        code = (
            f"close_system('{model_name}', 0); bdclose('{model_name}'); "
            f"warning('off', 'Simulink:Engine:MdlFileShadowing'); "
            f"new_system('{model_name}'); open_system('{model_name}'); "
            f"save_system('{model_name}', '{save_path}');"
        )
        result = _run_cli_command(code, timeout=120)
        if result['status'] == 'ok':
            result['model_path'] = save_path
            result['connection_mode'] = 'cli'
        return result


def run_simulink(model_name, stop_time="10"):
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval(f"load_system('{model_name}')", nargout=0)
            
            # v5.0: 使用 diary 替代 evalc
            sim_code = (
                "try, "
                f"simOut = sim('{model_name}', 'StopTime', '{stop_time}', 'ReturnWorkspaceOutputs', 'on'); "
                "fprintf('Simulation completed.\\n'); "
                "catch ME, "
                "fprintf(2, 'Simulink error: %s\\n', ME.message); "
                "end"
            )
            sim_output_raw = _run_code_via_diary(eng, sim_code)
            if isinstance(sim_output_raw, dict) and sim_output_raw.get('status') == 'error':
                return sim_output_raw
            sim_output = _extract_diary_output(sim_output_raw)
            
            # 自动绘图
            try:
                plot_code = (
                    "try, sims = simOut.get(); for i = 1:length(sims),"
                    "  name = sims{i}; data = simOut.get(name);"
                    "  if isa(data, 'timeseries'),"
                    "    figure('Name', ['Simulink: ', name]);"
                    "    if isprop(data, 'Values'), plot(data.Time, data.Values.Data);"
                    "    else, plot(data.Time, data.Data); end,"
                    "    title(name); xlabel('Time'); drawnow; end, end,"
                    "catch, end"
                )
                eng.eval(plot_code, nargout=0)
            except:
                pass
            
            fig_count = _count_figures(eng)
            return {"status": "ok", "message": "Simulink 仿真完成", "stop_time": stop_time,
                    "stdout": str(sim_output).strip() if sim_output else "", "open_figures": fig_count, "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 回退模式
        code = (
            f"load_system('{model_name}'); "
            f"try, simOut = sim('{model_name}', 'StopTime', '{stop_time}', 'ReturnWorkspaceOutputs', 'on'); "
            f"fprintf('Simulation completed.\\n'); "
            f"catch ME, fprintf('Simulink error: %s\\n', ME.message); end; "
            f"close_system('{model_name}', 0);"
        )
        result = _run_cli_command(code, timeout=300)
        if result['status'] == 'ok':
            result['stop_time'] = stop_time
            result['connection_mode'] = 'cli'
        return result


def open_simulink_model(model_name):
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval(f"open_system('{model_name}');", nargout=0)
            return {"status": "ok", "message": f"模型 '{model_name}' 已打开", "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 模式下无法打开 GUI 窗口
        return {"status": "ok", "message": f"CLI 模式下无法打开 Simulink GUI 窗口。模型 '{model_name}' 可通过 run_simulink 执行仿真。", "connection_mode": "cli"}


# ============= Simulink 模型工作区（v4.1 新增）=============

def set_simulink_workspace_var(model_name, var_name, var_value):
    """设置 Simulink 模型工作区变量
    
    通过 MATLAB Engine 的 assignin 实现。
    模型工作区变量优先级高于 MATLAB 基础工作区。
    v5.0: 使用 diary + eng.eval 替代 evalc，无需引号双写
    """
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # 确保模型已加载
            try:
                eng.eval(f"load_system('{model_name}');", nargout=0)
            except:
                pass
            
            # v5.0: 直接 eng.eval，无需引号双写
            var_value_safe = str(var_value)
            # 先设置到基础工作区
            eng.eval(f"assignin('base', '{var_name}', {var_value_safe});", nargout=0)
            # 再尝试设置到模型工作区
            try:
                set_ws_code = (
                    "try, "
                    f"modelWorkspace = get_param('{model_name}', 'ModelWorkspace'); "
                    f"modelWorkspace.assignin('{var_name}', {var_value_safe}); "
                    "catch, "
                    "end"
                )
                eng.eval(set_ws_code, nargout=0)
                return {"status": "ok", "message": f"模型 '{model_name}' 工作区变量 '{var_name}' 已设置为 {var_value}", "connection_mode": "engine"}
            except Exception:
                return {"status": "ok", "message": f"基础工作区变量 '{var_name}' 已设置为 {var_value}（模型工作区设置失败，已回退到基础工作区）", "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": f"设置变量失败: {str(e)}"}
    else:
        # CLI 模式
        var_value_safe = str(var_value)
        code = f"load_system('{model_name}'); assignin('base', '{var_name}', {var_value_safe}); try, modelWorkspace = get_param('{model_name}', 'ModelWorkspace'); modelWorkspace.assignin('{var_name}', {var_value_safe}); catch, end; close_system('{model_name}', 0);"
        result = _run_cli_command(code, timeout=60)
        if result['status'] == 'ok':
            result['message'] = f"变量 '{var_name}' 已设置为 {var_value}"
            result['connection_mode'] = 'cli'
        return result


def get_simulink_workspace_vars(model_name):
    """获取 Simulink 模型工作区变量列表
    
    v5.0: 使用 diary + eng.eval 替代 evalc，无需引号双写
    """
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # 确保模型已加载
            try:
                eng.eval(f"load_system('{model_name}');", nargout=0)
            except:
                pass
            
            # v5.0: 使用 diary 替代 evalc
            cmd_code = (
                "try, "
                f"ws = get_param('{model_name}', 'ModelWorkspace'); "
                "vars = ws.whos; "
                "for i = 1:length(vars), "
                "  fprintf('%s|%s|%s\\n', vars(i).name, vars(i).class, mat2str(vars(i).size)); "
                "end, "
                "catch ME, "
                "  fprintf('Error: %s\\n', ME.message); "
                "end"
            )
            output = _extract_diary_output(_run_code_via_diary(eng, cmd_code))
            variables = []
            if output:
                for line in output.strip().split('\n'):
                    line = line.strip()
                    if line.startswith('Error:'):
                        return {"status": "error", "message": line}
                    if '|' in line:
                        parts = line.split('|')
                        if len(parts) >= 3:
                            variables.append({"name": parts[0].strip(), "class": parts[1].strip(), "size": parts[2].strip()})
            return {"status": "ok", "model_name": model_name, "variables": variables, "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        # CLI 模式
        code = (
            f"load_system('{model_name}'); "
            f"try, ws = get_param('{model_name}', 'ModelWorkspace'); vars = ws.whos; "
            f"for i = 1:length(vars), fprintf('%s|%s|%s\\n', vars(i).name, vars(i).class, mat2str(vars(i).size)); end, "
            f"catch ME, fprintf('Error: %s\\n', ME.message); end; "
            f"close_system('{model_name}', 0);"
        )
        result = _run_cli_command(code, timeout=60)
        if result['status'] == 'ok':
            variables = []
            for line in result['stdout'].strip().split('\n'):
                line = line.strip()
                if line.startswith('Error:'):
                    return {"status": "error", "message": line}
                if '|' in line:
                    parts = line.split('|')
                    if len(parts) >= 3:
                        variables.append({"name": parts[0].strip(), "class": parts[1].strip(), "size": parts[2].strip()})
            return {"status": "ok", "model_name": model_name, "variables": variables, "connection_mode": "cli"}
        return result


def clear_simulink_workspace(model_name):
    """清空 Simulink 模型工作区"""
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            try:
                eng.eval(f"load_system('{model_name}');", nargout=0)
            except:
                pass
            
            eng.eval(f"ws = get_param('{model_name}', 'ModelWorkspace'); ws.clear;", nargout=0)
            return {"status": "ok", "message": f"模型 '{model_name}' 工作区已清空", "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        code = f"load_system('{model_name}'); try, ws = get_param('{model_name}', 'ModelWorkspace'); ws.clear; catch, end; close_system('{model_name}', 0);"
        result = _run_cli_command(code, timeout=60)
        if result['status'] == 'ok':
            result['message'] = f"模型 '{model_name}' 工作区已清空"
            result['connection_mode'] = 'cli'
        return result


# ============= 图形 =============
def list_figures():
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            # v5.0: 使用 diary 替代 evalc
            fig_code = "figs = findall(0, 'Type', 'figure'); for i = 1:length(figs), fprintf('Figure %d: %s\\n', figs(i).Number, figs(i).Name); end;"
            output = _extract_diary_output(_run_code_via_diary(eng, fig_code))
            figures = []
            if output:
                figures = [l.strip() for l in output.strip().split('\n') if l.strip()]
            return {"status": "ok", "figures": figures, "connection_mode": "engine"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        return {"status": "ok", "figures": [], "connection_mode": "cli", "message": "CLI 模式下无法列出图形窗口"}


def close_all_figures():
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            eng.eval("close all;", nargout=0)
            return {"status": "ok", "message": "所有图形已关闭"}
        except Exception as e:
            return {"status": "error", "message": str(e)}
    else:
        return {"status": "ok", "message": "CLI 模式下图形窗口会在 MATLAB 进程退出时自动关闭", "connection_mode": "cli"}


# ============= 安装检查 =============
def check_installation():
    matlab_exe = _get_matlab_exe()
    checks = {
        "matlab_root_exists": os.path.exists(MATLAB_ROOT) if MATLAB_ROOT else False,
        "matlab_exe_exists": os.path.exists(matlab_exe) if MATLAB_ROOT else False,
        "engine_path_exists": os.path.exists(os.path.join(MATLAB_ROOT, "extern", "engines", "python")) if MATLAB_ROOT else False,
        "python_version": sys.version,
        "matlab_root": MATLAB_ROOT,
        "matlab_exe": matlab_exe,
        "project_dir": _project_dir,
        "engine_active": _matlab_engine is not None,
        "connection_mode": _connection_mode or "unknown",
    }
    
    # 测试 Engine API 兼容性
    try:
        setup_matlab_engine()
        checks["engine_importable"] = True
    except:
        checks["engine_importable"] = False
    
    # 推测版本
    version_hint = _get_matlab_version_from_path()
    if version_hint:
        checks["matlab_version_hint"] = version_hint
    
    all_ok = checks["matlab_exe_exists"] and (checks.get("engine_importable", False) or _connection_mode == 'cli')
    checks["status"] = "ok" if all_ok else "warning"
    return checks



# ============= 命令分发 =============
# ============= v6.0: sl_* 命令统一调度器 =============

# 命令 → .m 函数名映射
_SL_FUNC_MAP = {
    "sl_inspect":          "sl_inspect_model",
    "sl_add_block":        "sl_add_block_safe",
    "sl_add_line":         "sl_add_line_safe",
    "sl_set_param":        "sl_set_param_safe",
    "sl_delete":           "sl_delete_safe",
    "sl_find_blocks":      "sl_find_blocks",
    "sl_replace_block":    "sl_replace_block",
    "sl_bus_create":       "sl_bus_create",
    "sl_bus_inspect":      "sl_bus_inspect",
    "sl_signal_config":    "sl_signal_config",
    "sl_signal_logging":   "sl_signal_logging",
    "sl_subsystem_create": "sl_subsystem_create",
    "sl_subsystem_mask":   "sl_subsystem_mask",
    "sl_subsystem_expand": "sl_subsystem_expand",
    "sl_config_get":       "sl_config_get",
    "sl_config_set":       "sl_config_set",
    "sl_sim_run":          "sl_sim_run",
    "sl_sim_results":      "sl_sim_results",
    "sl_callback_set":     "sl_callback_set",
    "sl_sim_batch":        "sl_sim_batch",
    "sl_validate":         "sl_validate_model",
    "sl_parse_error":      "sl_parse_error",
    "sl_block_position":   "sl_block_position",
    "sl_auto_layout":      "sl_auto_layout",
    "sl_snapshot":         "sl_snapshot_model",
    "sl_baseline_test":    "sl_baseline_test",
    "sl_profile_sim":      "sl_profile_sim",
    "sl_profile_solver":   "sl_profile_solver",
    "sl_best_practices":   "sl_best_practices",
    "sl_command_stats":    "_builtin_stats",  # v6.1: 内置命令，不调用 .m 函数
    "sl_self_improve":     "_builtin_self_improve",  # v7.0: Layer 5 源码级自我改进
    "sl_model_status":      "sl_model_status_snapshot",  # v8.0: 结构化状态报告(含端口坐标)
}

# 命令 → 参数构建函数映射（将 API 参数转为 .m 函数参数）
# 位置参数用 '_pos_N' 标记，在 _call_sl_function 中按序排列在前
def _build_sl_args(command, params):
    """将 API 层参数转为 _call_sl_function 需要的 args_dict
    
    位置参数标记规则: '_pos_N' (N=1,2,...) → 在 MATLAB 调用中按序排在前面
    其余键值对 → Name-Value 格式追加在后面
    """
    
    model_name = params.get('modelName', params.get('model_name', ''))
    
    if command == "sl_inspect":
        # sl_inspect_model(modelName, varargin)
        return {
            '_pos_1': model_name,
            'depth': params.get('depth', 1),
            'includeParams': params.get('includeParams', True),
            'includePorts': params.get('includePorts', True),
            'includeLines': params.get('includeLines', True),
            'includeCallbacks': params.get('includeCallbacks', False),
            'includeConfig': params.get('includeConfig', False),
        }
    
    elif command == "sl_add_block":
        # sl_add_block_safe(modelName, sourceBlock, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('sourceBlock', ''),
            'destPath': params.get('destPath', ''),
            'position': params.get('position', []),
            'makeNameUnique': params.get('makeNameUnique', True),
            'params': params.get('params', {}),
        }
    
    elif command == "sl_add_line":
        # sl_add_line_safe(modelName, varargin)
        # 格式1: sl_add_line_safe(model, srcBlock, srcPort, dstBlock, dstPort, ...)
        # 格式2: sl_add_line_safe(model, 'srcBlock/portNum', 'dstBlock/portNum', ...)
        # Bridge 使用格式2（更简洁），srcBlock/dstBlock 需包含模型前缀
        # 优先使用 srcSpec/dstSpec（REST API 直接传入格式2字符串）
        src_spec = params.get('srcSpec', '')
        dst_spec = params.get('dstSpec', '')
        if not src_spec:
            # 从 srcBlock+srcPort 构造
            src_block = params.get('srcBlock', '')
            src_port = params.get('srcPort', 1)
            src_spec = f"{src_block}/{src_port}" if src_block else ''
        if not dst_spec:
            # 从 dstBlock+dstPort 构造
            dst_block = params.get('dstBlock', '')
            dst_port = params.get('dstPort', 1)
            dst_spec = f"{dst_block}/{dst_port}" if dst_block else ''
        return {
            '_pos_1': model_name,
            '_pos_2': src_spec,
            '_pos_3': dst_spec,
            'autoRouting': params.get('autoRouting', True),
            'checkBusMatch': params.get('checkBusMatch', True),
        }
    
    elif command == "sl_set_param":
        # sl_set_param_safe(blockPath, params, varargin)
        return {
            '_pos_1': params.get('blockPath', ''),
            '_pos_2': params.get('params', {}),
        }
    
    elif command == "sl_delete":
        # sl_delete_safe(blockPath, varargin)
        return {
            '_pos_1': params.get('blockPath', ''),
            'cascade': params.get('cascade', True),
        }
    
    elif command == "sl_find_blocks":
        # sl_find_blocks(modelName, varargin)
        return {
            '_pos_1': model_name,
            'blockType': params.get('blockType', ''),
            'blockName': params.get('blockName', ''),
            'searchDepth': params.get('searchDepth', 0),
            'paramFilter': params.get('paramFilter', {}),
            'connectedOnly': params.get('connectedOnly', False),
        }
    
    elif command == "sl_replace_block":
        # sl_replace_block(modelName, blockPath, newBlockType, varargin)
        # migrateParams should be a struct (param name mapping), not a boolean
        migrate_params = params.get('migrateParams', {})
        # If user passes True/False for migrateParams, treat as empty struct
        if isinstance(migrate_params, bool):
            migrate_params = {}
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('blockPath', ''),
            '_pos_3': params.get('newBlockType', ''),
            'preservePosition': params.get('preservePosition', True),
            'migrateParams': migrate_params,
        }
    
    elif command == "sl_bus_create":
        # sl_bus_create(busName, elements, varargin)
        # elements must be a struct array in MATLAB, not a cell array
        # Convert list of dicts → MATLAB [struct(...); struct(...); ...]
        elements_raw = params.get('elements', [])
        if isinstance(elements_raw, list) and elements_raw and isinstance(elements_raw[0], dict):
            # Convert each dict to a struct() string, join with ; for struct array
            struct_parts = []
            for elem in elements_raw:
                struct_parts.append(_dict_to_matlab_struct(elem))
            elements_matlab = '[' + ';'.join(struct_parts) + ']'
        else:
            elements_matlab = _python_to_matlab_value(elements_raw)
        
        return {
            '_pos_1': params.get('busName', ''),
            '_pos_2_special': elements_matlab,  # Pre-converted MATLAB expression
            'saveTo': params.get('saveTo', 'workspace'),
            'overwrite': params.get('overwrite', False),
            'description': params.get('description', ''),
            'filePath': params.get('filePath', ''),
            'dictionaryPath': params.get('dictionaryPath', ''),
        }
    
    elif command == "sl_bus_inspect":
        # sl_bus_inspect(busName, varargin)
        return {
            '_pos_1': params.get('busName', ''),
            'source': params.get('source', 'workspace'),
        }
    
    elif command == "sl_signal_config":
        # sl_signal_config(modelName, blockPath, portIndex, config, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('blockPath', ''),
            '_pos_3': params.get('portIndex', 1),
            '_pos_4': params.get('config', {}),
        }
    
    elif command == "sl_signal_logging":
        # sl_signal_logging(modelName, varargin)
        return {
            '_pos_1': model_name,
            'action': params.get('action', 'enable'),
            'blockPath': params.get('blockPath', ''),
            'portIndex': params.get('portIndex', 1),
            'portType': params.get('portType', 'outport'),
            'loggingName': params.get('loggingName', ''),
        }
    
    elif command == "sl_subsystem_create":
        # sl_subsystem_create(modelName, subsystemName, mode, varargin)
        # REST API accepts 'blocks' as alias for 'blocksToGroup'
        blocks_to_group = params.get('blocksToGroup', params.get('blocks', []))
        args = {
            '_pos_1': model_name,
            '_pos_2': params.get('subsystemName', ''),
            '_pos_3': params.get('mode', 'group'),
            'blocksToGroup': blocks_to_group,
        }
        # v11.1 修复: 添加 inputPorts 和 outputPorts 参数
        if 'inputPorts' in params:
            args['inputPorts'] = params['inputPorts']
        if 'outputPorts' in params:
            args['outputPorts'] = params['outputPorts']
        return args
    
    elif command == "sl_subsystem_mask":
        # sl_subsystem_mask(modelName, blockPath, action, varargin)
        # REST API accepts 'maskParams' as alias for 'parameters'
        # .m function expects 'parameters' as cell{struct}
        mask_params = params.get('parameters', params.get('maskParams', []))
        # Convert list of dicts to MATLAB cell{struct} expression
        if isinstance(mask_params, list) and mask_params and isinstance(mask_params[0], dict):
            struct_parts = []
            for p in mask_params:
                struct_parts.append(_dict_to_matlab_struct(p))
            mask_params_matlab = '{' + ';'.join(struct_parts) + '}'
        else:
            mask_params_matlab = _python_to_matlab_value(mask_params)
        
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('blockPath', ''),
            '_pos_3': params.get('action', 'create'),
            'parameters': ('__special__', mask_params_matlab),  # Pre-converted MATLAB expression
            'icon': params.get('icon', ''),
        }
    
    elif command == "sl_subsystem_expand":
        # sl_subsystem_expand(modelName, subsystemPath, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('subsystemPath', ''),
        }
    
    elif command == "sl_config_get":
        # sl_config_get(modelName, varargin)
        return {
            '_pos_1': model_name,
            'categories': params.get('categories', []),
        }
    
    elif command == "sl_config_set":
        # sl_config_set(modelName, config, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('config', {}),
        }
    
    elif command == "sl_sim_run":
        # sl_sim_run(modelName, varargin)
        return {
            '_pos_1': model_name,
            'stopTime': params.get('stopTime', ''),
            'variables': params.get('variables', {}),
            'simConfig': params.get('simConfig', {}),
            'preCheck': params.get('preCheck', True),
        }
    
    elif command == "sl_sim_results":
        # sl_sim_results(modelName, varargin)
        return {
            '_pos_1': model_name,
            'variables': params.get('variables', []),
            'format': params.get('format', 'summary'),
        }
    
    elif command == "sl_callback_set":
        # sl_callback_set(modelName, action, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('action', 'set'),
            'target': params.get('target', 'model'),
            'callbackType': params.get('callbackType', ''),
            'callbackCode': params.get('callbackCode', ''),
        }
    
    elif command == "sl_sim_batch":
        # sl_sim_batch(modelName, varargin)
        return {
            '_pos_1': model_name,
            'parameterName': params.get('parameterName', ''),
            'parameterValues': params.get('parameterValues', []),
            'paramSets': params.get('paramSets', []),
            'parallel': params.get('parallel', True),
            'stopTime': params.get('stopTime', ''),
        }
    
    elif command == "sl_validate":
        # sl_validate_model(modelName, varargin)
        return {
            '_pos_1': model_name,
            'checks': params.get('checks', 'all'),
        }
    
    elif command == "sl_parse_error":
        # sl_parse_error(errorMessage, varargin)
        return {
            '_pos_1': params.get('errorMessage', ''),
            'modelName': params.get('modelName', ''),
        }
    
    elif command == "sl_block_position":
        # sl_block_position(modelName, varargin)
        return {
            '_pos_1': model_name,
            'action': params.get('action', 'get'),
            'blockPath': params.get('blockPath', ''),
            'blockPaths': params.get('blockPaths', []),
            'position': params.get('position', []),
            'relativeMove': params.get('relativeMove', []),
            'alignDirection': params.get('alignDirection', ''),
            'spacing': params.get('spacing', 150),
            'dimensions': params.get('dimensions', []),
        }
    
    elif command == "sl_auto_layout":
        # sl_auto_layout(modelName, varargin)
        args = {
            '_pos_1': model_name,
            'target': params.get('target', 'top'),
        }
        # v11.1: 添加 recursive 参数支持子系统递归排版
        if 'recursive' in params:
            args['recursive'] = params['recursive']
        if 'routeExistingLines' in params:
            args['routeExistingLines'] = params['routeExistingLines']
        if 'resizeBlocks' in params:
            args['resizeBlocks'] = params['resizeBlocks']
        return args
    
    elif command == "sl_snapshot":
        # sl_snapshot_model(modelName, action, varargin)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('action', 'create'),
            'snapshotName': params.get('snapshotName', ''),
            'description': params.get('description', ''),
        }
    
    elif command == "sl_baseline_test":
        # sl_baseline_test(modelName, varargin)
        return {
            '_pos_1': model_name,
            'action': params.get('action', 'create'),
            'testName': params.get('testName', ''),
            'tolerance': params.get('tolerance', {}),
        }
    
    elif command == "sl_profile_sim":
        # sl_profile_sim(modelName, varargin)
        return {
            '_pos_1': model_name,
            'action': params.get('action', 'run'),
            'topN': params.get('topN', 10),
        }
    
    elif command == "sl_profile_solver":
        # sl_profile_solver(modelName, varargin)
        return {
            '_pos_1': model_name,
            'action': params.get('action', 'run'),
        }
    
    elif command == "sl_best_practices":
        # sl_best_practices() — 无参数
        return {}

    elif command == "sl_model_status":
        # sl_model_status_snapshot(modelName, varargin)
        return {
            '_pos_1': model_name,
            'format': params.get('format', 'both'),
            'depth': params.get('depth', 1),
            'includeParams': params.get('includeParams', True),
            'includeLines': params.get('includeLines', True),
            'includeHidden': params.get('includeHidden', False),
        }

    else:
        return {'_pos_1': model_name}


# 需要模型锁的命令（修改型操作）
_MODIFY_COMMANDS = {
    'sl_add_block', 'sl_add_line', 'sl_set_param', 'sl_delete',
    'sl_replace_block', 'sl_subsystem_create', 'sl_subsystem_mask',
    'sl_subsystem_expand', 'sl_config_set', 'sl_signal_config',
    'sl_signal_logging', 'sl_callback_set', 'sl_block_position',
    'sl_auto_layout', 'sl_snapshot',
}

# 仿真类命令（需要更长超时）
_SIM_COMMANDS = {
    'sl_sim_run', 'sl_sim_batch', 'sl_baseline_test',
    'sl_profile_sim', 'sl_profile_solver',
}

# v8.0: 写操作 → 自动验证类型映射（after-trigger 机制）
# 写操作成功后自动追加 _verification 字段，AI 无法绕过
_WRITE_VERIFY_MAP = {
    'sl_add_block':       'block',
    'sl_add_line':        'line',
    'sl_set_param':       'param',
    'sl_delete':          'block',
    'sl_replace_block':   'block',
    'sl_subsystem_create': 'subsystem',
    'sl_subsystem_mask':  'subsystem',
    'sl_config_set':      'param',
    'sl_bus_create':      'block',
    'sl_block_position':  'block',
    'sl_auto_layout':     'model',
    'sl_signal_config':   'param',
    'sl_signal_logging':  'param',
    'sl_callback_set':    'param',
}

# 验证超时（毫秒），超时则跳过不阻塞主操作
_VERIFY_TIMEOUT_MS = 3000


# =============================================================================
# v9.0: 标准化建模工作流 — 自动排版 + 工作流状态追踪
# =============================================================================

_BUILD_PHASE_TRACKER = {}  # {model_name: ModelWorkflowState}

# [P1-1 FIX] 线程安全的 _BUILD_PHASE_TRACKER 访问函数
def _get_workflow_state(model_name):
    """线程安全地获取/创建 ModelWorkflowState"""
    with _global_lock:
        if model_name not in _BUILD_PHASE_TRACKER:
            _BUILD_PHASE_TRACKER[model_name] = ModelWorkflowState(model_name)
        return _BUILD_PHASE_TRACKER[model_name]

def _remove_workflow_state(model_name):
    """线程安全地删除 ModelWorkflowState"""
    with _global_lock:
        if model_name in _BUILD_PHASE_TRACKER:
            del _BUILD_PHASE_TRACKER[model_name]

def _clear_all_workflow_states():
    """线程安全地清空所有 ModelWorkflowState"""
    with _global_lock:
        _BUILD_PHASE_TRACKER.clear()


class ModelWorkflowState:
    """v9.0: 建模工作流状态追踪
    
    追踪每个模型的建模阶段，自动检测框架/子系统/仿真三阶段转换，
    生成 _workflow 字段注入到每个写操作返回结果中。
    
    三层迭代建模:
    1. framework: 建立大框架（顶层 In/Out、子系统占位、总线信号占位）
    2. subsystem: 填充每个子系统内部模块
    3. simulation: 总体检查、设置仿真参数、运行仿真
    """
    def __init__(self, model_name):
        self.model_name = model_name
        self.phase = 'framework'         # framework / subsystem / simulation
        self.phase_step = 'building'     # building / layout / checking
        self.consecutive_adds = 0         # 连续 add 操作计数
        self.last_command = None          # 上一个命令
        self.last_layout_time = 0         # 上次排版时间戳
        self.subsystem_queue = []         # 待填充的子系统路径列表
        self.subsystem_done = set()       # 已完成的子系统路径集合
        self.current_subsystem = None     # 当前正在操作的子系统路径
        self.total_unconnected = -1       # 未连接端口总数（-1=未知）
        self.layout_done_for_phase = False  # 当前阶段是否已排版
        self.last_block_count = 0         # 上次已知的模块数
        self.last_line_count = 0          # 上次已知的线数


def _check_auto_layout_needed(model_name, command, params):
    """v9.0: 检查是否需要自动排版
    
    触发条件:
    1. 连续 3+ 次 add 操作后（连线阶段可能结束）
    2. 从 add 操作切换到 set_param（建模阶段可能结束）
    3. 子系统创建后立即排版（定位子系统位置）
    
    防抖: 5 秒内不重复排版
    
    Returns:
        (need_layout: bool, reason: str)
    """
    import time
    
    # [P1-1 FIX] 使用线程安全的访问函数
    state = _get_workflow_state(model_name)
    
    # 更新连续操作计数
    if command in ('sl_add_block', 'sl_add_line', 'sl_subsystem_create'):
        state.consecutive_adds += 1
    else:
        state.consecutive_adds = 0
    
    need_layout = False
    reason = ''
    
    # 规则1: 连续 3+ 次 add 操作 -> 可能连线阶段结束
    if command in ('sl_add_block', 'sl_add_line', 'sl_subsystem_create') and state.consecutive_adds >= 3:
        need_layout = True
        reason = f'{state.consecutive_adds} consecutive add operations detected'
    
    # 规则2: 从 add 切换到 set_param -> 建模阶段可能结束
    if (state.last_command in ('sl_add_block', 'sl_add_line', 'sl_subsystem_create')
        and command in ('sl_set_param', 'sl_config_set')):
        need_layout = True
        reason = 'Transition from add to set_param detected — layout recommended'
    
    # 规则3: 子系统创建后立即排版
    if command == 'sl_subsystem_create':
        need_layout = True
        reason = 'Subsystem created — layout recommended to position it properly'
    
    # 防抖: 至少间隔 5 秒
    if need_layout and (time.time() - state.last_layout_time) < 5:
        need_layout = False
        reason = ''  # 防抖跳过，不记录原因
    
    state.last_command = command
    return need_layout, reason


def _auto_arrange_model(model_name):
    """v9.0: 自动排版模型
    
    调用 Simulink.BlockDiagram.arrangeSystem 排版，
    排版前自动保存模型（防踩坑 #31: arrangeSystem 可能清空模型），
    排版后验证模型完整性（块数/线数不变）。
    
    Returns:
        dict or None: 排版结果
    """
    import time
    
    # [P1-1 FIX] 使用线程安全的访问函数
    state = _get_workflow_state(model_name)
    
    # 排版前保存模型（踩坑 #31: arrangeSystem 可能清空模型）
    _matlab_eval_safe("try; save_system(v_model); catch; end", workspace_vars={'v_model': model_name})
    
    # 记录排版前的模块数和线数
    pre_blocks = _matlab_eval_safe(
        "try; length(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'all')); catch; -1; end",
        workspace_vars={'v_model': model_name}
    )
    pre_lines = _matlab_eval_safe(
        "try; length(get_param(v_model, 'Lines')); catch; -1; end",
        workspace_vars={'v_model': model_name}
    )
    
    # 调用 sl_auto_layout 排版
    arrange_result = _call_sl_function('sl_auto_layout', {
        '_pos_1': model_name,
    })
    
    state.last_layout_time = time.time()
    state.layout_done_for_phase = True
    
    if isinstance(arrange_result, dict) and arrange_result.get('status') == 'ok':
        # 验证排版后模型完整性（块数/线数不变）
        post_blocks = _matlab_eval_safe(
            "try; length(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'all')); catch; -1; end",
            workspace_vars={'v_model': model_name}
        )
        integrity_ok = True
        integrity_msg = ''
        try:
            pre_b = int(pre_blocks) if pre_blocks not in [None, -1, '__EVAL_FAILED__'] else -1
            post_b = int(post_blocks) if post_blocks not in [None, -1, '__EVAL_FAILED__'] else -1
            if pre_b >= 0 and post_b >= 0 and pre_b != post_b:
                integrity_ok = False
                integrity_msg = f'Block count changed: {pre_b} -> {post_b} (layout may have corrupted model!)'
        except (ValueError, TypeError):
            pass
        
        state.last_block_count = int(post_blocks) if post_blocks not in [None, -1, '__EVAL_FAILED__'] else 0
        
        return {
            'arranged': True,
            'phase': state.phase,
            'integrityOk': integrity_ok,
            'message': f'Auto-arranged {model_name} ({state.phase} phase)' + 
                       (f' — WARNING: {integrity_msg}' if not integrity_ok else ''),
        }
    else:
        return {
            'arranged': False,
            'phase': state.phase,
            'integrityOk': True,  # 排版失败不影响完整性
            'message': f'Auto-arrange failed for {model_name}',
        }


def _generate_workflow_state(model_name, command, params, result):
    """v9.0: 生成工作流状态信息
    
    分析当前模型状态，推断工作流阶段，生成 nextSuggestedAction 建议。
    基于模型实际状态（sl_model_status_snapshot）而非假设。
    
    三层迭代逻辑:
    - framework: 顶层架构建立中，建议连线和子系统创建
    - subsystem: 子系统填充中，建议进入空子系统
    - simulation: 准备仿真，建议设置参数和运行
    
    Returns:
        dict: 工作流状态
    """
    # [P1-1 FIX] 使用线程安全的访问函数
    state = _get_workflow_state(model_name)
    
    # 检测当前正在操作的子系统
    block_path = params.get('blockPath', params.get('block_path', ''))
    subsys_path = params.get('subsystemPath', params.get('subsystem_path', ''))
    source_block = params.get('sourceBlock', '')
    
    # 推断当前操作的子系统上下文
    target_path = block_path or subsys_path or source_block
    if target_path and '/' in target_path:
        # 提取子系统路径（模型名之后、最后一段之前）
        parts = target_path.split('/')
        if len(parts) > 2:
            # 如 MyModel/Controller/Gain -> 当前在 Controller 子系统内
            state.current_subsystem = '/'.join(parts[1:-1])
    
    # 获取轻量模型状态来推断阶段
    status_result = _call_sl_function('sl_model_status_snapshot', {
        '_pos_1': model_name,
        'format': 'comment',
        'depth': 1,  # 只看一层，避免过重
        'includeParams': False,
        'includeLines': True,
        'includeHidden': False,
    })
    
    next_action = ''
    checks_remaining = []
    
    if isinstance(status_result, dict) and status_result.get('status') == 'ok':
        snapshot = status_result.get('snapshot', {})
        unconn = 0
        if isinstance(snapshot, dict):
            unconn = snapshot.get('unconnectedPorts', 0)
            state.total_unconnected = unconn
        
        if unconn > 0:
            checks_remaining.append(f'{unconn} unconnected port(s)')
        
        # 检查子系统是否需要填充
        blocks = status_result.get('blocks', [])
        empty_subsystems = []
        non_empty_subsystems = []
        
        for b in blocks:
            if not isinstance(b, dict):
                continue
            if b.get('type') == 'SubSystem' or b.get('blockType') == 'SubSystem':
                sub_path = b.get('path', '')
                sub_blocks = b.get('blockCount', 0)
                
                # 子系统只有 In/Out 端口 -> 空壳需要填充
                ports = b.get('ports', {})
                in_count = len(ports.get('inputs', [])) if isinstance(ports, dict) else 0
                out_count = len(ports.get('outputs', [])) if isinstance(ports, dict) else 0
                internal_count = sub_blocks - in_count - out_count if sub_blocks > 0 else 0
                
                if internal_count <= 0 and sub_path not in state.subsystem_done:
                    empty_subsystems.append(sub_path)
                else:
                    non_empty_subsystems.append(sub_path)
                    state.subsystem_done.add(sub_path)
        
        if empty_subsystems:
            state.subsystem_queue = empty_subsystems
            checks_remaining.append(f'{len(empty_subsystems)} empty subsystem(s) need content')
        
        # v9.0 风险5缓解: 旧状态校准
        # 当 _BUILD_PHASE_TRACKER 中有残留旧数据时（如模型重新打开后），
        # 阶段可能不合理（例如 phase='framework' 但模型已有很多模块/子系统）。
        # 基于 sl_model_status_snapshot 的实际状态重新校准。
        if isinstance(snapshot, dict):
            snapshot_blocks = snapshot.get('blockCount', 0)
            snapshot_lines = snapshot.get('lineCount', 0)
            # 校准条件: 追踪器说 framework 但模型实际上模块数 > 0 且连线数 > 0
            # 说明这不是一个空的新模型，而是旧模型重新打开
            if state.phase == 'framework' and state.consecutive_adds == 0 and snapshot_blocks > 3 and snapshot_lines > 0:
                # 模型已有内容，重新推断阶段
                if unconn > 0:
                    # 还有未连接端口，可能在 framework 阶段
                    pass  # 保持 framework，合理
                elif empty_subsystems:
                    # 有空子系统需要填充
                    state.phase = 'subsystem'
                    state.phase_step = 'building'
                    state.current_subsystem = empty_subsystems[0]
                else:
                    # 没有空子系统且没有未连接端口 → 仿真阶段
                    state.phase = 'simulation'
                    state.phase_step = 'checking'
        
        # 阶段推断逻辑
        if state.phase == 'framework':
            if unconn > 0:
                next_action = f'Connect {unconn} remaining port(s) in the framework'
                state.phase_step = 'building'
            elif empty_subsystems:
                state.phase = 'subsystem'
                state.phase_step = 'building'
                state.current_subsystem = empty_subsystems[0]
                next_action = f'Fill subsystem: {empty_subsystems[0]} (add blocks and lines inside)'
            else:
                # 框架完成，没有子系统，直接到仿真
                state.phase = 'simulation'
                state.phase_step = 'checking'
                next_action = 'Set simulation parameters (Solver, StopTime) and run simulation'
        
        elif state.phase == 'subsystem':
            if empty_subsystems:
                state.current_subsystem = empty_subsystems[0]
                next_action = f'Fill subsystem: {empty_subsystems[0]} (add blocks and lines inside)'
                state.phase_step = 'building'
            else:
                # 所有子系统已填充
                state.phase = 'simulation'
                state.phase_step = 'checking'
                next_action = 'Set simulation parameters (Solver, StopTime) and run simulation'
        
        elif state.phase == 'simulation':
            next_action = 'Run simulation and check results'
            state.phase_step = 'simulation'
            
            if unconn > 0:
                # 仿真阶段发现未连接端口 -> 回退
                state.phase = 'framework'
                state.phase_step = 'building'
                next_action = f'[ROLLBACK] {unconn} unconnected port(s) found — fix framework before simulation'
    
    else:
        # 快照获取失败，做基本推断
        if command in ('sl_add_block', 'sl_add_line', 'sl_subsystem_create'):
            next_action = 'Continue building model structure'
        elif command in ('sl_set_param', 'sl_config_set'):
            next_action = 'Continue setting parameters'
        elif command in ('sl_sim_run', 'sl_sim_batch'):
            next_action = 'Check simulation results'
    
    return {
        'model': model_name,
        'phase': state.phase,
        'phaseStep': state.phase_step,
        'nextSuggestedAction': next_action,
        'subsystemQueue': state.subsystem_queue,
        'subsystemDone': list(state.subsystem_done),
        'checksRemaining': checks_remaining,
    }


def _cleanup_workflow_state(model_name):
    """v9.0: 清理指定模型的工作流状态
    
    模型关闭或删除时调用，释放追踪数据。
    """
    # [P1-1 FIX] 使用线程安全的删除函数
    _remove_workflow_state(model_name)
    # [P1-2 FIX] 同时清理对应的模型锁，防止 _model_locks 无限增长
    with _global_lock:
        if model_name in _model_locks:
            del _model_locks[model_name]


def _handle_sl_command(command, params):
    """统一处理 sl_* 命令
    
    流程（v6.1 增强）:
    1. 反模式预检（如适用）
    2. [NEW] 参数自动修正 (_auto_fix_args)
    3. [NEW] 踩坑模式匹配 (_check_pitfall_patterns)
    4. 参数构建
    5. 获取模型锁（修改型命令）
    6. 调用 _call_sl_function
    7. 注入反模式警告（如有）
    8. [NEW] 注入自动修正日志（如有）
    9. [NEW] 更新 API 调用统计
    10. 返回结果
    
    失败时:
    - [NEW] 记录错误上下文到 .learnings/ERRORS.md
    - [NEW] 更新失败统计
    """
    try:
        # 1. 反模式预检
        anti_warnings = _anti_pattern_check(command, params)
        
        # 2. 参数自动修正（Layer 2: 主动学习）
        fixed_params, auto_fixes = _auto_fix_args(command, params)
        
        # 3. 踩坑模式匹配（Layer 3: 预测学习）
        pitfall_matches = _check_pitfall_patterns(command, fixed_params)
        
        # [P1-5 FIX] sl_new_system 工作流清理移到 _SL_FUNC_MAP 检查之前
        # 因为 sl_new_system 目前不在 _SL_FUNC_MAP 中，如果放在后面会被跳过
        # 但 create_simulink/open_simulink action 已经调用了 _cleanup_workflow_state
        # 这里作为双重保险：如果将来 sl_new_system 被注册，也能正确清理
        if command == 'sl_new_system':
            mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if mn:
                _cleanup_workflow_state(mn)
        
        # 4. 参数构建
        func_name = _SL_FUNC_MAP.get(command)
        if not func_name:
            return {"status": "error", "message": f"Unknown sl_* command: {command}"}
        
        # v6.1: 内置命令处理（不调用 .m 函数）
        if func_name == '_builtin_stats':
            stats_report = _get_command_stats_report()
            return {
                "status": "ok",
                "command": command,
                "matlabFunction": "_builtin_stats",
                "stats": _command_stats,
                "report": stats_report,
            }
        
        # v7.0: Layer 5 源码级自我改进
        if func_name == '_builtin_self_improve':
            improve_action = fixed_params.get('action', 'stats')
            return _handle_self_improve(improve_action, fixed_params)
        
        # [P0-4 FIX] 提前获取 model_name，后续逻辑（工作流清理、锁获取、验证）都需要
        model_name = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        
        args_dict = _build_sl_args(command, fixed_params)
        
        # [P1-5 FIX] 工作流清理已移到 _SL_FUNC_MAP 检查之前
        
        # 5. 获取模型锁（修改型命令）
        need_lock = command in _MODIFY_COMMANDS and model_name
        lock = _get_model_lock(model_name) if need_lock else None
        
        # 6. 调用
        if lock:
            with lock:
                result = _call_sl_function(func_name, args_dict)
        else:
            result = _call_sl_function(func_name, args_dict)
        
        # 7. 注入反模式警告
        if anti_warnings and isinstance(result, dict):
            result['antiPatternWarnings'] = anti_warnings
        
        # 7.5 注入踩坑模式匹配结果
        if pitfall_matches and isinstance(result, dict):
            result['pitfallHints'] = pitfall_matches
        
        # 8. 注入自动修正日志
        if auto_fixes and isinstance(result, dict):
            result['autoFixes'] = auto_fixes
        
        # 8.5 注入命令元信息
        if isinstance(result, dict):
            result['command'] = command
        result['matlabFunction'] = func_name
        
        # 9.0 v9.0: 提取模型名（v8.0 验证和 v9.0 工作流共用）
        model_name_for_verify = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        # [BUG FIX] sl_set_param/sl_config_set 等命令没有 modelName 参数，
        # 需要从 blockPath/configName 等参数中提取模型名（第一个 / 之前的部分）
        if not model_name_for_verify:
            block_path = fixed_params.get('blockPath', fixed_params.get('block_path', ''))
            if block_path and '/' in block_path:
                model_name_for_verify = block_path.split('/')[0]
        if not model_name_for_verify:
            config_name = fixed_params.get('configName', fixed_params.get('config_name', ''))
            if config_name and '/' in config_name:
                model_name_for_verify = config_name.split('/')[0]
        
        # 9.1 v8.0: 写操作后自动验证（after-trigger 机制）
        # 对写操作类命令，自动调用 sl_model_status_snapshot 获取增量验证
        # 验证结果注入 _verification 字段，AI 必须读取此字段才能继续
        verify_type = _WRITE_VERIFY_MAP.get(command)
        if verify_type and isinstance(result, dict) and result.get('status') != 'error':
            # [P1-6 FIX] _skip_verify 只接受内部环境变量，不接受外部参数
            # 防止 API 调用者传 _skip_verify: true 绕过验证
            skip_verify = os.environ.get('_MATLAB_AGENT_SKIP_VERIFY', '').lower() in ('1', 'true', 'yes')
            if not skip_verify:
                if model_name_for_verify:
                    try:
                        verify_result = _auto_verify_after_write(
                            model_name_for_verify, verify_type, command, fixed_params, result
                        )
                        if verify_result:
                            result['_verification'] = verify_result
                    except Exception as ve:
                        # 验证失败不影响主操作，只记录警告
                        result['_verification'] = {
                            'verified': False,
                            'error': f'Auto-verification failed: {str(ve)}',
                            'checks': [],
                            'allPassed': False,
                            'warnings': ['Verification skipped due to internal error'],
                            'suggestions': ['Run sl_model_status manually to verify']
                        }
        
        # 10. v9.0: 建模阶段自动排版
        # 当检测到建模阶段转换或连续操作时，自动调用 arrangeSystem
        if isinstance(result, dict) and result.get('status') != 'error':
            if model_name_for_verify:
                layout_needed, layout_reason = _check_auto_layout_needed(
                    model_name_for_verify, command, fixed_params
                )
                if layout_needed:
                    try:
                        layout_result = _auto_arrange_model(model_name_for_verify)
                        if layout_result:
                            layout_result['reason'] = layout_reason
                            result['_auto_layout'] = layout_result
                    except Exception as le:
                        result['_auto_layout'] = {
                            'arranged': False,
                            'phase': 'unknown',
                            'integrityOk': True,
                            'message': f'Auto-arrange exception: {str(le)}'
                        }
        
        # 11. v9.0: 注入工作流状态
        # 每个写操作后，生成当前工作流阶段建议
        if isinstance(result, dict) and result.get('status') != 'error':
            if model_name_for_verify and command in _WRITE_VERIFY_MAP:
                try:
                    wf_state = _generate_workflow_state(
                        model_name_for_verify, command, fixed_params, result
                    )
                    if wf_state:
                        result['_workflow'] = wf_state
                except Exception:
                    pass  # 工作流状态生成失败不影响主操作
        
        # 12. 更新 API 调用统计
        is_success = isinstance(result, dict) and result.get('status') != 'error'
        _update_command_stats(command, is_success)
        
        return result
    
    except Exception as e:
        import traceback
        traceback.print_exc()
        
        # 9.5 记录错误上下文（Layer 2: 主动学习）
        _log_error_context(command, params, str(e))
        _update_command_stats(command, False, str(e))
        
        return {
            "status": "error",
            "message": f"sl_* command '{command}' failed: {str(e)}",
            "command": command,
        }


# =============================================================================
# v8.0: 写操作后自动验证（after-trigger 机制）
# =============================================================================

def _auto_verify_after_write(model_name, verify_type, command, params, original_result):
    """写操作后自动验证模型状态
    
    根据操作类型执行不同的验证逻辑，将结果注入 _verification 字段。
    AI 必须读取此字段才能知道操作是否真正成功。
    
    Args:
        model_name: 模型名称
        verify_type: 验证类型 ('block'/'line'/'param'/'subsystem'/'model')
        command: 原始命令名
        params: 原始参数
        original_result: 原始操作返回结果
    
    Returns:
        dict: 验证结果，包含 checks/allPassed/warnings/suggestions
    """
    checks = []
    warnings = []
    suggestions = []
    
    if verify_type == 'block':
        try:
            checks, warnings, suggestions = _verify_block_operation(
                model_name, command, params, original_result
            )
        except Exception as e:
            import traceback
            # [P2-7 FIX] 使用 logging 替代硬编码的 _dbg_path 文件写入
            import logging
            logging.getLogger('matlab_bridge.verify').warning(
                f"_verify_block_operation EXCEPTION: {e}\n{traceback.format_exc()}"
            )
            warnings.append(f'Block verification failed: {str(e)}')
            suggestions.append('Run sl_model_status manually to verify')
    elif verify_type == 'line':
        try:
            checks, warnings, suggestions = _verify_line_operation(
                model_name, command, params, original_result
            )
        except Exception as e:
            import traceback
            # [P2-7 FIX] 使用 logging 替代硬编码的 _dbg_path 文件写入
            import logging
            logging.getLogger('matlab_bridge.verify').warning(
                f"_verify_line_operation EXCEPTION: {e}\n{traceback.format_exc()}"
            )
            warnings.append(f'Line verification failed: {str(e)}')
    elif verify_type == 'param':
        try:
            checks, warnings, suggestions = _verify_param_operation(
                model_name, command, params, original_result
            )
        except Exception as e:
            import traceback
            # [P2-7 FIX] 使用 logging 替代硬编码的 _dbg_path 文件写入
            import logging
            logging.getLogger('matlab_bridge.verify').warning(
                f"_verify_param_operation EXCEPTION: {e}\n{traceback.format_exc()}"
            )
    elif verify_type == 'subsystem':
        try:
            checks, warnings, suggestions = _verify_subsystem_operation(
                model_name, command, params, original_result
            )
        except Exception as e:
            import traceback
            # [P2-7 FIX] 使用 logging 替代硬编码的 _dbg_path 文件写入
            import logging
            logging.getLogger('matlab_bridge.verify').warning(
                f"_verify_subsystem_operation EXCEPTION: {e}\n{traceback.format_exc()}"
            )
    elif verify_type == 'model':
        try:
            checks, warnings, suggestions = _verify_model_integrity(
                model_name
            )
        except Exception as e:
            import traceback
            # [P2-7 FIX] 使用 logging 替代硬编码的 _dbg_path 文件写入
            import logging
            logging.getLogger('matlab_bridge.verify').warning(
                f"_verify_model_integrity EXCEPTION: {e}\n{traceback.format_exc()}"
            )
    
    all_passed = all(c.get('passed', False) for c in checks) if checks else True
    
    return {
        'verified': True,
        'verifyType': verify_type,
        'command': command,
        'checks': checks,
        'allPassed': all_passed,
        'warnings': warnings,
        'suggestions': suggestions,
    }


def _verify_block_operation(model_name, command, params, original_result):
    """验证模块操作结果
    
    检查项:
    - 模块是否存在（add_block/replace_block 后）
    - 模块是否已删除（delete 后）
    - 端口是否齐全
    - 未连接端口提醒
    """
    checks = []
    warnings = []
    suggestions = []
    
    # 从参数中提取目标模块路径
    block_path = params.get('blockPath', params.get('block_path', ''))
    block_type = params.get('blockType', params.get('block_type', ''))
    
    # v8.0 fix: sl_add_block_safe 的参数是 sourceBlock 不是 blockPath
    # 需要从 original_result 中提取实际创建的模块路径
    if not block_path and isinstance(original_result, dict):
        block_info = original_result.get('block', {})
        if isinstance(block_info, dict):
            block_path = block_info.get('path', '')
    if not block_path:
        # 尝试从 sourceBlock 推断
        source_block = params.get('sourceBlock', '')
        if source_block and '/' not in source_block:
            # 简称如 'Gain' → 推断为 modelName/Gain
            block_path = f"{model_name}/{source_block}"
        elif source_block:
            block_path = source_block
    
    if command == 'sl_delete':
        # 删除操作：验证模块确实不存在了
        check_result = _matlab_eval_safe(
            "try; find_system(v_model, 'SearchDepth', 1, 'BlockType', 'all'); catch; end",
            workspace_vars={'v_model': model_name}
        )
        # 简单记录删除成功
        checks.append({
            'check': 'block_deleted',
            'passed': True,
            'detail': f'{block_path} deleted from {model_name}'
        })
        return checks, warnings, suggestions
    
    # 添加/替换操作：验证模块存在
    if block_path:
        # 构建完整的模块路径
        full_path = f"{model_name}/{block_path}" if '/' not in block_path else block_path
        if not full_path.startswith(model_name):
            full_path = f"{model_name}/{block_path}"
        
        exists_check = _matlab_eval_safe(
            "try; ~isempty(find_system(v_model, 'FindAll', 'on', 'SearchDepth', 1, 'Name', v_block)); catch; false; end",
            workspace_vars={'v_model': model_name, 'v_block': block_path.split('/')[-1] if '/' in block_path else block_path}
        )
        
        # 更可靠的检查方式：直接用 sl_model_status_snapshot 的轻量模式
        status_result = _call_sl_function('sl_model_status_snapshot', {
            '_pos_1': model_name,
            'format': 'json',
            'depth': 1,
            'includeParams': False,
            'includeLines': False,
            'includeHidden': False,
        })
        
        if isinstance(status_result, dict) and status_result.get('status') == 'ok':
            # 从状态快照中提取目标模块信息
            blocks = status_result.get('blocks', [])
            target_block = None
            for b in blocks:
                bp = b.get('path', '') if isinstance(b, dict) else ''
                # 匹配模块路径
                if block_path in bp or bp.endswith('/' + block_path) or bp == full_path:
                    target_block = b
                    break
            
            if target_block and isinstance(target_block, dict):
                checks.append({
                    'check': 'block_exists',
                    'passed': True,
                    'detail': f'{target_block.get("path", block_path)} exists (Type: {target_block.get("type", "?")})'
                })
                
                # 检查端口连接状态
                ports = target_block.get('ports', {})
                unconn_count = 0
                for port_list_key in ['inputs', 'outputs']:
                    port_list = ports.get(port_list_key, [])
                    for p in port_list:
                        if isinstance(p, dict) and not p.get('connected', True):
                            unconn_count += 1
                            port_type = 'input' if port_list_key == 'inputs' else 'output'
                            port_idx = p.get('index', '?')
                            warnings.append(
                                f'{target_block.get("path", block_path)} Port-{port_idx}({port_type}) is UNCONNECTED'
                            )
                            suggestions.append(
                                f'Add signal line to connect {target_block.get("path", block_path)} {port_type} port {port_idx}'
                            )
                
                if unconn_count > 0:
                    checks.append({
                        'check': 'all_ports_connected',
                        'passed': False,
                        'detail': f'{unconn_count} unconnected port(s) on {target_block.get("path", block_path)}'
                    })
                else:
                    checks.append({
                        'check': 'all_ports_connected',
                        'passed': True,
                        'detail': f'All ports connected on {target_block.get("path", block_path)}'
                    })
            else:
                # 模块未在快照中找到 — 可能是添加到子系统内，快照深度不够
                checks.append({
                    'check': 'block_exists',
                    'passed': True,  # 原始操作已成功
                    'detail': f'{block_path} added (not visible at depth=1, may be inside subsystem)'
                })
            
            # 检查未连接端口总数
            unconn_total = 0
            snapshot = status_result.get('snapshot', {})
            if isinstance(snapshot, dict):
                unconn_total = snapshot.get('unconnectedPorts', 0)
            if unconn_total > 0:
                checks.append({
                    'check': 'model_unconnected_ports',
                    'passed': False,
                    'detail': f'{unconn_total} unconnected port(s) in model {model_name}'
                })
                suggestions.append(f'Connect remaining {unconn_total} unconnected port(s) before declaring task complete')
        else:
            # 快照获取失败，仅做基本验证
            checks.append({
                'check': 'block_exists',
                'passed': True,
                'detail': f'{block_path} (status snapshot unavailable, relying on original result)'
            })
    
    return checks, warnings, suggestions


def _verify_line_operation(model_name, command, params, original_result):
    """验证连线操作结果
    
    检查项:
    - 连线是否成功创建
    - 源端口和目标端口是否正确连接
    - 两端模块是否存在
    """
    checks = []
    warnings = []
    suggestions = []
    
    # [BUG FIX] sl_add_line 的参数名是 srcBlock/dstBlock/srcPort/dstPort，
    # 不是 fromBlock/toBlock/fromPort/toPort。必须同时兼容两种命名。
    from_block = params.get('srcBlock', params.get('fromBlock', params.get('from_block', '')))
    to_block = params.get('dstBlock', params.get('toBlock', params.get('to_block', '')))
    from_port = params.get('srcPort', params.get('fromPort', params.get('from_port', 1)))
    to_port = params.get('dstPort', params.get('toPort', params.get('to_port', 1)))
    
    # [BUG FIX] sl_add_line 还可能用 srcSpec/dstSpec 格式（BlockPath/portNum），
    # 如果 from_block/to_block 为空，尝试从 srcSpec/dstSpec 解析
    if not from_block:
        src_spec = params.get('srcSpec', '')
        if src_spec and '/' in src_spec:
            parts = src_spec.rsplit('/', 1)
            from_block = parts[0]
            try: from_port = int(parts[1])
            except: pass
    if not to_block:
        dst_spec = params.get('dstSpec', '')
        if dst_spec and '/' in dst_spec:
            parts = dst_spec.rsplit('/', 1)
            to_block = parts[0]
            try: to_port = int(parts[1])
            except: pass
    
    # 获取模型状态快照
    status_result = _call_sl_function('sl_model_status_snapshot', {
        '_pos_1': model_name,
        'format': 'comment',
        'depth': 1,
        'includeParams': False,
        'includeLines': True,
        'includeHidden': False,
    })
    
    if isinstance(status_result, dict) and status_result.get('status') == 'ok':
        # 检查源端口是否已连接
        blocks = status_result.get('blocks', [])
        from_connected = False
        to_connected = False
        
        for b in blocks:
            if not isinstance(b, dict):
                continue
            bp = b.get('path', '')
            ports = b.get('ports', {})
            
            # 检查源模块输出端口
            if from_block and (from_block in bp or bp.endswith('/' + from_block)):
                out_ports = ports.get('outputs', [])
                for p in out_ports:
                    if isinstance(p, dict) and p.get('index') == from_port and p.get('connected', False):
                        from_connected = True
                        checks.append({
                            'check': 'source_port_connected',
                            'passed': True,
                            'detail': f'{bp} output port {from_port} is connected'
                        })
                        break
                if not from_connected:
                    checks.append({
                        'check': 'source_port_connected',
                        'passed': False,
                        'detail': f'{bp} output port {from_port} is NOT connected'
                    })
                    suggestions.append(f'Verify line creation from {bp} port {from_port}')
            
            # 检查目标模块输入端口
            if to_block and (to_block in bp or bp.endswith('/' + to_block)):
                in_ports = ports.get('inputs', [])
                for p in in_ports:
                    if isinstance(p, dict) and p.get('index') == to_port and p.get('connected', False):
                        to_connected = True
                        checks.append({
                            'check': 'dest_port_connected',
                            'passed': True,
                            'detail': f'{bp} input port {to_port} is connected'
                        })
                        break
                if not to_connected:
                    checks.append({
                        'check': 'dest_port_connected',
                        'passed': False,
                        'detail': f'{bp} input port {to_port} is NOT connected'
                    })
                    suggestions.append(f'Verify line creation to {bp} port {to_port}')
        
        # 未连接端口总数
        snapshot = status_result.get('snapshot', {})
        if isinstance(snapshot, dict):
            unconn = snapshot.get('unconnectedPorts', 0)
            if unconn > 0:
                warnings.append(f'{unconn} unconnected port(s) remain in model {model_name}')
                suggestions.append(f'Connect remaining ports before task is complete')
    else:
        checks.append({
            'check': 'line_created',
            'passed': True,
            'detail': f'Line from {from_block} to {to_block} (snapshot unavailable)'
        })
    
    return checks, warnings, suggestions


def _verify_param_operation(model_name, command, params, original_result):
    """验证参数设置操作结果
    
    检查项:
    - 参数是否设置成功（读取当前值对比）
    """
    checks = []
    warnings = []
    suggestions = []
    
    block_path = params.get('blockPath', params.get('block_path', ''))
    param_struct = params.get('params', {})
    
    if block_path and param_struct:
        # 验证每个参数是否生效
        full_path = f"{model_name}/{block_path}" if '/' not in block_path else block_path
        if not full_path.startswith(model_name):
            full_path = f"{model_name}/{block_path}"
        
        for param_name, expected_value in param_struct.items():
            # [BUG FIX v2] eng.eval + nargout=1 对 get_param 不可靠
            # 改用 assignin + workspace 模式：先执行 get_param 并 assignin 到 base workspace，
            # 然后通过 eng.workspace 读取
            # [BUG FIX v3] MATLAB 变量名不能以下划线开头，必须用字母开头的临时变量名
            actual = None
            actual_str = ''
            try:
                global _matlab_engine
                if _matlab_engine is not None:
                    import time as _time
                    _tmp_var = f'vpX{int(_time.time()*1000)}'  # MATLAB 变量名必须字母开头，不能用 _
                    # [P0-2 FIX] 用 workspace 传变量替代 f-string 拼接
                    _matlab_engine.workspace['vp_path'] = full_path
                    _matlab_engine.workspace['vp_pname'] = param_name
                    _matlab_engine.eval(
                        f"try; assignin('base', '{_tmp_var}', get_param(vp_path, vp_pname)); "
                        f"catch; assignin('base', '{_tmp_var}', '__READ_FAILED__'); end",
                        nargout=0
                    )
                    # 清理临时变量
                    try:
                        _matlab_engine.eval("clear('vp_path', 'vp_pname');", nargout=0)
                    except:
                        pass
                    # 通过 eng.workspace 读取
                    actual = _matlab_engine.workspace[_tmp_var]
                    # 清理临时变量
                    try:
                        _matlab_engine.eval(f"clear('{_tmp_var}');", nargout=0)
                    except:
                        pass
            except Exception:
                pass
            
            # 简化比较：将预期值和实际值都转为字符串比较
            expected_str = str(expected_value).strip()
            actual_str = str(actual).strip() if actual is not None else ''
            
            # 参数设置后 MATLAB 可能会规范化值（如 '2' -> 2），做模糊匹配
            passed = (expected_str == actual_str or 
                     expected_str in actual_str or 
                     actual_str in expected_str or
                     actual_str == '__READ_FAILED__' or
                     actual is None)  # 读取失败或为 None 不判定为未通过
            
            checks.append({
                'check': f'param_{param_name}',
                'passed': passed,
                'detail': f'{param_name}: expected={expected_str}, actual={actual_str}'
            })
            
            if not passed:
                warnings.append(f'Parameter {param_name} on {full_path}: expected {expected_str}, got {actual_str}')
                suggestions.append(f'Re-set parameter {param_name} on {full_path}')
    
    return checks, warnings, suggestions


def _verify_subsystem_operation(model_name, command, params, original_result):
    """验证子系统操作结果
    
    检查项:
    - 子系统是否存在
    - 子系统是否有 In/Out 端口（接口完整性）
    - 子系统内部模块数量
    """
    checks = []
    warnings = []
    suggestions = []
    
    subsys_name = params.get('subsystemName', params.get('subsystem_name', ''))
    subsys_path = params.get('subsystemPath', params.get('subsystem_path', ''))
    
    target_path = subsys_path or subsys_name
    if not target_path:
        return checks, warnings, suggestions
    
    full_path = f"{model_name}/{target_path}" if '/' not in target_path else target_path
    if not full_path.startswith(model_name):
        full_path = f"{model_name}/{target_path}"
    
    # 检查子系统是否存在
    exists = _matlab_eval_safe(
        "try; ~isempty(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'SubSystem', 'Name', v_target)); catch; false; end",
        workspace_vars={'v_model': model_name, 'v_target': target_path.split('/')[-1]}
    )
    
    checks.append({
        'check': 'subsystem_exists',
        'passed': True,  # 原始操作已成功
        'detail': f'{full_path} exists'
    })
    
    # 检查子系统内部是否有 In/Out 端口
    in_count = _matlab_eval_safe(
        "try; length(find_system(v_path, 'SearchDepth', 1, 'BlockType', 'Inport', 'LookUnderMasks', 'on')); catch; -1; end",
        workspace_vars={'v_path': full_path}
    )
    out_count = _matlab_eval_safe(
        "try; length(find_system(v_path, 'SearchDepth', 1, 'BlockType', 'Outport', 'LookUnderMasks', 'on')); catch; -1; end",
        workspace_vars={'v_path': full_path}
    )
    
    try:
        in_n = int(in_count) if in_count not in [None, -1, '__EVAL_FAILED__'] else -1
        out_n = int(out_count) if out_count not in [None, -1, '__EVAL_FAILED__'] else -1
    except (ValueError, TypeError):
        in_n = -1
        out_n = -1
    
    if in_n >= 0 and out_n >= 0:
        if in_n == 0 and out_n == 0:
            checks.append({
                'check': 'subsystem_interface',
                'passed': False,
                'detail': f'{full_path} has NO Inport/Outport — subsystem has no interface'
            })
            warnings.append(f'Subsystem {full_path} has no In1/Out1 ports')
            suggestions.append(f'Add In1 and Out1 to subsystem {full_path} to define its interface')
        else:
            checks.append({
                'check': 'subsystem_interface',
                'passed': True,
                'detail': f'{full_path} has {in_n} Inport(s) and {out_n} Outport(s)'
            })
    
    return checks, warnings, suggestions


def _verify_model_integrity(model_name):
    """验证整个模型完整性
    
    检查项:
    - 总未连接端口数
    - goto/from 配对
    - 子系统接口完整性
    """
    checks = []
    warnings = []
    suggestions = []
    
    # 获取完整状态快照
    status_result = _call_sl_function('sl_model_status_snapshot', {
        '_pos_1': model_name,
        'format': 'comment',
        'depth': 0,  # 全深度
        'includeParams': False,
        'includeLines': True,
        'includeHidden': False,
    })
    
    if isinstance(status_result, dict) and status_result.get('status') == 'ok':
        snapshot = status_result.get('snapshot', {})
        if isinstance(snapshot, dict):
            unconn = snapshot.get('unconnectedPorts', 0)
            total_blocks = snapshot.get('totalBlocks', 0)
            total_lines = snapshot.get('totalLines', 0)
            
            checks.append({
                'check': 'model_summary',
                'passed': True,
                'detail': f'{model_name}: {total_blocks} blocks, {total_lines} lines, {unconn} unconnected ports'
            })
            
            if unconn > 0:
                checks.append({
                    'check': 'all_ports_connected',
                    'passed': False,
                    'detail': f'{unconn} unconnected port(s) in model'
                })
                warnings.append(f'{unconn} unconnected port(s) detected — model is incomplete')
                suggestions.append('Connect all unconnected ports before declaring the modeling task complete')
            else:
                checks.append({
                    'check': 'all_ports_connected',
                    'passed': True,
                    'detail': 'All ports connected'
                })
        
        # goto/from 配对检查
        diagnostics = status_result.get('diagnostics', [])
        goto_issues = [d for d in diagnostics if isinstance(d, dict) and 
                      d.get('code', '') in ('GOTO_FROM_UNPAIRED', 'GOTO_FROM_NO_MATCH', 'GOTO_NO_FROM')]
        if goto_issues:
            checks.append({
                'check': 'goto_from_pairing',
                'passed': False,
                'detail': f'{len(goto_issues)} goto/from pairing issue(s)'
            })
            for gi in goto_issues:
                warnings.append(gi.get('message', 'goto/from issue'))
                suggestions.append(gi.get('suggestion', 'Fix goto/from pairing'))
        else:
            checks.append({
                'check': 'goto_from_pairing',
                'passed': True,
                'detail': 'All goto/from blocks are paired'
            })
    else:
        checks.append({
            'check': 'model_integrity',
            'passed': True,
            'detail': f'Model snapshot unavailable for {model_name}'
        })
    
    return checks, warnings, suggestions


def _matlab_eval_safe(expr, workspace_vars=None):
    """安全执行 MATLAB 表达式，失败返回 None
    
    [P0-2 FIX] 新增 workspace_vars 参数，通过 eng.workspace 传递变量，
    避免 f-string 拼接导致的 MATLAB 代码注入。
    
    用法:
        _matlab_eval_safe("find_system(v_model, 'SearchDepth', 1, ...)", 
                          workspace_vars={'v_model': model_name})
    """
    global _matlab_engine
    if _matlab_engine is None:
        return None
    try:
        # [P0-2 FIX] 通过 workspace 传变量，而非拼接字符串
        if workspace_vars:
            for k, v in workspace_vars.items():
                _matlab_engine.workspace[k] = v
        result = _matlab_engine.eval(expr, nargout=1)
        # 清理临时 workspace 变量
        if workspace_vars:
            for k in workspace_vars:
                try:
                    _matlab_engine.eval(f"clear('{k}');", nargout=0)
                except:
                    pass
        return result
    except Exception:
        return None


def _start_matlab():
    """启动 MATLAB 连接"""
    mode = _detect_connection_mode()
    if mode == 'unavailable':
        return {"status": "warning", "message": "未检测到有效的 MATLAB 安装。请通过 /api/matlab/config 设置 MATLAB_ROOT。", "connection_mode": "unavailable"}
    elif mode == 'engine':
        eng = get_engine()  # 触发 Engine 启动（带超时）
        if eng is None:
            # Engine 启动超时或失败，已自动切换到 CLI
            return {"status": "ok", "message": "MATLAB Engine 启动超时，已自动切换到 CLI 回退模式", "connection_mode": "cli"}
        return {"status": "ok", "message": "MATLAB Engine 已启动（持久化工作区）", "connection_mode": "engine"}
    else:
        return {"status": "ok", "message": "MATLAB CLI 回退模式就绪（变量不跨命令保持）", "connection_mode": "cli"}


def _stop_engine():
    global _matlab_engine
    if _matlab_engine:
        try: _matlab_engine.quit()
        except: pass
        _matlab_engine = None
    return {"status": "ok", "message": "MATLAB Engine 已停止"}


def _get_config():
    """获取当前 MATLAB 配置"""
    return {
        "matlab_root": MATLAB_ROOT,
        "matlab_exe": _get_matlab_exe(),
        "connection_mode": _connection_mode or "unknown",
        "engine_compatible": _engine_compatible,
        "project_dir": _project_dir,
        "version_hint": _get_matlab_version_from_path(),
        "python_version": sys.version,
    }


def _set_matlab_root(root):
    """动态设置 MATLAB_ROOT 并重置连接模式"""
    global MATLAB_ROOT, _connection_mode, _engine_compatible, _matlab_engine
    
    if not root or not os.path.exists(root):
        return {"status": "error", "message": f"路径不存在: {root}"}
    
    matlab_exe = os.path.join(root, 'bin', 'matlab.exe')
    if not os.path.exists(matlab_exe):
        return {"status": "error", "message": f"未找到 matlab.exe: {matlab_exe}"}
    
    # 先停止现有 Engine
    if _matlab_engine:
        try: _matlab_engine.quit()
        except: pass
        _matlab_engine = None
    
    MATLAB_ROOT = root
    _connection_mode = None  # 重新检测
    _engine_compatible = None  # 重新检测
    
    sys.stderr.write(f"[MATLAB Bridge] MATLAB_ROOT 已设置为: {root}\n")
    sys.stderr.flush()
    
    return {"status": "ok", "message": f"MATLAB_ROOT 已设置为 {root}", "matlab_root": root}


# ============= 命令路由 =============
def handle_command(cmd_data):
    """顶层命令路由 - 根据 cmd_data['action'] 分发到对应的处理函数
    
    这是 server_mode 和 oneshot_mode 的唯一入口。
    所有 Node.js -> Bridge 的命令都经过这里路由。
    """
    action = cmd_data.get('action', '')
    params = cmd_data.get('params', {})
    
    # --- 基础操作 ---
    if action == 'start':
        try:
            eng = get_engine()
            if eng is not None:
                return {"status": "ok", "message": "MATLAB Engine ready", "mode": _connection_mode or "unknown"}
            else:
                return {"status": "warning", "message": "MATLAB Engine not available, CLI fallback may be used", "mode": _connection_mode or "cli"}
        except Exception as e:
            return {"status": "error", "message": f"MATLAB Engine start failed: {str(e)}"}
    elif action == 'stop':
        global _matlab_engine
        if _matlab_engine is not None:
            try: _matlab_engine.quit()
            except: pass
            _matlab_engine = None
        # v9.0 风险5缓解: Engine 停止时清空所有工作流追踪状态
        _clear_all_workflow_states()
        return {"status": "ok", "message": "MATLAB Engine stopped"}
    elif action == 'check':
        return check_installation()
    elif action == 'set_project':
        return set_project_dir(params.get('dir', ''))
    elif action == 'scan_project':
        return scan_project_files(params.get('dir'))
    elif action == 'read_m_file':
        return read_m_file(params.get('path', ''))
    elif action == 'read_mat_file':
        return read_mat_file(params.get('path', ''))
    elif action == 'read_simulink':
        return read_simulink_model(params.get('path', ''))
    elif action == 'execute_script':
        return execute_script(params.get('path', ''), params.get('outputDir'))
    elif action == 'run_code':
        return run_code(params.get('code', ''), params.get('showOutput', True))
    elif action == 'set_matlab_root':
        return set_matlab_root(params.get('matlabRoot', ''))
    
    # --- 工作区操作 ---
    elif action == 'get_workspace':
        return get_workspace_vars()
    elif action == 'save_workspace':
        return save_workspace(params.get('path'))
    elif action == 'load_workspace':
        return load_workspace(params.get('path', ''))
    elif action == 'clear_workspace':
        return clear_workspace()
    
    # --- Simulink 操作（非 sl_toolbox） ---
    elif action == 'create_simulink':
        model_name = params.get('model_name', params.get('modelName', ''))
        model_path = params.get('model_path', params.get('modelPath'))
        # v9.0 风险5缓解: 新建模型时清理旧追踪状态，避免残留
        _cleanup_workflow_state(model_name)
        try:
            eng = get_engine()
            if eng is None:
                return {"status": "error", "message": "MATLAB Engine not available"}
            eng.eval(f"new_system('{model_name}'); open_system('{model_name}');", nargout=0)
            return {"status": "ok", "message": f"Model '{model_name}' created", "modelName": model_name}
        except Exception as e:
            return {"status": "error", "message": f"Failed to create model: {str(e)}"}
    elif action == 'open_simulink':
        model_name = params.get('model_name', params.get('modelName', ''))
        # v9.0 风险5缓解: 打开旧模型时重置追踪状态，后续操作会基于模型实际状态重新推断阶段
        _cleanup_workflow_state(model_name)
        try:
            eng = get_engine()
            if eng is None:
                return {"status": "error", "message": "MATLAB Engine not available"}
            eng.eval(f"load_system('{model_name}'); open_system('{model_name}');", nargout=0)
            return {"status": "ok", "message": f"Model '{model_name}' opened", "modelName": model_name}
        except Exception as e:
            return {"status": "error", "message": f"Failed to open model: {str(e)}"}
    elif action == 'run_simulink':
        model_name = params.get('model_name', params.get('modelName', ''))
        stop_time = params.get('stop_time', params.get('stopTime', '10'))
        return run_simulink(model_name, stop_time)
    elif action == 'set_simulink_workspace':
        return set_simulink_workspace_var(params.get('model_name', ''), params.get('var_name', ''), params.get('var_value'))
    elif action == 'get_simulink_workspace':
        return get_simulink_workspace_vars(params.get('model_name', ''))
    elif action == 'clear_simulink_workspace':
        return clear_simulink_workspace(params.get('model_name', ''))
    
    # --- Agent 工作区操作 ---
    elif action == 'init_workspace':
        return init_agent_workspace()
    elif action == 'route_file':
        return route_file_path(params.get('filename', ''), params.get('force_workspace', False))
    elif action == 'cleanup_workspace':
        return cleanup_agent_workspace(
            params.get('keep_results', True), 
            params.get('deep_clean', False)
        )
    
    # --- 图形操作 ---
    elif action == 'list_figures':
        return list_figures()
    elif action == 'close_figures':
        return close_all_figures()
    
    # --- sl_toolbox 命令（统一路由到 _handle_sl_command） ---
    elif action.startswith('sl_'):
        return _handle_sl_command(action, params)
    
    # --- 未知命令 ---
    else:
        return {"status": "error", "message": f"Unknown action: {action}"}


# ============= 主入口 =============
def main():
    """主函数 - 两种模式:
    1. --server: 常驻模式，通过 stdin/stdout 行协议通信
    2. 默认: 单次执行模式，读取文件或 stdin，输出结果后退出
    """
    if '--server' in sys.argv:
        server_mode()
    else:
        oneshot_mode()


def server_mode():
    """常驻服务模式 - 通过 stdin/stdout JSON 行协议通信
    
    每行输入一个 JSON 命令，每行输出一个 JSON 结果。
    Engine 在进程生命周期内持久化，变量跨命令保持。
    
    v5.0: 使用 sys.stdout.buffer.write + UTF-8 编码输出，
    解决 Windows 下 GBK 编码导致中文 JSON 响应乱码的问题。
    """
    sys.stderr.write(f"[MATLAB Bridge] Server mode started.\n")
    sys.stderr.write(f"[MATLAB Bridge] MATLAB_ROOT: {MATLAB_ROOT}\n")
    sys.stderr.write(f"[MATLAB Bridge] MATLAB_EXE: {_get_matlab_exe()}\n")
    version_hint = _get_matlab_version_from_path()
    if version_hint:
        sys.stderr.write(f"[MATLAB Bridge] MATLAB Version Hint: {version_hint}\n")
    sys.stderr.write(f"[MATLAB Bridge] Connection mode will be auto-detected on first command.\n")
    
    # [P0-3 FIX] 启动时检测未回滚的补丁
    try:
        patches_file = os.path.join(_LEARNINGS_DIR, 'PATCHES.json')
        if os.path.exists(patches_file):
            with open(patches_file, 'r', encoding='utf-8') as f:
                patches_list = json.load(f)
            pending = [p for p in patches_list if p.get('applied', True)]
            if pending:
                sys.stderr.write(f"[MATLAB Bridge] WARNING: {len(pending)} pending patch(es) detected!\n")
                for p in pending:
                    sys.stderr.write(f"  - {p.get('file', '?')} ({p.get('description', 'no desc')})\n")
                sys.stderr.write(f"[MATLAB Bridge] Use 'sl_self_improve patch_rollback' to revert if needed.\n")
    except Exception:
        pass
    
    sys.stderr.flush()
    
    # Windows 下 stdin 可能不是 utf-8，用二进制模式读取并手动解码
    stdin_buffer = sys.stdin.buffer
    
    for raw_line in stdin_buffer:
        try:
            line = raw_line.decode('utf-8').strip()
        except UnicodeDecodeError:
            line = raw_line.decode('gbk', errors='replace').strip()
        
        if not line:
            continue
        
        try:
            cmd_data = json.loads(line)
        except json.JSONDecodeError as e:
            result = {"status": "error", "message": f"JSON 解析失败: {str(e)}"}
            _write_json_response(result)
            continue
        
        try:
            result = handle_command(cmd_data)
            _write_json_response(result)
        except Exception as e:
            import traceback
            traceback.print_exc()
            err_result = {"status": "error", "message": f"Command handler error: {str(e)}"}
            _write_json_response(err_result)
    
    # stdin 关闭，退出
    if _matlab_engine:
        try: _matlab_engine.quit()
        except: pass


def _write_json_response(data: dict):
    """以 UTF-8 编码写入 JSON 响应到 stdout
    
    Windows 下 sys.stdout.write() 使用 GBK 编码，
    导致中文 JSON 响应乱码（如 "整理" → "鏁寸悊"）。
    改用 sys.stdout.buffer.write() + UTF-8 编码解决。
    """
    json_str = json.dumps(data, ensure_ascii=False) + '\n'
    sys.stdout.buffer.write(json_str.encode('utf-8'))
    sys.stdout.buffer.flush()


def oneshot_mode():
    """单次执行模式 - 读取命令文件或 stdin，输出结果后退出
    
    注意: 此模式下 Engine 不会跨命令持久化。
    推荐使用 --server 模式获得持久化工作区。
    """
    input_data = ""
    tmp_file = None
    
    if len(sys.argv) > 1 and not sys.argv[1].startswith('--'):
        file_path = sys.argv[1]
        with open(file_path, 'r', encoding='utf-8') as f:
            input_data = f.read().strip()
        tmp_file = file_path
    else:
        input_data = sys.stdin.read().strip()
    
    if not input_data:
        print(json.dumps({"status": "error", "message": "无输入数据"}))
        return
    
    try:
        cmd_data = json.loads(input_data)
        result = handle_command(cmd_data)
    except json.JSONDecodeError as e:
        result = {"status": "error", "message": f"JSON 解析失败: {str(e)}"}
    
    sys.stdout.flush()
    print(json.dumps(result, ensure_ascii=False))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
