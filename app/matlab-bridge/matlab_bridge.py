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
    mode = _detect_connection_mode()
    if mode == 'engine':
        eng = get_engine()
        if eng:
            try:
                tmp_dir_safe = tmp_dir.replace('\\', '/')
                eng.eval(f"addpath('{tmp_dir_safe}');", nargout=0)
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
        # v5.0: 使用 eng.eval 直接执行，无需 evalc 包裹
        # 中文路径现在可以正常传递，因为 eng.eval(code) 将代码直接传给 MATLAB
        try:
            eng.eval(f"cd('{dir_safe}');", nargout=0)
            eng.eval(f"addpath('{dir_safe}');", nargout=0)
        except Exception as e:
            # 如果直接 eval 中文路径失败，尝试 diary 方式
            try:
                cd_code = f"cd('{dir_safe}'); addpath('{dir_safe}');"
                _run_code_via_diary(eng, cd_code)
            except:
                pass
    # CLI 模式下只记录目录，每次执行时 cd
    
    # v5.4: 自动初始化隔离工作空间
    init_result = init_agent_workspace()
    
    return {"status": "ok", "project_dir": dir_path, "connection_mode": mode, 
            "workspace_isolation": init_result.get("tmp_dir", "")}


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
            output = _run_code_via_diary(eng, mat_info_code)
            variables = []
            if isinstance(output, str) and output:
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
            output = _run_code_via_diary(eng, cmd_code)
            blocks = []
            block_count = 0
            if isinstance(output, str) and output:
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
            matlab_output = _run_code_via_diary(eng, exec_code)
            
            if isinstance(matlab_output, dict):  # 错误情况
                matlab_output["script_path"] = script_path
                return matlab_output
            
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
    
    流程: 写 .m 文件 → diary 开启 → eng.eval(code) → diary 关闭 → 读输出文件
    """
    import tempfile
    
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
    
    # 2. 通过 eng.eval 直接执行代码（无需 evalc 包裹！）
    #    如果不需要捕获输出，直接 eng.eval(code, nargout=0) 即可
    #    需要 diary 时，先开启 diary，再 eval，最后关闭
    try:
        # 开启 diary 捕获输出
        diary_file_safe = diary_file.replace('\\', '/')
        eng.eval(f"diary('{diary_file_safe}');", nargout=0)
        
        # 直接执行代码（无需任何引号转义！）
        eng.eval(code, nargout=0)
        
        # 关闭 diary
        eng.eval("diary('off');", nargout=0)
        
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
        
        # 清理 diary 输出中的回显代码行（diary 会把执行的代码也记录进去）
        # 只保留非空输出行
        lines = output_str.split('\n')
        cleaned_lines = []
        for line in lines:
            stripped = line.strip()
            if stripped:
                cleaned_lines.append(stripped)
        output_str = '\n'.join(cleaned_lines)
        
        # 清理 HTML 标签
        output_str = re.sub(r'<[^>]+>', '', output_str)
        output_str = re.sub(r'\n{3,}', '\n\n', output_str)
        
    except Exception as e:
        # 确保 diary 被关闭
        try: eng.eval("diary('off');", nargout=0)
        except: pass
        error_msg = re.sub(r'<[^>]+>', '', str(e))
        return {"status": "error", "message": f"MATLAB 执行错误: {error_msg}"}
    finally:
        # 清理临时文件
        for f in [script_file, diary_file]:
            try:
                if os.path.exists(f): os.remove(f)
            except: pass
    
    return output_str


def run_code(code, show_output=True):
    """在持久化工作区中直接执行 MATLAB 代码
    
    Engine 模式：变量跨命令保持
    CLI 模式：每次执行独立，变量不保持
    unavailable 模式：直接报错
    
    v5.0: 使用 diary() + eng.eval() 替代 evalc()，彻底解决:
    - 引号双写问题（Name-Value 参数如 'LowerLimit' 不再被破坏）
    - 中文路径乱码（路径直接在 .m 文件中，无需转义）
    - 多行代码问题（.m 文件天然支持多行）
    """
    mode = _detect_connection_mode()
    
    if mode == 'unavailable':
        return {"status": "error", "message": "MATLAB 不可用。请先通过 /api/matlab/config 设置 MATLAB_ROOT。"}
    
    if mode == 'engine':
        eng = get_engine()
        try:
            if show_output:
                output_str = _run_code_via_diary(eng, code)
                if isinstance(output_str, dict):  # 错误情况
                    return output_str
            else:
                eng.eval(code, nargout=0)
                output_str = ""
            
            fig_count = _count_figures(eng)
            return {"status": "ok", "stdout": output_str, "open_figures": fig_count, "connection_mode": "engine"}
        except Exception as e:
            error_msg = re.sub(r'<[^>]+>', '', str(e))
            return {"status": "error", "message": f"MATLAB 执行错误: {error_msg}"}
    else:
        # CLI 回退模式
        # 在 CLI 模式下先 cd 到项目目录
        project_code = ""
        if _project_dir:
            dir_safe = _project_dir.replace('\\', '/')
            project_code = f"cd('{dir_safe}'); addpath('{dir_safe}'); "
        
        full_code = project_code + code
        result = _run_cli_command(full_code, timeout=120)
        if result['status'] == 'ok':
            result['connection_mode'] = 'cli'
        return result


def _count_figures(eng):
    try:
        return int(eng.eval("length(findall(0, 'Type', 'figure'));", nargout=1))
    except:
        return 0


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
            sim_output = _run_code_via_diary(eng, sim_code)
            if isinstance(sim_output, dict):  # 错误
                return sim_output
            
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
            output = _run_code_via_diary(eng, cmd_code)
            variables = []
            if isinstance(output, str) and output:
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
            output = _run_code_via_diary(eng, fig_code)
            figures = []
            if isinstance(output, str) and output:
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
def handle_command(cmd_data: dict):
    action = cmd_data.get("action", "")
    params = cmd_data.get("params", {})
    
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
        
        result = handle_command(cmd_data)
        _write_json_response(result)
    
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
