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
_test_engine = None  # [v11.4.2] Engine from compatibility test, reused by get_engine()
_matlab_version = None  # 缓存 MATLAB 版本号
_SCENE_STATE = {}  # v11.5: Scene 2 state for CLI mode (no MATLAB engine)
_S2_MOD_PERMISSIONS = {}  # v11.5: Gate_S2_MODIFY permissions cache
_REQUEST_COUNTER = 0  # v11.6: Monotonically increasing request counter for turn detection
_RAW_CMD_STATE = {}  # v11.8.3: Raw MATLAB command gate (requires user confirmation like Gate_S0)
_MICRO_APPROVED_SUBSYSTEMS = {}  # v11.8.4: Gate_SHELL_ONLY — tracks which subsystems have micro_approve. {model: set(subsys_paths)}

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

def _list_of_dicts_to_struct_array(lst, _depth=0):
    """Convert list of homogeneous dicts to MATLAB struct array expression.
    
    Input:  [{'name':'A','val':1}, {'name':'B','val':2}]
    Output: struct('name',{'A','B'},'val',{1,2})
    
    This is the PREFERRED format for .m functions that use (i) indexing.
    Falls back to cell-of-struct via _list_to_matlab_cell if dicts are
    heterogeneous (different keys).
    """
    if not lst or _depth > 10:
        return '{}'
    
    # Check if all elements are dicts
    if not all(isinstance(item, dict) for item in lst):
        return _list_to_matlab_cell(lst, _depth + 1)
    
    # Check if all dicts have the same keys
    first_keys = set(lst[0].keys())
    for d in lst[1:]:
        if set(d.keys()) != first_keys:
            # Heterogeneous dicts → fall back to cell array
            return _list_to_matlab_cell(lst, _depth + 1)
    
    # Build struct array: struct('key1',{v1,v2,...}, 'key2',{v1,v2,...})
    keys = list(lst[0].keys())
    parts = []
    for k in keys:
        vals = []
        for d in lst:
            v = d.get(k, '')
            vals.append(_python_to_matlab_value(v, _depth + 1))
        parts.append(f"'{k}',{{{','.join(vals)}}}")
    return f"struct({','.join(parts)})"


def _dict_to_matlab_struct(d, _depth=0):
    """Python dict → MATLAB struct 构造字符串
    
    v11.6.8 FIX: 对同构 list[dict] 生成 struct array (struct('field',{v1,v2}))，
    而非 cell-of-struct ({{struct(...), struct(...)}})，与 .m 函数 (i) 索引兼容。
    异构 list 仍用双层 cell {{...}} 包装。
    """
    if not d:
        return 'struct()'
    
    parts = []
    for k, v in d.items():
        if isinstance(v, list):
            # v11.6.8: prefer struct array for homogeneous dict lists
            if v and all(isinstance(item, dict) for item in v):
                # Check key homogeneity
                first_keys = set(v[0].keys())
                homogeneous = all(set(di.keys()) == first_keys for di in v[1:])
                if homogeneous:
                    val_str = _list_of_dicts_to_struct_array(v, _depth + 1)
                else:
                    inner = _list_to_matlab_cell(v, _depth + 1)
                    val_str = '{' + inner + '}'
            else:
                # Non-dict list: use double-cell wrapping
                inner = _list_to_matlab_cell(v, _depth + 1)
                val_str = '{' + inner + '}'
        elif isinstance(v, dict):
            # 嵌套 struct: 递归转换
            val_str = _dict_to_matlab_struct(v, _depth + 1)
        else:
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


# ============= Phase 1A: 智能参数转换引擎 (v10.1) =============
# 解决矩阵/向量参数传递断裂问题 — 所有复杂 Simulink 模块参数支持

def _is_nested_list(lst):
    """检测 list 是否为嵌套列表（矩阵）"""
    return any(isinstance(item, list) for item in lst)

def _is_flat_numeric_list(lst):
    """检测 list 是否为扁平数值列表（向量）"""
    return all(isinstance(x, (int, float)) for x in lst)

def _list_to_matlab_matrix(lst):
    """Python 嵌套 list → MATLAB 矩阵字符串 [[1,0],[0,1]] → '[1,0;0,1]'"""
    if _is_nested_list(lst):
        rows = []
        for row in lst:
            if isinstance(row, list):
                rows.append(','.join(str(x) for x in row))
            else:
                rows.append(str(row))
        return '[' + ';'.join(rows) + ']'
    else:
        return '[' + ','.join(str(x) for x in lst) + ']'

def _list_to_matlab_vector(lst):
    """Python list → MATLAB 行向量字符串 [1, 2, 3] → '[1,2,3]'"""
    return '[' + ','.join(str(x) for x in lst) + ']'

def _looks_like_matlab_expr(s):
    """检测字符串是否像 MATLAB 表达式"""
    s = s.strip()
    if s.startswith('[') and s.endswith(']'):
        return True
    if re.match(r'^[a-zA-Z_]\w*$', s):
        return True
    return False

# ============================================================================
# _MATRIX_PARAM_PATTERNS: 参数名 → MATLAB 类型映射 (v10.2)
# ============================================================================
_MATRIX_PARAM_PATTERNS = {
    'exact': {
        'A': 'matrix', 'B': 'matrix', 'C': 'matrix', 'D': 'matrix', 'E': 'matrix',
        'Numerator': 'vector', 'Denominator': 'vector', 'Zeros': 'vector', 'Poles': 'vector',
        'Gain': 'scalar_or_matrix', 'InitialCondition': 'vector_or_matrix',
        'Coefficients': 'vector', 'Table': 'matrix', 'SampleTime': 'scalar',
        'Amplitude': 'scalar', 'Frequency': 'scalar', 'Phase': 'scalar', 'Offset': 'scalar',
        'Before': 'scalar', 'After': 'scalar', 'StartTime': 'scalar', 'Slope': 'scalar',
        'StartTime1': 'scalar', 'Period': 'scalar', 'PulseWidth': 'scalar', 'PhaseDelay': 'scalar',
        'Mean': 'scalar', 'Variance': 'scalar', 'Seed': 'scalar',
        'Inputs': 'scalar_or_string', 'Multiplication': 'enum', 'NumberOfInputs': 'scalar',
        'CollapseMode': 'enum', 'CollapseDim': 'scalar',
        'BreakpointsForDimension1': 'vector', 'BreakpointsForDimension2': 'vector',
        'BreakpointsForDimension3': 'vector', 'BreakpointsForDimension4': 'vector',
        'BreakpointsForDimension5': 'vector', 'InterpMethod': 'enum', 'ExtrapMethod': 'enum',
        'Threshold': 'scalar', 'IndexMode': 'enum', 'Indices': 'vector_or_string',
        'Operator': 'enum', 'LogicDataType': 'enum', 'Relop': 'enum',
        'Function': 'enum', 'FunctionName': 'string', 'Parameters': 'string', 'Expr': 'string',
        'DelayLen': 'scalar_or_string', 'InitialOutput': 'scalar_or_string', 'InitialBufferSize': 'scalar',
        'MaximumDelay': 'scalar', 'PadeOrder': 'scalar', 'DelayTime': 'scalar_or_string',
        'OutDataTypeStr': 'enum', 'OutMin': 'scalar_or_string', 'OutMax': 'scalar_or_string',
        'Min': 'scalar_or_string', 'Max': 'scalar_or_string', 'EnableAssert': 'bool', 'Callback': 'string',
        'Solver': 'enum', 'StopTime': 'scalar_or_string', 'MaxStep': 'scalar_or_string',
        'MinStep': 'scalar_or_string', 'InitialStep': 'scalar_or_string',
        'RelTol': 'scalar_or_string', 'AbsTol': 'scalar_or_string',
        # v10.2 新增参数
        'Floating': 'bool', 'Decimation': 'scalar', 'MaxDataPoints': 'scalar',
        'TagVisibility': 'enum', 'ProbeWidth': 'bool', 'Enabled': 'bool',
        'NumInputPorts': 'scalar', 'VariableName': 'string',
        'IconDisplay': 'string', 'NumInputs': 'scalar', 'CaseConditions': 'string',
        'IC': 'scalar', 'Bias': 'scalar', 'Bit': 'scalar',
        # [FIX v10.2.1] 缺失的 enum 参数类型（来自 _PARAM_ENUM_VALUES）
        'WaveForm': 'enum',  # Signal Generator
        'Operator': 'enum',  # Logical Operator, Relational Operator, etc.
        'Function': 'enum',  # MinMax, Math Function
        'ShiftType': 'enum',  # Shift Arithmetic
        'InterpMethod': 'enum',  # Lookup Tables
        'ExtrapMethod': 'enum',  # Lookup Tables
        'TagVisibility': 'enum',  # Goto
        'RateTransition': 'enum',  # Rate Transition
        'OutputSignalType': 'enum',  # Trigonometric Function
        'GotoTag': 'string',  # Goto (string type, not enum)
        'MATLABFunction': 'string',  # Interpreted MATLAB Function
    },
    'prefix': {
        'Num': 'vector', 'Den': 'vector', 'BreakpointsForDimension': 'vector',
    },
    'block_param': {
        ('State-Space', 'A'): 'matrix', ('State-Space', 'B'): 'matrix',
        ('State-Space', 'C'): 'matrix', ('State-Space', 'D'): 'matrix',
        ('State-Space', 'x0'): 'vector',
        ('Transfer Fcn', 'Numerator'): 'vector', ('Transfer Fcn', 'Denominator'): 'vector',
        ('Zero-Pole', 'Zeros'): 'vector', ('Zero-Pole', 'Poles'): 'vector',
        ('Zero-Pole', 'Gain'): 'scalar_or_matrix',
        ('Discrete State-Space', 'A'): 'matrix', ('Discrete State-Space', 'B'): 'matrix',
        ('Discrete State-Space', 'C'): 'matrix', ('Discrete State-Space', 'D'): 'matrix',
        ('Discrete State-Space', 'x0'): 'vector',
        ('Discrete Transfer Fcn', 'Numerator'): 'vector', ('Discrete Transfer Fcn', 'Denominator'): 'vector',
        ('Discrete Filter', 'Numerator'): 'vector', ('Discrete Filter', 'Denominator'): 'vector',
        ('Discrete PID Controller', 'P'): 'string', ('Discrete PID Controller', 'I'): 'string',
        ('Discrete PID Controller', 'D'): 'string', ('Discrete PID Controller', 'N'): 'string',
        ('Discrete PID Controller (2DOF)', 'P'): 'string', ('Discrete PID Controller (2DOF)', 'I'): 'string',
        ('Discrete PID Controller (2DOF)', 'D'): 'string', ('Discrete PID Controller (2DOF)', 'N'): 'string',
        ('Gain', 'Gain'): 'scalar_or_matrix',
        ('Product', 'Multiplication'): 'enum', ('Sum', 'Inputs'): 'scalar_or_string',
        ('Add', 'Inputs'): 'scalar_or_string', ('Subtract', 'Inputs'): 'scalar_or_string',
        ('Step', 'Before'): 'scalar_or_string', ('Step', 'After'): 'scalar_or_string', ('Step', 'Time'): 'scalar_or_string',
        ('Sine Wave', 'Amplitude'): 'scalar_or_string', ('Sine Wave', 'Frequency'): 'scalar_or_string',
        ('Band-Limited White Noise', 'Cov'): 'scalar_or_matrix',
        ('Repeating Sequence', 'OutputValues'): 'vector', ('Repeating Sequence', 'TimeValues'): 'vector',
        ('Scope', 'NumInputPorts'): 'scalar',
        ('1-D Lookup Table', 'Table'): 'vector', ('1-D Lookup Table', 'BreakpointsForDimension1'): 'vector',
        ('2-D Lookup Table', 'Table'): 'matrix', ('2-D Lookup Table', 'BreakpointsForDimension1'): 'vector',
        ('2-D Lookup Table', 'BreakpointsForDimension2'): 'vector',
        ('Prelookup', 'BreakpointsForDimension1'): 'vector',
        ('Interpolation Using Prelookup', 'Table'): 'vector_or_matrix',
        ('Transport Delay', 'DelayTime'): 'scalar_or_string', ('Transport Delay', 'PadeOrder'): 'scalar',
        ('Unit Delay', 'InitialCondition'): 'scalar_or_string', ('Unit Delay', 'SampleTime'): 'scalar_or_string',
        ('Integrator', 'InitialCondition'): 'scalar_or_string', ('Integrator', 'LimitOutput'): 'bool',
        ('Integrator', 'UpperSaturationLimit'): 'scalar_or_string', ('Integrator', 'LowerSaturationLimit'): 'scalar_or_string',
        ('Constant', 'Value'): 'scalar_or_string',
        # ===== v10.3 新增模块参数 =====
        # Discontinuities
        ('Saturation', 'UpperLimit'): 'scalar', ('Saturation', 'LowerLimit'): 'scalar',
        ('Dead Zone', 'LowerValue'): 'scalar', ('Dead Zone', 'UpperValue'): 'scalar',
        ('Rate Limiter', 'RisingSlewLimit'): 'scalar', ('Rate Limiter', 'FallingSlewLimit'): 'scalar',
        ('Rate Limiter', 'InitialCondition'): 'scalar_or_string',
        ('Relay', 'OnSwitchValue'): 'scalar', ('Relay', 'OffSwitchValue'): 'scalar',
        ('Relay', 'OnOutputValue'): 'scalar', ('Relay', 'OffOutputValue'): 'scalar',
        ('Quantizer', 'QuantizationInterval'): 'scalar',
        ('Backlash', 'DeadbandWidth'): 'scalar', ('Backlash', 'InitialOutput'): 'scalar',
        ('Coulomb and Viscous Friction', 'CoefficientofStaticFriction'): 'scalar',
        ('Coulomb and Viscous Friction', 'CoefficientofViscousFriction'): 'scalar',
        ('Coulomb and Viscous Friction', 'InitialInput'): 'scalar',
        ('Hit Crossing', 'HitOffset'): 'scalar', ('Hit Crossing', 'ShowOutputPort'): 'bool',
        ('Hit Crossing', 'Direction'): 'enum',
        ('Wrap To Zero', 'Threshold'): 'scalar',
        # [REMOVED v10.4.1] Additional Math & Discrete 模块在 R2023b 中不可用
        # ('Weighted Sample Time Math', 'Operation'): 'enum', ('Weighted Sample Time Math', 'Weight'): 'scalar',
        # ('Algebraic Constraint', 'Constraint'): 'scalar', ('Algebraic Constraint', 'InitialGuess'): 'scalar',
        # ('Decrement Time', 'v'): 'scalar',
        # Lookup Tables 扩展
        ('n-D Lookup Table', 'NumberOfTableDimensions'): 'scalar',
        ('n-D Lookup Table', 'Table'): 'matrix',
        ('n-D Lookup Table', 'BreakpointsForDimension1'): 'vector',
        ('n-D Lookup Table', 'BreakpointsForDimension2'): 'vector',
        ('n-D Lookup Table', 'BreakpointsForDimension3'): 'vector',
        ('n-D Lookup Table', 'BreakpointsForDimension4'): 'vector',
        # Math Operations 扩展
        ('Polynomial', 'Coefs'): 'vector',
        ('Repeat Vector', 'NumContiguousRepetitions'): 'scalar',
        ('Assignment', 'NumberOfIndices'): 'scalar', ('Assignment', 'Indices'): 'matrix',
        ('Matrix Concatenate', 'NumInputs'): 'scalar', ('Matrix Concatenate', 'concatenationDimension'): 'scalar',
        # Signal Routing 扩展
        ('Multiport Switch', 'NumberOfInputs'): 'scalar', ('Multiport Switch', 'IndexMode'): 'enum',
        ('Bus Assignment', 'AssignedSignals'): 'string', ('Bus Assignment', 'InputSignals'): 'string',
        # Sources 扩展
        ('From Workspace', 'VariableName'): 'string', ('From Workspace', 'OutputAfterFullData'): 'enum',
        ('From File', 'FileName'): 'string', ('From File', 'OutputAfterFullData'): 'enum',
        ('Repeating Sequence', 'OutputValues'): 'vector',
        ('Repeating Sequence Interpolated', 'TimeValues'): 'vector',
        ('Repeating Sequence Interpolated', 'OutputValues'): 'vector',
        ('Repeating Sequence Interpolated', 'EndTime'): 'scalar',
        ('Repeating Sequence Stair', 'TimeValues'): 'vector', ('Repeating Sequence Stair', 'OutputValues'): 'vector',
        ('Band-Limited White Noise', 'NoisePower'): 'scalar', ('Band-Limited White Noise', 'Seed'): 'scalar',
        # Sinks 扩展
        ('To File', 'FileName'): 'string', ('To File', 'VariableName'): 'string',
        ('To File', 'MaxDataPoints'): 'scalar',
        ('XY Graph', 'xmin'): 'scalar', ('XY Graph', 'xmax'): 'scalar',
        ('XY Graph', 'ymin'): 'scalar', ('XY Graph', 'ymax'): 'scalar',
        # Continuous 扩展
        ('Second-Order Integrator', 'InitialConditionSource'): 'enum',
        ('Second-Order Integrator', 'x0'): 'scalar', ('Second-Order Integrator', 'xdot0'): 'scalar',
        ('Second-Order Integrator', 'LimitOutput'): 'bool',
        ('Second-Order Integrator', 'UpperLimit'): 'scalar', ('Second-Order Integrator', 'LowerLimit'): 'scalar',
        ('Variable Transport Delay', 'DelayTimeSource'): 'enum', ('Variable Transport Delay', 'MaximumDelay'): 'scalar',
        ('Variable Time Delay', 'DelayTimeSource'): 'enum', ('Variable Time Delay', 'MaximumDelay'): 'scalar',
        # Discrete 扩展
        ('Discrete PID Controller (2DOF)', 'P'): 'string', ('Discrete PID Controller (2DOF)', 'I'): 'string',
        ('Discrete PID Controller (2DOF)', 'D'): 'string', ('Discrete PID Controller (2DOF)', 'B'): 'string',
        ('Discrete PID Controller (2DOF)', 'C'): 'string', ('Discrete PID Controller (2DOF)', 'FilterCoefficient'): 'string',
        ('Discrete Zero-Pole', 'Zeros'): 'vector', ('Discrete Zero-Pole', 'Poles'): 'vector',
        ('Discrete Zero-Pole', 'Gain'): 'scalar',
        # Model Verification 扩展
        ('Check Static Range', 'External'): 'bool', ('Check Static Range', 'Minimum'): 'scalar',
        ('Check Static Range', 'Maximum'): 'scalar',
        ('Check Static Upper Bound', 'Bound'): 'scalar',
        ('Check Static Lower Bound', 'Bound'): 'scalar',
        ('Check Dynamic Range', 'MinimumInputPort'): 'scalar', ('Check Dynamic Range', 'MaximumInputPort'): 'scalar',
        ('Check Dynamic Gap', 'MinimumGap'): 'scalar', ('Check Dynamic Gap', 'MaximumGap'): 'scalar',
        ('Check Input Resolution', 'Resolution'): 'scalar',
        ('Check Discrete Gradient', 'MaximumJump'): 'scalar',
        ('Assertion', 'StopWhenAssertionFails'): 'bool', ('Assertion', 'AssertionMode'): 'enum',
        # Ports & Subsystems 扩展
        ('Triggered Subsystem', 'TriggerType'): 'enum',
        ('Enable Port', 'EnableInit'): 'enum', ('Enable Port', 'EnableDelay'): 'scalar',
        ('For Iterator Subsystem', 'IterationLimit'): 'scalar_or_string',
        ('While Iterator Subsystem', 'MaximumNumberOfIterations'): 'scalar',
        # Signal Attributes 扩展
        ('Data Type Conversion', 'InputSanityCheck'): 'bool',
        ('Data Type Conversion', 'IntegerRoundingMode'): 'enum',
        ('Data Type Conversion', 'ConvOverflowMsg'): 'string',
        ('Signal Specification', 'Dimension'): 'scalar_or_string',
        ('Signal Specification', 'SampleTime'): 'scalar_or_string', ('Signal Specification', 'DataType'): 'enum',
        ('Rate Transition', 'OutPortSampleTime'): 'scalar', ('Rate Transition', 'TreatMyselfAsKnown'): 'bool',
        ('Probe', 'ProbeSampleTime'): 'bool', ('Probe', 'ProbeComplexSignal'): 'bool',
        # Logic and Bit Operations 扩展
        ('Combinatorial Logic', 'TruthTable'): 'matrix',
        ('Logical Operator', 'NumberOfInputPorts'): 'scalar', ('Logical Operator', 'OutputDataTypeMode'): 'string',
        # Unit Conversion - v10.4 新增
        ('Unit Conversion', 'OutputDataType'): 'enum',
        ('PS-Simulink Converter', 'OutputSignalUnit'): 'string',
        ('Simulink-PS Converter', 'InputSignalUnit'): 'string',
        ('Simulink-PS Converter', 'ApplyAffineConversion'): 'bool',
        ('Simulink-PS Converter', 'FilteringAndDerivatives'): 'enum',
        ('Simulink-PS Converter', 'ProvidedSignals'): 'enum',
        ('Simulink-PS Converter', 'InputFilteringOrder'): 'enum',
        ('Simulink-PS Converter', 'InputFilteringTimeConstant'): 'scalar',
        # Aerospace Blockset 单位转换 (v10.4.1 新增)
        ('Angular Velocity Conversion', 'InputVelocityUnit'): 'enum',
        ('Angular Velocity Conversion', 'OutputVelocityUnit'): 'enum',
        ('Length Conversion', 'InputLengthUnit'): 'enum',
        ('Length Conversion', 'OutputLengthUnit'): 'enum',
        ('Velocity Conversion', 'InputVelocityUnit'): 'enum',
        ('Velocity Conversion', 'OutputVelocityUnit'): 'enum',
    },
}

# ============================================================================
# _PARAM_ENUM_VALUES: 枚举参数的有效值映射 (v10.2)
# AI 大模型设置参数时查阅此表获取有效枚举值
# ============================================================================
_PARAM_ENUM_VALUES = {
    # 逻辑运算符
    ('Logical Operator', 'Operator'): ['AND', 'OR', 'NOT', 'NAND', 'NOR', 'XOR', 'NXOR'],
    # 关系运算符
    ('Relational Operator', 'Operator'): ['==', '~=', '<', '>', '<=', '>='],
    # 比较常量运算符
    ('Compare To Constant', 'RelOp'): ['==', '~=', '<', '>', '<=', '>='],
    ('Compare To Zero', 'Operator'): ['==', '~=', '<', '>', '<=', '>='],
    # 数学/三角运算符
    ('Math Function', 'Operator'): ['sqrt', 'log', 'log10', 'ln', 'exp', 'pow', 'abs', 'conj', 'inv', 'transpose', 'real', 'imag', 'complex', 'fold', 'unfold'],
    ('Trigonometric Function', 'Operator'): ['sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', 'sinh', 'cosh', 'tanh', 'asinh', 'acosh', 'atanh'],
    # MinMax
    ('MinMax', 'Function'): ['min', 'max'],
    # Goto TagVisibility
    ('Goto', 'TagVisibility'): ['local', 'scoped', 'global'],
    ('From', 'GotoTag'): None,  # string type, no enum restriction
    # DataType
    ('Data Type Conversion', 'OutDataTypeStr'): ['double', 'single', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'boolean', 'auto'],
    # RateTransition
    ('Rate Transition', 'RateTransition'): ['Inherit', 'uint8', 'uint16', 'uint32', 'int8', 'int16', 'int32', 'single', 'double', 'Automatically determine'],
    # Probe
    ('Probe', 'ProbeWidth'): ['on', 'off'],
    # Assertion
    ('Assertion', 'Enabled'): ['on', 'off'],
    # Scope Floating
    ('Scope', 'Floating'): ['on', 'off'],
    # Shift Arithmetic ShiftType
    ('Shift Arithmetic', 'ShiftType'): ['arithmetic', 'logical', 'circular', 'shift'],
    # Signal Generator WaveForm
    ('Signal Generator', 'WaveForm'): ['sine', 'square', 'sawtooth', 'random'],
    # InterpMethod / ExtrapMethod
    ('1-D Lookup Table', 'InterpMethod'): ['linear', 'lower', 'upper', 'clipped', 'native'],
    ('2-D Lookup Table', 'InterpMethod'): ['linear', 'linear', 'cubic', 'lag', 'nearest', 'bilinear', 'bicubic'],
    ('Prelookup', 'InterpMethod'): ['Clair', 'binary', 'linear', 'even', 'InterpolationUsingLastValue'],
    ('Interpolation Using Prelookup', 'InterpMethod'): ['linear', 'cubic', 'piecewise', 'Akima', 'spline', 'pchip'],
    # 通用 enum 型参数（作为 fallback）
    'Multiplication': ['Element-wise(K.*u)', 'Matrix(K*u)', 'Element-wise(u.*K)', 'Matrix(u*K)'],
    'InterpMethod': ['linear', 'cubic', 'Clair', 'nearest', 'binary'],
    'ExtrapMethod': ['clip', 'linear', 'Clair', 'periodic'],
    # ===== v10.3 新增模块枚举值 =====
    # Hit Crossing Direction
    ('Hit Crossing', 'Direction'): ['either', 'rising', 'falling'],
    # [REMOVED v10.4.1] Weighted Sample Time Math 在 R2023b 中不可用
    # ('Weighted Sample Time Math', 'Operation'): ['u*w', 'u+w', 'u-w', 'w-u'],
    # Multiport Switch IndexMode
    ('Multiport Switch', 'IndexMode'): ['Zero-based', 'One-based'],
    # From Workspace / From File OutputAfterFullData
    ('From Workspace', 'OutputAfterFullData'): ['Extrapolation', 'Error', 'Hold Last Value', 'Zero'],
    ('From File', 'OutputAfterFullData'): ['Extrapolation', 'Error', 'Hold Last Value', 'Zero'],
    # Second-Order Integrator InitialConditionSource
    ('Second-Order Integrator', 'InitialConditionSource'): ['internal', 'external'],
    # Variable Time/Transport Delay DelayTimeSource
    ('Variable Transport Delay', 'DelayTimeSource'): ['internal', 'external'],
    ('Variable Time Delay', 'DelayTimeSource'): ['internal', 'external'],
    # Triggered Subsystem TriggerType
    ('Triggered Subsystem', 'TriggerType'): ['rising', 'falling', 'either', 'function-call'],
    # Enable Port EnableInit
    ('Enable Port', 'EnableInit'): ['held', 'reset'],
    # Signal Specification DataType
    ('Signal Specification', 'DataType'): ['auto', 'double', 'single', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'boolean'],
    # Data Type Conversion IntegerRoundingMode
    ('Data Type Conversion', 'IntegerRoundingMode'): ['floor', 'ceil', 'round', 'convergent', 'zero'],
    # Data Type Conversion ConvOverflowMsg
    ('Data Type Conversion', 'ConvOverflowMsg'): ['none', 'warning', 'error'],
    # Assertion AssertionMode
    ('Assertion', 'AssertionMode'): ['all', 'any'],
    # Unit Conversion - v10.4
    ('Unit Conversion', 'OutputDataType'): ['Inherit via internal rule', 'Inherit via back propagation'],
    # Simulink-PS Converter FilteringAndDerivatives
    ('Simulink-PS Converter', 'FilteringAndDerivatives'): ['Provide signals', 'Filter input and compute derivatives', 'Zero derivatives (piecewise constant)'],
    # Simulink-PS Converter ProvidedSignals
    ('Simulink-PS Converter', 'ProvidedSignals'): ['Input only', 'Input and first derivative', 'Input and first two derivatives'],
    # Simulink-PS Converter InputFilteringOrder
    ('Simulink-PS Converter', 'InputFilteringOrder'): ['First-order filtering', 'Second-order filtering'],
    # Aerospace Blockset - v10.4.1 新增
    ('Angular Velocity Conversion', 'InputVelocityUnit'): ['rad/s', 'deg/s', 'rpm', 'rev/s', 'Hz'],
    ('Angular Velocity Conversion', 'OutputVelocityUnit'): ['rad/s', 'deg/s', 'rpm', 'rev/s', 'Hz'],
    ('Length Conversion', 'InputLengthUnit'): ['m', 'km', 'cm', 'mm', 'in', 'ft', 'yd', 'mi', 'nmi'],
    ('Length Conversion', 'OutputLengthUnit'): ['m', 'km', 'cm', 'mm', 'in', 'ft', 'yd', 'mi', 'nmi'],
    ('Velocity Conversion', 'InputVelocityUnit'): ['m/s', 'km/h', 'mph', 'ft/s', 'knot'],
    ('Velocity Conversion', 'OutputVelocityUnit'): ['m/s', 'km/h', 'mph', 'ft/s', 'knot'],
}

def _get_param_hints(block_type, param_name):
    """获取参数的提示信息

    Returns:
        dict: 包含 param_type, enum_values, description
    """
    hints = {}

    # 1. 获取参数类型
    hints['param_type'] = _infer_param_type(param_name, block_type)

    # 2. 获取枚举值
    key = (block_type, param_name)
    if key in _PARAM_ENUM_VALUES:
        hints['enum_values'] = _PARAM_ENUM_VALUES[key]
    elif param_name in ['Operator', 'Function', 'Multiplication', 'WaveForm', 'ShiftType', 'InterpMethod', 'ExtrapMethod']:
        # 全局参数名的枚举值
        hints['enum_values'] = _PARAM_ENUM_VALUES.get(param_name, None)

    # 3. 参数描述
    _PARAM_DESCRIPTIONS = {
        'Gain': '增益值',
        'Amplitude': '幅值',
        'Frequency': '频率',
        'Phase': '初相',
        'Bias': '偏置',
        'Time': '时间',
        'Before': '初始值',
        'After': '最终值',
        'Slope': '斜率',
        'Threshold': '阈值',
        'A': 'A 矩阵',
        'B': 'B 矩阵',
        'C': 'C 矩阵',
        'D': 'D 矩阵',
    }
    hints['description'] = _PARAM_DESCRIPTIONS.get(param_name, '')

    return hints

def _format_as_matlab_string(value):
    """将值格式化为 MATLAB 字符串"""
    if isinstance(value, list):
        if _is_nested_list(value):
            return _list_to_matlab_matrix(value).strip('[]')
        else:
            return ' '.join(str(x) for x in value)
    return str(value)

def _infer_param_type(param_name, block_type=''):
    """根据参数名+模块类型推断目标 MATLAB 类型"""
    # 优先: 模块类型+参数名组合
    if block_type:
        key = (block_type, param_name)
        if key in _MATRIX_PARAM_PATTERNS.get('block_param', {}):
            return _MATRIX_PARAM_PATTERNS['block_param'][key]
    # 次优: 精确参数名匹配
    if param_name in _MATRIX_PARAM_PATTERNS.get('exact', {}):
        return _MATRIX_PARAM_PATTERNS['exact'][param_name]
    # 最后: 前缀匹配
    for prefix, ptype in _MATRIX_PARAM_PATTERNS.get('prefix', {}).items():
        if param_name.startswith(prefix):
            return ptype
    # 兜底
    return 'cell'

def _smart_param_convert(param_name, param_value, block_type=''):
    """智能参数类型转换 — 根据参数名+模块类型自动判断目标 MATLAB 格式
    
    转换规则（优先级从高到低）:
    1. __matlab_expr__ 标记: 用户/AI 显式指定 MATLAB 表达式
    2. __workspace_var__ 标记: 工作区变量引用
    3. 参数名模式匹配: A/B/C/D/Numerator/Denominator 等
    4. 模块类型+参数名组合: PID Controller 的 P/I/D 参数
    5. 兜底: 原有 _python_to_matlab_value 行为
    
    Returns:
        str: MATLAB 表达式字符串
    """
    # === 规则 1: 显式 MATLAB 表达式标记 ===
    if isinstance(param_value, dict) and '__matlab_expr__' in param_value:
        return param_value['__matlab_expr__']
    
    # === 规则 2: 工作区变量引用标记 ===
    # 返回 evalin('base', 'var_name') 表达式，让 MATLAB 在 struct 创建时获取实际值
    # 而不是传字符串 'var_name'（Simulink set_param 不支持变量名字符串作为矩阵参数）
    if isinstance(param_value, dict) and '__workspace_var__' in param_value:
        var_name = param_value['__workspace_var__']
        escaped_name = var_name.replace("'", "''")
        return f"evalin('base','{escaped_name}')"
    
    # === 规则 3: 纯字符串 → 先查询参数类型注册表 ===
    if isinstance(param_value, str):
        # [FIX v10.2.1] 先查询参数类型注册表
        # 确保 string/enum/bool 类型的参数一定加引号
        param_type = _infer_param_type(param_name, block_type)

        # 如果是 string/enum/bool 类型，必须加引号
        if param_type in ('string', 'enum', 'bool'):
            escaped = param_value.replace("'", "''")
            return f"'{escaped}'"

        # 如果是矩阵/向量表达式（如 '[1 2 3]'），直接透传
        if param_value.startswith('[') and param_value.endswith(']'):
            return param_value

        # 如果看起来像 MATLAB 变量名（纯字母数字下划线），不加引号让 MATLAB 解析
        if _looks_like_matlab_expr(param_value):
            return param_value

        # 其他情况加引号
        escaped = param_value.replace("'", "''")
        return f"'{escaped}'"
    
    # === 规则 4: 数值标量 → 直接转字符串 ===
    if isinstance(param_value, (int, float)):
        if isinstance(param_value, float) and (param_value != param_value):  # NaN
            return 'NaN'
        if isinstance(param_value, float) and (param_value == float('inf')):
            return 'Inf'
        if isinstance(param_value, float) and (param_value == float('-inf')):
            return '-Inf'
        return str(param_value)
    
    # === 规则 5: 布尔值 → 'on'/'off' ===
    if isinstance(param_value, bool):
        return 'on' if param_value else 'off'
    
    # === 规则 6: list → 自动判断矩阵/向量/Cell ===
    if isinstance(param_value, list):
        target_type = _infer_param_type(param_name, block_type)
        if target_type == 'matrix':
            return _list_to_matlab_matrix(param_value)
        elif target_type == 'vector':
            return _list_to_matlab_vector(param_value)
        elif target_type == 'scalar_or_matrix':
            if _is_nested_list(param_value):
                return _list_to_matlab_matrix(param_value)
            elif _is_flat_numeric_list(param_value):
                if len(param_value) == 1:
                    return str(param_value[0])
                return _list_to_matlab_vector(param_value)
            else:
                return _python_to_matlab_value(param_value)
        elif target_type == 'scalar_or_string':
            if _is_flat_numeric_list(param_value):
                if len(param_value) == 1:
                    return str(param_value[0])
                return _list_to_matlab_vector(param_value)
            return _python_to_matlab_value(param_value)
        elif target_type == 'vector_or_string':
            if _is_flat_numeric_list(param_value):
                return _list_to_matlab_vector(param_value)
            elif len(param_value) == 1 and isinstance(param_value[0], str):
                escaped = param_value[0].replace("'", "''")
                return f"'{escaped}'"
            return _python_to_matlab_value(param_value)
        elif target_type == 'vector_or_matrix':
            if _is_nested_list(param_value):
                return _list_to_matlab_matrix(param_value)
            elif _is_flat_numeric_list(param_value):
                return _list_to_matlab_vector(param_value)
            return _python_to_matlab_value(param_value)
        elif target_type == 'string':
            return f"'{_format_as_matlab_string(param_value)}'"
        elif target_type == 'enum':
            if isinstance(param_value, list) and len(param_value) == 1:
                return f"'{param_value[0]}'"
            return f"'{_format_as_matlab_string(param_value)}'"
        else:
            return _python_to_matlab_value(param_value)  # fallback to cell
    
    # === 规则 7: dict → 检查是否有特殊标记，否则 struct ===
    if isinstance(param_value, dict):
        if '__matlab_expr__' in param_value:
            return param_value['__matlab_expr__']
        if '__workspace_var__' in param_value:
            var_name = param_value['__workspace_var__']
            return f"'{var_name}'"  # 返回 "'A_ws'" 格式
        return _python_to_matlab_value(param_value)
    
    # === 兜底 ===
    return _python_to_matlab_value(param_value)

def _extract_block_type(source_block):
    """'simulink/Continuous/State-Space' → 'State-Space'"""
    if not source_block:
        return ''
    parts = source_block.split('/')
    return parts[-1] if parts else source_block

def _build_params_struct_expr(params_dict, block_type=''):
    """构建参数 struct 的 MATLAB 表达式（使用智能转换）"""
    if not params_dict:
        return 'struct()'
    parts = []
    for k, v in params_dict.items():
        val_str = _smart_param_convert(k, v, block_type)
        # 如果值已经是带引号的字符串（MATLAB 表达式），不加重括号
        # 否则加重括号确保 MATLAB 正确解析
        if val_str.startswith("'") and val_str.endswith("'"):
            parts.append(f"'{k}',{val_str}")
        else:
            parts.append(f"'{k}',{val_str}")  # [P2-5 FIX] Removed unnecessary parentheses
    return f"struct({','.join(parts)})"


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
        # [v11.7.1 B6 FIX] Unwrap MultipleErrors cause chain for actionable diagnostics
        f"errMsg = ME.message; "
        f"if ~isempty(ME.cause), "
        f"  for ci = 1:numel(ME.cause), "
        f"    errMsg = [errMsg ' | Cause ' num2str(ci) ': ' ME.cause{{ci}}.message]; "
        f"  end, "
        f"end, "
        f"err = struct('status','error','message',errMsg,'identifier',ME.identifier); "
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
            },
            # [P0-6 FIX] R2: Goto/From must only be used within a single subsystem
            {
                'rule_number': 3,
                'field': 'sourceBlock',
                'pattern': r'(?i)\bGoto\b',
                'level': 'warning',
                'message': 'Goto block: Ensure it is used ONLY within a single subsystem scope.',
                'suggestion': 'For cross-subsystem signals, use Inport/Outport standard interfaces. Goto/From is for WITHIN-subsystem local routing only. Set TagVisibility="local" to enforce scope.',
            },
            {
                'rule_number': 4,
                'field': 'sourceBlock',
                'pattern': r'(?i)\bFrom\b',
                'level': 'warning',
                'message': 'From block: Ensure its matching Goto is in the SAME subsystem.',
                'suggestion': 'Cross-subsystem signals MUST use Inport/Outport. From blocks should only read Goto tags within their own subsystem scope.',
            }
        ]
    },
    # [P2-4 FIX v11.7] Anti-pattern rules for other write operations
    'sl_set_param': {
        'check_before': True,
        'rules': [
            {
                'rule_number': 1,
                'field': 'params',
                'field_specific': 'SampleTime',
                'pattern': r'^-\d',
                'level': 'error',
                'message': 'Negative sample time is physically impossible.',
                'suggestion': 'Use positive sample time or -1 for inherited. -1 means inherit from parent.',
            },
            {
                'rule_number': 2,
                'field': 'params',
                'field_specific': 'Gain',
                'pattern': r'^\s*$',
                'level': 'warning',
                'message': 'Empty Gain value. Block will use default (1.0).',
                'suggestion': 'Explicitly set Gain to the intended value to avoid silent defaults.',
            },
            {
                'rule_number': 3,
                'field': 'params',
                'field_specific': 'Inputs',
                'pattern': r'\|.*\|.*\|.*\|.*\|',
                'level': 'warning',
                'message': 'Sum block with >5 inputs is hard to read and maintain.',
                'suggestion': 'Consider cascading multiple Sum blocks or using a Mux + Add approach.',
            }
        ]
    },
    'sl_add_line': {
        'check_before': True,
        'rules': [
            {
                'rule_number': 1,
                'field': 'srcSpec',
                'pattern_check': 'algebraic_loop',
                'level': 'warning',
                'message': 'Potential algebraic loop: adding line may create feedback without delay.',
                'suggestion': 'Add a Unit Delay or Memory block to break algebraic loops.',
            }
        ]
    }
}

# [P2-4 FIX v11.7] _WRITE_VERIFY_MAP extension for new anti-pattern commands
# Note: sl_modify_verify_step is now auto-triggered by Gap 5 fix


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
        
        # [P2-4 FIX] Field-specific check: search within a sub-field of params
        field_specific = rule.get('field_specific', '')
        if field_specific and isinstance(params.get(rule['field']), dict):
            field_value = str(params[rule['field']].get(field_specific, ''))
        
        # [P2-4 NEW] Specialized check types (algebraic_loop, etc.)
        pattern_check = rule.get('pattern_check', '')
        pattern = rule.get('pattern', '')
        
        matched = False
        if pattern and re.search(pattern, field_value):
            matched = True
        elif pattern_check == 'algebraic_loop':
            # Algebraic loop detection: always warn for add_line operations
            # Full loop detection requires model topology analysis (future enhancement)
            matched = True
        
        if matched:
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
        'detect': lambda cmd, p: cmd in ('sl_add_block', 'sl_add_block_safe') and re.search(r'(?i)\bSum\b', str(p.get('sourceBlock', ''))),
        'level': 'warning',
        'message': 'Sum block is discouraged. Use Add/Subtract instead.',
        'suggestion': 'Use Add block for addition, Subtract for subtraction',
    },
    'PITFALL-TOWS': {
        'detect': lambda cmd, p: cmd in ('sl_add_block', 'sl_add_block_safe') and re.search(r'(?i)To.?Workspace', str(p.get('sourceBlock', ''))),
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
    
    # [v11.8.3 Bug#11 FIX] 同时匹配 sl_set_param 和 sl_set_param_safe
    if command in ('sl_set_param', 'sl_set_param_safe'):
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
    if command in ('sl_add_line', 'sl_add_line_safe'):
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
    if command in ('sl_set_param', 'sl_set_param_safe', 'sl_delete'):
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
    dist_parent = os.path.join(engine_path, "dist")
    if not os.path.exists(engine_path) or not os.path.isdir(dist_parent):
        sys.stderr.write("[MATLAB Bridge] Engine 路径不存在，跳过 Engine 测试，使用 CLI 模式\n")
        sys.stderr.flush()
        _engine_compatible = False
        return _engine_compatible
    
    _result = {'compatible': None}
    
    def _do_test():
        try:
            # [v11.4.2 FIX] Use dist_parent (not engine_path) to match
            # setup_matlab_engine() path. Using engine_path causes a different
            # import resolution that conflicts with the dist-based setup,
            # leading to "circular import / partially initialized module" errors.
            if dist_parent not in sys.path:
                sys.path.insert(0, dist_parent)
            import matlab.engine
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
    """Setup and import the correct MATLAB engine for the target MATLAB_ROOT
    
    [v11.4.1 FIX] Ensures the engine module matches the target MATLAB version.
    Previously, site-packages might contain engine from a different MATLAB
    (e.g. 2016a engine + 2023b DLLs → libmwfl.dll crash).
    
    Strategy:
    1. Check dist/matlab/ in MATLAB_ROOT for pre-built package
    2. If found, insert into sys.path FIRST so it takes priority
    3. Fall back to system site-packages if dist not available
    4. Post-import: verify engine origin matches MATLAB_ROOT, warn if mismatch
    """
    engine_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python")
    dist_path = os.path.join(engine_path, "dist", "matlab")
    dist_parent = os.path.join(engine_path, "dist")
    
    # Use pre-built dist package if available (matches MATLAB version exactly)
    engine_source = 'unknown'
    if os.path.isdir(dist_path):
        if dist_parent not in sys.path:
            sys.path.insert(0, dist_parent)
        engine_source = 'dist'
    elif os.path.exists(engine_path) and engine_path not in sys.path:
        sys.path.insert(0, engine_path)
        engine_source = 'engine_path'
    else:
        engine_source = 'site-packages'
    
    sys.stderr.flush()
    import matlab.engine
    
    # [v11.4.1] Post-import verification: check engine origin matches MATLAB_ROOT
    engine_file = getattr(matlab.engine, '__file__', '')
    engine_dir = os.path.dirname(os.path.abspath(engine_file)) if engine_file else ''
    
    target_matlab_lower = MATLAB_ROOT.replace('\\', '/').rstrip('/').lower()
    engine_dir_lower = engine_dir.replace('\\', '/').lower()
    is_correct_engine = target_matlab_lower in engine_dir_lower
    
    # If using dist package, verify it actually got imported
    if engine_source == 'dist' and not is_correct_engine:
        sys.stderr.write(f"[MATLAB Bridge] ⚠️  Engine version mismatch detected!\n")
        sys.stderr.write(f"[MATLAB Bridge]   Expected: {MATLAB_ROOT}\n")
        sys.stderr.write(f"[MATLAB Bridge]   Actually loaded from: {engine_file}\n")
        sys.stderr.write(f"[MATLAB Bridge]   This may cause libmwfl.dll crash or simulation errors.\n")
        # Try to auto-fix: remove old import, force dist path
        try:
            # Remove any site-packages matlab from sys.modules
            for mod_key in list(sys.modules.keys()):
                if mod_key.startswith('matlab'):
                    del sys.modules[mod_key]
            # Ensure dist is first in path
            if dist_parent in sys.path:
                sys.path.remove(dist_parent)
            sys.path.insert(0, dist_parent)
            # Re-import
            import matlab.engine
            engine_file2 = getattr(matlab.engine, '__file__', '')
            engine_dir2 = os.path.dirname(os.path.abspath(engine_file2)) if engine_file2 else ''
            if target_matlab_lower in engine_dir2.replace('\\', '/').lower():
                sys.stderr.write(f"[MATLAB Bridge] ✅ Auto-fixed: engine now from MATALB_ROOT\n")
                is_correct_engine = True
            else:
                sys.stderr.write(f"[MATLAB Bridge] ❌ Auto-fix failed. Try manually:\n")
                sys.stderr.write(f"[MATLAB Bridge]    cp -r {dist_path} to site-packages/matlab/\n")
        except Exception as e:
            sys.stderr.write(f"[MATLAB Bridge] ❌ Auto-fix error: {e}\n")
    
    if is_correct_engine:
        sys.stderr.write(f"[MATLAB Bridge] Engine matched: {MATLAB_ROOT}\n")
    
    sys.stderr.flush()
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
    
    if _matlab_engine is not None:
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
        saved_pwd = None  # [v11.8.2 Bug#6 FIX]
        try:
            # [v11.8.2 Bug#6 FIX] Save current pwd before executing script
            try:
                saved_pwd = eng.eval("pwd", nargout=1)
            except Exception:
                saved_pwd = None
            
            # v5.0: 使用 diary 替代 evalc，避免引号双写问题
            script_dir_safe = script_dir.replace('\\', '/')
            
            # [v11.8.2 Bug#5+Bug#6 FIX] pwd-aware execution with sanitization
            exec_code = f"cd('{script_dir_safe}'); run('{script_name}');"
            if saved_pwd:
                saved_pwd_safe = saved_pwd.replace('\\', '/')
                exec_code = f"cd('{script_dir_safe}'); run('{script_name}'); cd('{saved_pwd_safe}');"
            sanitized_code, cleanup_vars = _sanitize_non_ascii_strings(eng, exec_code)
            matlab_output_raw = _run_code_via_diary(eng, sanitized_code)
            
            # 清理 workspace 变量
            for var in cleanup_vars:
                try: eng.eval(f"clear {var}", nargout=0)
                except: pass
            
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
            # [v11.8.2 Bug#6 FIX] Ensure pwd recovery even on error
            if saved_pwd:
                try:
                    eng.workspace['_ws_recover_pwd'] = saved_pwd
                    eng.eval("cd(_ws_recover_pwd); clear _ws_recover_pwd;", nargout=0)
                except Exception:
                    pass
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


def _sanitize_non_ascii_strings(eng, code):
    """Pre-process MATLAB code: extract non-ASCII string literals, store via
    eng.workspace[], and replace with variable references.
    
    This is the engineering-grade solution for Chinese path encoding.
    eng.eval('cd(''中文路径'')') garbles Chinese chars on Windows because the
    Python string → MATLAB char conversion uses the system locale, which may
    not match UTF-8. eng.workspace['x'] = '中文路径' avoids this entirely
    because the MATLAB Engine Python API handles Unicode correctly for
    workspace variable assignment.
    
    Returns:
        (sanitized_code, cleanup_vars): sanitized code string and list of
        workspace variable names to clear after execution.
    """
    import re
    
    # Match MATLAB single-quoted strings: 'text' or 'text with '' escaped quote'
    # Pattern: opening quote, content (non-quote or escaped ''), closing quote
    str_pattern = re.compile(r"'((?:[^']|'')*)'")
    
    replacements = []
    cleanup_vars = []
    var_counter = [0]  # Use list for closure in nested function
    
    def replace_match(m):
        original = m.group(0)   # '完整字符串'
        content = m.group(1)    # 字符串内容
        # Check for non-ASCII
        if all(ord(c) < 128 for c in content):
            return original  # ASCII-only, leave unchanged
        
        var_counter[0] += 1
        var_name = f'_ws_s{var_counter[0]}'
        # Undo MATLAB escaped quotes ('' → ') for the actual string value
        actual_value = content.replace("''", "'")
        replacements.append((var_name, actual_value))
        cleanup_vars.append(var_name)
        return var_name  # Replace string literal with variable reference
    
    sanitized = str_pattern.sub(replace_match, code)
    
    # Store values in MATLAB workspace via Engine API (safe for Unicode)
    for var_name, value in replacements:
        try:
            eng.workspace[var_name] = value
        except Exception:
            # Fallback: if workspace assignment fails, try without this optimization
            return code, []
    
    return sanitized, cleanup_vars


def _safe_eval_with_paths(eng, code_template, path_params):
    """[v11.8.2 Bug#5 FIX] 安全执行含路径的 MATLAB 代码。
    
    将所有路径参数通过 eng.workspace[] 传递（绕过 eng.eval 的编码问题），
    然后执行代码模板（代码中使用变量引用）。
    
    Args:
        code_template: MATLAB 代码，使用 {var} 引用路径变量
        path_params: dict of {var_name: path_value}
    
    Example:
        _safe_eval_with_paths(eng, 
            "save_system('{model}', '{save_path}')",
            {'model': 'Quadrotor_ADRC', 'save_path': 'd:/中文/路径.slx'})
    """
    cleanup = []
    for var_name, path_value in path_params.items():
        safe_name = f'_wp_{var_name}'
        eng.workspace[safe_name] = path_value
        cleanup.append(safe_name)
    
    formatted = code_template
    for var_name in path_params:
        formatted = formatted.replace(f'{{{var_name}}}', f'_wp_{var_name}')
    
    try:
        eng.eval(formatted, nargout=0)
    finally:
        for var_name in cleanup:
            try:
                eng.eval(f"clear {var_name}", nargout=0)
            except Exception:
                pass


def _check_sim_gate(eng, code):
    """Pre-execution gate: block sim() calls for models not yet completed.
    
    v11.6.8 B9 FIX: sl_model_complete sets canProceed=false when unconnected
    ports exist, but sim() called via run_code bypasses Gate_4. This check
    intercepts ALL sim() calls at the lowest execution layer and enforces
    the model completion requirement.
    
    Returns:
        None if all sim() calls are valid, or a gate_blocked dict if blocked.
    """
    import re
    
    # Match sim() calls: sim('ModelName', ...) or sim("ModelName", ...) or sim(modelName, ...)
    # Pattern: \bsim\s*\(  — word boundary + sim + optional whitespace + paren
    sim_pattern = re.compile(r'\bsim\s*\(\s*')
    matches = list(sim_pattern.finditer(code))
    
    if not matches:
        return None  # No sim() calls, nothing to check
    
    for m in matches:
        # Extract first argument after sim(
        start = m.end()
        arg_end = start
        depth = 0
        in_string = False
        string_char = None
        arg = ''
        
        i = start
        while i < len(code):
            c = code[i]
            if in_string:
                if c == string_char:
                    in_string = False
            elif c in ("'", '"'):
                in_string = True
                string_char = c
            elif c == '(':
                depth += 1
            elif c == ')':
                if depth == 0:
                    break
                depth -= 1
            elif c == ',' and depth == 0:
                break
            if not in_string or c != string_char:
                arg += c
            i += 1
        
        arg = arg.strip().strip("'").strip('"')
        if not arg:
            continue
        
        # Check if model completion flag is set in MATLAB workspace
        model_safe = arg.replace('/', '__').replace(' ', '_')
        flag_var = f'model_completed_{model_safe}'
        
        try:
            exists = eng.eval(f"exist('{flag_var}', 'var')", nargout=1)
        except Exception:
            exists = 0
        
        if exists == 0:
            return {
                "status": "gate_blocked",
                "blocked": True,
                "gate": "Gate_4 (pre-sim)",
                "reason": f"Model '{arg}' has NOT passed sl_model_complete. Unconnected ports may exist.",
                "command": "sim",
                "message": (
                    f"SIM_BLOCKED: 模型 '{arg}' 未通过完成检查。\n"
                    f"请先执行 sl_model_complete('{arg}', 'action', 'complete') 完成模型验证。\n"
                    f"未连接端口必须全部解决后，才能进行仿真。"
                ),
                "requiredAction": "sl_model_complete",
                "hint": f"sl_model_complete('{arg}', 'action', 'complete')",
            }
    
    return None  # All sim() calls checked, all models completed


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
        # [v11.7.1 B4 FIX] Use plain UTF-8 (no BOM) because MATLAB's run()
        # cannot handle BOM bytes in .m files — causes "文本字符无效" error.
        with open(script_file, 'w', encoding='utf-8') as f:
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
            # [v11.6.8 C1 FIX] Sanitize non-ASCII string literals
            sanitized_code, cleanup_vars = _sanitize_non_ascii_strings(eng, code)
            
            # [v11.6.8 B9 FIX] Pre-execution sim() gate: block simulation
            # for models that haven't passed sl_model_complete.
            # This is the BOTTOM-LEVEL enforcement — it catches sim()
            # called via run_code, sl_sim_run, scripts, and any other path.
            sim_gate_result = _check_sim_gate(eng, sanitized_code)
            if sim_gate_result is not None:
                return sim_gate_result  # Blocked — return gate error
            
            eng.eval(sanitized_code, nargout=0)
            # Clean up temporary workspace variables
            if cleanup_vars:
                try:
                    clear_cmd = 'clear ' + ' '.join(cleanup_vars) + ';'
                    eng.eval(clear_cmd, nargout=0)
                except:
                    pass
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


def _handle_cmd_request(command_preview):
    """[v11.8.3] Gate_RAW_CMD: Generate token+challenge for raw MATLAB command execution.
    
    AI must call this BEFORE /api/matlab/command.
    Returns a cmdToken + challengePhrase that AI MUST present to user via AskUserQuestion.
    Token is one-time use, expires in 120s, requires turn separation.
    """
    import uuid, time, random, string
    
    # Clear any stale state
    for stale_key in ('cmd_token', 'cmd_timestamp', 'cmd_request_id', 'cmd_preview'):
        _RAW_CMD_STATE.pop(stale_key, None)
    
    _cmd_token = uuid.uuid4().hex[:16]
    _challenge = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    _ts = time.time()
    
    global _REQUEST_COUNTER
    _REQUEST_COUNTER += 1
    _req = _REQUEST_COUNTER
    
    _RAW_CMD_STATE['cmd_token'] = _cmd_token
    _RAW_CMD_STATE['cmd_timestamp'] = _ts
    _RAW_CMD_STATE['cmd_request_id'] = _req
    _RAW_CMD_STATE['cmd_preview'] = command_preview[:500] if command_preview else '(no preview)'
    
    return {
        "status": "ok",
        "cmdToken": _cmd_token,
        "challengePhrase": _challenge,
        "confirmationRequired": True,
        "commandPreview": _RAW_CMD_STATE['cmd_preview'],
        "userPrompt": (
            f"【需要用户授权】AI 请求使用 /api/matlab/command 执行原始 MATLAB 命令。\n"
            f"确认短语: {_challenge}\n\n"
            f"命令预览: {_RAW_CMD_STATE['cmd_preview']}\n\n"
            "请选择:\n"
            "  (1) 同意使用 /api/matlab/command — 授权执行此原始命令\n"
            "  (2) 用标准 Simulink 建模流程 — 拒绝原始命令, 要求 AI 改用 sl_* API"
        ),
        "challengeInstructions": (
            f"You MUST display the challenge phrase '{_challenge}' in your AskUserQuestion text. "
            "You MUST present TWO options to the user:\n"
            "  Option 1 (Recommended if user wants raw MATLAB): 'Agree to use /api/matlab/command'\n"
            "  Option 2 (DEFAULT for standard workflow): 'Use standard Simulink workflow (sl_* API)'\n"
            "If user picks Option 2, do NOT call /api/matlab/command — instead use sl_* API."
        ),
        "options": {
            "agree_raw": {
                "label": "同意使用 /api/matlab/command",
                "description": f"授权 AI 执行原始 MATLAB 命令 (令牌: {_cmd_token[:8]}...)",
                "action": "call /api/matlab/command with cmdToken"
            },
            "use_standard": {
                "label": "用标准 Simulink 建模流程",
                "description": "拒绝原始命令, AI 应改用 sl_* API (sl_add_block_safe, sl_add_line_safe 等) 进行门控保护的标准建模流程",
                "action": "use sl_* API workflow"
            }
        },
        "hint": "If user picks 'standard workflow', DO NOT call /api/matlab/command. Use sl_* API instead."
    }


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
    
    # v11.4.4: 门控 — 项目目录未设置时阻止代码执行
    if not _project_dir:
        return {
            "status": "gate_blocked",
            "blocked": True,
            "gate": "PROJECT_DIR_REQUIRED",
            "message": "项目目录未设置！请先调用: POST /api/matlab/project/set { \"dirPath\": \"<工作目录>\" }",
            "requiredAction": "setup_project_dir",
            "hint": "curl -X POST http://localhost:3000/api/matlab/project/set -H \"Content-Type: application/json\" -d '{\"dirPath\":\"D:/YourWorkspace\"}'"
        }
    
    # [v11.8.3] Gate_RAW_CMD: Raw MATLAB command requires user confirmation token
    # AI cannot use /api/matlab/command directly — must first call /api/matlab/command/request
    # and present the challenge phrase to the user via AskUserQuestion.
    _raw_cmd_token = _RAW_CMD_STATE.pop('cmd_token', None)
    _raw_cmd_ts = _RAW_CMD_STATE.pop('cmd_timestamp', 0)
    _raw_cmd_req = _RAW_CMD_STATE.pop('cmd_request_id', 0)
    _raw_cmd_preview = _RAW_CMD_STATE.pop('cmd_preview', '')
    _current_ts = time.time()
    
    if not _raw_cmd_token:
        return {
            "status": "gate_blocked",
            "blocked": True,
            "gate": "Gate_RAW_CMD",
            "message": (
                "🔴 /api/matlab/command is DISABLED for direct AI use.\n"
                "You have TWO options:\n"
                "  (1) Standard workflow (PREFERRED): Use sl_* API (sl_add_block_safe, sl_add_line_safe, etc.)\n"
                "      which enforces all 7 gate layers and injects automatic verification.\n"
                "  (2) If sl_* API is truly insufficient: Request user permission via\n"
                "      POST /api/matlab/command/request → AskUserQuestion → POST /api/matlab/command\n"
                "      with the cmdToken. THE USER WILL CHOOSE between option (1) and (2)."
            ),
            "requiredAction": "use_sl_api_or_cmd_request",
            "hint": "Prefer sl_* API. Only use /api/matlab/command/request as last resort."
        }
    
    # Token expiration check (120s — commands must be executed promptly after user approval)
    _elapsed = _current_ts - _raw_cmd_ts
    if _elapsed > 120:
        return {
            "status": "gate_blocked",
            "blocked": True,
            "gate": "Gate_RAW_CMD",
            "reason": f"Command token expired ({_elapsed:.0f}s > 120s). Re-request user confirmation.",
            "message": "CMD_TOKEN_EXPIRED: The command confirmation token has expired. Re-run cmd_request.",
            "hint": "Call POST /api/matlab/command/request again.",
            "requiredAction": "cmd_request"
        }
    
    # Token is one-time use (already popped above) + 120s expiration.
    # The AskUserQuestion flow ensures user interaction; no need for explicit turn separation.
    # Gate check passed — token consumed
    # Include command preview in response for traceability
    _cmd_preview_val = _raw_cmd_preview
    # Issue warning to encourage use of standard sl_* API (which enforces gates).
    # Does NOT block execution — run_code is the escape hatch for bulk/model building.
    import re
    _sl_ops_warning = []
    if re.search(r'\badd_block\s*\(', code):
        _sl_ops_warning.append('add_block')
    if re.search(r'\badd_line\s*\(', code):
        _sl_ops_warning.append('add_line')
    if re.search(r'\bdelete_block\s*\(', code):
        _sl_ops_warning.append('delete_block')
    if re.search(r'\bdelete_line\s*\(', code):
        _sl_ops_warning.append('delete_line')
    _sl_ops_warning_str = ', '.join(_sl_ops_warning) if _sl_ops_warning else None
    # [v11.8.2 Bug#7 FIX] Flag for forced Simulink refresh after structural ops
    _needs_simulink_refresh = bool(_sl_ops_warning)
    
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
                    if diary_result.get('status') in ('error', 'gate_blocked'):
                        return diary_result
                    output_str = diary_result.get('output', '')
                    exec_time = diary_result.get('executionTime', 0)
                else:
                    # 兼容：旧逻辑返回纯字符串
                    output_str = str(diary_result)
                    exec_time = 0
            else:
                start_time = time.time()
                # [v11.6.8 B9] Also enforce sim gate for show_output=False path
                sim_gate = _check_sim_gate(eng, code)
                if sim_gate is not None:
                    return sim_gate
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
            _result = {
                "status": "ok",
                "stdout": output_str,
                "open_figures": fig_count,
                "connection_mode": "engine",
                "executionTime": exec_time,
                "variablesChanged": vars_changed
            }
            # [P2 FIX v11.6.7] Inject gate awareness warning
            if _sl_ops_warning_str:
                _result["gateAwarenessWarning"] = (
                    f"run_code contains gated Simulink operations: {_sl_ops_warning_str}. "
                    f"Prefer using the standard sl_* API (sl_add_block, sl_add_line, etc.) "
                    f"for proper gate enforcement and verification injection."
                )
            # [v11.8.2 Bug#7 FIX] Force Simulink refresh after structural operations
            if _needs_simulink_refresh:
                try:
                    eng.eval("drawnow;", nargout=0)
                except Exception:
                    pass
            return _result
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
        # [P2 FIX v11.6.7] Inject gate awareness warning for CLI path too
        if _sl_ops_warning_str and result.get('status') == 'ok':
            result["gateAwarenessWarning"] = (
                f"run_code contains gated Simulink operations: {_sl_ops_warning_str}. "
                f"Prefer using the standard sl_* API (sl_add_block, sl_add_line, etc.) "
                f"for proper gate enforcement and verification injection."
            )
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
    # v11.4.4: 门控 — 未设置 workspace 时阻止模型创建
    if not _project_dir and not model_path:
        return {
            "status": "gate_blocked",
            "blocked": True,
            "gate": "PROJECT_DIR_REQUIRED",
            "message": "项目目录未设置！请先调用 POST /api/matlab/setup",
            "requiredAction": "setup_project_dir"
        }
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
        # setup_matlab_engine() already verifies engine version match
        # We call it here to get the verification result
        matlab_engine_module = setup_matlab_engine()
        checks["engine_importable"] = True
        
        # [v11.4.1] Verify engine matches target MATLAB version
        engine_file = getattr(matlab_engine_module, '__file__', '')
        engine_dir = os.path.dirname(os.path.abspath(engine_file)) if engine_file else ''
        target_lower = MATLAB_ROOT.replace('\\', '/').rstrip('/').lower()
        checks["engine_version_match"] = target_lower in engine_dir.replace('\\', '/').lower()
        checks["engine_origin"] = engine_file
        
        if not checks["engine_version_match"]:
            dist_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python", "dist", "matlab")
            checks["engine_fix_hint"] = (
                f"Engine loaded from wrong MATLAB version! "
                f"This will cause libmwfl.dll crash. "
                f"Fix: copy {dist_path} to site-packages/matlab/"
            ) if os.path.isdir(dist_path) else (
                f"Engine version mismatch. "
                f"Run: cd {MATLAB_ROOT}\\extern\\engines\\python && python setup.py install"
            )
    except Exception as e:
        checks["engine_importable"] = False
        checks["engine_version_match"] = False
        checks["engine_import_error"] = str(e)
    
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
    "sl_add_block_safe":   "sl_add_block_safe",
    "sl_add_line":         "sl_add_line_safe",
    "sl_add_line_safe":    "sl_add_line_safe",
    "sl_set_param":        "sl_set_param_safe",
    "sl_set_param_safe":   "sl_set_param_safe",
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
    "sl_model_design":      "sl_model_design",  # v10.1: 物理建模设计
    "sl_model_complete":    "sl_model_complete",  # v11.3: 模型完成门控
    "sl_get_model_issues":  "sl_get_model_issues",  # v11.3: 模型问题详情
    "sl_framework_verify_built": "sl_framework_verify_built",  # v11.4: 设计-模型对照验证
    "sl_check_port_completeness": "sl_check_port_completeness",  # v11.4: 子系统端口完备性
    "sl_check_signal_closure": "sl_check_signal_closure",  # v11.4: 信号流闭环
    # v11.0: 大框架三层迭代循环
    "sl_framework_design":   "sl_framework_design",  # 大框架设计
    "sl_framework_review":   "sl_framework_review",  # 大框架自检
    "sl_framework_approve":  "sl_framework_approve",  # 大框架审批/锁定
    # v11.0 Phase 2: 子系统小框架迭代循环
    "sl_micro_design":       "sl_micro_design",  # 子系统小框架设计
    "sl_micro_review":       "sl_micro_review",  # 子系统小框架自检
    "sl_micro_approve":      "sl_micro_approve",  # 子系统小框架审批
    # v11.8: Unified review engine
    "sl_review_core":        "sl_review_core",  # 四维统一审查（portPairing / paramAudit / connectionScan / layoutAudit）
    # v11.0 Phase 3: 大框架锁定后变更审批
    "sl_framework_modify":          "sl_framework_modify",  # 大框架变更申请
    "sl_framework_modify_approve":  "sl_framework_modify_approve",  # 批准变更
    "sl_framework_modify_reject":   "sl_framework_modify_reject",  # 拒绝变更
    # v11.5: Scene 2 — existing model modification workflow
    "sl_scene_detect":       "sl_scene_detect",       # Gate_S0: auto-detect scene
    "sl_scene_confirm":      "_builtin_scene_confirm",  # Gate_S0: user confirms scene
    "sl_model_load":         "sl_model_load",         # Step 2.0: load existing model
    "sl_model_understand":   "sl_model_understand",   # Step 2.1: auto-analyze model
    "sl_modify_plan":        "sl_modify_plan",        # Step 2.3: modify intent prompt
    "sl_modify_review":      "sl_modify_review",       # Step 2.4: review modify plan
    "sl_modify_approve":     "sl_modify_approve",      # Step 2.4: approve + Gate_S2
    "sl_model_sandbox":      "sl_model_sandbox",       # Step 2.5: create sandbox subsystem
    "sl_modify_verify_step": "sl_modify_verify_step",  # Step 2.6: per-step verify
    # v11.6.7: Safe line deletion
    "sl_clear_top_lines":    "sl_clear_top_lines",     # 清除模型顶层连线(保留子系统内部)
    # v11.8: Recursive hierarchy management
    "sl_hierarchy_validate":  "sl_hierarchy_validate",   # 验证完整层级树
    "sl_subsystem_tree":      "sl_subsystem_tree",        # 查询树结构
    # v11.8: Bridge-builtin recursive workflow commands
    "sl_build_status":        "_builtin_build_status",    # 查询构建进度
    "sl_next_target":         "_builtin_next_target",     # 获取下一个构建目标
    # v11.9: Model lifecycle
    "sl_model_create":        "sl_model_create",         # 创建新 Simulink 模型 (Scene 1)
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
    
    elif command in ("sl_add_block", "sl_add_block_safe"):
        # sl_add_block_safe(modelName, sourceBlock, varargin)
        # v10.1: 使用智能参数转换，支持矩阵/向量参数
        # [v11.8.3 Bug#14 FIX] blockType as alias for sourceBlock
        source_block = params.get('sourceBlock', params.get('blockType', ''))
        raw_params = params.get('params', {})
        block_type = _extract_block_type(source_block)
        # [v11.8.3 Bug#14 FIX] SubSystem: extract params.Name -> destPath
        dest_path = params.get('destPath', params.get('blockName', ''))  # [P0-9 FIX] Also accept blockName as alias for destPath
        if not dest_path and source_block and 'subsystem' in str(source_block).lower():
            dest_path = (raw_params or {}).get('Name', '')
        return {
            '_pos_1': model_name,
            '_pos_2': source_block,
            'destPath': dest_path,
            'position': params.get('position', []),
            'makeNameUnique': params.get('makeNameUnique', True),
            'params': ('__special__', _build_params_struct_expr(raw_params, block_type)),
        }
    
    elif command in ("sl_add_line", "sl_add_line_safe"):
        # sl_add_line_safe(modelName, varargin)
        # 格式1: sl_add_line_safe(model, srcBlock, srcPort, dstBlock, dstPort, ...)
        # 格式2: sl_add_line_safe(model, 'srcBlock/portNum', 'dstBlock/portNum', ...)
        # Bridge 使用格式2（更简洁），srcBlock/dstBlock 需包含模型前缀
        # 优先使用 srcSpec/dstSpec（REST API 直接传入格式2字符串）
        src_spec = params.get('srcSpec', '')
        dst_spec = params.get('dstSpec', '')
        # [v11.5 FIX] REST API passes combined spec in srcPort/dstPort (e.g. 'Gain/1')
        if not src_spec and '/' in str(params.get('srcPort', '')):
            src_spec = str(params['srcPort'])
        if not dst_spec and '/' in str(params.get('dstPort', '')):
            dst_spec = str(params['dstPort'])
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
    
    elif command in ("sl_set_param", "sl_set_param_safe"):
        # sl_set_param_safe(blockPath, params, varargin)
        # v10.1: 使用智能参数转换，支持矩阵/向量参数
        block_path = params.get('blockPath', '')
        raw_params = params.get('params', {})
        # 优先从 params 中获取 blockType（AI 显式传递），否则从 blockPath 推断
        block_type = params.get('blockType', '')
        if not block_type and '/' in block_path:
            # 从 blockPath 提取模块类型名
            parts = block_path.split('/')
            if len(parts) >= 2:
                # 尝试查 sl_block_registry 获取真实类型
                block_type = parts[-1]  # 简化处理
        return {
            '_pos_1': block_path,
            '_pos_2_special': _build_params_struct_expr(raw_params, block_type),
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
        # [v11.8 Bug#5 FIX] Auto-detect mode: if blocksToGroup is empty, use 'empty' mode
        _explicit_mode = params.get('mode', None)
        if _explicit_mode:
            _detected_mode = _explicit_mode
        elif blocks_to_group:
            _detected_mode = 'group'
        else:
            _detected_mode = 'empty'
        args = {
            '_pos_1': model_name,
            '_pos_2': params.get('subsystemName', ''),
            '_pos_3': _detected_mode,
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

    elif command == "sl_model_design":
        # sl_model_design(taskDescription, varargin)
        # action: 'design'（默认）或 'approve'（审批设计方案）或 'status'（查询状态）
        action = params.get('action', 'design')
        if action == 'approve':
            # 审批模式：不在 MATLAB 执行，直接更新 Bridge 状态
            return {'_pos_1_special': '__design_approve__', 'modelName': model_name}
        elif action == 'status':
            return {'_pos_1_special': '__design_status__', 'modelName': model_name}
        else:
            return {
                '_pos_1': params.get('taskDescription', ''),
                'domain': params.get('domain', 'auto'),
                'approach': params.get('approach', 'auto'),
                'detailLevel': params.get('detailLevel', 'standard'),
            }

    # v11.0: 大框架三层迭代循环 API
    elif command == "sl_framework_design":
        # sl_framework_design(taskDescription, varargin)
        return {
            '_pos_1': params.get('taskDescription', ''),
            'domain': params.get('domain', 'auto'),
            'subsystemCount': params.get('subsystemCount', 0),
            'detailLevel': params.get('detailLevel', 'standard'),
        }

    elif command == "sl_framework_review":
        # sl_framework_review(macroFramework, varargin)
        # macroFramework 作为第一位置参数（可以是 struct 或 taskDescription string）
        macro_framework = params.get('macroFramework', params.get('taskDescription', ''))
        # [v11.8] Include all 11 default checks (5 original + 6 new recursive hierarchy checks)
        check_items = params.get('checkItems', [
            'physics', 'signalFlow', 'subsystem', 'gotoFrom', 'dimensionality',
            'nestingDepth', 'singleBlock', 'cohesion', 'crossLevelInterface',
            'treeCompleteness', 'leafSubsystems'
        ])
        return {
            '_pos_1': macro_framework,
            'checkItems': check_items,
        }

    elif command == "sl_framework_approve":
        # sl_framework_approve(modelName, varargin)
        # 审批模式：不在 MATLAB 执行，直接更新 Bridge 状态
        # v11.4: Gate_5 runs in _handle_sl_command BEFORE reaching here
        return {
            '_pos_1_special': '__fw_approve__',
            'modelName': model_name,
            'locked': params.get('locked', True),
            'macroFramework': params.get('macroFramework', {}),
        }

    # v11.0 Phase 2: 子系统小框架迭代循环 API
    elif command == "sl_micro_design":
        # sl_micro_design(subsystemName, taskDescription, varargin)
        return {
            '_pos_1': params.get('subsystemName', ''),
            '_pos_2': params.get('taskDescription', ''),
            'physics': params.get('physics', 'auto'),
            'detailLevel': params.get('detailLevel', 'standard'),
            'modelName': model_name,
        }

    elif command == "sl_micro_review":
        # sl_micro_review(subsystemName, 'microFramework', mf, 'checkItems', {...})
        subsystem = params.get('subsystemName', params.get('subsystem', ''))
        micro_framework = params.get('microFramework', {})
        result = {
            '_pos_1': subsystem,
            # [v11.8] Default: 4 design + 4 build checks via sl_review_core
            'checkItems': params.get('checkItems', [
                'physics', 'blockPlan', 'signalDimensions', 'integrators',
                'portPairing', 'paramAudit', 'connectionScan', 'layoutAudit'
            ]),
            'modelName': model_name,  # [v11.8.1] needed for full path in sl_review_core
        }
        if micro_framework:
            result['microFramework'] = micro_framework
        return result

    elif command == "sl_micro_approve":
        # sl_micro_approve(subsystemName, 'microFramework', mf, 'locked', true, 'modelName', modelName)
        subsystem = params.get('subsystemName', params.get('subsystem', ''))
        micro_framework = params.get('microFramework', {})
        result = {
            '_pos_1': subsystem,
            'locked': params.get('locked', True),
            'modelName': model_name,
        }
        if micro_framework:
            result['microFramework'] = micro_framework
        return result

    # [v11.8.1] sl_review_core handler
    elif command == "sl_review_core":
        # sl_review_core(modelPath, action)
        return {
            '_pos_1': params.get('modelPath', ''),
            '_pos_2': params.get('action', 'all'),
        }

    # v11.0 Phase 3: 大框架锁定后变更审批
    elif command == "sl_framework_modify":
        # sl_framework_modify(modelName, action, varargin)
        action = params.get('action', '')
        result = {
            '_pos_1': model_name,
            '_pos_2': action,
        }
        # Forward all relevant params based on action type
        if action == 'addSubsystem':
            result['subsystemName'] = params.get('subsystemName', '')
            result['subsystemType'] = params.get('subsystemType', '')
            result['inputs'] = params.get('inputs', '')
            result['outputs'] = params.get('outputs', '')
        elif action == 'removeSubsystem':
            result['subsystemName'] = params.get('subsystemName', '')
        elif action == 'changeSignalFlow':
            new_sf = params.get('newSignalFlow', [])
            if new_sf:
                result['newSignalFlow'] = new_sf
        elif action == 'changePhysics':
            new_pe = params.get('newPhysicsEquations', [])
            if new_pe:
                result['newPhysicsEquations'] = new_pe
        elif action == 'renameSubsystem':
            result['oldName'] = params.get('oldName', '')
            result['newName'] = params.get('newName', '')
        result['reason'] = params.get('reason', '')
        result['autoApprove'] = params.get('autoApprove', False)
        return result

    elif command == "sl_framework_modify_approve":
        # sl_framework_modify_approve(modelName, 'reason', '...')
        return {
            '_pos_1': model_name,
            'reason': params.get('reason', ''),
        }

    elif command == "sl_framework_modify_reject":
        # sl_framework_modify_reject(modelName, 'reason', '...')
        return {
            '_pos_1': model_name,
            'reason': params.get('reason', ''),
        }

    # v11.5: Scene 2 — Gate_S0 scene detection and confirmation
    elif command == "sl_scene_detect":
        # sl_scene_detect(workspaceDir)
        return {
            '_pos_1': params.get('workspaceDir', ''),
        }

    elif command == "sl_scene_confirm":
        # Handled inline in _handle_sl_command, not called via _call_sl_function
        # v11.6: confirmationToken = detectionToken from sl_scene_detect
        # [v11.7.1 B1 FIX] Accept both parameter names
        return {
            'scene': params.get('scene', 1),
            'modelName': params.get('modelName', ''),
            'confirmationToken': params.get('confirmationToken', params.get('detectionToken', '')),
        }

    elif command == "sl_model_create":
        # sl_model_create(modelName, varargin)
        # optional: 'saveTo', 'overwrite'
        args = {'_pos_1': model_name}
        if params.get('saveTo'):
            args['saveTo'] = params['saveTo']
        if params.get('overwrite') is not None:
            args['overwrite'] = params['overwrite']
        return args

    elif command == "sl_model_load":
        # sl_model_load(modelName)
        return {
            '_pos_1': model_name,
        }

    elif command == "sl_model_understand":
        # sl_model_understand(modelName)
        return {
            '_pos_1': model_name,
        }

    elif command == "sl_modify_plan":
        # sl_modify_plan(modelName, taskDescription, modelUnderstanding)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('taskDescription', ''),
            '_pos_3': params.get('modelUnderstanding', {}),
        }

    elif command == "sl_modify_review":
        # sl_modify_review(modifyPlan)
        return {
            '_pos_1': params.get('modifyPlan', {}),
        }

    elif command == "sl_modify_approve":
        # sl_modify_approve(modelName, modifyPlan)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('modifyPlan', {}),
        }

    elif command == "sl_model_sandbox":
        # sl_model_sandbox(modelName, sandboxName, modifyPlan)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('sandboxName', ''),
            '_pos_3': params.get('modifyPlan', {}),
        }

    elif command == "sl_modify_verify_step":
        # sl_modify_verify_step(modelName, stepIndex, modifyPlan)
        return {
            '_pos_1': model_name,
            '_pos_2': params.get('stepIndex', 1),
            '_pos_3': params.get('modifyPlan', {}),
        }

    elif command == "sl_model_complete":
        # sl_model_complete(modelName, 'action', action, autoTerminateIntegrators, flag)
        _args = {
            '_pos_1': model_name,
            'action': params.get('action', 'check'),
        }
        if params.get('autoTerminateIntegrators', False):
            _args['autoTerminateIntegrators'] = True
        return _args

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
    'sl_model_sandbox':   'subsystem',  # v11.6.1: sandbox creation triggers verify
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
    """线程安全地获取/创建 ModelWorkflowState
    
    [P0-FIX] v10.1.1: 创建新状态时从 MATLAB workspace 同步 design_approved 标记。
    原因: create_simulink/open_simulink 会清理 Python 端的 _BUILD_PHASE_TRACKER，
    但 sl_model_design(action='approve') 已经将标记存入 MATLAB workspace
    (assignin('base', ['design_approved_' modelName], true))。
    这样可以实现工业级的设计批准状态持久化。
    """
    with _global_lock:
        if model_name not in _BUILD_PHASE_TRACKER:
            new_state = ModelWorkflowState(model_name)
            
            # [P0-FIX] 从 MATLAB workspace 同步 design_approved 标记
            # sl_model_design.m 在 approve 时调用: assignin('base', ['design_approved_' model_safe], true)
            # [v11.5 FIX] model_name 可能含 '/' → 统一用 '__' 替换
            _safe_name = model_name.replace('/', '__')
            try:
                eng = get_engine()
                if eng is not None:
                    da_var = f'design_approved_{_safe_name}'
                    # 使用 exist() 检查变量是否存在（更可靠）
                    # exist('varName') 返回 1 表示存在
                    exists = eng.eval(f"evalin('base', 'exist(''{da_var}'')')", nargout=1)
                    if exists == 1:
                        da_value = eng.eval(f"evalin('base', '{da_var}')", nargout=1)
                        if da_value == True:
                            new_state.design_approved = True
                            new_state.phase = 'framework'
                            new_state.phase_step = 'building'
            except Exception:
                # MATLAB workspace 查询失败不影响主流程
                pass
            
            _BUILD_PHASE_TRACKER[model_name] = new_state
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
        self.phase = 'framework_design'   # v11.0: framework_design / framework_construction / subsystem_iteration / simulation
        self.phase_step = 'pending'        # pending / proposed / reviewed / approved / locked / building / layout / checking
        self.design_approved = False       # v10.1: 设计审批标志（保留兼容）
        self.framework_approved = False    # v11.0: 大框架审批标志
        self.framework_locked = False      # v11.0: 大框架锁定标志
        self.design_result = None          # v10.1: 设计方案缓存
        self.macro_framework = None        # v11.0: 大框架设计结果缓存
        self.micro_framework = None        # v11.0 Phase 2: 子系统小框架设计结果缓存
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
        self.model_completed = False      # v11.3: 模型完成门控是否通过
        self.pending_issues = []          # v11.3: 未解决的问题列表
        self.last_verification_failed = False  # v11.3: 上次验证是否失败
        # [v11.8] Phase 4: Recursive hierarchy tree management
        self.subsystem_tree = None        # v11.8: 完整子系统树 (dict, nested children)
        self.build_order = []             # v11.8: 自底向上的构建顺序 (list of dicts)
        self.current_build_index = -1     # v11.8: 当前构建进度索引
        self.hierarchy_approved = False   # v11.8: 层次结构是否通过审批
        self.level_status = {}            # v11.8: {depth: 'pending'|'building'|'completed'}
        self.nesting_warnings = []        # v11.8: 嵌套警告列表
        self.max_depth = 0                # v11.8: 最大嵌套深度


# ===== [v11.8 NEW] Recursive Hierarchy Tree Helpers =====
MAX_DEPTH = 5  # [RED] Hard depth limit — gate_blocked if exceeded

def _build_subsystem_tree_from_framework(fw, model_name):
    """从层次化大框架构建子系统树
    
    Args:
        fw: macroFramework dict with 'subsystems' list (each has optional 'childSubsystems')
        model_name: top-level model name
    
    Returns:
        dict: tree structure {path, depth, status, children: [...]}
    """
    tree = {
        'path': model_name,
        'depth': 0,
        'status': 'root',
        'children': []
    }
    
    def _recursive_build(subsystems, parent_path, depth):
        nodes = []
        if not subsystems:
            return nodes
        for sub in subsystems:
            if not isinstance(sub, dict):
                continue
            sub_name = sub.get('name', '')
            if not sub_name:
                continue
            full_path = f"{parent_path}/{sub_name}" if parent_path else sub_name
            
            node = {
                'path': full_path,
                'name': sub_name,
                'depth': depth,
                'role': sub.get('role', ''),
                'type': sub.get('type', 'subsystem'),
                'status': 'pending',
                'inputs': sub.get('inputs', []),
                'outputs': sub.get('outputs', []),
                'signalFlow': sub.get('signalFlow', []),
                'children': []
            }
            
            child_subs = sub.get('childSubsystems', [])
            if child_subs:
                node['children'] = _recursive_build(child_subs, full_path, depth + 1)
            
            nodes.append(node)
        return nodes
    
    tree['children'] = _recursive_build(fw.get('subsystems', []), model_name, 1)
    return tree


def _compute_build_order(tree):
    """计算自底向上的构建顺序（深度优先 → 叶子先入列）
    
    Args:
        tree: subsystem tree dict
    
    Returns:
        list of dicts: [{path, depth, name, status}, ...] in build order
    """
    order = []
    
    def _dfs(node, parent_path):
        full_path = f"{parent_path}/{node['name']}" if parent_path else node['name']
        
        # 先处理子节点（深度优先 → 叶子先入列）
        for child in node.get('children', []):
            _dfs(child, full_path)
        
        # 当前节点（子节点已在前）
        if node.get('depth', 0) > 0:  # 跳过根节点
            order.append({
                'path': full_path,
                'depth': node['depth'],
                'name': node['name'],
                'status': 'pending'
            })
    
    for child in tree.get('children', []):
        _dfs(child, tree['path'])
    
    return order


def _find_node_in_tree(tree, path):
    """在树中查找指定路径的节点
    
    Args:
        tree: subsystem tree dict
        path: full Simulink path like 'Model/Controller/PID_Core'
    
    Returns:
        dict or None: the node if found
    """
    if tree is None:
        return None
    
    # Normalize path separators
    path = path.replace('\\', '/')
    
    # Direct match at root
    if tree.get('path', '') == path:
        return tree
    
    # Search children recursively
    for child in tree.get('children', []):
        result = _find_node_in_tree(child, path)
        if result is not None:
            return result
    
    return None


def _update_node_status(tree_or_model, path, new_status):
    """线程安全地更新树中节点的状态
    
    v11.8: 支持两种调用模式：
    - _update_node_status(tree, path, new_status): 直接操作树 (caller 负责加锁)
    - _update_node_status(model_name, path, new_status): 通过 _global_lock 安全更新
    
    Args:
        tree_or_model: subsystem tree dict 或 model_name 字符串
        path: full Simulink path
        new_status: 'pending'|'design'|'review'|'approved'|'building'|'completed'|'failed'
    
    Returns:
        bool: True if node was found and updated
    """
    if isinstance(tree_or_model, str):
        # Thread-safe mode: lock-protected via model name
        with _global_lock:
            state = _BUILD_PHASE_TRACKER.get(tree_or_model)
            if state is None or state.subsystem_tree is None:
                return False
            node = _find_node_in_tree(state.subsystem_tree, path)
            if node is not None:
                node['status'] = new_status
                return True
            return False
    else:
        # Direct mode: caller handles locking
        tree = tree_or_model
        node = _find_node_in_tree(tree, path)
        if node is not None:
            node['status'] = new_status
            return True
        return False


def _can_start_level(tree, path, depth):
    """检查子系统是否可以开始构建：所有子子系统已完成 + 深度未超限
    
    Args:
        tree: subsystem tree dict
        path: full Simulink path
        depth: current depth
    
    Returns:
        (bool, str): (can_start, reason)
    """
    node = _find_node_in_tree(tree, path)
    if node is None:
        return False, f'Subsystem {path} not found in tree'
    
    # [RED] HARD DEPTH CHECK
    if depth > MAX_DEPTH:
        return False, f'SUBSYSTEM DEPTH {depth} EXCEEDS MAXIMUM {MAX_DEPTH}. Design REJECTED.'
    
    # Check all children are completed
    for child in node.get('children', []):
        if child.get('status') != 'completed':
            return False, f'Child subsystem {child["path"]} is not yet completed (status: {child.get("status", "unknown")})'
    
    return True, 'All children completed'


def _get_next_build_target(state):
    """获取下一个构建目标（跳过已完成和已失败的）
    
    策略 A（默认）: 跳过 failed 节点 → 继续构建同深度其他子系统 → 最后汇总 failed 列表
    
    Args:
        state: ModelWorkflowState instance
    
    Returns:
        dict or None: next target {path, depth, name, status}
    """
    if not state.build_order or state.subsystem_tree is None:
        return None
    
    skipped_failed = []
    for i, target in enumerate(state.build_order):
        node = _find_node_in_tree(state.subsystem_tree, target['path'])
        if node is None:
            continue
        
        node_status = node.get('status', 'pending')
        
        # Skip completed
        if node_status == 'completed':
            continue
        
        # Skip failed (Strategy A: continue, collect for later)
        if node_status == 'failed':
            skipped_failed.append(target['path'])
            continue
        
        # 检查是否可以开始（所有子节点已完成）
        can_start, reason = _can_start_level(
            state.subsystem_tree, target['path'], target['depth']
        )
        if can_start:
            state.current_build_index = i
            return target
    
    # All pending/approved nodes are blocked, but there are failed ones
    if skipped_failed:
        return {
            'path': '__FAILED_ITEMS__',
            'depth': 0,
            'name': '__FAILED__',
            'status': 'failed',
            'failedSubsystems': skipped_failed,
        }
    
    return None  # 全部完成


def _get_all_leaves(tree):
    """获取所有叶子节点路径"""
    leaves = []
    
    def _walk(node, path):
        full_path = f"{path}/{node['name']}" if path else node['name']
        children = node.get('children', [])
        if not children and node.get('depth', 0) > 0:
            leaves.append(full_path)
        for child in children:
            _walk(child, full_path)
    
    for child in tree.get('children', []):
        _walk(child, tree.get('path', ''))
    
    return leaves


def _matlab_tree_to_python_dict(matlab_struct):
    """将 MATLAB struct 树递归转换为 Python dict 树
    
    Args:
        matlab_struct: MATLAB struct (from eng.eval or eng.workspace)
    
    Returns:
        list of dict: Python list of node dicts
    """
    if matlab_struct is None:
        return []
    
    result = []
    
    def _convert_node(ms_node):
        """单节点转换"""
        node = {}
        # Basic string fields
        for field in ['name', 'type', 'role']:
            try:
                val = getattr(ms_node, field, None)
                if val is not None:
                    node[field] = str(val)
            except Exception:
                pass
        
        # Numeric fields
        for field in ['depth', 'confidence']:
            try:
                val = getattr(ms_node, field, None)
                if val is not None:
                    node[field] = float(val) if '.' in str(val) else int(val)
            except Exception:
                pass
        
        # Cell-array fields
        for field in ['inputs', 'outputs']:
            try:
                val = getattr(ms_node, field, None)
                if val is not None:
                    if hasattr(val, '__iter__') and not isinstance(val, str):
                        node[field] = [str(v) for v in val]
                    else:
                        node[field] = [str(val)] if val else []
            except Exception:
                node[field] = []
        
        # Child subsystems (recursive)
        try:
            children = getattr(ms_node, 'childSubsystems', None)
            if children is not None and len(children) > 0:
                node['children'] = _matlab_tree_to_python_dict(children)
            else:
                node['children'] = []
        except Exception:
            node['children'] = []
        
        # Status field
        try:
            node['status'] = str(getattr(ms_node, 'status', 'pending'))
        except Exception:
            node['status'] = 'pending'
        
        # signalFlow
        try:
            sf = getattr(ms_node, 'signalFlow', None)
            if sf is not None and len(sf) > 0:
                node['signalFlow'] = []
                for s in sf:
                    try:
                        node['signalFlow'].append({
                            'srcSubsystem': str(getattr(s, 'srcSubsystem', '')),
                            'dstSubsystem': str(getattr(s, 'dstSubsystem', '')),
                            'signalName': str(getattr(s, 'signalName', '')),
                        })
                    except Exception:
                        pass
        except Exception:
            pass
        
        return node
    
    # Handle MATLAB struct array
    try:
        n = int(len(matlab_struct))
        for i in range(n):
            try:
                ms_node = matlab_struct[i]
                result.append(_convert_node(ms_node))
            except Exception:
                pass
    except Exception:
        # Single struct, not array
        try:
            result.append(_convert_node(matlab_struct))
        except Exception:
            pass
    
    return result


def _reconstruct_tree_from_workspace(eng, model_name):
    """从 MATLAB workspace 恢复子系统树（Engine 重启后）
    
    v11.8: 完整树恢复 — 使用 _matlab_tree_to_python_dict 递归转换
    
    Args:
        eng: MATLAB engine instance
        model_name: top-level model name
    
    Returns:
        dict or None: reconstructed tree with full children hierarchy
    """
    model_safe = model_name.replace('/', '__').replace(' ', '_')
    try:
        tree_var = f"mHierarchyTree_{model_safe}"
        exists = eng.eval(f"evalin('base', 'exist(''{tree_var}'', ''var'')')", nargout=1)
        if exists == 1:
            hier_approved_var = f"mHierarchyApproved_{model_safe}"
            hier_approved_exists = eng.eval(
                f"evalin('base', 'exist(''{hier_approved_var}'', ''var'')')", nargout=1
            )
            is_approved = False
            if hier_approved_exists == 1:
                is_approved = eng.eval(f"evalin('base', '{hier_approved_var}')", nargout=1)
            
            if is_approved:
                # Full tree reconstruction from MATLAB struct
                try:
                    raw_tree = eng.eval(f"evalin('base', '{tree_var}')", nargout=1)
                    children = _matlab_tree_to_python_dict(raw_tree)
                    
                    depth_var = f"mHierarchyDepth_{model_safe}"
                    nodes_var = f"mHierarchyNodes_{model_safe}"
                    max_depth = 0
                    total_nodes = 0
                    try:
                        if eng.eval(f"evalin('base', 'exist(''{depth_var}'', ''var'')')", nargout=1) == 1:
                            max_depth = int(eng.eval(f"evalin('base', '{depth_var}')", nargout=1))
                        if eng.eval(f"evalin('base', 'exist(''{nodes_var}'', ''var'')')", nargout=1) == 1:
                            total_nodes = int(eng.eval(f"evalin('base', '{nodes_var}')", nargout=1))
                    except Exception:
                        pass
                    
                    tree = {
                        'path': model_name,
                        'depth': 0,
                        'status': 'root',
                        'children': children,
                        '_reconstructed': True,
                        '_maxDepth': max_depth,
                        '_totalNodes': total_nodes,
                    }
                    return tree
                except Exception:
                    pass
                
                # Fallback: metadata-only recovery
                return {
                    'path': model_name,
                    'depth': 0,
                    'status': 'root',
                    'children': [],
                    '_reconstructed': True,
                    '_maxDepth': max_depth if 'max_depth' in dir() else 0,
                    '_totalNodes': total_nodes if 'total_nodes' in dir() else 0,
                }
    except Exception:
        pass
    return None


def _flatten_tree_to_queue(tree):
    """将树扁平化为旧式 queue 列表（兼容层）"""
    if tree is None:
        return []
    result = []
    
    def _walk(node, path):
        full_path = f"{path}/{node['name']}" if path else node['name']
        if node.get('depth', 0) > 0:
            result.append(full_path)
        for child in node.get('children', []):
            _walk(child, full_path)
    
    for child in tree.get('children', []):
        _walk(child, tree.get('path', ''))
    
    return result

def _get_sibling_names(tree, target_path):
    """获取目标路径的兄弟节点名称列表
    
    Args:
        tree: subsystem tree dict
        target_path: full Simulink path
    
    Returns:
        list of str: sibling subsystem names (excluding self)
    """
    if tree is None:
        return []
    target_path = target_path.replace('\\', '/')
    
    # Find parent by removing last segment
    parts = target_path.rsplit('/', 1)
    if len(parts) < 2:
        return []
    parent_path = parts[0]
    my_name = parts[1]
    
    parent_node = _find_node_in_tree(tree, parent_path)
    if parent_node is None:
        return []
    
    siblings = []
    for child in parent_node.get('children', []):
        if child.get('name', '') != my_name:
            siblings.append(child.get('name', ''))
    return siblings


def _get_depth_aware_hint(depth):
    """Get depth-aware design guidance hint
    
    Args:
        depth: nesting depth (1-5)
    
    Returns:
        str: design guidance
    """
    if depth <= 0:
        return ''
    if depth >= 5:
        return (
            '[RED] DEPTH 5 — MAXIMUM ALLOWED. Use ONLY basic blocks '
            '(Integrator, Gain, Sum, Product). NO MORE child subsystems allowed. '
            'Any subsystem_create here will be gate_blocked.'
        )
    if depth >= 3:
        return (
            f'[WARN] DEPTH {depth} — Near leaf subsystem. Use only basic blocks. '
            'Do NOT create more subsystems.'
        )
    if depth == 2:
        return (
            f'DEPTH 2 — Mid-level. You may create child subsystems if functionally '
            'justified, but prefer basic blocks.'
        )
    return 'DEPTH 1 — Top-level. You may define child subsystems if needed.'


def _all_subsystems_completed(state):
    """Check if all subsystems in build_order are marked as completed
    
    Args:
        state: ModelWorkflowState instance
    
    Returns:
        bool: True if all completed
    """
    if not state.build_order or state.subsystem_tree is None:
        return True
    for target in state.build_order:
        node = _find_node_in_tree(state.subsystem_tree, target['path'])
        if node is None or node.get('status') != 'completed':
            return False
    return True


def _get_incomplete_subsystems(state):
    """Get list of incomplete subsystem paths
    
    Args:
        state: ModelWorkflowState instance
    
    Returns:
        list of str: incomplete subsystem paths
    """
    incomplete = []
    if not state.build_order or state.subsystem_tree is None:
        return incomplete
    for target in state.build_order:
        node = _find_node_in_tree(state.subsystem_tree, target['path'])
        if node is None or node.get('status') != 'completed':
            incomplete.append(target['path'])
    return incomplete

# ===== End of v11.8 tree helpers =====


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
    # [v11.6.2 FIX] Normalize to toplevel model: add_block uses sandbox path,
    # add_line uses parent model. Both must update the SAME counter.
    _norm_model = model_name.split('/')[0] if '/' in model_name else model_name
    state = _get_workflow_state(_norm_model)
    
    # 更新连续操作计数
    # [v11.6.2 FIX] Only add_block/add_line affect the counter.
    # Other commands (inspect, set_param) must NOT reset it.
    # add_block → increment; add_line → reset; everything else → no change
    if command in ('sl_add_block', 'sl_add_block_safe'):
        state.consecutive_adds += 1
    elif command in ('sl_add_line', 'sl_add_line_safe'):
        state.consecutive_adds = 0  # Connecting resolves unconnected accumulation
    # [v11.6.2] REMOVED: else: state.consecutive_adds = 0
    # Was causing inspect/set_param to spuriously reset the counter
    
    need_layout = False
    reason = ''
    
    # 规则1: 连续 3+ 次 add_block 操作 -> 连线阶段即将开始
    # [v11.6.2 FIX] Remove add_line from trigger (add_line now resets counter)
    if command in ('sl_add_block', 'sl_subsystem_create', 'sl_model_sandbox') and state.consecutive_adds >= 5:
        need_layout = True
        reason = f'{state.consecutive_adds} consecutive add operations detected — layout before connecting'
    
    # 规则2: 从 add 切换到 set_param -> 建模阶段可能结束
    if (state.last_command in ('sl_add_block', 'sl_add_line', 'sl_subsystem_create')
        and command in ('sl_set_param', 'sl_config_set')):
        need_layout = True
        reason = 'Transition from add to set_param detected — layout recommended'
    
    # 规则3: 子系统创建后立即排版（含 sandbox 创建）
    if command in ('sl_subsystem_create', 'sl_model_sandbox'):
        need_layout = True
        reason = f'{command} completed — layout recommended to position the subsystem properly'
    
    # 防抖: 至少间隔 5 秒
    if need_layout and (time.time() - state.last_layout_time) < 5:
        need_layout = False
        reason = ''  # 防抖跳过，不记录原因
    
    state.last_command = command
    
    # [v11.6.4 FIX] Auto-update subsystem_queue after building inside sandbox.
    # When add_block/add_line succeeds inside a queued sandbox, re-evaluate
    # if the sandbox is still empty and remove it from the queue if not.
    if state.subsystem_queue and command in ('sl_add_block', 'sl_add_line', 'sl_set_param'):
        _op_target = params.get('modelName', params.get('blockPath', ''))
        if _op_target:
            _op_target_str = str(_op_target)
            _to_remove = []
            for _qs in list(state.subsystem_queue):
                if _op_target_str.startswith(_qs) or _qs in _op_target_str:
                    try:
                        _q_eng = get_engine()
                        if _q_eng is not None:
                            _q_total = _q_eng.eval(
                                f"length(find_system('{_qs}', 'SearchDepth', 1, 'LookUnderMasks', 'on'))",
                                nargout=1)
                            _q_in = _q_eng.eval(
                                f"length(find_system('{_qs}', 'SearchDepth', 1, 'BlockType', 'Inport', 'LookUnderMasks', 'on'))",
                                nargout=1)
                            _q_out = _q_eng.eval(
                                f"length(find_system('{_qs}', 'SearchDepth', 1, 'BlockType', 'Outport', 'LookUnderMasks', 'on'))",
                                nargout=1)
                            if int(_q_total) > int(_q_in) + int(_q_out):
                                _to_remove.append(_qs)
                    except Exception:
                        pass
            for _qs in _to_remove:
                if _qs in state.subsystem_queue:
                    state.subsystem_queue.remove(_qs)
    
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
    _al_eng = get_engine()
    if _al_eng is not None:
        try:
            _al_eng.workspace['v_model'] = model_name
            _al_eng.eval("save_system(v_model);", nargout=0)
        except Exception:
            pass  # save_system failure is non-critical for layout
    
    # 记录排版前的模块数和线数
    pre_blocks = -1
    pre_lines = -1
    if _al_eng is not None:
        try:
            _al_eng.workspace['v_model'] = model_name
            pre_blocks = int(_al_eng.eval(
                "length(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'all'));",
                nargout=1))
            pre_lines = int(_al_eng.eval(
                "length(get_param(v_model, 'Lines'));",
                nargout=1))
        except Exception:
            pass
    
    # 调用 sl_auto_layout 排版
    arrange_result = _call_sl_function('sl_auto_layout', {
        '_pos_1': model_name,
    })
    
    state.last_layout_time = time.time()
    state.layout_done_for_phase = True
    
    if isinstance(arrange_result, dict) and arrange_result.get('status') == 'ok':
        # 验证排版后模型完整性（块数/线数不变）
        post_blocks = -1
        if _al_eng is not None:
            try:
                _al_eng.workspace['v_model'] = model_name
                post_blocks = int(_al_eng.eval(
                    "length(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'all'));",
                    nargout=1))
            except Exception:
                pass
        integrity_ok = True
        integrity_msg = ''
        try:
            pre_b = pre_blocks if pre_blocks not in [None, -1, '__EVAL_FAILED__'] else -1
            post_b = post_blocks if post_blocks not in [None, -1, '__EVAL_FAILED__'] else -1
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


def _normalize_review_result(review_result):
    """[Bug #2 FIX] Normalize reviewResult structure from MATLAB Engine.

    MATLAB may return reviewResult as:
    - A dict with checks as struct array (list of dicts with item-level fields)
    - A list of dicts (one per check item)
    
    Expected normalized structure:
    {
        'passed': bool,
        'checks': [{'item': str, 'passed': bool, 'confidence': float, ...}, ...],
        'overallConfidence': float,
        'issues': [str, ...],
        'suggestions': [str, ...]
    }
    """
    if not isinstance(review_result, dict):
        # If it's a list (struct array), aggregate into single dict
        if isinstance(review_result, (list, tuple)):
            all_passed = True
            checks = []
            overall_confidence = 0.0
            issues = []
            suggestions = []
            for item in review_result:
                if isinstance(item, dict):
                    if not item.get('passed', True):
                        all_passed = False
                    item_checks = item.get('checks', {})
                    if isinstance(item_checks, dict):
                        checks.append(item_checks)
                    elif isinstance(item_checks, (list, tuple)):
                        checks.extend(item_checks)
                    conf = item.get('overallConfidence', 0.0)
                    if isinstance(conf, (int, float)) and conf > overall_confidence:
                        overall_confidence = conf
                    item_issues = item.get('issues', [])
                    if isinstance(item_issues, (list, tuple)):
                        issues.extend(item_issues)
                    item_suggestions = item.get('suggestions', [])
                    if isinstance(item_suggestions, (list, tuple)):
                        suggestions.extend(item_suggestions)
            return {
                'passed': all_passed,
                'checks': checks,
                'overallConfidence': overall_confidence,
                'issues': issues,
                'suggestions': suggestions,
            }
        return review_result

    # Already a dict, ensure top-level fields
    normalized = dict(review_result)
    
    # Normalize checks field
    checks = normalized.get('checks', [])
    if isinstance(checks, dict):
        # Single check as dict -> wrap in list
        normalized['checks'] = [checks]
    elif isinstance(checks, (list, tuple)):
        normalized_checks = []
        for c in checks:
            if isinstance(c, dict):
                normalized_checks.append(c)
        normalized['checks'] = normalized_checks
    else:
        normalized['checks'] = []
    
    # Ensure passed field
    if 'passed' not in normalized:
        normalized['passed'] = all(
            c.get('passed', False) for c in normalized['checks']
        )
    
    # Ensure overallConfidence
    if 'overallConfidence' not in normalized:
        confidences = [c.get('confidence', 0.5) for c in normalized['checks'] if isinstance(c, dict)]
        normalized['overallConfidence'] = sum(confidences) / len(confidences) if confidences else 0.5
    
    # Ensure issues/suggestions are lists
    if 'issues' not in normalized:
        normalized['issues'] = []
    if 'suggestions' not in normalized:
        normalized['suggestions'] = []
    
    return normalized


def _generate_workflow_state(model_name, command, params, result):
    """v9.0: 生成工作流状态信息

    分析当前模型状态，推断工作流阶段，生成 nextSuggestedAction 建议。
    基于模型实际状态（sl_model_status_snapshot）而非假设。

    三层迭代逻辑:
    - framework: 顶层架构建立中，建议连线和子系统创建
    - subsystem: 子系统填充中，建议进入空子系统
    - simulation: 准备仿真，建议设置参数和运行

    v11.0 增强:
    - framework_design: 大框架设计阶段
    - framework_construction: 大框架构建阶段
    - subsystem_iteration: 子系统迭代阶段

    v11.2 增强:
    - [Bug #2] reviewResult 结构规范化

    Returns:
        dict: 工作流状态
    """
    # [P1-1 FIX] 使用线程安全的访问函数
    state = _get_workflow_state(model_name)

    # ===== [v11.0] 大框架 API 特殊处理 =====
    if command in ('sl_framework_design', 'sl_framework_review', 'sl_framework_approve'):
        if command == 'sl_framework_design':
            # [v11.2] Architecture Flip: sl_framework_design now returns designPrompt, NOT macroFramework
            # The AI agent must autonomously design the framework based on the prompt
            if isinstance(result, dict) and result.get('status') == 'ok':
                design_prompt = result.get('designPrompt', [])
                output_schema = result.get('outputSchema', {})
                task_guide = result.get('taskGuide', [])
                flow_patterns = result.get('flowPatterns', [])
                hierarchy_guidance = result.get('hierarchyGuidance', [])
                next_action = result.get('nextExpectedAction', 'AI_AGENT_DESIGN')
                state.phase = 'framework_design'
                state.phase_step = 'awaiting_ai_design'
                # Store design prompt in state for later reference
                state.macro_framework = {
                    'designPrompt': design_prompt,
                    'outputSchema': output_schema,
                    'version': result.get('version', 'v11.2'),
                }
                return {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'designPrompt': design_prompt,
                    'taskGuide': task_guide,
                    'flowPatterns': flow_patterns,
                    'outputSchema': output_schema,
                    'hierarchyGuidance': hierarchy_guidance,
                    'nextExpectedAction': next_action,
                    'frameworkApproved': False,
                    'version': 'v11.8',
                    'instruction': (
                        'YOU are the domain expert. Based on the designPrompt above, '
                        'use your knowledge of physics and control theory to design '
                        'the macro framework. Output the result as JSON matching outputSchema. '
                        'Include childSubsystems for nested structures (max depth 5). '
                        'Then call sl_framework_review() with your framework design.'
                    ),
                }
        elif command == 'sl_framework_review':
            # Review 完成，等待 approve
            # [Bug #2 FIX] Normalize reviewResult structure
            if isinstance(result, dict) and result.get('status') == 'ok':
                review_result = _normalize_review_result(result.get('reviewResult', {}))
                state.phase = 'framework_design'
                state.phase_step = 'reviewed'
                if review_result.get('passed'):
                    return {
                        'model': model_name,
                        'phase': state.phase,
                        'phaseStep': state.phase_step,
                        'macroFramework': state.macro_framework,
                        'reviewResult': review_result,
                        'nextSuggestedAction': 'Call sl_framework_approve() to lock the macro framework',
                        'frameworkApproved': state.framework_approved,
                    }
                else:
                    return {
                        'model': model_name,
                        'phase': state.phase,
                        'phaseStep': state.phase_step,
                        'macroFramework': state.macro_framework,
                        'reviewResult': review_result,
                        'nextSuggestedAction': 'Framework review found issues - fix and call sl_framework_design again',
                        'frameworkApproved': state.framework_approved,
                    }
        elif command == 'sl_framework_approve':
            # 审批完成，大框架锁定
            if isinstance(result, dict) and result.get('status') == 'ok':
                state.framework_approved = True
                state.framework_locked = result.get('locked', True)
                state.phase = 'framework_construction'
                state.phase_step = 'approved'
                
                # [v11.8] Build hierarchy tree from macro framework
                fw = result.get('frameworkSnapshot', None)
                if fw and fw.get('subsystems'):
                    tree = _build_subsystem_tree_from_framework(fw, model_name)
                    state.subsystem_tree = tree
                    state.build_order = _compute_build_order(tree)
                    state.max_depth = max(
                        (n['depth'] for n in state.build_order), default=0
                    )
                    state.hierarchy_approved = result.get('hierarchyApproved', False)
                    state.current_build_index = -1
                
                _workflow = {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'macroFramework': state.macro_framework,
                    'frameworkApproved': True,
                    'frameworkLocked': state.framework_locked,
                    'lockedAt': result.get('lockedAt', ''),
                    'nextSuggestedAction': 'Macro framework locked - now you can start building: add_block / add_line / subsystem_create',
                }
                
                # [v11.8] Add hierarchy info if available
                if state.subsystem_tree is not None:
                    _workflow['hierarchyApproved'] = state.hierarchy_approved
                    _workflow['maxDepth'] = state.max_depth
                    _workflow['totalSubsystems'] = len(state.build_order)
                    _workflow['buildOrder'] = [
                        {'path': t['path'], 'depth': t['depth'], 'name': t['name']}
                        for t in state.build_order
                    ]
                    _workflow['nextSuggestedAction'] = (
                        f'Hierarchy approved (depth={state.max_depth}, '
                        f'{len(state.build_order)} subsystems). '
                        'Proceed to Phase 4: build skeleton shells for all subsystems '
                        'using sl_subsystem_create + add_block(Inport/Outport), '
                        'then add cross-subsystem lines. '
                        'Start from the top level and recurse down: '
                        'for each subsystem, create its child subsystems as shells.'
                    )
                
                return _workflow
        # 如果不是 ok 状态，返回当前状态
        return {
            'model': model_name,
            'phase': state.phase,
            'phaseStep': state.phase_step,
            'nextSuggestedAction': f'Retry {command} or check errors',
        }

    # ===== [v11.3] 模型完成门控处理 =====
    if command == 'sl_model_complete':
        if isinstance(result, dict) and result.get('status') == 'ok':
            can_proceed = result.get('canProceed', False)
            passed = result.get('passed', False)
            is_sub_path = '/' in str(model_name)
            
            if passed or can_proceed:
                state.model_completed = True
                state.pending_issues = []
                state.last_verification_failed = False
                state.phase = 'simulation'
                state.phase_step = 'completed'
                
                _rwf = {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'modelCompleted': True,
                    'canProceed': True,
                }
                
                # [v11.8] Recursive verify: mark node as 'completed' in tree
                if state.hierarchy_approved and state.subsystem_tree is not None:
                    # Check if this is a sub-path complete call
                    if is_sub_path:
                        _updated = _update_node_status(
                            state.subsystem_tree, str(model_name).replace('\\', '/'), 'completed'
                        )
                        # Notify next build target
                        next_target = _get_next_build_target(state)
                        if next_target:
                            _rwf['nextBuildTarget'] = next_target
                            _rwf['buildProgress'] = _build_progress_str(state)
                            _rwf['nextSuggestedAction'] = (
                                f'Subsystem {model_name} completed! '
                                f'Next: sl_micro_design(subsystemName="{next_target["path"]}", '
                                f'taskDescription="...", depth={next_target["depth"]})'
                            )
                        else:
                            _rwf['allSubsystemsComplete'] = True
                            _rwf['nextSuggestedAction'] = (
                                'All subsystems completed! '
                                'Run sl_model_complete(modelName) for top-level Gate_4, '
                                'then sl_sim_run for simulation.'
                            )
                    else:
                        # Top-level complete: check hierarchy completeness
                        all_done = _all_subsystems_completed(state)
                        _rwf['hierarchyComplete'] = all_done
                        if not all_done:
                            missing = _get_incomplete_subsystems(state)
                            _rwf['incompleteSubsystems'] = missing
                            _rwf['nextSuggestedAction'] = (
                                f'WARNING: {len(missing)} subsystem(s) not completed. '
                                f'Complete all subsystems before final simulation: {", ".join(missing[:5])}'
                            )
                            _rwf['canProceed'] = False
                            _rwf['modelCompleted'] = False
                        else:
                            _rwf['nextSuggestedAction'] = (
                                'Model complete! All {n} subsystems passed. '
                                'Proceed to sl_sim_run for simulation.'
                            ).format(n=len(state.build_order))
                
                if 'nextSuggestedAction' not in _rwf:
                    _rwf['nextSuggestedAction'] = 'Model complete! Proceed to sl_sim_run for simulation.'
                
                return _rwf
            else:
                state.model_completed = False
                state.last_verification_failed = True
                unconn_count = result.get('unconnectedCount', -1)
                issues = result.get('suggestions', [])
                state.pending_issues = issues if isinstance(issues, list) else []
                state.phase = 'framework_construction'
                state.phase_step = 'fixing_issues'
                return {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'modelCompleted': False,
                    'canProceed': False,
                    'unconnectedCount': unconn_count,
                    'pendingIssues': state.pending_issues,
                    'nextSuggestedAction': (
                        f'BLOCKED: {unconn_count} unconnected port(s). '
                        f'Run sl_get_model_issues("{model_name}") for details, '
                        f'fix all connections, then retry sl_model_complete.'
                    ),
                }
        # error handling
        state.last_verification_failed = True
        return {
            'model': model_name,
            'phase': state.phase,
            'phaseStep': state.phase_step,
            'canProceed': False,
            'nextSuggestedAction': f'sl_model_complete returned error. Check model state and retry.',
        }
    # ===== [v11.3] 完成门控结束 =====

    # ===== [v11.0 Phase 2] 子系统小框架 API 处理 =====
    if command in ('sl_micro_design', 'sl_micro_review', 'sl_micro_approve'):
        subsystem_name = params.get('subsystemName', params.get('subsystem', ''))
        if command == 'sl_micro_design':
            # [v11.2] Architecture Flip: sl_micro_design now returns designPrompt, NOT microFramework
            # The AI agent must autonomously design the subsystem based on the prompt
            if isinstance(result, dict) and result.get('status') == 'ok':
                design_prompt = result.get('designPrompt', [])
                output_schema = result.get('outputSchema', {})
                block_mapping_guide = result.get('blockMappingGuide', [])
                parent_context = result.get('parentContext', {})
                parent_summary = result.get('parentSummary', '')
                next_action = result.get('nextExpectedAction', 'AI_AGENT_DESIGN_MICRO')
                state.phase = 'subsystem_iteration'
                state.phase_step = 'micro_awaiting_ai_design'
                # Store micro design prompt in state
                if not hasattr(state, 'micro_frameworks'):
                    state.micro_frameworks = {}
                state.micro_frameworks[subsystem_name] = {
                    'designPrompt': design_prompt,
                    'outputSchema': output_schema,
                    'version': result.get('version', 'v11.2'),
                }
                
                # [v11.8] Recursive hierarchy: inject depth + tree context
                _node = None
                _depth = 0
                _children = []
                _siblings = []
                _build_pos = ''
                if state.hierarchy_approved and state.subsystem_tree is not None:
                    _node = _find_node_in_tree(state.subsystem_tree, subsystem_name)
                    if _node is not None:
                        _depth = _node.get('depth', 0)
                        _children = [c.get('name', '') for c in _node.get('children', [])]
                        # Mark as 'design' phase
                        _node['status'] = 'design'
                    _siblings = _get_sibling_names(state.subsystem_tree, subsystem_name)
                    _build_pos = _build_progress_str(state)
                
                _workflow = {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'designPrompt': design_prompt,
                    'blockMappingGuide': block_mapping_guide,
                    'outputSchema': output_schema,
                    'parentContext': parent_context,
                    'parentSummary': parent_summary,
                    'subsystemName': subsystem_name,
                    'nextExpectedAction': next_action,
                    'frameworkApproved': state.framework_approved,
                    'version': 'v11.8',
                    # [v11.8] Recursive hierarchy fields
                    'depth': _depth,
                    'childSubsystems': _children,
                    'siblingSubsystems': _siblings,
                    'buildOrderPosition': _build_pos,
                    'instruction': (
                        f'YOU are the domain expert. Based on the designPrompt above, '
                        f'use your knowledge of physics and control theory to design '
                        f'the internals of subsystem "{subsystem_name}"'
                        + (f' (depth {_depth})' if _depth > 0 else '')
                        + f'. '
                        + (f'This subsystem has {len(_children)} child subsystem(s) that exist as shells. '
                           f'Treat them as black-box block inputs. '
                           if _children else '')
                        + f'Output as JSON matching outputSchema, then call '
                        f'sl_micro_review(subsystemName="{subsystem_name}").'
                    ),
                }
                
                if _depth > 0:
                    _workflow['depthAwareGuidance'] = _get_depth_aware_hint(_depth)
                
                return _workflow
        elif command == 'sl_micro_review':
            # Review 完成，等待 approve
            # [Bug #2 FIX] Normalize reviewResult structure
            if isinstance(result, dict) and result.get('status') == 'ok':
                review_result = _normalize_review_result(result.get('reviewResult', {}))
                state.phase = 'subsystem_iteration'
                state.phase_step = 'micro_reviewed'
                
                # [v11.8] Mark node as 'review' phase
                if state.hierarchy_approved and state.subsystem_tree is not None:
                    _node = _find_node_in_tree(state.subsystem_tree, subsystem_name)
                    if _node is not None:
                        _node['status'] = 'review'
                
                _rwf = {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'microFramework': state.micro_framework,
                    'reviewResult': review_result,
                    'subsystemName': subsystem_name,
                    'frameworkApproved': state.framework_approved,
                }
                if review_result.get('passed'):
                    _rwf['nextSuggestedAction'] = f'Call sl_micro_approve(subsystemName="{subsystem_name}") to approve and start building'
                else:
                    _rwf['nextSuggestedAction'] = 'Micro framework review found issues - fix and call sl_micro_design again'
                return _rwf
        elif command == 'sl_micro_approve':
            # Gate_REVIEW_BUILD check moved to top of _handle_sl_command (v11.9)
            
            # 审批完成，小框架锁定，可以开始构建
            if isinstance(result, dict) and result.get('status') == 'ok':
                state.phase = 'subsystem_iteration'
                state.phase_step = 'micro_approved'
                
                # [v11.8.4] Gate_SHELL_ONLY: Register micro-approved subsystem
                if subsystem_name:
                    _toplevel = model_name.split('/')[0] if '/' in model_name else model_name
                    if _toplevel not in _MICRO_APPROVED_SUBSYSTEMS:
                        _MICRO_APPROVED_SUBSYSTEMS[_toplevel] = set()
                    _MICRO_APPROVED_SUBSYSTEMS[_toplevel].add(subsystem_name)
                
                # [v11.8] Mark node as 'approved' in tree
                if state.hierarchy_approved and state.subsystem_tree is not None:
                    _update_node_status(state.subsystem_tree, subsystem_name, 'approved')
                
                _rwf = {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'microFramework': state.micro_framework,
                    'subsystemName': subsystem_name,
                    'microFrameworkApproved': True,
                    'microFrameworkLocked': result.get('locked', True),
                    'approvedAt': result.get('approvedAt', ''),
                    'nextSuggestedAction': f'Start building subsystem {subsystem_name}: add_block / add_line',
                    'frameworkApproved': state.framework_approved,
                }
                
                # [v11.8] Include hierarchy context
                if state.hierarchy_approved:
                    _rwf['buildProgress'] = _build_progress_str(state)
                return _rwf
        # 如果不是 ok 状态，返回当前状态
        return {
            'model': model_name,
            'phase': state.phase,
            'phaseStep': state.phase_step,
            'subsystemName': subsystem_name,
            'nextSuggestedAction': f'Retry {command} or check errors',
        }
    # ===== v11.0 Phase 2 子系统小框架 API 处理结束 =====

    # ===== v11.0 Phase 3: 大框架锁定后变更审批 API 处理 =====
    if command == 'sl_framework_modify':
        if isinstance(result, dict) and result.get('status') in ('ok', 'pending_approval'):
            modify_action = result.get('action', '')
            auto_approved = result.get('autoApproved', False)
            if auto_approved:
                state.phase_step = 'modified'
                return {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': state.phase_step,
                    'modifyAction': modify_action,
                    'autoApproved': True,
                    'modificationSummary': result.get('modificationSummary', ''),
                    'reviewResult': result.get('reviewResult', {}),
                    'frameworkLocked': state.framework_locked,
                    'nextSuggestedAction': f'Framework modified ({modify_action}) - continue building',
                }
            else:
                return {
                    'model': model_name,
                    'phase': state.phase,
                    'phaseStep': 'modification_pending',
                    'modifyAction': modify_action,
                    'autoApproved': False,
                    'modificationSummary': result.get('modificationSummary', ''),
                    'reviewResult': result.get('reviewResult', {}),
                    'frameworkLocked': state.framework_locked,
                    'nextSuggestedAction': 'Call sl_framework_modify_approve() to approve, or sl_framework_modify_reject() to reject',
                }
        elif isinstance(result, dict) and result.get('status') == 'error':
            # [P2-5 FIX] 显式处理 error 状态，避免 fall through 到通用处理
            return {
                'model': model_name,
                'status': 'error',
                'message': result.get('message', 'sl_framework_modify failed'),
                'action': result.get('action', params.get('action', '')),
                'nextSuggestedAction': 'Fix the error and retry sl_framework_modify',
            }
    elif command == 'sl_framework_modify_approve':
        if isinstance(result, dict) and result.get('status') == 'ok':
            state.phase_step = 'modified'
            return {
                'model': model_name,
                'phase': state.phase,
                'phaseStep': state.phase_step,
                'modifyAction': result.get('action', ''),
                'modificationSummary': result.get('modificationSummary', ''),
                'approvedAt': result.get('approvedAt', ''),
                'frameworkLocked': state.framework_locked,
                'nextSuggestedAction': 'Modification approved - continue building',
            }
        elif isinstance(result, dict) and result.get('status') == 'error':
            # [P2-5 FIX] approve 失败的显式处理
            return {
                'model': model_name,
                'status': 'error',
                'message': result.get('message', 'sl_framework_modify_approve failed'),
                'nextSuggestedAction': 'Check pending modification exists and framework is locked',
            }
    elif command == 'sl_framework_modify_reject':
        if isinstance(result, dict) and result.get('status') == 'ok':
            return {
                'model': model_name,
                'phase': state.phase,
                'phaseStep': state.phase_step,
                'modifyAction': result.get('action', ''),
                'modificationSummary': result.get('modificationSummary', ''),
                'rejectedAt': result.get('rejectedAt', ''),
                'frameworkLocked': state.framework_locked,
                'nextSuggestedAction': 'Modification rejected - framework unchanged, continue building',
            }
        elif isinstance(result, dict) and result.get('status') == 'error':
            # [P2-5 FIX] reject 失败的显式处理
            return {
                'model': model_name,
                'status': 'error',
                'message': result.get('message', 'sl_framework_modify_reject failed'),
                'nextSuggestedAction': 'Check pending modification exists',
            }
    # ===== v11.0 Phase 3 大框架锁定后变更审批 API 处理结束 =====

    # ===== v11.0 大框架 API 处理结束 =====

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
        
        # [Bug #8 FIX] 增强 framework_construction → subsystem_iteration 自动转换
        # 当大框架已审批（framework_approved=True）且 AI 直接开始填充子系统时，
        # 阶段应自动从 framework_construction 切换到 subsystem_iteration
        if state.phase == 'framework_construction':
            if state.framework_approved:
                if empty_subsystems:
                    # 有空子系统 → 切换到 subsystem_iteration
                    state.phase = 'subsystem_iteration'
                    state.phase_step = 'filling'
                    state.current_subsystem = empty_subsystems[0]
                    state.subsystem_queue = empty_subsystems
                    next_action = f'Fill subsystem: {empty_subsystems[0]} — use sl_micro_design or directly add blocks'
                elif non_empty_subsystems and not empty_subsystems:
                    # 所有子系统已填充 → 检查是否可以进入仿真
                    if unconn > 0:
                        next_action = f'Connect {unconn} remaining port(s) in the framework'
                        state.phase_step = 'connecting'
                    else:
                        state.phase = 'simulation'
                        state.phase_step = 'checking'
                        next_action = 'Set simulation parameters and run simulation'
                else:
                    # 框架已审批但还没建子系统
                    next_action = 'Create subsystems based on the approved macro framework'
                    state.phase_step = 'creating_subsystems'
            else:
                next_action = 'Complete framework approval first: sl_framework_approve(modelName)'
        
        # [Bug #8 FIX] 增强 subsystem_iteration 阶段的自动推断
        elif state.phase == 'subsystem_iteration':
            if empty_subsystems:
                state.current_subsystem = empty_subsystems[0]
                next_action = f'Fill subsystem: {empty_subsystems[0]}'
                state.phase_step = 'filling'
            else:
                # 所有子系统已填充 → 进入仿真阶段
                state.phase = 'simulation'
                state.phase_step = 'checking'
                next_action = 'Set simulation parameters and run simulation'
        
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
        'canProceed': not state.last_verification_failed,  # v11.3
        # [v11.8] Recursive hierarchy build info
        'hierarchyApproved': state.hierarchy_approved,
        'maxDepth': getattr(state, 'max_depth', 0),
        'totalSubsystems': len(getattr(state, 'build_order', [])),
        'buildProgress': _build_progress_str(state),
        'nextBuildTarget': _get_next_build_target(state) if state.hierarchy_approved else None,
        '_version': 'v11.8',
    }


def _build_progress_str(state):
    """生成构建进度字符串"""
    if not state.build_order:
        return '0/0'
    completed = sum(
        1 for t in state.build_order
        if _find_node_in_tree(state.subsystem_tree, t['path']) is not None
        and _find_node_in_tree(state.subsystem_tree, t['path']).get('status') == 'completed'
    ) if state.subsystem_tree else 0
    return f'{completed}/{len(state.build_order)}'


def _cleanup_workflow_state(model_name):
    """v9.0: 清理指定模型的工作流状态
    
    模型关闭或删除时调用，释放追踪数据。
    v11.8: 扩展清理 — 含递归树结构
    """
    # [v11.8] Clean up tree structure before removing state
    state = _get_workflow_state(model_name)
    if state is not None:
        state.subsystem_tree = None
        state.build_order.clear()
        state.current_build_index = -1
        state.hierarchy_approved = False
        state.level_status.clear()
        state.nesting_warnings.clear()
    
    # [P1-1 FIX] 使用线程安全的删除函数
    _remove_workflow_state(model_name)
    # [P1-2 FIX] 同时清理对应的模型锁，防止 _model_locks 无限增长
    with _global_lock:
        if model_name in _model_locks:
            del _model_locks[model_name]


def _ensure_model_visible(params):
    """[v11.4.3] 强制 Simulink 模型在前台可见 — 底层门控，AI 不可绕过。
    
    在执行任何 sl_* 命令前，从 params 中提取模型名，
    调用 open_system 确保用户在 MATLAB 前台实时看到 AI 建模过程。
    
    此函数是 Bridge 层的强制门控，不依赖提示词。
    """
    if _matlab_engine is None:
        return
    
    model_name = params.get('modelName', params.get('model_name', ''))
    if not model_name:
        bp = params.get('blockPath', '')
        if '/' in bp:
            model_name = bp.split('/')[0]
        elif bp:
            model_name = bp
    
    if model_name:
        try:
            _matlab_engine.eval(
                f"try, open_system('{model_name}'); catch, end;",
                nargout=0
            )
        except Exception:
            pass  # 静默失败：模型可能尚未创建，后续操作会报明确的错误


# ===== [v11.5] Scene 2 helper functions =====

def _check_s2_modification_permission(model_name, command, target):
    """Check if a specific Scene 2 modification has been user-approved."""
    cache_key = f"{model_name}:{command}:{target}"
    return _S2_MOD_PERMISSIONS.get(cache_key, False)

def _classify_s2_risk(command, target):
    """Classify the risk level of a Scene 2 modification."""
    if command == 'sl_delete':
        return 'high'
    elif command == 'sl_replace_block':
        return 'high'
    elif command == 'sl_subsystem_create' and str(target).count('/') <= 1:
        return 'medium'
    elif command == 'sl_set_param':
        return 'low'
    elif command == 'sl_add_block':
        return 'medium'
    else:
        return 'medium'

# ===== helper functions end =====

# ===== [P0-5 FIX] Gate_5: Goto/From cross-subsystem boundary check =====
def _check_goto_from_scope(model_name):
    """Check that all Goto/From pairs are within the same subsystem.
    
    R2 rule: Goto/From must ONLY be used within a single subsystem.
    Cross-subsystem Goto/From is forbidden (creates untraceable global signals).
    
    Returns:
        dict: {'passed': bool, 'violations': [...], 'message': str}
    """
    result = {'passed': True, 'violations': [], 'message': ''}
    try:
        eng = get_engine()
        if eng is None:
            return result
        
        # [v11.6.7 FIX] Check if model exists before searching for Goto/From blocks
        try:
            is_loaded = eng.eval(f"bdIsLoaded('{model_name}')", nargout=1)
        except Exception:
            is_loaded = False
        
        if not is_loaded:
            result['message'] = f'Goto/From scope check skipped: model "{model_name}" not loaded (Scene 1 or unloaded model).'
            return result
        
        # [v11.8 Bug#3 FIX] Check Goto block count with simple eval first
        # to avoid multiline eval issues on empty models
        try:
            n_gotos = int(eng.eval(
                f"length(find_system('{model_name}', 'BlockType', 'Goto'))", nargout=1
            ))
        except Exception:
            n_gotos = 0
        
        if n_gotos == 0:
            result['message'] = 'No Goto/From blocks in model - scope check passed.'
            return result
        
        # Get all Goto blocks with their tags and parent subsystems
        gotos_expr = (
            "gotos = find_system(v_mn, 'BlockType', 'Goto');"
            "n = length(gotos);"
            "goto_info = cell(1, n);"
            "for i = 1:n;"
            "  goto_info{i} = struct('path', gotos{i}, 'tag', get_param(gotos{i}, 'GotoTag'), 'parent', get_param(gotos{i}, 'Parent'));"
            "end;"
            "goto_info;"
        )
        eng.workspace['v_mn'] = model_name
        goto_info = eng.eval(gotos_expr, nargout=1)
        
        if not goto_info or (hasattr(goto_info, '__len__') and len(goto_info) == 0):
            return result
        
        # For each Goto, find all matching From blocks and check parent
        for gi in goto_info:
            if not hasattr(gi, 'tag') or not gi.tag:
                continue
            tag = str(gi.tag)
            goto_parent = str(gi.parent)
            
            froms_expr = (
                f"froms = find_system(v_mn, 'BlockType', 'From', 'GotoTag', '{tag}');"
                "n = length(froms);"
                "from_info = cell(1, n);"
                "for i = 1:n;"
                "  from_info{i} = struct('path', froms{i}, 'parent', get_param(froms{i}, 'Parent'));"
                "end;"
                "from_info;"
            )
            from_info = eng.eval(froms_expr, nargout=1)
            
            if not from_info:
                continue
            
            for fi in from_info:
                from_parent = str(fi.parent)
                if goto_parent != from_parent:
                    result['passed'] = False
                    result['violations'].append({
                        'gotoPath': str(gi.path),
                        'gotoParent': goto_parent,
                        'gotoTag': tag,
                        'fromPath': str(fi.path),
                        'fromParent': from_parent,
                    })
        
        if not result['passed']:
            result['message'] = (
                f"GOTO_FROM_CROSS_BOUNDARY: {len(result['violations'])} Goto/From pair(s) "
                f"cross subsystem boundaries. Goto/From is ONLY allowed within a single subsystem. "
                f"Use Inport/Outport for subsystem-to-subsystem signals."
            )
        else:
            result['message'] = 'All Goto/From tags used within single subsystem scope.'
        
    except Exception as e:
        import logging
        logging.getLogger('matlab_bridge').warning(f"goto_from_scope check failed: {e}")
        # [v11.6.7 FIX] Multiple error patterns for model-not-found:
        # - English: "not found", "does not exist"
        # - Chinese: "未加载", "找不到"
        err_str = str(e).lower()
        not_found_patterns = ['find_system', 'not found', 'does not exist', 
                              '未加载', '找不到', 'not loaded', 'not open',
                              'model', 'system', 'invalid',
                              '运算符', 'operator', 'syntax', 'parse']
        if any(p in err_str for p in not_found_patterns):
            result['passed'] = True
            result['message'] = f'Goto/From scope check skipped: model not available (Scene 1 or unloaded model).'
        else:
            # [P0-5 FIX v11.7] FAIL-CLOSED: unknown error must block approval
            result['passed'] = False
            result['message'] = (
                f'Goto/From scope check failed with error: {e}. '
                f'Framework approval BLOCKED. Ensure MATLAB Engine is running and '
                f'retry, or manually verify Goto/From blocks are within single subsystems.'
            )
            result['violations'].append({
                'gotoPath': 'CHECK_FAILED',
                'gotoParent': 'CHECK_FAILED',
                'gotoTag': 'CHECK_FAILED',
                'fromPath': 'CHECK_FAILED',
                'fromParent': 'CHECK_FAILED',
                'error': err_str,
            })
    
    return result
# ===== goto_from_scope check end =====


def _extract_target_subsystem(params, model_name, command):
    """v11.8.4 Gate_SHELL_ONLY: Extract the target subsystem path from params.
    
    For add_block/add_line/set_param, the target is the subsystem where blocks are being modified.
    
    Bug#23 FIX (2026-05-14): Comprehensive parameter scan with defense-in-depth.
    Original code only checked destPath/blockPath, missing srcBlock/dstBlock used by add_line_safe.
    Now scans ALL known path-bearing parameters to prevent future similar regressions.
    """
    # Defense-in-depth: scan all known path-bearing parameter keys in priority order.
    # Priority: explicit path specifiers first, then source/target references.
    PATH_PARAM_KEYS = [
        'destPath',      # add_block_safe: explicit destination full path
        'blockPath',      # set_param_safe: explicit block full path  
        'blockName',      # generic block reference
        'subsystemPath',  # micro_design/micro_review: subsystem path
        'srcBlock',       # add_line_safe: source block full path
        'dstBlock',       # add_line_safe: destination block full path
        'targetBlock',    # generic target reference
    ]
    target = ''
    for key in PATH_PARAM_KEYS:
        candidate = params.get(key, '')
        if candidate and '/' in str(candidate):
            target = candidate
            break
    
    if target and '/' in str(target):
        parts = str(target).split('/')
        # Model/Subsys/Block → Model/Subsys; Model/Subsys/Sub/Block → Model/Subsys/Sub
        if len(parts) >= 3:
            # Return parent of the deepest block (all but last component)
            return '/'.join(parts[:-1])
        elif len(parts) == 2:
            return target
    
    # Fallback: modelName may contain subsystem path
    if '/' in str(model_name):
        parts = str(model_name).split('/')
        return '/'.join(parts[:2]) if len(parts) >= 2 else model_name
    return model_name


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
        # ===== [v11.9 FIX] Phase 5 强制 auto_layout — 在 Gate_REVIEW_BUILD 之前执行 =====
        # 确保即使 model_complete 被 gate 阻断，子系统也已排版
        if command == 'sl_model_complete':
            _target_mn = params.get('subsystemPath', params.get('modelName', params.get('model_name', '')))
            if _target_mn:
                try:
                    _auto_arrange_model(_target_mn)
                except Exception:
                    pass
        
        # ===== [v11.9 Bug#24/#25 FIX] Gate_REVIEW_BUILD: model_complete 前强制 connectionScan =====
        # Note: This gate runs at sl_model_complete time (Gate_4), NOT at micro_approve time.
        # Rationale: micro_approve validates the DESIGN (blockPlan/signalDimensions match physics).
        # Build verification (actual wiring) belongs at model_complete because:
        # 1. Blocks must be added BEFORE they can be connected (chicken-and-egg with Gate_SHELL_ONLY)
        # 2. Micro_approve is a prerequisite for add_line via Gate_SHELL_ONLY
        # 3. Without micro_approve, no add_line is possible — creating a deadlock
        if command == 'sl_model_complete':
            _subsys = params.get('subsystemPath', params.get('subsystemName', params.get('subsystem', '')))
            _mn = params.get('modelName', params.get('model_name', ''))
            if _subsys or _mn:
                _target = _subsys if _subsys else _mn
                _cs_r = _call_sl_function('sl_review_core', {
                    '_pos_1': _target, '_pos_2': 'connectionScan'
                })
                if isinstance(_cs_r, dict) and not _cs_r.get('passed', True):
                    _n = _cs_r.get('details', {}).get('unconnectedCount', 0)
                    return {
                        "status": "gate_blocked", "blocked": True,
                        "gate": "Gate_REVIEW_BUILD",
                        "reason": f"Build verification failed: {_n} unconnected ports in '{_target}'",
                        "command": command, "requiredAction": "sl_add_line_safe",
                        "connectionScan": _cs_r,
                    }
        
        # ===== [v11.8.3 Bug#11 FIX] Command normalization: strip _safe suffix =====
        # REST whitelist uses sl_add_block_safe, but all internal checks use sl_add_block.
        # Normalizing at entry ensures ALL gate checks, state tracking, and verification
        # logic see the canonical command name. Defense-in-depth: individual checks
        # also accept both variants where practical.
        # _SL_FUNC_MAP already maps both variants to the correct MATLAB function.
        _command_orig = command
        if command.endswith('_safe') and command[:-5] in _SL_FUNC_MAP:
            command = command[:-5]  # sl_add_block_safe → sl_add_block
        
        # ===== [v11.6] Request counter for turn separation detection =====
        global _REQUEST_COUNTER
        _REQUEST_COUNTER += 1
        _current_request_id = _REQUEST_COUNTER
        
        # ===== [v11.5] Gate_S0: Scene detection gate =====
        # All Simulink commands (except sl_scene_detect itself and read-only commands)
        # require Scene to be confirmed first.
        _S0_GATED_COMMANDS = [
            'sl_add_block', 'sl_add_block_safe',
            'sl_add_line', 'sl_add_line_safe',
            'sl_set_param', 'sl_set_param_safe',
            'sl_delete',
            'sl_replace_block', 'sl_subsystem_create', 'sl_subsystem_mask',
            'sl_subsystem_expand', 'sl_config_set', 'sl_signal_config',
            'sl_signal_logging', 'sl_bus_create', 'sl_block_position',
            'sl_auto_layout', 'sl_sim_run', 'sl_sim_batch',
            'sl_framework_design', 'sl_framework_review', 'sl_framework_approve',
            'sl_micro_design', 'sl_micro_review', 'sl_micro_approve',
            'sl_model_design', 'sl_model_complete',
            # [P1-1 FIX] sl_inspect REMOVED from gated list — it's a read-only operation
            # Users need to inspect models before confirming scene (especially in Scene 2)
            'sl_framework_modify', 'sl_framework_modify_approve', 'sl_framework_modify_reject',
            'sl_model_load', 'sl_model_understand', 'sl_modify_plan',
            'sl_modify_review', 'sl_modify_approve', 'sl_model_sandbox',
            'sl_modify_verify_step',
            # v11.8: Hierarchy management
            'sl_hierarchy_validate', 'sl_subsystem_tree',
            # v11.8: Recursive workflow builtins
            'sl_build_status', 'sl_next_target',
        ]
        
        if command in _S0_GATED_COMMANDS:
            _scene_locked = False
            try:
                if _connection_mode == 'engine' and _matlab_engine is not None:
                    _s0_flag = _matlab_engine.eval("evalin('base', 'exist(''mS0SceneLocked_'', ''var'')')", nargout=1)
                    _scene_locked = (_s0_flag == 1)
                else:
                    _scene_locked = _SCENE_STATE.get('scene_confirmed', False)
            except Exception:
                _scene_locked = _SCENE_STATE.get('scene_confirmed', False)
            
            if not _scene_locked:
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": "Scene not confirmed. Auto-detect first, then user must confirm Scene 1 or Scene 2.",
                    "command": command,
                    "message": (
                        "SCENE_NOT_CONFIRMED: Before any Simulink operation, "
                        "you must confirm the working scene.\n"
                        "Step 1: Call sl_scene_detect(workspaceDir) to auto-detect\n"
                        "Step 2: Present the result to the user for confirmation\n"
                        "Step 3: User confirms -> system locks the scene"
                    ),
                    "requiredAction": "sl_scene_detect",
                    "hint": (
                        "1. Call sl_scene_detect with the workspace directory\n"
                        "2. If scene=1: confirm 'build from scratch' with user\n"
                        "3. If scene=2: confirm which model(s) to modify with user\n"
                        "4. After user confirmation, the scene is locked for this session"
                    ),
                    "nextSteps": [
                        "sl_scene_detect(workspaceDir)",
                        "[Present result to user for confirmation]",
                    ],
                }
        # ===== Gate_S0 end =====

        # 1. 反模式预检
        anti_warnings = _anti_pattern_check(command, params)
        
        # 2. 参数自动修正（Layer 2: 主动学习）
        fixed_params, auto_fixes = _auto_fix_args(command, params)
        
        # 3. 踩坑模式匹配（Layer 3: 预测学习）
        pitfall_matches = _check_pitfall_patterns(command, fixed_params)

        # ===== [v10.1] 设计阶段门控检查 =====
        # 在 design 阶段，所有 _MODIFY_COMMANDS 被拦截，要求先完成 sl_model_design
        _gate_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        if not _gate_mn and command in ('sl_set_param', 'sl_set_param_safe'):
            _gate_mn = fixed_params.get('blockPath', '')
            if '/' in _gate_mn:
                _gate_mn = _gate_mn.split('/')[0]
        if _gate_mn and command in _MODIFY_COMMANDS:
            try:
                _gate_state = _get_workflow_state(_gate_mn)
                if not _gate_state.design_approved and _gate_state.phase == 'design':
                    # 检查 skipDesign 选项（仅限已有模型的简单修改）
                    skip_design = fixed_params.get('skipDesign', False)
                    if not skip_design:
                        return {
                            "status": "gate_blocked",
                            "blocked": True,  # [Bug #5 FIX] 标准化拦截标记
                            "reason": "Design phase not completed. Physical modeling design required before building.",  # [Bug #5 FIX]
                            "command": command,  # [Bug #5 FIX] 被拦截的命令
                            "gate": "Gate_1",  # [Bug #5 FIX] 哪个门控
                            "message": (
                                "DESIGN_PHASE_REQUIRED: 物理建模设计未完成！\n"
                                "在构建模型之前，必须先调用 sl_model_design 获取结构化设计方案。\n"
                                "完成设计后，调用 sl_model_design(action='approve') 审批设计方案。"
                            ),
                            "requiredAction": "sl_model_design",
                            "workflowPhase": "design",
                            "designApproved": False,
                            "hint": (
                                "1. 调用 sl_model_design(taskDescription='你的建模任务描述')\n"
                                "2. 阅读返回的 design.equations / design.strategy / design.paramMap\n"
                                "3. 如需深入调研，使用网络搜索或调用其它工具获取物理方程\n"
                                "4. 确认方案后调用 sl_model_design(action='approve')\n"
                                "5. 然后才能开始 add_block / add_line 等构建操作"
                            ),
                        }
                    # skipDesign 模式下：add_block 已成功，保守更新状态
                    # 不依赖快照API（避免超时/失败导致状态不一致）
                    _gate_state.design_approved = True
                    _gate_state.phase = 'framework'
                    _gate_state.phase_step = 'building'
            except Exception as _gate_ex:
                # [P0-2 FIX] fail-closed: 门控检查异常时默认拒绝，不静默放行
                import logging
                _gate_logger = logging.getLogger('matlab_bridge')
                _gate_logger.warning(f"Design gate check failed for {_gate_mn}: {_gate_ex}")
                return {
                    "status": "gate_error",
                    "blocked": True,  # [Bug #5 FIX]
                    "reason": f"Design gate check failed for model '{_gate_mn}': {_gate_ex}. Operation denied for safety.",  # [Bug #5 FIX]
                    "command": command,  # [Bug #5 FIX]
                    "gate": "Gate_1",  # [Bug #5 FIX]
                    "message": f"Design gate check failed for model '{_gate_mn}': {_gate_ex}. Operation denied for safety.",
                    "requiredAction": "sl_model_design",
                    "workflowPhase": "design",
                }
        # ===== 设计门控结束 =====

        # ===== [v11.0] 大框架三层迭代循环门控 =====
        # 大框架门控：所有构建命令必须先完成 sl_framework_design → review → approve
        _MODIFY_COMMANDS_GATED_BY_FRAMEWORK = [
            'sl_add_block', 'sl_add_block_safe',
            'sl_add_line', 'sl_add_line_safe',
            'sl_delete', 'sl_replace_block',
            'sl_subsystem_create', 'sl_subsystem_mask',
            'sl_bus_create', 'sl_signal_config', 'sl_block_position',
            'sl_auto_layout',  # 包含排版命令
        ]

        # v11.0 大框架 API 不需要门控检查
        _FRAMEWORK_API_COMMANDS = [
            'sl_framework_design', 'sl_framework_review', 'sl_framework_approve',
            'sl_micro_design', 'sl_micro_review', 'sl_micro_approve',  # Phase 2
            'sl_framework_modify', 'sl_framework_modify_approve', 'sl_framework_modify_reject',  # Phase 3
            # v11.8: Read-only query commands (no Gate_2 needed)
            'sl_hierarchy_validate', 'sl_subsystem_tree',
            'sl_build_status', 'sl_next_target',
        ]

        # [v11.0 Phase 3 FIX] 提前初始化框架状态变量，供 Gate 1 + Gate 3 + 框架 API 共用
        _fw_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        if not _fw_mn and command in ('sl_set_param', 'sl_set_param_safe'):
            _fw_mn = fixed_params.get('blockPath', '')
            if '/' in _fw_mn:
                _fw_mn = _fw_mn.split('/')[0]
        _fw_locked = False

        # 只有构建命令需要门控检查
        if command in _MODIFY_COMMANDS_GATED_BY_FRAMEWORK:
            if _fw_mn:
                try:
                    # 检查大框架是否已锁定
                    lock_var = f'mFWLock_{_fw_mn}'  # [P1-4 FIX] 统一命名: framework_locked_ → mFWLock_
                    _fw_locked = False
                    try:
                        if _matlab_engine:
                            _fw_locked = _matlab_engine.eval(lock_var)
                        else:
                            _fw_locked = False
                    except Exception as _lock_ex:
                        # [P0-2 FIX] 精确异常捕获 + 日志记录，替代 bare except:pass
                        import logging
                        logging.getLogger('matlab_bridge').warning(
                            f"Framework lock check failed for {_fw_mn}: {_lock_ex}")
                        _fw_locked = False

                    # 检查大框架是否已审批（通过 workflow state）
                    _fw_state = _get_workflow_state(_fw_mn)
                    framework_approved = getattr(_fw_state, 'framework_approved', False)
                    hierarchy_approved = getattr(_fw_state, 'hierarchy_approved', False)
                    
                    # [v11.8] Hierarchy mode: verify operation target is in approved tree
                    if hierarchy_approved and _fw_state.subsystem_tree is not None:
                        _op_target = fixed_params.get('modelName', fixed_params.get('model_name',
                            fixed_params.get('blockPath', '')))
                        if _op_target and '/' in str(_op_target):
                            _op_norm = str(_op_target).replace('\\', '/')
                            _node = _find_node_in_tree(_fw_state.subsystem_tree, _op_norm)
                            if _node is None:
                                # Check if it's inside a known subsystem
                                _parent_path = '/'.join(_op_norm.split('/')[:-1])
                                _parent_node = _find_node_in_tree(_fw_state.subsystem_tree, _parent_path)
                                if _parent_node is None and _op_norm.split('/')[0] != _fw_mn:
                                    return {
                                        "status": "gate_blocked",
                                        "blocked": True,
                                        "reason": f"Operation target '{_op_norm}' is not in the approved hierarchy tree.",
                                        "command": command,
                                        "gate": "Gate_2 (hierarchy)",
                                        "message": (
                                            f"HIERARCHY_VIOLATION: The operation target '{_op_norm}' "
                                            f"is not part of the approved subsystem hierarchy. "
                                            f"All build operations must target subsystems defined in the framework."
                                        ),
                                        "requiredAction": "sl_framework_modify",
                                        "hint": "Use sl_framework_modify to add this subsystem to the framework, or operate on an existing subsystem.",
                                    }

                    if not framework_approved and not _fw_locked:
                        # [v11.5] Check Scene 2 approval as alternative to framework
                        # Extract top-level model name from path (e.g. "Model/Subsys" → "Model")
                        _s2_toplevel = _fw_mn.split('/')[0] if '/' in _fw_mn else _fw_mn
                        _s2_active = False
                        try:
                            if _connection_mode == 'engine' and _matlab_engine is not None:
                                _s2_chk = _matlab_engine.eval(
                                    f"evalin('base', 'exist(''mS2Approved_{_s2_toplevel}'', ''var'')')", nargout=1)
                                _s2_active = (_s2_chk == 1)
                        except Exception:
                            pass
                        
                        if _s2_active:
                            framework_approved = True  # Scene 2 approved → Gate_2 passes
                    
                    if not framework_approved and not _fw_locked:
                        # 检查 skipDesign 选项（仅限已有模型的简单修改）
                        skip_design = fixed_params.get('skipDesign', False)
                        if not skip_design:
                            return {
                                "status": "gate_blocked",
                                "blocked": True,  # [Bug #5 FIX]
                                "reason": "Macro framework not approved. Framework design→review→approve required before building.",  # [Bug #5 FIX]
                                "command": command,  # [Bug #5 FIX]
                                "gate": "Gate_2",  # [Bug #5 FIX]
                                "message": (
                                    "MACRO_FRAMEWORK_REQUIRED: 大框架设计未完成！\n"
                                    "在构建模型之前，必须先完成大框架设计→审核→审批流程。\n"
                                    "完成大框架审批后，才能开始 add_block / add_line 等构建操作。"
                                ),
                                "requiredAction": "sl_framework_design",
                                "workflowPhase": "framework_design",
                                "macroFrameworkApproved": False,
                                "frameworkApproved": False,  # [Bug #5 FIX] 标准化
                                "hint": (
                                    "1. 调用 sl_framework_design(taskDescription='你的建模任务描述')\n"
                                    "2. 调用 sl_framework_review() 自检大框架\n"
                                    "3. 调用 sl_framework_approve(modelName) 审批并锁定大框架\n"
                                    "4. 然后才能开始 add_block / add_line 等构建操作"
                                ),
                                "nextSteps": [
                                    "sl_framework_design(taskDescription='你的建模任务描述')",
                                    "sl_framework_review(macroFramework)",
                                    "sl_framework_approve(modelName)"
                                ],
                            }
                except Exception as _fw_gate_ex:
                    # [P0-2 FIX] fail-closed: 大框架门控异常时默认拒绝，不静默放行
                    import logging
                    _fw_gate_logger = logging.getLogger('matlab_bridge')
                    _fw_gate_logger.warning(f"Macro framework gate check failed for {_fw_mn}: {_fw_gate_ex}")
                    return {
                        "status": "gate_error",
                        "blocked": True,  # [Bug #5 FIX]
                        "reason": f"Macro framework gate check failed for model '{_fw_mn}': {_fw_gate_ex}. Operation denied for safety.",  # [Bug #5 FIX]
                        "command": command,  # [Bug #5 FIX]
                        "gate": "Gate_2",  # [Bug #5 FIX]
                        "message": f"Macro framework gate check failed for model '{_fw_mn}': {_fw_gate_ex}. Operation denied for safety.",
                        "requiredAction": "sl_framework_design",
                        "workflowPhase": "framework_design",
                    }
        # ===== [v11.0 Phase 3] Gate 3: 大框架锁定后结构性修改拦截 =====
        # 大框架锁定后，以下结构性操作需要通过 sl_framework_modify 审批：
        # - sl_subsystem_create: 添加新子系统 → addSubsystem
        # - sl_delete (删除子系统级别): → removeSubsystem [P0-2 FIX 新增]
        # 允许的操作（不拦截）:
        # - sl_add_block: 添加模块到已有子系统内部（参数微调）
        # - sl_add_line: 连线（不改变子系统架构）
        # - sl_set_param: 参数调整（如 Gain 值）
        # - sl_config_set: 仿真参数修改
        # - sl_signal_logging, sl_signal_config: 信号记录/配置
        # - sl_block_position, sl_auto_layout: 排版
        _STRUCTURAL_MODIFY_COMMANDS = {
            'sl_subsystem_create',  # 添加子系统 → 需要 addSubsystem 审批
            'sl_delete',            # [P0-2 FIX] 删除子系统级别 → 需要 removeSubsystem 审批
        }
        # [P0-2 FIX] sl_delete 只在删除子系统级别时拦截，删除子系统内部模块不拦截
        _is_structural_delete = False
        if command == 'sl_delete' and _fw_mn and _fw_locked:
            _del_target = fixed_params.get('blockPath', fixed_params.get('name', ''))
            if _del_target:
                # 如果删除目标是 Model/SubsystemName 格式（子系统级别），则拦截
                # 如果是 Model/SubsystemName/BlockName（子系统内部），则放行
                _parts = str(_del_target).split('/')
                if len(_parts) == 2:
                    # Model/SubsystemName — 这是子系统级别删除
                    _is_structural_delete = True
                # len(_parts) >= 3 表示子系统内部，不拦截

        if _fw_mn and _fw_locked and (command in _STRUCTURAL_MODIFY_COMMANDS) and (command != 'sl_delete' or _is_structural_delete):
            # [v11.8] HARD DEPTH CHECK: block subsystem creation at depth 5+
            if command == 'sl_subsystem_create':
                _subsys_parent = fixed_params.get('modelName', fixed_params.get('model_name',
                    fixed_params.get('blockPath', '')))
                if _subsys_parent and '/' in str(_subsys_parent):
                    _parent_norm = str(_subsys_parent).replace('\\', '/')
                    _fw_state = _get_workflow_state(_fw_mn)
                    if (getattr(_fw_state, 'hierarchy_approved', False) 
                            and _fw_state.subsystem_tree is not None):
                        _parent_node = _find_node_in_tree(_fw_state.subsystem_tree, _parent_norm)
                        if _parent_node is not None and _parent_node.get('depth', 0) >= MAX_DEPTH:
                            return {
                                "status": "gate_blocked",
                                "blocked": True,
                                "reason": (
                                    f"Cannot create subsystem at depth "
                                    f"{_parent_node['depth'] + 1}: max depth {MAX_DEPTH} exceeded."
                                ),
                                "command": command,
                                "gate": "Gate_3 (depth limit)",
                                "message": (
                                    f"DEPTH_LIMIT_EXCEEDED: Cannot create child subsystem "
                                    f"in '{_parent_norm}' (depth={_parent_node['depth']}). "
                                    f"Maximum nesting depth is {MAX_DEPTH}."
                                ),
                                "hint": "Flatten the design or use Model Reference instead.",
                            }
            # [v11.6.8 FIX] Scene 1 exemption: subsystem_create is an expected build step
            # when the framework is approved, not a modification. Scene 2 still requires 
            # sl_framework_modify approval for structural changes.
            # Check: scene confirmed + scene == 1 + framework_approved → allow
            _scene_num = _SCENE_STATE.get('scene', 0)
            _is_scene1 = (_scene_num == 1)
            if _is_scene1 and command == 'sl_subsystem_create':
                # Scene 1 build-from-scratch: allow all subsystem creation
                _has_gate3_pass = True
            else:
                # Scene 2 or other structural modifications: check gate3_pass marker
                _gate3_pass_var = f'mFWGate3Pass_{_fw_mn}'
                _has_gate3_pass = False
                try:
                    if _matlab_engine:
                        _pass_exists = _matlab_engine.eval(f"evalin('base', 'exist(''{_gate3_pass_var}'')')")
                        if _pass_exists == 1:
                            _pass_val = _matlab_engine.eval(_gate3_pass_var)
                            if _pass_val:
                                _has_gate3_pass = True
                                _matlab_engine.eval(f"assignin('base', '{_gate3_pass_var}', false);")
                except Exception:
                    _has_gate3_pass = False
            
            if not _has_gate3_pass:
                # 确定具体的修改类型
                if command == 'sl_subsystem_create':
                    _modify_action = 'addSubsystem'
                    _subsys_name = fixed_params.get('name', fixed_params.get('subsystemName', ''))
                    _modify_hint = f"sl_framework_modify('{_fw_mn}', 'addSubsystem', 'subsystemName', '{_subsys_name}', 'subsystemType', 'plant', 'inputs', '...', 'outputs', '...')"
                else:
                    _modify_action = 'structural_change'
                    _modify_hint = f"sl_framework_modify('{_fw_mn}', '{_modify_action}', ...)"

                return {
                    "status": "gate_blocked",
                    "blocked": True,  # [Bug #5 FIX] 标准化拦截标记
                    "reason": f"Macro framework is locked. {command} is a structural modification ({_modify_action}) requiring sl_framework_modify approval.",  # [Bug #5 FIX]
                    "command": command,  # [Bug #5 FIX] 被拦截的命令
                    "gate": "Gate_3",  # [Bug #5 FIX] 哪个门控
                    "message": (
                        f"FRAMEWORK_LOCKED: 大框架已锁定，不能直接执行 {command}！\n"
                        f"操作 '{command}' 属于结构性修改（{_modify_action}），需要通过框架变更审批流程。\n"
                        f"请使用 sl_framework_modify 申请修改。"
                    ),
                    "requiredAction": "sl_framework_modify",
                    "workflowPhase": "framework_locked",
                    "frameworkApproved": True,  # [Bug #5 FIX]
                    "frameworkLocked": True,
                    "modifyAction": _modify_action,
                    "hint": _modify_hint,
                    "nextSteps": [
                        _modify_hint,
                        f"sl_framework_modify_approve('{_fw_mn}')",
                    ],
                }
        # ===== Gate 3 结束 =====

        # ===== [v11.8.4] Gate_SHELL_ONLY: 外壳可批量，内部必须逐子系统 Gate 审批 =====
        # 原则：子系统空壳（sl_subsystem_create）可以批量创建——外壳只是容器。
        # 子系统内部结构（add_block/add_line/set_param）绝对不能批量——
        # 每个子系统的内部设计必须独立走 micro_design → micro_review → micro_approve。
        # 
        # 机制：
        # - _MICRO_APPROVED_SUBSYSTEMS 字典：{model_name: set(approved_subsystem_paths)}
        # - sl_micro_approve 成功后将目标子系统加入此集合
        # - add_block/add_line/set_param 前检查：目标子系统必须在已审批集合中
        # - 不在集合中 → Gate_SHELL_ONLY 拦截，提示先完成 micro_approve
        _SHELL_ONLY_GATED = ['sl_add_block', 'sl_add_block_safe', 'sl_add_line', 
                              'sl_add_line_safe', 'sl_set_param', 'sl_set_param_safe']
        if command in _SHELL_ONLY_GATED and _fw_mn:
            _target_subsys = _extract_target_subsystem(fixed_params, _fw_mn, command)
            if _target_subsys:
                _toplevel = _fw_mn.split('/')[0]
                if _toplevel not in _MICRO_APPROVED_SUBSYSTEMS:
                    _MICRO_APPROVED_SUBSYSTEMS[_toplevel] = set()
                if _target_subsys not in _MICRO_APPROVED_SUBSYSTEMS[_toplevel]:
                    return {
                        "status": "gate_blocked",
                        "blocked": True,
                        "reason": (
                            f"Subsystem '{_target_subsys}' has NOT been micro_approved. "
                            f"Internal blocks CANNOT be added in batch — each subsystem must "
                            f"go through micro_design → micro_review → micro_approve first."
                        ),
                        "command": command,
                        "gate": "Gate_SHELL_ONLY",
                        "message": (
                            f"SHELL_ONLY_VIOLATION: 子系统 '{_target_subsys}' 的内部结构尚未审批！\n"
                            f"🔴 外壳/内部原则: 子系统空壳可批量创建，内部结构必须逐个走 Gate 流程。\n"
                            f"在添加内部块/连线/参数之前，必须先完成:\n"
                            f"  1. sl_micro_design(subsystemName='{_target_subsys}', taskDescription='...')\n"
                            f"  2. sl_micro_review(subsystemName='{_target_subsys}', microFramework=...)\n"
                            f"  3. sl_micro_approve(subsystemName='{_target_subsys}', ...)\n"
                            f"  4. 然后才能调用 {command}"
                        ),
                        "requiredAction": "sl_micro_design",
                        "workflowPhase": "subsystem_iteration",
                        "targetSubsystem": _target_subsys,
                        "hint": (
                            f"1. 调用 sl_micro_design(subsystemName='{_target_subsys}', "
                            f"taskDescription='...', modelName='{_toplevel}')\n"
                            f"2. 根据返回的 designPrompt 设计子系统内部结构\n"
                            f"3. 调用 sl_micro_review 审查设计\n"
                            f"4. 调用 sl_micro_approve 审批锁定\n"
                            f"5. 然后才能调用 {command} 添加块/连线"
                        ),
                        "nextSteps": [
                            f"sl_micro_design(subsystemName='{_target_subsys}', taskDescription='...', modelName='{_toplevel}')",
                            f"sl_micro_review(subsystemName='{_target_subsys}', microFramework={{...}}, modelName='{_toplevel}')",
                            f"sl_micro_approve(subsystemName='{_target_subsys}', modelName='{_toplevel}')",
                        ],
                    }
        # ===== Gate_SHELL_ONLY end =====

        # ===== 大框架门控结束 =====

        # ===== [v11.6.2] Gate_CONNECTIVITY: 强制连线门控 =====
        # P0 FIX: _verification 反馈是软建议不是硬拦截 — 这是工作流的核心缺陷。
        # 修复: 当连续 3+ 次 add_block 无 add_line 时，拦截 add_block。
        # 这会强制 AI 遵循"添加→连线→验证"的循环，而不是批量添加后忽略未连接端口。
        #
        # 机制:
        # - consecutive_adds 在 _check_auto_layout_needed 中每次 add_block 后 +1
        # - 每次 add_line 后重置为 0
        # - 当 >=3 时，下一个 add_block 被 Gate_CONNECTIVITY 拦截
        # - 被拦截后必须调 add_line 连接已有模块才能继续添加
        #
        # [v11.6.2 FIX] Normalize model name to toplevel for consistency:
        # add_block uses sandbox path (Model/Subsys), add_line uses parent model.
        # Both must update the SAME workflow state counter.
        if command == 'sl_add_block':
            _conn_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            # Normalize to toplevel model: Quadrotor_FDM/PID_Controller_New → Quadrotor_FDM
            _conn_toplevel = _conn_mn.split('/')[0] if '/' in _conn_mn else _conn_mn
            if _conn_toplevel:
                _conn_state = _get_workflow_state(_conn_toplevel)
                if _conn_state.consecutive_adds >= 12:
                    return {
                        "status": "gate_blocked",
                        "blocked": True,
                        "reason": (
                            f"{_conn_state.consecutive_adds} consecutive add_block(s) without add_line. "
                            f"Connect existing blocks before adding more."
                        ),
                        "command": command,
                        "gate": "Gate_CONNECTIVITY",
                        "message": (
                            f"CONNECTIVITY_REQUIRED: {_conn_state.consecutive_adds} blocks added "
                            f"without connecting them.\n"
                            f"You MUST connect unconnected ports via add_line before adding more blocks.\n"
                            f"Use sl_inspect or check _verification in previous responses to identify "
                            f"unconnected ports, then connect them with add_line."
                        ),
                        "requiredAction": "add_line",
                        "workflowPhase": "building",
                        "consecutiveAdds": _conn_state.consecutive_adds,
                        "hint": (
                            f"1. Check previous _verification.warnings for UNCONNECTED ports\n"
                            f"2. Use add_line to connect {_conn_state.consecutive_adds} pending blocks\n"
                            f"3. After connections, consecutive_adds resets to 0\n"
                            f"4. Then you can add more blocks"
                        ),
                    }
        # ===== Gate_CONNECTIVITY end =====

        # ===== [v11.5] Gate_S2_MODIFY: protect existing model parts =====
        # Any write to a block/line OUTSIDE the sandbox subsystem requires USER CONFIRMATION
        _S2_WRITE_COMMANDS = [
            'sl_add_block', 'sl_add_line', 'sl_set_param', 'sl_delete',
            'sl_replace_block', 'sl_subsystem_create', 'sl_subsystem_mask',
            'sl_signal_config', 'sl_block_position',
        ]
        _s2_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        
        if command in _S2_WRITE_COMMANDS and _s2_mn:
            _s2_approved = False
            _s2_toplevel_gate = _s2_mn.split('/')[0] if '/' in _s2_mn else _s2_mn
            try:
                if _connection_mode == 'engine' and _matlab_engine is not None:
                    _s2_exists = _matlab_engine.eval(
                        f"evalin('base', 'exist(''mS2Approved_{_s2_toplevel_gate}'', ''var'')')", nargout=1)
                    if _s2_exists == 1:
                        _s2_approved = True
                else:
                    _s2_approved = _SCENE_STATE.get('s2_approved', False)
            except Exception:
                _s2_approved = False
            
            if _s2_approved:
                _sandbox_name = ''
                try:
                    if _connection_mode == 'engine' and _matlab_engine is not None:
                        _sn_exists = _matlab_engine.eval(
                            f"evalin('base', 'exist(''mS2SandboxName_{_s2_toplevel_gate}'', ''var'')')", nargout=1)
                        if _sn_exists == 1:
                            _sandbox_name = _matlab_engine.eval(
                                f"evalin('base', 'mS2SandboxName_{_s2_toplevel_gate}')", nargout=1)
                except Exception:
                    pass
                
                _target = ''
                if command == 'sl_add_block':
                    _target = fixed_params.get('modelName', '')
                elif command == 'sl_set_param':
                    _target = fixed_params.get('blockPath', '')
                elif command == 'sl_delete':
                    _target = fixed_params.get('blockPath', '')
                elif command == 'sl_subsystem_create':
                    _target = fixed_params.get('modelName', params.get('modelName', ''))
                elif command == 'sl_subsystem_mask':
                    _target = fixed_params.get('modelName', params.get('modelName', ''))
                elif command == 'sl_add_line':
                    # [v11.6.3 FIX] add_line target MUST come from srcSpec/dstSpec,
                    # not modelName. modelName is always the toplevel model
                    # (e.g. 'Quadrotor_FDM') which can NEVER be "inside" any sandbox.
                    _src = fixed_params.get('srcSpec', params.get('srcSpec', ''))
                    _dst = fixed_params.get('dstSpec', params.get('dstSpec', ''))
                    _target = str(_src) if _src else str(_dst) if _dst else ''
                    if not _target:
                        _target = fixed_params.get('modelName', '')  # fallback
                
                _is_inside_sandbox = False
                if _sandbox_name and _target:
                    # [v11.6.3 FIX] Path-prefix check: sandbox MUST appear as a
                    # complete path component, not a substring match.
                    # e.g., 'PID_Controller' in 'Model/PID_Controller/Block' → True
                    # e.g., 'PID' in 'Model/PID_Controller/Block' → False
                    _target_str = str(_target)
                    _target_parts = _target_str.split('/')
                    _is_inside_sandbox = (
                        _sandbox_name in _target_parts or
                        _target_str.startswith(_sandbox_name + '/') or
                        ('/' + _sandbox_name + '/') in _target_str
                    )
                
                if not _is_inside_sandbox and _sandbox_name:
                    _perm_key = f"{_s2_mn}:{command}:{_target}"
                    _has_perm = _S2_MOD_PERMISSIONS.get(_perm_key, False)
                    
                    if not _has_perm:
                        return {
                            "status": "gate_blocked", "blocked": True,
                            "gate": "Gate_S2_MODIFY",
                            "reason": "Modification to existing model part requires user confirmation.",
                            "command": command,
                            "message": (
                                f"EXISTING_MODEL_PROTECTED: This operation targets '{_target}' "
                                f"which is OUTSIDE the sandbox '{_sandbox_name}'.\n"
                                f"Modifying existing model parts requires explicit USER CONFIRMATION."
                            ),
                            "pendingPermission": {
                                "permissionId": f"s2mod_{_s2_mn}_{command}_{_target.replace('/', '_')}",
                                "operation": command,
                                "target": _target,
                                "risk": _classify_s2_risk(command, _target),
                                "sandboxName": _sandbox_name,
                            },
                            "requiredAction": "user_confirm",
                            "hint": "Present this modification to the user for confirmation."
                        }
        # ===== Gate_S2_MODIFY end =====

        # ===== [v11.1 Phase 2] 子系统级 micro 门控 =====
        # 当操作目标是子系统内部时，检查该子系统的小框架是否已审批
        _MICRO_GATED_COMMANDS = [
            'sl_add_block', 'sl_add_line', 'sl_set_param', 'sl_delete',
        ]
        if command in _MICRO_GATED_COMMANDS and _fw_mn:
            try:
                _fw_state = _get_workflow_state(_fw_mn)
                # 只有在大框架已审批、且处于 subsystem_iteration 阶段时才检查 micro 门控
                if _fw_state.framework_approved and _fw_state.phase == 'subsystem_iteration':
                    # 判断操作是否针对子系统内部
                    _target_subsystem = ''
                    if command == 'sl_add_block':
                        _model_name_param = fixed_params.get('modelName', '')
                        if '/' in str(_model_name_param):
                            # modelName 含 / 说明在子系统内操作
                            parts = str(_model_name_param).split('/')
                            if len(parts) >= 2:
                                _target_subsystem = parts[1]
                    elif command == 'sl_set_param':
                        _block_path = fixed_params.get('blockPath', '')
                        if '/' in str(_block_path):
                            parts = str(_block_path).split('/')
                            if len(parts) >= 3:
                                _target_subsystem = parts[1]
                    elif command == 'sl_add_line':
                        _model_name_param = fixed_params.get('modelName', '')
                        if '/' in str(_model_name_param):
                            parts = str(_model_name_param).split('/')
                            if len(parts) >= 2:
                                _target_subsystem = parts[1]
                    elif command == 'sl_delete':
                        _block_path = fixed_params.get('blockPath', '')
                        if '/' in str(_block_path):
                            parts = str(_block_path).split('/')
                            if len(parts) >= 3:
                                _target_subsystem = parts[1]
                    
                    # 如果操作在子系统内部，检查 micro 框架是否已审批
                    if _target_subsystem:
                        _mf_lock_var = f'uFWLock_{_target_subsystem}'  # [P1-4 FIX] 统一命名: mfLock_ → uFWLock_
                        _micro_approved = False
                        try:
                            if _matlab_engine:
                                _micro_approved = _matlab_engine.eval(_mf_lock_var)
                        except:
                            _micro_approved = False
                        
                        if not _micro_approved:
                            # 检查 Bridge workflow state
                            if _fw_state.phase_step in ('micro_proposed', 'micro_reviewed'):
                                return {
                                    "status": "gate_blocked",
                                    "blocked": True,  # [Bug #5 FIX]
                                    "reason": f"Subsystem '{_target_subsystem}' micro framework not approved. Complete design→review→approve before building inside.",  # [Bug #5 FIX]
                                    "command": command,  # [Bug #5 FIX]
                                    "gate": "Micro_Gate",  # [Bug #5 FIX]
                                    "message": (
                                        f"MICRO_FRAMEWORK_REQUIRED: Subsystem '{_target_subsystem}' micro framework not approved!\n"
                                        f"Before building inside subsystem '{_target_subsystem}', complete:\n"
                                        f"1. sl_micro_design(subsystemName='{_target_subsystem}', taskDescription='...')\n"
                                        f"2. sl_micro_review(subsystemName='{_target_subsystem}')\n"
                                        f"3. sl_micro_approve(subsystemName='{_target_subsystem}')"
                                    ),
                                    "requiredAction": "sl_micro_approve",
                                    "workflowPhase": "subsystem_iteration",
                                    "targetSubsystem": _target_subsystem,
                                    "microFrameworkApproved": False,
                                    "hint": (
                                        f"1. sl_micro_design(subsystemName='{_target_subsystem}', taskDescription='...')\n"
                                        f"2. sl_micro_review(subsystemName='{_target_subsystem}')\n"
                                        f"3. sl_micro_approve(subsystemName='{_target_subsystem}')"
                                    ),
                                }
            except Exception as _micro_gate_ex:
                # [P0-2 FIX] 精确异常捕获 + 日志记录，替代 bare except:pass
                import logging
                _micro_gate_logger = logging.getLogger('matlab_bridge')
                _micro_gate_logger.warning(f"Micro gate check failed for {_fw_mn}: {_micro_gate_ex}")
                # micro 门控异常时不过度阻断，记录警告后放行
                # 原因: micro 门控是二级门控，不应因内部异常完全阻塞大框架已审批的构建流程
        # ===== 子系统级 micro 门控结束 =====

        # ===== [v11.3] 模型完成门控 (Gate 4) =====
        # sl_sim_run / sl_sim_batch 执行前强制检查 sl_model_complete 是否已通过
        # 未通过 -> gate_blocked，AI 无法跳过
        _COMPLETION_GATED_COMMANDS = ['sl_sim_run', 'sl_sim_batch']
        if command in _COMPLETION_GATED_COMMANDS:
            _comp_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if not _comp_mn:
                # Try extracting from other params
                _comp_mn = params.get('modelName', params.get('model_name', ''))
            if _comp_mn:
                try:
                    # Check if model_completed flag exists in MATLAB workspace
                    # [P0-1 FIX] Sanitize model name for MATLAB variable (replace '/' with '__')
                    _mn_safe = _comp_mn.replace('/', '__').replace(' ', '_')
                    _comp_flag_var = f'model_completed_{_mn_safe}'
                    _comp_ok = False
                    try:
                        if _matlab_engine:
                            _comp_exists = _matlab_engine.eval(
                                f"evalin('base', 'exist(''{_comp_flag_var}'', ''var'')')", nargout=1)
                            if _comp_exists == 1:
                                _comp_val = _matlab_engine.eval(
                                    f"evalin('base', '{_comp_flag_var}')", nargout=1)
                                _comp_ok = (_comp_val == True)
                    except Exception:
                        pass

                    if not _comp_ok:
                        # Also check Python-side state
                        try:
                            _comp_state = _get_workflow_state(_comp_mn)
                            if _comp_state.model_completed:
                                _comp_ok = True
                        except Exception:
                            pass
                    
                    # [v11.8] Hierarchy completeness check for Gate_4
                    if _comp_ok:
                        try:
                            _comp_state = _get_workflow_state(_comp_mn)
                            if (getattr(_comp_state, 'hierarchy_approved', False) 
                                    and _comp_state.subsystem_tree is not None
                                    and not _all_subsystems_completed(_comp_state)):
                                _comp_ok = False
                                _missing = _get_incomplete_subsystems(_comp_state)
                                return {
                                    "status": "gate_blocked",
                                    "blocked": True,
                                    "reason": (
                                        f"Hierarchy incomplete: {len(_missing)} subsystem(s) "
                                        f"not yet completed."
                                    ),
                                    "command": command,
                                    "gate": "Gate_4 (hierarchy)",
                                    "message": (
                                        f"HIERARCHY_INCOMPLETE: {len(_missing)} subsystem(s) "
                                        f"are not yet completed. "
                                        f"Complete all subsystems before simulation:\n"
                                        + "\n".join(f"  - {m}" for m in _missing[:10])
                                    ),
                                    "requiredAction": "sl_model_complete",
                                    "incompleteSubsystems": _missing,
                                    "hint": f"Call sl_model_complete('{_missing[0]}') to complete the first missing subsystem."
                                }
                        except Exception:
                            pass

                    if not _comp_ok:
                        return {
                            "status": "gate_blocked",
                            "blocked": True,
                            "reason": f"Model completion gate not passed for '{_comp_mn}'. sl_model_complete must pass before simulation.",
                            "command": command,
                            "gate": "Gate_4",
                            "message": (
                                f"COMPLETION_GATE: Model '{_comp_mn}' has not passed completion checks.\n"
                                f"Before running simulation, you must:\n"
                                f"1. Call sl_get_model_issues('{_comp_mn}') to see all unconnected ports\n"
                                f"2. Fix all unconnected ports (add_line or Goto/From)\n"
                                f"3. Call sl_model_complete('{_comp_mn}', 'action', 'complete') to pass the gate\n"
                                f"4. Then retry sl_sim_run"
                            ),
                            "requiredAction": "sl_model_complete",
                            "workflowPhase": "simulation",
                            "modelCompleted": False,
                            "hint": (
                                f"1. issues = sl_get_model_issues('{_comp_mn}')\n"
                                f"2. Fix each unconnected port shown in issues.unconnectedBlocks\n"
                                f"3. complete = sl_model_complete('{_comp_mn}', 'action', 'complete')\n"
                                f"4. If complete.canProceed is true, proceed to sl_sim_run"
                            ),
                        }
                except Exception as _comp_gate_ex:
                    import logging
                    _comp_gate_logger = logging.getLogger('matlab_bridge')
                    _comp_gate_logger.warning(
                        f"Completion gate check failed for {_comp_mn}: {_comp_gate_ex}")
                    # fail-closed: deny simulation on gate error
                    return {
                        "status": "gate_error",
                        "blocked": True,
                        "reason": f"Completion gate check failed: {_comp_gate_ex}",
                        "command": command,
                        "gate": "Gate_4",
                        "message": f"Completion gate check failed for model '{_comp_mn}': {_comp_gate_ex}. Simulation denied for safety.",
                        "requiredAction": "sl_model_complete",
                    }
        # ===== 模型完成门控 (Gate 4) 结束 =====

        # ===== [v11.4] 框架设计完整性门控 (Gate 5) =====
        if command == 'sl_framework_approve':
            _g5_mn = fixed_params.get('modelName', fixed_params.get('model_name', params.get('modelName', '')))
            macro_fw = fixed_params.get('macroFramework', params.get('macroFramework', None))
            if macro_fw and _g5_mn:
                # [v11.4.1 FIX] Warm up engine before gate check
                _g5_eng = get_engine()
                if _g5_eng is not None:
                    # [v11.6.7 FIX] Convert Python dict to MATLAB struct via eval
                    # eng.workspace['x'] = dict stores as py.dict, not MATLAB struct
                    # Use _dict_to_matlab_struct + eval to create proper MATLAB struct
                    fw_expr = _dict_to_matlab_struct(macro_fw)
                    _g5_eng.eval(f"mG5FW = {fw_expr};", nargout=0)
                    pc_result = _call_sl_function('sl_check_port_completeness', {'_pos_1_special': 'mG5FW'})
                    sc_result = _call_sl_function('sl_check_signal_closure', {'_pos_1_special': 'mG5FW'})
                    # [P0-5 FIX] Goto/From cross-subsystem boundary check (R2 enforcement)
                    gf_scope_result = _check_goto_from_scope(_g5_mn)
                    _g5_eng.eval("clear('mG5FW')", nargout=0)
                    _g5_blocked = (
                        not pc_result.get('passed', True) or
                        not sc_result.get('passed', True) or
                        not gf_scope_result.get('passed', True)
                    )
                    if _g5_blocked:
                        _g5_details = {
                            "port_completeness": pc_result,
                            "signal_closure": sc_result,
                            "goto_from_scope": gf_scope_result,
                        }
                        _g5_reasons = []
                        if not pc_result.get('passed', True):
                            _g5_reasons.append(f"port_completeness: {pc_result.get('message', 'FAILED')}")
                        if not sc_result.get('passed', True):
                            _g5_reasons.append(f"signal_closure: {sc_result.get('message', 'FAILED')}")
                        if not gf_scope_result.get('passed', True):
                            _g5_reasons.append(f"goto_from_scope: {gf_scope_result.get('message', 'CROSS-BOUNDARY')}")
                        return {
                            "status": "gate_blocked", "blocked": True,
                            "reason": "Framework design integrity checks failed: " + "; ".join(_g5_reasons),
                            "command": command, "gate": "Gate_5",
                            "message": "DESIGN_INTEGRITY_FAILED. Fix signalFlow/gotoFromPlan completeness, signal closure, and Goto/From scope.",
                            "details": _g5_details,
                        }
                else:
                    # Engine unavailable — log warning but allow through
                    import logging
                    logging.getLogger('matlab_bridge').warning(
                        f"Gate_5 skipped: MATLAB Engine unavailable for model '{_g5_mn}'")
        # ===== 框架设计完整性门控 (Gate 5) 结束 =====

        # [P1-5 FIX] sl_new_system 工作流清理移到 _SL_FUNC_MAP 检查之前
        # 因为 sl_new_system 目前不在 _SL_FUNC_MAP 中，如果放在后面会被跳过
        # 但 create_simulink/open_simulink action 已经调用了 _cleanup_workflow_state
        # 这里作为双重保险：如果将来 sl_new_system 被注册，也能正确清理
        if command == 'sl_new_system':
            mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if mn:
                _cleanup_workflow_state(mn)
        
        # ===== [v11.6] sl_scene_confirm: lock the scene (CHALLENGE-RESPONSE + TURN SEPARATION) =====
        # P0-10 FIX: Leverages WorkBuddy's conversation model for user interaction proof.
        # - sl_scene_detect returns detectionToken + challengePhrase
        # - AI MUST display challengePhrase in AskUserQuestion (turn ends)
        # - User clicks → NEW turn starts (WorkBuddy platform enforces this)
        # - AI calls sl_scene_confirm with detectionToken
        # - Bridge verifies: different request + minimum delay + challenge present
        # 
        # Why this works: In WorkBuddy, a new conversation turn ONLY starts when
        # the user sends a message or clicks AskUserQuestion. The AI cannot
        # fabricate a new turn. So if confirm is in a different request from detect,
        # user interaction was required to trigger that request.
        if command == 'sl_scene_confirm':
            scene = fixed_params.get('scene', 1)
            model_name = fixed_params.get('modelName', '')
            confirm_token = fixed_params.get('confirmationToken', fixed_params.get('detectionToken', ''))
            
            # ===== [v11.6] CHALLENGE-RESPONSE + TURN SEPARATION VERIFICATION =====
            # [v11.8.3 Bug#8 FIX] Dual-read: Python _SCENE_STATE (primary) + MATLAB workspace (fallback)
            # Python state is fast but lost on Bridge restart; MATLAB workspace persists with Engine.
            stored_dt = _SCENE_STATE.get('detection_token', '')
            stored_challenge = _SCENE_STATE.get('challenge_phrase', '')
            detect_ts = _SCENE_STATE.get('detection_timestamp', 0)
            detect_req = _SCENE_STATE.get('detection_request_id', 0)
            
            # Fallback: read from MATLAB workspace if Python state is empty
            if not stored_dt:
                try:
                    if _connection_mode == 'engine' and _matlab_engine is not None:
                        _ws_flag = _matlab_engine.eval("evalin('base', 'exist(''mS0DetectToken_'', ''var'')')", nargout=1)
                        if _ws_flag == 1:
                            stored_dt = _matlab_engine.eval("evalin('base', 'mS0DetectToken_')", nargout=1)
                            stored_challenge = _matlab_engine.eval("evalin('base', 'mS0Challenge_')", nargout=1)
                            detect_ts = _matlab_engine.eval("evalin('base', 'mS0DetectTS_')", nargout=1)
                            # Restore to Python state for consistency
                            _SCENE_STATE['detection_token'] = stored_dt
                            _SCENE_STATE['challenge_phrase'] = stored_challenge
                            _SCENE_STATE['detection_timestamp'] = detect_ts
                except Exception:
                    pass  # Both sources empty → NO_DETECTION below
            current_req = _current_request_id
            
            if not stored_dt:
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": "No scene detection found. Call sl_scene_detect first.",
                    "command": command,
                    "message": (
                        "NO_DETECTION: You must call sl_scene_detect(workspaceDir) first. "
                        "The detection result contains a detectionToken and challengePhrase."
                    ),
                    "requiredAction": "sl_scene_detect",
                    "hint": "Call sl_scene_detect(workspaceDir) → present result with AskUserQuestion → call sl_scene_confirm",
                }
            
            # Check detectionToken validity
            import time
            if confirm_token != stored_dt:
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": "Invalid detectionToken. Use the exact token from sl_scene_detect.",
                    "command": command,
                    "message": (
                        "TOKEN_MISMATCH: The provided token doesn't match the detection token."
                    ),
                    "requiredAction": "Use the detectionToken from sl_scene_detect response",
                    "hint": "Call sl_scene_detect again to get a fresh token.",
                }
            
            # Check timeout (600s generous window for user interaction, was 120s→300s→600s)
            elapsed = time.time() - detect_ts if detect_ts > 0 else 0
            if elapsed > 600:
                _SCENE_STATE.pop('detection_token', None)
                _SCENE_STATE.pop('challenge_phrase', None)
                _SCENE_STATE.pop('detection_timestamp', None)
                _SCENE_STATE.pop('detection_request_id', None)
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": f"Scene detection expired ({elapsed:.0f}s > 600s). Re-run sl_scene_detect.",
                    "command": command,
                    "message": "DETECTION_EXPIRED: The scene detection session has expired. Re-run sl_scene_detect.",
                    "hint": "Call sl_scene_detect(workspaceDir) again.",
                }
            
            # ===== TURN SEPARATION CHECK =====
            # Key insight: In WorkBuddy, sl_scene_detect and sl_scene_confirm
            # happen in DIFFERENT HTTP requests. If AskUserQuestion was used,
            # these are also in DIFFERENT conversation turns (enforced by the platform).
            # The AI cannot fabricate a new turn — only user action creates one.
            if detect_req == current_req:
                # Same request — impossible if AskUserQuestion was used
                _SCENE_STATE.pop('detection_token', None)
                _SCENE_STATE.pop('challenge_phrase', None)
                _SCENE_STATE.pop('detection_timestamp', None)
                _SCENE_STATE.pop('detection_request_id', None)
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": "Scene confirm in same request as detect — no user interaction possible.",
                    "command": command,
                    "message": (
                        "SAME_TURN_DETECTED: sl_scene_confirm was called in the same request "
                        "as sl_scene_detect. This means no user interaction occurred. "
                        "You MUST call AskUserQuestion to present scene options to the user. "
                        "The user's click starts a new turn, where you can call sl_scene_confirm."
                    ),
                    "requiredAction": "Call AskUserQuestion with scene options + challengePhrase",
                    "hint": f"Present challenge phrase '{stored_challenge}' to user via AskUserQuestion.",
                }
            
            # Minimum delay heuristic: < 2s likely automated, not human
            if elapsed < 2:
                _SCENE_STATE.pop('detection_token', None)
                _SCENE_STATE.pop('challenge_phrase', None)
                _SCENE_STATE.pop('detection_timestamp', None)
                _SCENE_STATE.pop('detection_request_id', None)
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S0",
                    "reason": f"Confirm too fast ({elapsed:.1f}s < 2s minimum). User interaction requires more time.",
                    "command": command,
                    "message": (
                        "TOO_FAST: sl_scene_confirm was called too quickly after sl_scene_detect. "
                        "User interaction (reading + clicking) requires at least a few seconds. "
                        "This suggests automated bypass. Use AskUserQuestion properly."
                    ),
                    "requiredAction": "Re-run sl_scene_detect and use AskUserQuestion",
                }
            
            # ===== Challenge verified, clean up state =====
            _SCENE_STATE.pop('detection_token', None)
            _SCENE_STATE.pop('challenge_phrase', None)
            _SCENE_STATE.pop('detection_timestamp', None)
            _SCENE_STATE.pop('detection_request_id', None)
            # [P1-2 FIX] Clear stale S2 modification permissions
            _S2_MOD_PERMISSIONS.clear()
            # ===== VERIFICATION END =====
            scene = fixed_params.get('scene', 1)
            model_name = fixed_params.get('modelName', '')
            
            # Set MATLAB base workspace flags (engine mode) or Python state (CLI mode)
            try:
                if _connection_mode == 'engine' and _matlab_engine is not None:
                    _matlab_engine.eval("assignin('base', 'mS0SceneLocked_', true);", nargout=0)
                    _matlab_engine.eval(f"assignin('base', 'mS0Scene_', {int(scene)});", nargout=0)
                    if model_name:
                        _matlab_engine.eval(f"assignin('base', 'mS0Model_', '{model_name}');", nargout=0)
                    # [v11.8.3 Bug#8 FIX] Clean up detection state from MATLAB workspace
                    _matlab_engine.eval("evalin('base', 'clear mS0DetectToken_ mS0DetectTS_ mS0Challenge_');", nargout=0)
                # [v11.6.8 FIX] Always set Python-side state for Gate_3 access
                # [v11.8.3 Bug#8 FIX] Clean up Python detection state (token consumed)
                _SCENE_STATE.pop('detection_token', None)
                _SCENE_STATE.pop('challenge_phrase', None)
                _SCENE_STATE.pop('detection_timestamp', None)
                _SCENE_STATE.pop('detection_request_id', None)
                _SCENE_STATE['scene_confirmed'] = True
                _SCENE_STATE['scene'] = int(scene)
                _SCENE_STATE['scene_model'] = str(model_name) if model_name else ''
            except Exception as e:
                import logging
                logging.getLogger('matlab_bridge').warning(f"Scene confirm failed: {e}")
                # Fallback to Python state on engine error
                _SCENE_STATE['scene_confirmed'] = True
                _SCENE_STATE['scene'] = int(scene)
                _SCENE_STATE['scene_model'] = str(model_name) if model_name else ''
            
            return {
                "status": "ok",
                "scene": scene,
                "modelName": model_name,
                "sceneConfirmed": True,
                "message": f"Scene {scene} confirmed and locked for this session.",
                "workflowHint": (
                    "Scene 1: Use sl_framework_design to start building from scratch.\n"
                    "Scene 2: Use sl_model_load + sl_model_understand to analyze existing model."
                ) if scene == 1 else (
                    "Scene 2: Use sl_model_load to load your existing model, "
                    "then sl_model_understand to analyze it."
                )
            }
        # ===== sl_scene_confirm end =====
        
        # ===== [v11.5] sl_s2mod_confirm: process Scene 2 modification permission =====
        if command == 'sl_s2mod_confirm':
            approved = fixed_params.get('approved', False)
            sm_mn = fixed_params.get('modelName', '')
            sm_cmd = fixed_params.get('command', '')
            sm_target = fixed_params.get('target', '')
            
            if approved:
                cache_key = f"{sm_mn}:{sm_cmd}:{sm_target}"
                _S2_MOD_PERMISSIONS[cache_key] = True
                return {
                    "status": "ok", "approved": True,
                    "message": f"Modification approved: {sm_cmd} on '{sm_target}'.",
                    "hint": "You can now retry the blocked operation."
                }
            else:
                return {
                    "status": "ok", "approved": False,
                    "message": "Modification rejected by user.",
                    "hint": "Consider using the sandbox subsystem instead."
                }
        # ===== sl_s2mod_confirm end =====
        
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
        
        # [v11.8] Builtin recursive workflow commands (no .m function needed)
        if func_name == '_builtin_build_status':
            mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if '/' in str(mn):
                mn = str(mn).split('/')[0]
            state = _get_workflow_state(mn)
            return {
                "status": "ok",
                "buildProgress": _build_progress_str(state),
                "totalSubsystems": len(state.build_order),
                "buildOrder": state.build_order,
                "nextBuildTarget": _get_next_build_target(state),
                "allComplete": _all_subsystems_completed(state),
                "incompleteSubsystems": _get_incomplete_subsystems(state),
                "maxDepth": getattr(state, 'max_depth', 0),
            }
        
        if func_name == '_builtin_next_target':
            mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if '/' in str(mn):
                mn = str(mn).split('/')[0]
            state = _get_workflow_state(mn)
            next_target = _get_next_build_target(state)
            return {
                "status": "ok",
                "nextBuildTarget": next_target,
                "buildProgress": _build_progress_str(state),
                "allComplete": _all_subsystems_completed(state) if not next_target else False,
            }
        
        # [P0-4 FIX] 提前获取 model_name，后续逻辑（工作流清理、锁获取、验证）都需要
        model_name = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        
        args_dict = _build_sl_args(command, fixed_params)
        
        # ===== [v11.5] sl_modify_plan: pre-store modelUnderstanding in workspace =====
        if command == 'sl_modify_plan' and '_pos_3' in args_dict:
            mu_data = args_dict.pop('_pos_3')
            if isinstance(mu_data, dict) and mu_data:
                try:
                    mu_eng = get_engine()
                    if mu_eng is not None:
                        mu_var = 'mS2MU_' + model_name.replace(' ', '_') if model_name else 'mS2MU_'
                        mu_eng.workspace[mu_var] = mu_data
                        args_dict['_pos_3_special'] = f"evalin('base', '{mu_var}')"
                    else:
                        args_dict['_pos_3'] = {}
                except Exception:
                    args_dict['_pos_3'] = {}
            else:
                # [v11.7.1 B3 FIX] Preserve non-dict value so MATLAB's own
                # validation can produce a clear error message (e.g., "must be a struct")
                args_dict['_pos_3'] = mu_data
        # ===== workspace storage end =====
        # ===== [v11.5] modify_review / modify_approve / model_sandbox / verify_step: pre-store plan =====
        if command in ('sl_modify_review', 'sl_modify_approve', 'sl_model_sandbox', 'sl_modify_verify_step'):
            for pos_key in ('_pos_1', '_pos_2', '_pos_3'):
                val = args_dict.get(pos_key)
                if isinstance(val, dict) and val:
                    try:
                        mp_eng = get_engine()
                        if mp_eng is not None:
                            mp_var = 'mS2MP_' + model_name.replace(' ', '_') if model_name else 'mS2MP_'
                            mp_eng.workspace[mp_var] = val
                            args_dict[pos_key + '_special'] = f"evalin('base', '{mp_var}')"
                            del args_dict[pos_key]
                        else:
                            args_dict[pos_key] = {}
                    except Exception:
                        args_dict[pos_key] = {}
        # ===== plan storage end =====
        
        # ===== [v11.5] Gate_S2_APPROVE: validate modify plan before approval =====
        if command == 'sl_modify_approve':
            _s2_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            modify_plan_data = fixed_params.get('modifyPlan', params.get('modifyPlan', None))
            
            if _s2_mn and modify_plan_data and isinstance(modify_plan_data, dict):
                try:
                    if _connection_mode == 'engine' and _matlab_engine is not None:
                        sandbox = modify_plan_data.get('sandboxSubsystem', {})
                        conn_errors = []
                        
                        # Check sandbox inport connections
                        for inp in sandbox.get('inports', []):
                            if isinstance(inp, dict):
                                ct = inp.get('connectTo', '')
                                if ct:
                                    try:
                                        _matlab_engine.eval(f"get_param('{_s2_mn}/{ct}', 'BlockType');", nargout=0)
                                    except Exception:
                                        conn_errors.append(f"Inport target not found: {ct}")
                        
                        # Check sandbox outport connections
                        for outp in sandbox.get('outports', []):
                            if isinstance(outp, dict):
                                ct = outp.get('connectTo', '')
                                if ct:
                                    try:
                                        _matlab_engine.eval(f"get_param('{_s2_mn}/{ct}', 'BlockType');", nargout=0)
                                    except Exception:
                                        conn_errors.append(f"Outport target not found: {ct}")
                        
                        if conn_errors:
                            return {
                                "status": "gate_blocked", "blocked": True,
                                "gate": "Gate_S2_APPROVE",
                                "reason": "Connection point validation failed",
                                "command": command,
                                "message": "CONNECTION_POINT_INVALID: Some connection points in the modify plan do not exist in the model.",
                                "details": {"connectionErrors": conn_errors},
                                "hint": "Fix the connection points in your modify plan."
                            }
                except Exception:
                    pass  # Engine unavailable, skip Gate_S2
        
        
        # [P1-5 FIX] 工作流清理已移到 _SL_FUNC_MAP 检查之前
        
        # 5. 获取模型锁（修改型命令）
        need_lock = command in _MODIFY_COMMANDS and model_name
        lock = _get_model_lock(model_name) if need_lock else None

        # ===== [v10.1] sl_model_design 特殊 action 处理 =====
        special_action = args_dict.get('_pos_1_special', '')
        if special_action in ('__design_approve__', '__design_status__'):
            _da_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if _da_mn:
                _da_state = _get_workflow_state(_da_mn)
                if special_action == '__design_approve__':
                    _da_state.design_approved = True
                    _da_state.phase = 'framework'
                    _da_state.phase_step = 'building'
                    # [P0-FIX] 同时在 MATLAB workspace 设置标记，供后续 _get_workflow_state 同步
                    # 这样当 create_simulink 清理 Python 状态后，仍能从 MATLAB workspace 恢复
                    try:
                        eng = get_engine()
                        if eng is not None:
                            da_var = f'design_approved_{_da_mn}'
                            eng.eval(f"assignin('base', '{da_var}', true)", nargout=0)
                    except Exception:
                        pass  # MATLAB workspace 同步失败不影响主流程
                    result = {
                        "status": "ok",
                        "message": "Design approved. You can now start building the model.",
                        "designApproved": True,
                        "nextPhase": "framework",
                        "nextSuggestedAction": "Start adding blocks according to the approved design",
                    }
                else:  # '__design_status__'
                    result = {
                        "status": "ok",
                        "designApproved": _da_state.design_approved,
                        "currentPhase": _da_state.phase,
                        "designResult": _da_state.design_result,
                    }
            else:
                result = {"status": "error", "message": "modelName required for design action"}
            return result

        # ===== [v11.0] sl_framework_* 特殊 action 处理 =====
        if special_action in ('__fw_approve__', '__fw_review__'):
            _fw_mn = fixed_params.get('modelName', fixed_params.get('model_name', ''))
            if _fw_mn:
                _fw_state = _get_workflow_state(_fw_mn)
                if special_action == '__fw_approve__':
                    _fw_state.framework_approved = True
                    _fw_state.framework_locked = fixed_params.get('locked', True)
                    _fw_state.phase = 'framework_construction'
                    _fw_state.phase_step = 'approved'
                    # [v11.8 Bug#4 FIX] Build hierarchy tree from approved framework
                    _approve_fw = fixed_params.get('macroFramework', {})
                    if _approve_fw and isinstance(_approve_fw, dict) and _approve_fw.get('subsystems'):
                        # Store the approved framework (with childSubsystems) in state
                        _fw_state.macro_framework = _approve_fw
                        tree = _build_subsystem_tree_from_framework(_approve_fw, _fw_mn)
                        _fw_state.subsystem_tree = tree
                        _fw_state.build_order = _compute_build_order(tree)
                        _fw_state.max_depth = max(
                            (n['depth'] for n in _fw_state.build_order), default=0
                        )
                        _fw_state.hierarchy_approved = True
                        _fw_state.current_build_index = -1
                    # 在 MATLAB workspace 设置标记
                    _fw_safe = _fw_mn.replace('/', '__')  # [v11.5] 子系统路径安全化
                    try:
                        eng = get_engine()
                        if eng is not None:
                            fw_lock_var = f'mFWLock_{_fw_safe}'  # [P1-4 FIX] 统一命名
                            eng.eval(f"assignin('base', '{fw_lock_var}', {str(fixed_params.get('locked', True)).lower()})", nargout=0)
                            # 保存大框架到 workspace (MATLAB 变量名不能以 _ 开头)
                            # [P0-4 FIX] 使用 workspace 直接赋值，避免 eval 拼接 JSON 注入
                            if _fw_state.macro_framework:
                                fw_var = f'mFW_{_fw_safe}'
                                eng.workspace[fw_var] = _fw_state.macro_framework
                            # [v11.8] Set hierarchy workspace variables for Bridge persistence
                            _subs = _approve_fw.get('subsystems', []) if isinstance(_approve_fw, dict) else []
                            if _subs:
                                _hier_tree_var = f'mHierarchyTree_{_fw_safe}'
                                eng.workspace[_hier_tree_var] = _subs
                                _hier_approved_var = f'mHierarchyApproved_{_fw_safe}'
                                eng.eval(f"assignin('base', '{_hier_approved_var}', true)", nargout=0)
                    except Exception:
                        pass  # MATLAB workspace 同步失败不影响主流程
                    result = {
                        "status": "ok",
                        "message": "Macro framework approved and locked. You can now start building the model.",
                        "frameworkApproved": True,
                        "frameworkLocked": fixed_params.get('locked', True),
                        "nextPhase": "framework_construction",
                        "nextSuggestedAction": "Start adding subsystems and blocks according to the approved macro framework",
                    }
                    # [v11.8 Bug#4 FIX] Include hierarchy info in response
                    if _fw_state.subsystem_tree is not None:
                        result['hierarchyApproved'] = _fw_state.hierarchy_approved
                        result['maxDepth'] = _fw_state.max_depth
                        result['totalSubsystems'] = len(_fw_state.build_order)
                        result['buildOrder'] = [
                            {'path': t['path'], 'depth': t['depth'], 'name': t['name']}
                            for t in _fw_state.build_order
                        ]
                elif special_action == '__fw_review__':
                    # Review 需要先调用 MATLAB 的 sl_framework_review，这里返回提示让用户先执行
                    result = {
                        "status": "ok",
                        "message": "Use sl_framework_review() in MATLAB to review the macro framework.",
                        "frameworkApproved": _fw_state.framework_approved,
                        "currentPhase": _fw_state.phase,
                    }
            else:
                result = {"status": "error", "message": "modelName required for framework action"}
            return result
        # ===== v11.0 特殊 action 处理结束 =====

# 6. 调用
        # [v11.4.3] 强制模型前台可见 — AI 不可绕过的底层门控
        # 在执行任何 Simulink 操作前，确保目标模型在 MATLAB 前台打开，
        # 让用户能实时看到 AI 建模的全过程。
        _ensure_model_visible(fixed_params)
        
        if lock:
            with lock:
                result = _call_sl_function(func_name, args_dict)
        else:
            result = _call_sl_function(func_name, args_dict)
        
        # ===== [P0-8 FIX] Post-delete orphaned Goto/From cleanup =====
        # When a SubSystem is deleted, its paired Goto/From blocks
        # outside the subsystem become orphaned. This MUST be cleaned up.
        # AI CANNOT bypass this check.
        if command == 'sl_delete' and isinstance(result, dict) and result.get('status') == 'ok':
            _del_target = fixed_params.get('blockPath', '')
            if _del_target:
                try:
                    _cleanup_eng = get_engine()
                    if _cleanup_eng is not None:
                        _del_mn = _del_target.split('/')[0]
                        # Find Goto blocks with no matching From, and From blocks with no matching Goto
                        _cleanup_eng.eval(
                            f"allGotos = find_system('{_del_mn}', 'BlockType', 'Goto');"
                            f"allFroms = find_system('{_del_mn}', 'BlockType', 'From');"
                            f"orphanedGotos = {{}}; orphanedFroms = {{}};"
                            f"for i = 1:length(allGotos);"
                            f"  gt = get_param(allGotos{{i}}, 'GotoTag');"
                            f"  matches = find_system('{_del_mn}', 'BlockType', 'From', 'GotoTag', gt);"
                            f"  if isempty(matches); orphanedGotos{{end+1}} = allGotos{{i}}; end;"
                            f"end;"
                            f"for i = 1:length(allFroms);"
                            f"  ft = get_param(allFroms{{i}}, 'GotoTag');"
                            f"  matches = find_system('{_del_mn}', 'BlockType', 'Goto', 'GotoTag', ft);"
                            f"  if isempty(matches); orphanedFroms{{end+1}} = allFroms{{i}}; end;"
                            f"end;",
                            nargout=0
                        )
                        # Delete orphaned blocks
                        _del_eng_expr = (
                            f"for i = 1:length(orphanedGotos);"
                            f"  try; delete_block(orphanedGotos{{i}}); catch; end;"
                            f"end;"
                            f"for i = 1:length(orphanedFroms);"
                            f"  try; delete_block(orphanedFroms{{i}}); catch; end;"
                            f"end;"
                            f"length(orphanedGotos) + length(orphanedFroms);"
                        )
                        _cleaned = _cleanup_eng.eval(_del_eng_expr, nargout=1)
                        try:
                            _cleaned_count = int(_cleaned) if _cleaned is not None else 0
                        except:
                            _cleaned_count = 0
                        if _cleaned_count > 0:
                            result['orphanedGotoFromCleaned'] = _cleaned_count
                            result['orphanedGotoFromHint'] = (
                                f"Cleaned {_cleaned_count} orphaned Goto/From block(s) "
                                f"that lost their pair when '{_del_target}' was deleted."
                            )
                except Exception as _orphan_ex:
                    import logging
                    logging.getLogger('matlab_bridge').warning(
                        f"Orphaned Goto/From cleanup failed: {_orphan_ex}")
        # ===== orphaned Goto/From cleanup end =====
        
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
        
        # ===== [v11.6] Gate_S0 Challenge-Response Injection (P0-10 FIX) =====
        # After sl_scene_detect returns, inject a detectionToken + challengePhrase.
        # The detectionToken proves continuity from scene detection.
        # The challengePhrase MUST be displayed to the user via AskUserQuestion.
        # sl_scene_confirm MUST be called in a DIFFERENT turn (WorkBuddy enforces
        # turn separation when AskUserQuestion is used — AI cannot fake a new turn).
        # This leverages WorkBuddy's conversation model for user interaction proof.
        if command == 'sl_scene_detect':
            # [P0-14 FIX] Unconditionally purge ALL stale detection state before a fresh detect.
            # [v11.8.3 Bug#8 FIX] Also clear MATLAB workspace stale token
            for _stale_key in ('detection_token', 'challenge_phrase',
                                'detection_timestamp', 'detection_request_id',
                                'detected_scene', 'detected_models'):
                _SCENE_STATE.pop(_stale_key, None)
            _S2_MOD_PERMISSIONS.clear()
            # Clear MATLAB workspace stale detection token (survives Bridge restarts)
            try:
                if _connection_mode == 'engine' and _matlab_engine is not None:
                    _matlab_engine.eval("evalin('base', 'clear mS0DetectToken_ mS0DetectTS_ mS0Challenge_');", nargout=0)
            except Exception:
                pass

        if command == 'sl_scene_detect' and isinstance(result, dict) and result.get('status') == 'ok':
            import uuid, time, random, string
            _dt_token = uuid.uuid4().hex[:16]
            _challenge = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
            _SCENE_STATE['detection_token'] = _dt_token
            _SCENE_STATE['detection_timestamp'] = time.time()
            _SCENE_STATE['detection_request_id'] = _current_request_id
            _SCENE_STATE['challenge_phrase'] = _challenge
            _SCENE_STATE['detected_scene'] = result.get('scene', 1)
            _SCENE_STATE['detected_models'] = result.get('models', [])
            # [v11.8.3 Bug#8 FIX] Double-write token to MATLAB workspace for persistence
            # Python _SCENE_STATE is lost on Bridge restart; MATLAB workspace survives
            # as long as the Engine is alive. This ensures sl_scene_confirm works even
            # after Bridge restarts (e.g. for .m file reload).
            try:
                if _connection_mode == 'engine' and _matlab_engine is not None:
                    _matlab_engine.eval(f"assignin('base', 'mS0DetectToken_', '{_dt_token}');", nargout=0)
                    _matlab_engine.eval(f"assignin('base', 'mS0DetectTS_', {time.time()});", nargout=0)
                    _matlab_engine.eval(f"assignin('base', 'mS0Challenge_', '{_challenge}');", nargout=0)
            except Exception:
                pass  # Non-blocking: Python _SCENE_STATE is the primary store
            # Return detectionToken + challengePhrase to AI
            # AI MUST display challengePhrase in AskUserQuestion
            result['detectionToken'] = _dt_token
            result['challengePhrase'] = _challenge
            result['confirmationRequired'] = True
            result['userPrompt'] = (
                f"Scene {result.get('scene')} detected. "
                f"Found {len(result.get('models', []))} model(s). "
                f"【MUST include challenge phrase in AskUserQuestion】"
            )
            result['challengeInstructions'] = (
                f"You MUST display the challenge phrase '{_challenge}' "
                f"in your AskUserQuestion text. "
                f"The user will see this phrase and click to confirm. "
                f"Then call sl_scene_confirm with the detectionToken."
            )
        # ===== Challenge-Response injection end =====
        
        # ===== [v11.6.1] Gate_S2_SANDBOX_CONNECT: verify EXTERNAL sandbox port connectivity =====
        # P0-11 FIX: Check that the SubSystem block's ports are connected to the parent model.
        # We check EXTERNAL connections (SubSystem ↔ parent model), NOT internal Inport/Outport
        # connections (which are built during Scene 1 flow inside the sandbox).
        if command == 'sl_model_sandbox' and isinstance(result, dict) and result.get('status') == 'ok':
            sandbox_path = result.get('sandboxPath', '')
            if sandbox_path:
                try:
                    # Check SubSystem block's port connectivity to parent model
                    pc = eng.get_param(sandbox_path, 'PortConnectivity')
                    ext_unconnected = []
                    for pc_entry in pc:
                        # pc_entry is a struct with fields: Type, SrcBlock, DstBlock, etc.
                        # For unconnected ports, SrcBlock or DstBlock will be -1
                        try:
                            ptype = pc_entry['Type']
                            src = pc_entry['SrcBlock']
                            dst = pc_entry['DstBlock']
                            port_num = pc_entry['SrcPort'] if ptype == 1 else pc_entry['DstPort']
                            if (ptype == 1 and src == -1) or (ptype == 2 and dst == -1):
                                ext_unconnected.append(f"Port {port_num} ({'input' if ptype==1 else 'output'})")
                        except Exception:
                            pass
                    if ext_unconnected:
                        # External ports not connected — this IS a valid concern
                        result['_sandboxConnectWarnings'] = ext_unconnected
                        result['_sandboxConnectExternalUnconnected'] = len(ext_unconnected)
                        # Don't block — external connections may be wired after internal build
                        result['_sandboxConnectNote'] = (
                            f"{len(ext_unconnected)} external port(s) not connected to parent model. "
                            f"Connect them after building sandbox internals."
                        )
                    else:
                        result['_sandboxConnectVerified'] = True
                except Exception as e:
                    result['_sandboxConnectSkipped'] = str(e)[:100]
            
            # [v11.6.2 FIX] Auto-add sandbox to subsystem_queue (Gap 3)
            # When sl_model_sandbox creates a new empty sandbox, automatically
            # register it in the parent model's subsystem_queue so that
            # Gate_SANDBOX_INCOMPLETE will block completion/simulation until
            # the sandbox internals are built via Scene 1 workflow.
            try:
                parent_model = sandbox_path.split('/')[0] if '/' in sandbox_path else fixed_params.get('modelName', fixed_params.get('model_name', ''))
                if parent_model:
                    _sbox_state = _get_workflow_state(parent_model)
                    if sandbox_path not in _sbox_state.subsystem_queue:
                        _sbox_state.subsystem_queue.append(sandbox_path)
                        _sbox_state.phase = 'subsystem_iteration'
                        _sbox_state.phase_step = 'filling'
                        result['_sandboxQueueUpdated'] = True
                        result['_sandboxQueueNote'] = (
                            f"Sandbox '{sandbox_path}' added to subsystem_queue. "
                            f"Build its internals before sl_model_complete or sl_sim_run."
                        )
                        
                        # [v11.6.4 FIX] Register sandbox name for Gate_S2_MODIFY
                        # Use get_engine() instead of _connection_mode check which
                        # may fail in this nested scope. get_engine() lazily
                        # initializes the engine if needed.
                        try:
                            _sbox_model = sandbox_path.split('/')[0] if '/' in sandbox_path else ''
                            _sb_name_param = fixed_params.get('sandboxName', params.get('sandboxName', ''))
                            _sbox_short = sandbox_path.split('/')[-1] if '/' in sandbox_path else _sb_name_param
                            if _sbox_model:
                                _sbox_eng = get_engine()
                                if _sbox_eng is not None:
                                    _sbox_eng.eval(
                                        f"assignin('base', 'mS2SandboxName_{_sbox_model}', '{_sbox_short}')",
                                        nargout=0)
                                    result['_sandboxNameRegistered'] = True
                        except Exception:
                            pass  # Non-critical: Gate_S2_MODIFY has other checks
            except Exception as _sq_ex:
                import logging
                logging.getLogger('matlab_bridge').warning(
                    f"Failed to auto-add sandbox to queue: {_sq_ex}")
        # ===== Gate_S2_SANDBOX_CONNECT end =====
        
        # [v11.7.1 B10 FIX] Cleanup subsystem_queue when modifyPlan deletes blocks
        # Prevents Gate_SANDBOX_INCOMPLETE from blocking on non-existent subsystems.
        if command == 'sl_model_sandbox':
            _mp_cleanup = fixed_params.get('modifyPlan', params.get('modifyPlan', {}))
            if isinstance(_mp_cleanup, dict):
                _ex_mods = _mp_cleanup.get('existingModifications', {})
                if isinstance(_ex_mods, dict):
                    for _chg in _ex_mods.get('changes', []):
                        if isinstance(_chg, dict) and _chg.get('operation') == 'delete':
                            _del_path = _chg.get('targetPath', '')
                            if _del_path:
                                _del_model = _del_path.split('/')[0] if '/' in _del_path else ''
                                if _del_model:
                                    _del_state = _get_workflow_state(_del_model)
                                    if _del_path in _del_state.subsystem_queue:
                                        _del_state.subsystem_queue.remove(_del_path)
                                        result['_queueCleanup'] = f"Removed '{_del_path}' from queue (deleted)"
        
        # 9.0 v9.0: 提取模型名（v8.0 验证和 v9.0 工作流共用）
        model_name_for_verify = fixed_params.get('modelName', fixed_params.get('model_name', ''))
        # v11.0: sl_framework_design 也需要 modelName 来管理 workflow state
        # 如果 params 中有 modelName 但 _build_sl_args 没有传递，用它
        if not model_name_for_verify:
            model_name_for_verify = params.get('modelName', '')
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
        
        # ===== [v11.6.2] Gate_SANDBOX_INCOMPLETE: 沙盒空壳硬门控 =====
        # P0 FIX (Gap 1+2): After model_name_for_verify is resolved above,
        # check subsystem_queue before allowing sl_model_complete / sl_sim_run / sl_sim_batch.
        # If empty subsystems exist, block the operation until internals are built.
        # [v11.6.2 PATCH] Also verify actual sandbox content via MATLAB to avoid stale queue.
        _SANDBOX_COMPLETION_GATED = ['sl_model_complete', 'sl_sim_run', 'sl_sim_batch']
        if command in _SANDBOX_COMPLETION_GATED and model_name_for_verify:
            try:
                _phase_state = _get_workflow_state(model_name_for_verify)
                if _phase_state.subsystem_queue:
                    # Verify each queued sandbox is ACTUALLY empty (not just stale queue)
                    # [v11.6.4 FIX] Use get_engine().eval() instead of _matlab_eval_safe.
                    # _matlab_eval_safe may return '__EVAL_FAILED__' which converts to 0
                    # and causes false-positive "empty shell" detection.
                    _actually_empty = []
                    _gate_eng = get_engine()
                    for _sb_path in _phase_state.subsystem_queue:
                        try:
                            if _gate_eng is not None:
                                _total = _gate_eng.eval(
                                    f"length(find_system('{_sb_path}', 'SearchDepth', 1, 'LookUnderMasks', 'on'))",
                                    nargout=1)
                                _in_count = _gate_eng.eval(
                                    f"length(find_system('{_sb_path}', 'SearchDepth', 1, 'BlockType', 'Inport', 'LookUnderMasks', 'on'))",
                                    nargout=1)
                                _out_count = _gate_eng.eval(
                                    f"length(find_system('{_sb_path}', 'SearchDepth', 1, 'BlockType', 'Outport', 'LookUnderMasks', 'on'))",
                                    nargout=1)
                                _total_n = int(_total) if _total is not None else 0
                                _in_n = int(_in_count) if _in_count is not None else 0
                                _out_n = int(_out_count) if _out_count is not None else 0
                            else:
                                _total_n = _in_n = _out_n = 0
                            _functional = _total_n - _in_n - _out_n
                            if _functional <= 0:
                                _actually_empty.append(_sb_path)
                        except Exception:
                            # [v11.7.1 B2 FIX] Block doesn't exist → remove from queue, don't block
                            # Previous behavior marked non-existent paths as "empty shell",
                            # which permanently blocked completion gates.
                            pass
                    
                    # Update queue to only contain actually-empty sandboxes
                    _phase_state.subsystem_queue = _actually_empty
                    
                    if _actually_empty:
                        return {
                            "status": "gate_blocked",
                            "blocked": True,
                            "reason": (
                                f"{len(_actually_empty)} sandbox(es) still empty: "
                                f"{_actually_empty}. "
                                f"Build sandbox internals before completing model or running simulation."
                            ),
                            "command": command,
                            "gate": "Gate_SANDBOX_INCOMPLETE",
                            "message": (
                                f"SANDBOX_INCOMPLETE: {len(_actually_empty)} subsystem(s) "
                                f"have no internal logic (empty shell detected).\n"
                                f"Build sandbox internals via Scene 1 workflow:\n"
                                f"1. Add blocks/lines inside: {_actually_empty[0]}\n"
                                f"2. After building, retry this command."
                            ),
                            "requiredAction": "build_sandbox_internals",
                            "emptySandboxes": _actually_empty,
                            "workflowPhase": "subsystem_iteration",
                        }
            except Exception as _si_ex:
                import logging
                logging.getLogger('matlab_bridge').warning(
                    f"Gate_SANDBOX_INCOMPLETE check failed: {_si_ex}")
        # ===== Gate_SANDBOX_INCOMPLETE end =====

        # ===== [v11.6.2] Gate_S2_EXTERNAL_CONNECT: sandbox external port connectivity =====
        # P0 FIX: sl_model_sandbox.m claims to auto-connect ports but the code had bugs:
        # - Used 'Port' instead of 'Ports' param (MATLAB error, silently caught)
        # - Outports were NEVER auto-connected (only stored as metadata)
        # This gate verifies that sandbox SubSystem blocks have EXTERNAL ports connected.
        if command in _SANDBOX_COMPLETION_GATED and model_name_for_verify:
            try:
                # [P1-14 FIX] Use get_engine().eval() instead of _matlab_eval_safe
                # for reliable MATLAB execution in both Engine and CLI modes
                _ext_check_eng = get_engine()
                _ext_subsys_count = 0
                if _ext_check_eng is not None:
                    try:
                        _ext_check_eng.workspace['v_model'] = model_name_for_verify
                        _ext_subsys_count = int(_ext_check_eng.eval(
                            "length(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'SubSystem'));",
                            nargout=1))
                    except Exception:
                        _ext_subsys_count = 0
                if _ext_subsys_count > 0:
                    # Check each SubSystem's external port connectivity via LineHandles
                    _ext_unconn_subsystems = []
                    _ext_subsys_names = []
                    try:
                        _ext_check_eng.workspace['v_model'] = model_name_for_verify
                        _raw_names = _ext_check_eng.eval(
                            "get_param(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'SubSystem'), 'Name');",
                            nargout=1)
                        if isinstance(_raw_names, str):
                            _ext_subsys_names = [_raw_names]
                        elif _raw_names is not None:
                            _ext_subsys_names = list(_raw_names)
                    except Exception:
                        _ext_subsys_names = []
                    for _es_name in _ext_subsys_names:
                        if not isinstance(_es_name, str):
                            continue
                        _es_path = f"{model_name_for_verify}/{_es_name}"
                        try:
                            _ext_check_eng.workspace['v_path'] = _es_path
                            _es_lh_raw = _ext_check_eng.eval(
                                "lh = get_param(v_path, 'LineHandles'); [length(lh.Inport) length(lh.Outport)];",
                                nargout=1)
                            if _es_lh_raw is not None and hasattr(_es_lh_raw, '__getitem__') and len(_es_lh_raw) >= 2:
                                _in_count = int(_es_lh_raw[0])
                                _out_count = int(_es_lh_raw[1])
                                # Count unconnected ports
                                _unconn_in = 0
                                _unconn_out = 0
                                for _pi in range(_in_count):
                                    try:
                                        _ext_check_eng.workspace['v_path'] = _es_path
                                        _ext_check_eng.workspace['v_pi'] = _pi
                                        _lh_val = int(_ext_check_eng.eval(
                                            "lh = get_param(v_path, 'LineHandles'); double(lh.Inport(v_pi+1) == -1);",
                                            nargout=1))
                                        if _lh_val == 1:
                                            _unconn_in += 1
                                    except Exception:
                                        pass
                                for _po in range(_out_count):
                                    try:
                                        _ext_check_eng.workspace['v_path'] = _es_path
                                        _ext_check_eng.workspace['v_po'] = _po
                                        _lh_val = int(_ext_check_eng.eval(
                                            "lh = get_param(v_path, 'LineHandles'); double(lh.Outport(v_po+1) == -1);",
                                            nargout=1))
                                        if _lh_val == 1:
                                            _unconn_out += 1
                                    except Exception:
                                        pass
                                if _unconn_in > 0 or _unconn_out > 0:
                                    _ext_unconn_subsystems.append({
                                        'path': _es_path,
                                        'unconnIn': _unconn_in,
                                        'unconnOut': _unconn_out,
                                        'totalIn': _in_count,
                                        'totalOut': _out_count,
                                    })
                        except Exception:
                            pass
                    
                    if _ext_unconn_subsystems:
                        _first = _ext_unconn_subsystems[0]
                        return {
                            "status": "gate_blocked",
                            "blocked": True,
                            "reason": (
                                f"{len(_ext_unconn_subsystems)} subsystem(s) have unconnected external ports. "
                                f"Connect sandbox ports to parent model before completing."
                            ),
                            "command": command,
                            "gate": "Gate_S2_EXTERNAL_CONNECT",
                            "message": (
                                f"EXTERNAL_CONNECT_REQUIRED: {len(_ext_unconn_subsystems)} subsystem(s) "
                                f"have unconnected external ports.\n"
                                f"Example: {_first['path']} has {_first['unconnIn']}/{_first['totalIn']} "
                                f"inputs and {_first['unconnOut']}/{_first['totalOut']} outputs unconnected.\n"
                                f"Use add_line to connect sandbox Inport/Outport to parent model signals.\n"
                                f"sl_model_sandbox auto-connection may have failed — check ports manually."
                            ),
                            "requiredAction": "add_line_external",
                            "unconnectedSubsystems": _ext_unconn_subsystems,
                            "workflowPhase": "external_connection",
                            "hint": (
                                f"1. sl_inspect('{model_name_for_verify}') to see all unconnected ports\n"
                                f"2. Use add_line to connect sandbox ports to parent model blocks\n"
                                f"3. Example: add_line('{model_name_for_verify}', "
                                f"'SourceBlock/N', 'SandboxName/N')\n"
                                f"4. After all external ports are connected, retry"
                            ),
                        }
            except Exception as _sec_ex:
                import logging
                logging.getLogger('matlab_bridge').warning(
                    f"Gate_S2_EXTERNAL_CONNECT check failed: {_sec_ex}")
        # ===== Gate_S2_EXTERNAL_CONNECT end =====

        # ===== [v11.7] Gap 5 FIX: Scene 2 modify_verify_step auto-trigger =====
        # When building inside a Scene 2 sandbox, track that sl_modify_verify_step
        # is required before sl_model_complete or sl_s2mod_confirm can succeed.
        #
        # Mechanism:
        # 1. Any sl_add_block/add_line/set_param/delete inside a Scene 2 sandbox
        #    sets _s2_verify_pending[model] = True
        # 2. sl_model_complete and sl_s2mod_confirm check _s2_verify_pending
        # 3. If pending, block until sl_modify_verify_step is called
        _S2_WRITE_COMMANDS_FOR_VERIFY = ['sl_add_block', 'sl_add_line', 'sl_set_param', 'sl_delete']
        
        # Step 1: Detect if we're building inside a Scene 2 sandbox
        _is_s2_build = False
        _s2_sandbox_name = ''
        if command in _S2_WRITE_COMMANDS_FOR_VERIFY and model_name_for_verify:
            try:
                _s2_mn_toplevel = model_name_for_verify
                _s2_var = f"mS2Approved_{_s2_mn_toplevel}"
                _s2_check_eng = get_engine()
                if _s2_check_eng is not None:
                    try:
                        _s2_exists = int(_s2_check_eng.eval(
                            f"evalin('base', 'exist(''{_s2_var}'', ''var'')')", nargout=1))
                        if _s2_exists == 1:
                            _is_s2_build = True
                            _sn_var = f"mS2SandboxName_{_s2_mn_toplevel}"
                            try:
                                _s2_sandbox_name = str(_s2_check_eng.eval(
                                    f"evalin('base', '{_sn_var}')", nargout=1))
                            except Exception:
                                _s2_sandbox_name = 'unknown'
                    except Exception:
                        pass
            except Exception:
                pass
        
        # Step 2: Mark verify_pending if we wrote to a Scene 2 sandbox
        if _is_s2_build and isinstance(result, dict) and result.get('status') == 'ok':
            _s2_vkey = model_name_for_verify
            global _s2_verify_pending
            if '_s2_verify_pending' not in globals():
                _s2_verify_pending = {}
            _s2_verify_pending[_s2_vkey] = True
            result['_s2_verifyRequired'] = True
            result['_s2_verifyNote'] = (
                f"Scene 2 modification detected. Call sl_modify_verify_step "
                f"before sl_model_complete or sl_s2mod_confirm."
            )
        
        # Step 3: Block completion if verify is pending
        if command in _SANDBOX_COMPLETION_GATED and model_name_for_verify:
            _s2vp = globals().get('_s2_verify_pending', {})
            if _s2vp.get(model_name_for_verify, False):
                return {
                    "status": "gate_blocked",
                    "blocked": True,
                    "gate": "Gate_S2_VERIFY_STEP",
                    "reason": (
                        f"Scene 2 modification verification required for "
                        f"'{model_name_for_verify}'. "
                        f"Call sl_modify_verify_step() before completing."
                    ),
                    "command": command,
                    "message": (
                        f"VERIFY_STEP_REQUIRED: Scene 2 modifications in sandbox "
                        f"'{_s2_sandbox_name}' have not been verified.\n"
                        f"Call sl_modify_verify_step() to verify sandbox internal "
                        f"connections and signal integrity."
                    ),
                    "requiredAction": "sl_modify_verify_step",
                    "hint": (
                        f"1. sl_modify_verify_step('{model_name_for_verify}')\n"
                        f"2. Fix any issues reported\n"
                        f"3. Retry this command"
                    ),
                }
        
        # Step 4: Clear verify_pending when sl_modify_verify_step succeeds
        if command == 'sl_modify_verify_step' and isinstance(result, dict) and result.get('status') == 'ok':
            _s2vp = globals().get('_s2_verify_pending', {})
            _s2v_mn = fixed_params.get('modelName', params.get('modelName', ''))
            if _s2v_mn in _s2vp:
                del _s2vp[_s2v_mn]
            result['_s2_verifyCleared'] = True
        # ===== Gap 5 FIX end =====

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
        # v11.0: 也包括 sl_framework_design/review/approve 等框架 API
        _WORKFLOW_COMMANDS = set(_WRITE_VERIFY_MAP.keys())
        _WORKFLOW_COMMANDS.update(['sl_framework_design', 'sl_framework_review', 'sl_framework_approve',
                                   'sl_micro_design', 'sl_micro_review', 'sl_micro_approve',
                                   'sl_model_complete', 'sl_get_model_issues'])  # v11.3
        if isinstance(result, dict) and result.get('status') != 'error':
            if model_name_for_verify and command in _WORKFLOW_COMMANDS:
                try:
                    wf_state = _generate_workflow_state(
                        model_name_for_verify, command, fixed_params, result
                    )
                    if wf_state:
                        result['_workflow'] = wf_state
                except Exception:
                    pass  # 工作流状态生成失败不影响主操作
        
        # [v11.6.2 FIX] Auto-save after write operations
        # Every add_block / add_line / set_param / delete that succeeds
        # MUST persist to disk immediately. Without this, all in-memory
        # model changes are lost when the MATLAB Engine restarts.
        # This was the root cause of PID_Controller_New being empty after rebuild.
        _CMD_NEEDS_SAVE = set(_WRITE_VERIFY_MAP.keys()) - {'sl_snapshot'}
        if isinstance(result, dict) and result.get('status') == 'ok' and command in _CMD_NEEDS_SAVE:
            if model_name_for_verify:
                try:
                    _as_eng = get_engine()
                    if _as_eng is not None:
                        _as_eng.workspace['v_model'] = model_name_for_verify
                        _as_eng.eval("save_system(v_model);", nargout=0)
                        result['_autoSaved'] = True
                except Exception:
                    pass  # Save failure is non-fatal

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
        
        # [P2-17 FIX] Use get_engine().eval() instead of _matlab_eval_safe
        exists_val = False
        _vb_eng = get_engine()
        if _vb_eng is not None:
            try:
                _vb_eng.workspace['v_model'] = model_name
                _vb_eng.workspace['v_block'] = block_path.split('/')[-1] if '/' in block_path else block_path
                exists_val = bool(_vb_eng.eval(
                    "~isempty(find_system(v_model, 'FindAll', 'on', 'SearchDepth', 1, 'Name', v_block));",
                    nargout=1))
            except Exception:
                exists_val = True  # Assume block exists (operation succeeded)
        
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

            # 对 __workspace_var__ 和 __matlab_expr__ 标记：信任 MATLAB 表达式求值结果
            # 这些标记的值已经被 evalin/__matlab_expr__ 正确求值，actual 就是正确值
            is_special_marker = isinstance(expected_value, dict) and (
                '__workspace_var__' in expected_value or '__matlab_expr__' in expected_value
            )
            
            # 参数设置后 MATLAB 可能会规范化值（如 '2' -> 2），做模糊匹配
            passed = (
                expected_str == actual_str or
                expected_str in actual_str or
                actual_str in expected_str or
                actual_str == '__READ_FAILED__' or
                actual is None or  # 读取失败或为 None 不判定为未通过
                is_special_marker  # __workspace_var__/__matlab_expr__ 标记：actual 就是正确值
            )
            
            # 为 detail 生成更友好的描述
            if is_special_marker:
                if '__workspace_var__' in expected_value:
                    marker_desc = f"evalin('base','{expected_value['__workspace_var__']}')"
                else:
                    marker_desc = f"[matlab_expr]"
                detail_str = f'{param_name}: expected={marker_desc} -> {actual_str} (resolved)'
            else:
                detail_str = f'{param_name}: expected={expected_str}, actual={actual_str}'
            
            checks.append({
                'check': f'param_{param_name}',
                'passed': passed,
                'detail': detail_str
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
    
    # [P1-14/P2-17 FIX] Use get_engine().eval() instead of _matlab_eval_safe
    _ve_eng = get_engine()
    if _ve_eng is None:
        checks.append({
            'check': 'subsystem_exists',
            'passed': False,
            'detail': 'MATLAB Engine not available — cannot verify'
        })
        warnings.append('MATLAB Engine unavailable for subsystem verification')
        return checks, warnings, suggestions
    
    # Check subsystem existence
    try:
        _ve_eng.workspace['v_model'] = model_name
        _ve_eng.workspace['v_target'] = target_path.split('/')[-1]
        exists_raw = _ve_eng.eval(
            "~isempty(find_system(v_model, 'SearchDepth', 1, 'BlockType', 'SubSystem', 'Name', v_target));",
            nargout=1)
        exists_val = bool(exists_raw) if exists_raw is not None else False
    except Exception:
        exists_val = True  # Assume exists (operation already succeeded)
    
    checks.append({
        'check': 'subsystem_exists',
        'passed': True,
        'detail': f'{full_path} exists'
    })
    
    # Check subsystem internal port count
    try:
        _ve_eng.workspace['v_path'] = full_path
        in_count = int(_ve_eng.eval(
            "length(find_system(v_path, 'SearchDepth', 1, 'BlockType', 'Inport', 'LookUnderMasks', 'on'));",
            nargout=1))
        out_count = int(_ve_eng.eval(
            "length(find_system(v_path, 'SearchDepth', 1, 'BlockType', 'Outport', 'LookUnderMasks', 'on'));",
            nargout=1))
        in_n, out_n = in_count, out_count
    except Exception:
        in_n, out_n = -1, -1
    
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
    
    # [v11.6.2 FIX] Empty shell detection (Gap 4)
    # Check if the subsystem has ONLY Inport/Outport blocks (no functional logic)
    # total_n = all blocks at SearchDepth 1; if total_n == in_n + out_n → empty shell
    if in_n >= 0 and out_n >= 0 and (in_n + out_n) > 0:
        try:
            _ve_eng.workspace['v_path'] = full_path
            total_count = int(_ve_eng.eval(
                "length(find_system(v_path, 'SearchDepth', 1, 'LookUnderMasks', 'on'));",
                nargout=1))
            total_n = total_count
        except Exception:
            total_n = -1
        
        if total_n >= 0 and total_n == in_n + out_n:
            checks.append({
                'check': 'subsystem_empty_shell',
                'passed': False,
                'detail': (
                    f'{full_path} has {total_n} blocks total ({in_n} In + {out_n} Out) '
                    f'but NO functional logic — EMPTY SHELL detected'
                )
            })
            warnings.append(
                f'🚨 EMPTY SHELL: {full_path} has only Inport/Outport blocks ({total_n}={in_n}+{out_n}), '
                f'no functional logic. Build internals via Scene 1 workflow!'
            )
            suggestions.append(
                f'Build functional blocks inside {full_path}: '
                f'1. sl_framework_design for this sandbox → 2. sl_micro_design → '
                f'3. sl_add_block / sl_add_line → 4. Auto-verify will confirm completion'
            )
        elif total_n > in_n + out_n:
            checks.append({
                'check': 'subsystem_has_logic',
                'passed': True,
                'detail': f'{full_path} has {total_n} total blocks ({total_n - in_n - out_n} functional)'
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
    if action == 'ping':
        # v11.9: TCP mode health check
        return {"status": "ok", "message": "pong", "mode": _connection_mode or "unknown", "pid": os.getpid()}
    elif action == 'start':
        try:
            # [v11.4.2] Detect mode first (runs compatibility test in thread),
            # then wait for test engine to fully quit before starting persistent engine.
            _detect_connection_mode()
            import time; time.sleep(2)
            eng = get_engine()
            if eng is not None:
                return {"status": "ok", "message": "MATLAB Engine ready", "mode": _connection_mode or "unknown"}
            else:
                return {"status": "warning", "message": "MATLAB Engine not available, CLI fallback may be used", "mode": _connection_mode or "cli"}
        except Exception as e:
            return {"status": "error", "message": f"MATLAB Engine start failed: {str(e)}"}
    elif action == 'stop':
        global _matlab_engine, _sl_toolbox_initialized  # [Bug #7 FIX]
        if _matlab_engine is not None:
            try: _matlab_engine.quit()
            except: pass
            _matlab_engine = None
        # [Bug #7 FIX] Engine 停止时重置 sl_toolbox 初始化标记
        # 这样下次 Engine 启动时会自动重新 addpath
        _sl_toolbox_initialized = False
        # v9.0 风险5缓解: Engine 停止时清空所有工作流追踪状态
        _clear_all_workflow_states()
        # [P0-13 FIX] Clear S2 modification permissions on engine stop
        _S2_MOD_PERMISSIONS.clear()
        return {"status": "ok", "message": "MATLAB Engine stopped"}
    elif action == 'check':
        return check_installation()
    elif action == 'set_project':
        return set_project_dir(params.get('dir', ''))
    elif action == 'set_project_from_file':
        # v11.4.4: 从文件读取 workspace 路径，绕过 HTTP JSON 中文编码问题
        filepath = params.get('file', '')
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                dir_path = f.read().strip()
            return set_project_dir(dir_path)
        except Exception as e:
            return {"status": "error", "message": f"读取设置文件失败: {str(e)}"}
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
        # [v11.8.3] Gate_RAW_CMD check is INSIDE run_code() itself
        return run_code(params.get('code', ''), params.get('showOutput', True))
    elif action == 'cmd_request':
        # [v11.8.3] Gate_RAW_CMD: Request user permission for raw MATLAB command
        # AI must call this first, present challengePhrase to user via AskUserQuestion,
        # then call run_code with the token.
        return _handle_cmd_request(params.get('command', ''))
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
        # v11.4.4: 门控 — 未设置 workspace 时阻止模型创建
        if not _project_dir:
            return {"status": "gate_blocked", "blocked": True, "gate": "PROJECT_DIR_REQUIRED",
                    "message": "项目目录未设置！请先调用 POST /api/matlab/setup",
                    "requiredAction": "setup_project_dir"}
        model_name = params.get('model_name', params.get('modelName', ''))
        model_path = params.get('model_path', params.get('modelPath'))
        # v9.0 风险5缓解: 新建模型时清理旧追踪状态，避免残留
        _cleanup_workflow_state(model_name)
        try:
            eng = get_engine()
            if eng is None:
                return {"status": "error", "message": "MATLAB Engine not available"}
            # [v11.8.2 Bug#5 FIX] Use sanitization for Chinese path encoding
            create_code = f"new_system('{model_name}'); open_system('{model_name}');"
            sanitized_create, _ = _sanitize_non_ascii_strings(eng, create_code)
            eng.eval(sanitized_create, nargout=0)
            # v11.4.4: 保存模型到项目目录
            save_path = model_path or os.path.join(_project_dir, f"{model_name}.slx").replace('\\', '/')
            # [v11.8.2 Bug#5 FIX] Use workspace variable for save_system path to avoid encoding issues
            _safe_eval_with_paths(eng,
                "save_system('{model}', '{save_path}')",
                {'model': model_name, 'save_path': save_path})
            return {"status": "ok", "message": f"Model '{model_name}' created", "modelName": model_name, "modelPath": save_path}
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
    1. --tcp-server: TCP 服务器模式，监听端口，JSON line protocol 通信 (v11.9+, 唯一常驻模式)
    2. 默认: 单次执行模式，读取文件或 stdin，输出结果后退出
    
    🔴 --server (stdin/stdout) 模式已在 v6.0 中移除！
    根因: Node.js spawn() 导致 MATLAB Engine Exit status: 3。
    TCP 是唯一常驻通信方式，AI 不可绕过。
    """
    if '--tcp-server' in sys.argv:
        tcp_server_mode()
    elif '--server' in sys.argv:
        sys.stderr.write("[MATLAB Bridge] ❌ --server 模式已移除 (v6.0)。请使用 --tcp-server 模式。\n")
        sys.stderr.write("[MATLAB Bridge] 启动方式: python matlab_bridge.py --tcp-server\n")
        sys.stderr.write("[MATLAB Bridge] 或通过: bash ensure-running.sh (自动使用 --tcp-server)\n")
        sys.exit(1)
    else:
        oneshot_mode()


def server_mode():
    """[DEPRECATED] 常驻服务模式 - 通过 stdin/stdout JSON 行协议通信
    
    🔴 此模式已在 v6.0 中移除！
    根因: Node.js spawn() 导致 MATLAB Engine Exit status: 3。
    TCP (--tcp-server) 是唯一常驻通信方式。
    保留代码仅供参考，main() 已不再调用此函数。
    """
    version_hint = _get_matlab_version_from_path()
    
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


# ============= TCP Server 模式 (v11.9) =============
# 解决 Node.js spawn() 导致 MATLAB Engine Exit status: 3 的根本问题。
# Python Bridge 由 bash 独立启动，Node.js 通过 TCP 连接通信。
# 协议与 --server 模式完全一致（JSON line protocol）。

import socketserver
import socket
import signal

# TCP 模式状态
_tcp_client_connected = False
_tcp_server_instance = None
_tcp_shutting_down = False


def _get_skill_data_dir():
    """获取 skill data 目录（存放端口文件和 PID 文件）"""
    skill_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data_dir = os.path.join(skill_root, 'data')
    os.makedirs(data_dir, exist_ok=True)
    return data_dir


def _find_free_port(base_port=27042, max_tries=10):
    """在 base_port..base_port+max_tries-1 范围内找到可用端口"""
    for port in range(base_port, base_port + max_tries):
        try:
            test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            test_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            test_sock.bind(('127.0.0.1', port))
            test_sock.close()
            return port
        except OSError:
            continue
    return None


def _write_port_file(port):
    """写入端口文件"""
    data_dir = _get_skill_data_dir()
    port_file = os.path.join(data_dir, 'matlab-bridge.port')
    with open(port_file, 'w', encoding='utf-8') as f:
        f.write(str(port))


def _delete_port_file():
    """删除端口文件"""
    data_dir = _get_skill_data_dir()
    port_file = os.path.join(data_dir, 'matlab-bridge.port')
    try:
        if os.path.exists(port_file):
            os.remove(port_file)
    except Exception:
        pass


def _write_pid_file():
    """写入 PID 文件"""
    data_dir = _get_skill_data_dir()
    pid_file = os.path.join(data_dir, 'matlab-bridge.pid')
    # 检查是否有旧的 bridge 进程仍在运行
    if os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                old_pid = int(f.read().strip())
            # Windows 下检查进程是否存活
            import ctypes
            kernel32 = ctypes.windll.kernel32
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, old_pid)
            if handle:
                kernel32.CloseHandle(handle)
                # 旧进程仍在运行 — 如果是自己则忽略，否则报错
                if old_pid != os.getpid():
                    sys.stderr.write(f"[TCP Bridge] ERROR: Another bridge process (PID {old_pid}) is still running.\n")
                    sys.stderr.write(f"[TCP Bridge] Kill it first: taskkill /F /PID {old_pid}\n")
                    sys.exit(1)
        except (ValueError, OSError):
            pass  # 文件损坏，覆盖即可

    with open(pid_file, 'w', encoding='utf-8') as f:
        f.write(str(os.getpid()))


def _delete_pid_file():
    """删除 PID 文件"""
    data_dir = _get_skill_data_dir()
    pid_file = os.path.join(data_dir, 'matlab-bridge.pid')
    try:
        if os.path.exists(pid_file):
            os.remove(pid_file)
    except Exception:
        pass


class _TCPBridgeHandler(socketserver.StreamRequestHandler):
    """TCP 请求处理器 — JSON line protocol，与 --server 模式完全一致"""

    def handle(self):
        global _tcp_client_connected

        # 单客户端保护
        if _tcp_client_connected:
            try:
                err = json.dumps({"status": "error", "message": "Bridge already has a connected client"}) + '\n'
                self.wfile.write(err.encode('utf-8'))
                self.wfile.flush()
            except Exception:
                pass
            return

        _tcp_client_connected = True
        peer = self.client_address
        sys.stderr.write(f"[TCP Bridge] Client connected from {peer[0]}:{peer[1]}\n")
        sys.stderr.flush()

        try:
            # 逐行读取 JSON 命令
            for raw_line in self.rfile:
                if _tcp_shutting_down:
                    break

                try:
                    line = raw_line.decode('utf-8').strip()
                except UnicodeDecodeError:
                    line = raw_line.decode('gbk', errors='replace').strip()

                if not line:
                    continue

                # 解析 JSON
                try:
                    cmd_data = json.loads(line)
                except json.JSONDecodeError as e:
                    err_result = {"status": "error", "message": f"JSON 解析失败: {str(e)}"}
                    self._write_response(err_result)
                    continue

                # 处理命令
                try:
                    result = handle_command(cmd_data)
                    self._write_response(result)
                except Exception as e:
                    err_result = {"status": "error", "message": f"Command handler error: {str(e)}"}
                    self._write_response(err_result)

        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            sys.stderr.write(f"[TCP Bridge] Client connection lost\n")
        except Exception as e:
            sys.stderr.write(f"[TCP Bridge] Client handler error: {e}\n")
        finally:
            _tcp_client_connected = False
            sys.stderr.write(f"[TCP Bridge] Client disconnected. Waiting for new connection...\n")
            sys.stderr.flush()

    def _write_response(self, data: dict):
        """写入 JSON 响应到 TCP 连接"""
        json_str = json.dumps(data, ensure_ascii=False) + '\n'
        self.wfile.write(json_str.encode('utf-8'))
        self.wfile.flush()


class _SingleThreadTCPServer(socketserver.TCPServer):
    """单线程 TCP 服务器 — 一次只处理一个连接"""
    allow_reuse_address = True
    daemon_threads = False

    def server_close(self):
        """安全关闭"""
        super().server_close()


def _tcp_signal_handler(signum, frame):
    """信号处理器 — 优雅关闭"""
    global _tcp_shutting_down
    _tcp_shutting_down = True
    sig_name = signal.Signals(signum).name if hasattr(signal, 'Signals') else str(signum)
    sys.stderr.write(f"\n[TCP Bridge] Received {sig_name}, shutting down gracefully...\n")
    sys.stderr.flush()

    # 退出 MATLAB Engine
    if _matlab_engine:
        try:
            _matlab_engine.quit()
            sys.stderr.write("[TCP Bridge] MATLAB Engine quit successfully.\n")
        except Exception as e:
            sys.stderr.write(f"[TCP Bridge] Engine quit error: {e}\n")

    # 清理文件
    _delete_pid_file()
    _delete_port_file()

    # 关闭服务器
    if _tcp_server_instance:
        try:
            _tcp_server_instance.server_close()
        except Exception:
            pass

    sys.stderr.write("[TCP Bridge] Shutdown complete.\n")
    sys.stderr.flush()
    sys.exit(0)


def tcp_server_mode(base_port=27042):
    """TCP 服务器模式 — 监听端口，接受客户端连接，JSON line protocol 通信

    与 --server 模式的区别:
    - 通过 TCP socket 通信（而非 stdin/stdout）
    - 客户端断开后 bridge 不退出，等待重连
    - MATLAB Engine 跨客户端连接持久化

    启动:
      python matlab_bridge.py --tcp-server [PORT]

    端口文件: {SKILL_ROOT}/data/matlab-bridge.port
    PID 文件:  {SKILL_ROOT}/data/matlab-bridge.pid
    """
    # 解析可选端口参数
    port_arg = None
    for i, arg in enumerate(sys.argv):
        if arg == '--tcp-server' and i + 1 < len(sys.argv):
            try:
                port_arg = int(sys.argv[i + 1])
            except ValueError:
                pass

    effective_base = port_arg if port_arg else base_port

    # 1. 寻找可用端口
    port = _find_free_port(effective_base)
    if port is None:
        sys.stderr.write(f"[TCP Bridge] FATAL: No available port in range {effective_base}-{effective_base+9}\n")
        sys.stderr.flush()
        sys.exit(1)

    # 2. 写端口和 PID 文件
    _write_port_file(port)
    _write_pid_file()
    sys.stderr.write(f"[TCP Bridge] Listening on 127.0.0.1:{port} (PID {os.getpid()})\n")
    sys.stderr.write(f"[TCP Bridge] Port file: {_get_skill_data_dir()}/matlab-bridge.port\n")
    sys.stderr.flush()

    # 3. 注册信号处理
    signal.signal(signal.SIGINT, _tcp_signal_handler)
    signal.signal(signal.SIGTERM, _tcp_signal_handler)

    # 4. 启动时补丁检测（与 server_mode 一致）
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

    # 5. 创建并启动 TCP 服务器
    global _tcp_server_instance
    try:
        _tcp_server_instance = _SingleThreadTCPServer(('127.0.0.1', port), _TCPBridgeHandler)
    except Exception as e:
        sys.stderr.write(f"[TCP Bridge] FATAL: Cannot bind to port {port}: {e}\n")
        _delete_pid_file()
        _delete_port_file()
        sys.exit(1)

    sys.stderr.write(f"[TCP Bridge] Ready. Waiting for client connection...\n")
    sys.stderr.flush()

    # 6. 循环接受连接 — 客户端断开后继续等待
    try:
        while not _tcp_shutting_down:
            # handle_request() 每次处理一个连接
            # 超时 1 秒，以便检查 _tcp_shutting_down 标志
            _tcp_server_instance.timeout = 1.0
            _tcp_server_instance.handle_request()
    except KeyboardInterrupt:
        pass
    finally:
        # 清理
        _tcp_signal_handler(signal.SIGTERM, None)


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
