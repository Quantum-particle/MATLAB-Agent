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

# ============= Workspace Isolation（v5.4）============
# 中间执行文件隔离到 .matlab_agent_tmp/ 子文件夹，避免污染用户工作目录

_AGENT_TMP_DIR_NAME = '.matlab_agent_tmp'

# 允许留在工作目录的文件扩展名（用户项目原生文件）
_KEEP_IN_WORKSPACE_EXTS = {'.m', '.slx', '.mdl', '.mat', '.fig', '.xlsx', '.xls', '.csv', '.docx', '.pdf'}

# 需要隔离到子文件夹的文件扩展名（中间执行文件）
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
    
    Args:
        release: 如 '2017a', '2024b'
    Returns:
        bool
    """
    current = _detect_matlab_version()
    if current == 'unknown':
        return False
    # 标准化: 确保 'R' 前缀
    if not current.startswith('R'):
        current = 'R' + current
    target = release if release.startswith('R') else 'R' + release
    return current >= target


# ============= v6.0: 类型转换辅助函数 =============

def _dict_to_matlab_struct(d):
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
            val_str = _python_to_matlab_value(v)
            parts.append(f"s.{k} = {val_str};")
        # 包装为: struct(), s = ans; s.field1=val1; s.field2=val2; s
        assign_code = ' '.join(parts)
        return f"struct(), {assign_code}"
    
    # 简单结构: 直接用 struct() 构造
    parts = []
    for k, v in d.items():
        val_str = _python_to_matlab_value(v)
        parts.append(f"'{k}',{val_str}")
    return f"struct({','.join(parts)})"


def _python_to_matlab_value(v):
    """将 Python 值转为 MATLAB 表达式字符串"""
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
        return _list_to_matlab_cell(v)
    elif isinstance(v, dict):
        return _dict_to_matlab_struct(v)
    else:
        return f"'{str(v)}'"


def _list_to_matlab_cell(lst):
    """Python list → MATLAB cell 构造字符串"""
    if not lst:
        return '{}'
    items = []
    for item in lst:
        items.append(_python_to_matlab_value(item))
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
            # 自定义检测函数
            try:
                detect_fn = eval(rule['detect_fn'])
                should_fix = detect_fn(command, fixed)
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
            # 自定义修复函数
            try:
                fix_fn = eval(rule['fix_fn'])
                fixed, custom_fixes = fix_fn(command, fixed)
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
            
            # 创建备份
            backup_path = abs_path + '.bak'
            with open(backup_path, 'w', encoding='utf-8') as f:
                f.write(content)
            
            # 应用补丁
            new_file_content = content.replace(old_content, new_content, 1)
            with open(abs_path, 'w', encoding='utf-8') as f:
                f.write(new_file_content)
            
            # 记录到 LEARNINGS
            _log_self_improve_action('patch_source', {
                'file': abs_path,
                'description': description,
                'old_length': len(old_content),
                'new_length': len(new_content),
                'backup': backup_path,
            })
            
            return {
                "status": "ok",
                "action": action,
                "message": f"Patched {abs_path}",
                "backup": backup_path,
                "description": description
            }
        except Exception as e:
            return {"status": "error", "message": f"Patch failed: {str(e)}"}
    
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
            "rules": _dynamic_fix_rules
        }
    
    else:
        return {"status": "error", "message": f"Unknown self_improve action: {action}. Available: list_rules, add_rule, remove_rule, update_rule, test_rule, patch_source, get_errors, auto_learn, stats"}


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
                try:
                    import tempfile
                    tmp_dir = tempfile.gettempdir()
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
    """初始化 Agent 工作空间隔离子目录
    
    在项目目录下创建 .matlab_agent_tmp/ 子文件夹，
    并在 MATLAB 中 addpath 该目录（确保隔离目录中的 .m 文件也能被找到）。
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
    
    # 在 MATLAB 中 addpath 隔离目录（确保隔离目录中的 .m 文件也能被找到）
    # v6.0: 通过 eng.workspace 传递路径，避免中文路径被 eval 字符串破坏
    mode = _detect_connection_mode()
    if mode == 'engine':
        eng = get_engine()
        if eng:
            try:
                tmp_dir_safe = tmp_dir.replace('\\', '/')
                eng.workspace['matlab_agent_tmp_path'] = tmp_dir_safe
                eng.eval("addpath(matlab_agent_tmp_path);", nargout=0)
                eng.eval("clear matlab_agent_tmp_path;", nargout=0)
            except:
                pass
    
    _agent_workspace_initialized = True
    return {"status": "ok", "message": f"隔离工作空间已初始化: {tmp_dir}", "tmp_dir": tmp_dir}


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


def cleanup_agent_workspace(keep_results=True):
    """清理 Agent 工作空间中的中间执行文件
    
    参数:
        keep_results: 是否保留结果文件（.txt, .dll, .exe 等），
                      默认 True（只删除真正的中间文件）
    
    删除规则:
        - 始终删除: .obj, .o, .tmp, .log, .bak, .def, .tlc, .tlh, .xml, .rpt, .mk
        - 保留（如果 keep_results=True）: .c, .h, .dll, .lib, .exp, .exe, .txt, .json
        - 不删除: .m, .slx, .mdl, .mat, .fig 等（这些不会出现在隔离目录中）
    """
    global _agent_workspace_initialized
    
    tmp_dir = _get_agent_tmp_dir()
    if not tmp_dir or not os.path.exists(tmp_dir):
        return {"status": "ok", "message": "隔离目录不存在，无需清理"}
    
    # 始终删除的中间文件扩展名
    always_delete_exts = {'.obj', '.o', '.tmp', '.log', '.bak', '.def', '.tlc', '.tlh', '.xml', '.rpt', '.mk'}
    
    # 结果文件扩展名（keep_results=True 时保留）
    result_exts = {'.c', '.h', '.cpp', '.hpp', '.dll', '.lib', '.exp', '.exe', '.txt', '.json', '.bat', '.py', '.js', '.ts'}
    
    deleted_files = []
    kept_files = []
    
    for fname in os.listdir(tmp_dir):
        fpath = os.path.join(tmp_dir, fname)
        if not os.path.isfile(fpath):
            continue
        
        _, ext = os.path.splitext(fname)
        ext = ext.lower()
        
        if ext in always_delete_exts:
            try:
                os.remove(fpath)
                deleted_files.append(fname)
            except:
                pass
        elif ext in result_exts:
            if keep_results:
                kept_files.append(fname)
            else:
                try:
                    os.remove(fpath)
                    deleted_files.append(fname)
                except:
                    pass
    
    # 如果隔离目录为空，删除目录本身
    remaining = os.listdir(tmp_dir)
    if not remaining:
        try:
            os.rmdir(tmp_dir)
            _agent_workspace_initialized = False
        except:
            pass
    
    return {
        "status": "ok",
        "message": f"已清理 {len(deleted_files)} 个中间文件" + (f"，保留 {len(kept_files)} 个结果文件" if kept_files else ""),
        "deleted": deleted_files,
        "kept": kept_files if keep_results else [],
        "tmp_dir_removed": not os.path.exists(tmp_dir) if not remaining else False
    }


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
    import tempfile
    import time
    
    # 创建临时目录和文件
    tmp_dir = tempfile.gettempdir()
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
        # 开启 diary 捕获输出
        diary_file_safe = diary_file.replace('\\', '/')
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
        
        # 关闭 diary
        eng.eval("diary('off');", nargout=0)
        
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
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('subsystemName', ''),
            '_pos_3': params.get('mode', 'group'),
            'blocksToGroup': blocks_to_group,
        }
    
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
        return {
            '_pos_1': model_name,
            'target': params.get('target', 'top'),
        }
    
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
        
        args_dict = _build_sl_args(command, fixed_params)
        
        # 5. 获取模型锁（修改型命令）
        model_name = fixed_params.get('modelName', fixed_params.get('model_name', ''))
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
        
        # 9. 更新 API 调用统计
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


def handle_command(cmd_data: dict):
    action = cmd_data.get("action", "")
    params = cmd_data.get("params", {})
    
    # ====== v6.0: sl_* 命令处理（带反模式预检+并发保护） ======
    SL_COMMANDS = {
        # 模型编辑层 (7)
        "sl_inspect",
        "sl_add_block",
        "sl_add_line",
        "sl_set_param",
        "sl_delete",
        "sl_find_blocks",
        "sl_replace_block",
        # 信号与总线层 (4)
        "sl_bus_create",
        "sl_bus_inspect",
        "sl_signal_config",
        "sl_signal_logging",
        # 子系统与层次层 (3)
        "sl_subsystem_create",
        "sl_subsystem_mask",
        "sl_subsystem_expand",
        # 模型配置层 (2)
        "sl_config_get",
        "sl_config_set",
        # 仿真控制层 (4)
        "sl_sim_run",
        "sl_sim_results",
        "sl_callback_set",
        "sl_sim_batch",
        # 验证与诊断层 (2)
        "sl_validate",
        "sl_parse_error",
        # 布局与导出层 (3)
        "sl_block_position",
        "sl_auto_layout",
        "sl_snapshot",
        # 测试与性能层 (3)
        "sl_baseline_test",
        "sl_profile_sim",
        "sl_profile_solver",
        # 基础设施 (1)
        "sl_best_practices",
        # v6.1 自我改进 (1)
        "sl_command_stats",
        # v7.0 Layer 5 源码级自我改进 (1)
        "sl_self_improve",
    }
    
    if action in SL_COMMANDS:
        return _handle_sl_command(action, params)
    
    # ====== 原有命令 ======
    handlers = {
        "check": lambda: check_installation(),
        "start": lambda: _start_matlab(),
        "stop": lambda: _stop_engine(),
        "set_project": lambda: set_project_dir(params.get("dir", "")),
        "scan_project": lambda: scan_project_files(params.get("dir")),
        "read_m_file": lambda: read_m_file(params.get("path", "")),
        "read_mat_file": lambda: read_mat_file(params.get("path", "")),
        "read_simulink": lambda: read_simulink_model(params.get("path", "")),
        "execute_script": lambda: execute_script(params.get("script_path", ""), params.get("output_dir")),
        "run_code": lambda: run_code(params.get("code", ""), params.get("show_output", True)),
        "get_workspace": lambda: get_workspace_vars(),
        "save_workspace": lambda: save_workspace(params.get("path")),
        "load_workspace": lambda: load_workspace(params.get("path", "")),
        "clear_workspace": lambda: clear_workspace(),
        "create_simulink": lambda: create_simulink_model(params.get("model_name", ""), params.get("model_path")),
        "run_simulink": lambda: run_simulink(params.get("model_name", ""), params.get("stop_time", "10")),
        "open_simulink": lambda: open_simulink_model(params.get("model_name", "")),
        "set_simulink_workspace": lambda: set_simulink_workspace_var(params.get("model_name", ""), params.get("var_name", ""), params.get("var_value", "")),
        "get_simulink_workspace": lambda: get_simulink_workspace_vars(params.get("model_name", "")),
        "clear_simulink_workspace": lambda: clear_simulink_workspace(params.get("model_name", "")),
        "list_figures": lambda: list_figures(),
        "close_figures": lambda: close_all_figures(),
        "get_config": lambda: _get_config(),
        "set_matlab_root": lambda: _set_matlab_root(params.get("root", "")),
        # v5.4: workspace isolation
        "init_workspace": lambda: init_agent_workspace(),
        "route_file": lambda: {"status": "ok", "routed_path": route_file_path(params.get("filename", ""), params.get("force_workspace", False)), "tmp_dir": _get_agent_tmp_dir()},
        "cleanup_workspace": lambda: cleanup_agent_workspace(params.get("keep_results", True)),
    }
    
    # 这些命令不需要 MATLAB 就能运行
    NO_MATLAB_NEEDED = {"check", "set_project", "scan_project", "read_m_file", 
                         "read_mat_file", "read_simulink", "get_config", "set_matlab_root",
                         "init_workspace", "route_file", "cleanup_workspace"}
    
    # 如果 MATLAB 不可用，只允许不需要 MATLAB 的命令
    if action not in NO_MATLAB_NEEDED and action not in {"start", "stop"}:
        if not _is_matlab_available():
            return {"status": "error", "message": "MATLAB 不可用。请先通过 /api/matlab/config 设置 MATLAB_ROOT。", "connection_mode": "unavailable"}
    
    handler = handlers.get(action)
    if handler is None:
        return {"status": "error", "message": f"未知命令: {action}"}
    try:
        return handler()
    except Exception as e:
        return {"status": "error", "message": f"处理命令时出错: {str(e)}", "detail": traceback.format_exc()}


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
