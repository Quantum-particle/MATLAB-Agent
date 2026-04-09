# -*- coding: utf-8 -*-
"""
MATLAB Bridge v4.0 - 通用化 MATLAB 会话服务

运行模式: 作为常驻进程运行，通过 stdin/stdout JSON 行协议通信。
Node.js 启动此进程后保持运行，通过管道发送命令、接收结果。

启动:
  python matlab_bridge.py --server

通信协议:
  每行一个 JSON 对象，输入为命令，输出为结果。
  输入: {"action": "run_code", "params": {"code": "x = 42;"}}
  输出: {"status": "ok", "stdout": "x = 42", "open_figures": 0}

v4.0 通用化升级:
  - MATLAB_ROOT 不再硬编码，支持环境变量/注册表/常见路径自动检测
  - CLI 回退模式：当 Python Engine API 不兼容时（如 R2016a + Python 3.11），
    自动切换到 matlab -batch / matlab -r 命令行模式
  - 多版本 MATLAB 支持（通过 MATLAB_ROOT 环境变量动态选择）

版本: 4.0.0 (2026-04-09)
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


# ============= MATLAB_ROOT 自动检测 =============

def _detect_matlab_root():
    """自动检测 MATLAB 安装路径
    
    优先级:
    1. 环境变量 MATLAB_ROOT（由 Node.js 传入或用户手动设置）
    2. Windows 注册表扫描
    3. 常见安装路径扫描
    """
    # 1. 环境变量
    env_root = os.environ.get('MATLAB_ROOT', '')
    if env_root and os.path.exists(env_root):
        return env_root
    
    # 2. Windows 注册表扫描
    if sys.platform == 'win32':
        try:
            import winreg
            # 扫描 HKLM\SOFTWARE\MathWorks\MATLAB\<version>\<release>
            key_path = r"SOFTWARE\MathWorks\MATLAB"
            access_flag = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
            
            try:
                key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path, 0, access_flag)
            except FileNotFoundError:
                # 尝试 32-bit 注册表视图
                try:
                    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path, 0, winreg.KEY_READ)
                except FileNotFoundError:
                    key = None
            
            if key:
                installations = []
                i = 0
                while True:
                    try:
                        version_name = winreg.EnumKey(key, i)
                        i += 1
                        # 每个 version_name 类似 "23.2" 或 "9.0"
                        try:
                            version_key = winreg.OpenKey(key, version_name, 0, access_flag)
                            j = 0
                            while True:
                                try:
                                    release_name = winreg.EnumKey(version_key, j)
                                    j += 1
                                    try:
                                        release_key = winreg.OpenKey(version_key, release_name, 0, access_flag)
                                        try:
                                            matlab_root, _ = winreg.QueryValueEx(release_key, "MATLABROOT")
                                            if matlab_root and os.path.exists(matlab_root):
                                                exe_path = os.path.join(matlab_root, 'bin', 'matlab.exe')
                                                if os.path.exists(exe_path):
                                                    installations.append({
                                                        'version': version_name,
                                                        'release': release_name,
                                                        'root': matlab_root
                                                    })
                                        except FileNotFoundError:
                                            pass
                                        finally:
                                            winreg.CloseKey(release_key)
                                    except:
                                        pass
                                except OSError:
                                    break
                            winreg.CloseKey(version_key)
                        except:
                            pass
                    except OSError:
                        break
                
                winreg.CloseKey(key)
                
                if installations:
                    # 选择最新版本（version 数字越大越新）
                    installations.sort(key=lambda x: float(x['version']) if x['version'].replace('.', '').isdigit() else 0, reverse=True)
                    return installations[0]['root']
        except ImportError:
            pass  # winreg 不可用（非 Windows）
    
    # 3. 常见安装路径扫描
    common_roots = [
        'C:\\Program Files\\MATLAB',
        'C:\\Program Files (x86)\\MATLAB',
        'D:\\Program Files\\MATLAB',
        'D:\\Program Files (x86)\\MATLAB',
        'C:\\MATLAB',
        'D:\\MATLAB',
        # 非标准路径（括号前无空格）
        'C:\\Program Files(x86)\\MATLAB',
        'D:\\Program Files(x86)\\MATLAB',
    ]
    
    # 非标准父目录，只匹配 MATLAB 开头的子目录
    non_standard_parents = [
        'C:\\Program Files(x86)',
        'D:\\Program Files(x86)',
    ]
    
    def _is_matlab_dirname(name):
        """判断目录名是否像 MATLAB 版本目录"""
        return bool(re.match(r'^R\d{4}[ab]$', name, re.IGNORECASE) or
                   re.match(r'^MATLAB\s*\d{4}[ab]?$', name, re.IGNORECASE))
    
    for root in common_roots:
        if not os.path.exists(root):
            continue
        try:
            entries = os.listdir(root)
            # 匹配 R20XXx 格式或 MATLAB+年份 格式，优先选最新
            matlab_dirs = []
            for entry in entries:
                full_path = os.path.join(root, entry)
                exe_path = os.path.join(full_path, 'bin', 'matlab.exe')
                if os.path.isdir(full_path) and os.path.exists(exe_path):
                    if _is_matlab_dirname(entry) or re.match(r'^MATLAB$', entry, re.IGNORECASE):
                        matlab_dirs.append(entry)
            
            if matlab_dirs:
                # 排序：R20XXb > R20XXa，数字越大越新
                def sort_key(name):
                    m = re.match(r'R?(\d{4})([ab])', name, re.IGNORECASE)
                    if m:
                        return int(m.group(1)) * 10 + (1 if m.group(2).lower() == 'b' else 0)
                    m2 = re.match(r'MATLAB\s*(\d{4})', name, re.IGNORECASE)
                    if m2:
                        return int(m2.group(1)) * 10
                    return 0
                matlab_dirs.sort(key=sort_key, reverse=True)
                return os.path.join(root, matlab_dirs[0])
        except:
            pass
    
    return None


# ============= MATLAB 连接模式 =============

# 连接模式：engine = Python Engine API, cli = 命令行模式
_connection_mode = None  # 'engine' | 'cli'
_engine_compatible = None  # 是否已测试过 Engine 兼容性

MATLAB_ROOT = _detect_matlab_root()  # 不再硬编码回退路径；None 表示未检测到
_project_dir = None
_matlab_engine = None
_matlab_version = None  # 缓存 MATLAB 版本号


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
    """通过命令行检测 MATLAB 版本"""
    global _matlab_version
    matlab_exe = _get_matlab_exe()
    if not os.path.exists(matlab_exe):
        return _matlab_version
    
    try:
        # R2019a+ 支持 -batch
        result = subprocess.run(
            [matlab_exe, '-batch', 'disp(version);exit;'],
            capture_output=True, text=True, timeout=30,
            encoding='utf-8', errors='replace'
        )
        output = result.stdout.strip()
        # 提取版本号
        for line in output.split('\n'):
            line = line.strip()
            if line:
                _matlab_version = line
                return _matlab_version
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    
    return _matlab_version


def _test_engine_compatibility():
    """测试 Python Engine API 是否兼容当前 MATLAB 版本
    
    返回: True = 兼容可用, False = 不兼容需 CLI 回退
    
    使用线程超时机制防止 start_matlab() 永远卡住（最多等 30 秒）。
    """
    global _engine_compatible
    if _engine_compatible is not None:
        return _engine_compatible
    
    ENGINE_TEST_TIMEOUT = 30  # Engine 兼容性测试超时（秒）
    
    _result = {'compatible': None}
    
    def _do_test():
        try:
            engine_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python")
            if os.path.exists(engine_path) and engine_path not in sys.path:
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
            full_code = clean_code + ';exit;'
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
        eng.eval(f"cd('{dir_safe}');", nargout=0)
        eng.eval(f"addpath('{dir_safe}');", nargout=0)
    # CLI 模式下只记录目录，每次执行时 cd
    
    return {"status": "ok", "project_dir": dir_path, "connection_mode": mode}


def get_project_dir():
    return _project_dir or os.environ.get('MATLAB_WORKSPACE', 'd:/MATLAB_Workspace/work1')


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
            mat_info_cmd = (
                "evalc('"
                "info = whos('-file', '" + file_path + "');"
                "for i = 1:length(info),"
                "  fprintf('%s|%s|%s\\n', info(i).name, info(i).class, mat2str(info(i).size));"
                "end;"
                "clear info;"
                "')"
            )
            output = eng.eval(mat_info_cmd, nargout=1)
            variables = []
            if output:
                for line in str(output).strip().split('\n'):
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
            cmd = ("evalc('"
                   "load_system('" + model_name + "');"
                   "blocks = find_system('" + model_name + "', 'SearchDepth', 1);"
                   "fprintf('Blocks: %d\\n', length(blocks));"
                   "for i = 1:min(length(blocks), 50),"
                   "  fprintf('%s\\n', blocks{i});"
                   "end;"
                   "')")
            output = eng.eval(cmd, nargout=1)
            blocks = []
            block_count = 0
            if output:
                for line in str(output).strip().split('\n'):
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
            script_dir_safe = script_dir.replace('\\', '/')
            capture_cmd = "evalc('cd(''" + script_dir_safe + "''); run(''" + script_name + "'');')"
            matlab_output = eng.eval(capture_cmd, nargout=1)
            
            if matlab_output:
                matlab_output = str(matlab_output)
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


def run_code(code, show_output=True):
    """在持久化工作区中直接执行 MATLAB 代码
    
    Engine 模式：变量跨命令保持
    CLI 模式：每次执行独立，变量不保持
    unavailable 模式：直接报错
    """
    mode = _detect_connection_mode()
    
    if mode == 'unavailable':
        return {"status": "error", "message": "MATLAB 不可用。请先通过 /api/matlab/config 设置 MATLAB_ROOT。"}
    
    if mode == 'engine':
        eng = get_engine()
        try:
            if show_output:
                escaped_code = code.replace("'", "''")
                capture_cmd = f"evalc('{escaped_code}')"
                output = eng.eval(capture_cmd, nargout=1)
                output_str = str(output).strip() if output else ""
                output_str = re.sub(r'<[^>]+>', '', output_str)
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
            capture_cmd = ("evalc('"
                "try, "
                f"simOut = sim('{model_name}', 'StopTime', '{stop_time}', 'ReturnWorkspaceOutputs', 'on'); "
                "fprintf('Simulation completed.\\n'); "
                "catch ME, "
                "fprintf(2, 'Simulink error: %s\\n', ME.message); "
                "end"
                "')")
            sim_output = eng.eval(capture_cmd, nargout=1)
            
            # 自动绘图
            try:
                plot_cmd = ("evalc('"
                    "try, sims = simOut.get(); for i = 1:length(sims),"
                    "  name = sims{i}; data = simOut.get(name);"
                    "  if isa(data, ''timeseries''),"
                    "    figure(''Name'', [''Simulink: '', name]);"
                    "    if isprop(data, ''Values''), plot(data.Time, data.Values.Data);"
                    "    else, plot(data.Time, data.Data); end,"
                    "    title(name); xlabel(''Time''); drawnow; end, end,"
                    "catch, end"
                    "')")
                eng.eval(plot_cmd, nargout=0)
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


# ============= 图形 =============
def list_figures():
    mode = _detect_connection_mode()
    
    if mode == 'engine':
        eng = get_engine()
        try:
            fig_info = eng.eval("evalc('figs = findall(0, ''Type'', ''figure''); for i = 1:length(figs), fprintf(''Figure %d: %s\\n'', figs(i).Number, figs(i).Name); end;')", nargout=1)
            figures = [l.strip() for l in str(fig_info).strip().split('\n') if l.strip()] if fig_info else []
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
        "matlab_root_exists": os.path.exists(MATLAB_ROOT),
        "matlab_exe_exists": os.path.exists(matlab_exe),
        "engine_path_exists": os.path.exists(os.path.join(MATLAB_ROOT, "extern", "engines", "python")),
        "python_version": sys.version,
        "matlab_root": MATLAB_ROOT,
        "matlab_exe": matlab_exe,
        "project_dir": _project_dir,
        "engine_active": _matlab_engine is not None,
        "connection_mode": _connection_mode or "unknown",
        "detected_installations": _get_detected_installations(),
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


def _get_detected_installations():
    """扫描所有已安装的 MATLAB 版本"""
    installations = []
    
    # 注册表扫描
    if sys.platform == 'win32':
        try:
            import winreg
            key_path = r"SOFTWARE\MathWorks\MATLAB"
            access_flag = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
            
            try:
                key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path, 0, access_flag)
            except FileNotFoundError:
                try:
                    key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path, 0, winreg.KEY_READ)
                except FileNotFoundError:
                    key = None
            
            if key:
                i = 0
                while True:
                    try:
                        version_name = winreg.EnumKey(key, i)
                        i += 1
                        try:
                            version_key = winreg.OpenKey(key, version_name, 0, access_flag)
                            j = 0
                            while True:
                                try:
                                    release_name = winreg.EnumKey(version_key, j)
                                    j += 1
                                    try:
                                        release_key = winreg.OpenKey(version_key, release_name, 0, access_flag)
                                        try:
                                            matlab_root, _ = winreg.QueryValueEx(release_key, "MATLABROOT")
                                            if matlab_root and os.path.exists(matlab_root):
                                                installations.append({
                                                    'version': version_name,
                                                    'release': release_name,
                                                    'root': matlab_root,
                                                    'exe_exists': os.path.exists(os.path.join(matlab_root, 'bin', 'matlab.exe'))
                                                })
                                        except FileNotFoundError:
                                            pass
                                        finally:
                                            winreg.CloseKey(release_key)
                                    except:
                                        pass
                                except OSError:
                                    break
                            winreg.CloseKey(version_key)
                        except:
                            pass
                    except OSError:
                        break
                winreg.CloseKey(key)
        except ImportError:
            pass
    
    # 常见路径扫描
    common_roots = [
        'C:\\Program Files\\MATLAB',
        'C:\\Program Files (x86)\\MATLAB',
        'D:\\Program Files\\MATLAB',
        'D:\\Program Files (x86)\\MATLAB',
        'C:\\MATLAB',
        'D:\\MATLAB',
    ]
    
    for root in common_roots:
        if not os.path.exists(root):
            continue
        try:
            for entry in os.listdir(root):
                full_path = os.path.join(root, entry)
                exe_path = os.path.join(full_path, 'bin', 'matlab.exe')
                if os.path.isdir(full_path) and os.path.exists(exe_path):
                    if not any(inst['root'] == full_path for inst in installations):
                        installations.append({
                            'version': entry,
                            'release': entry,
                            'root': full_path,
                            'exe_exists': True
                        })
        except:
            pass
    
    return installations


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
        "list_figures": lambda: list_figures(),
        "close_figures": lambda: close_all_figures(),
        "get_config": lambda: _get_config(),
        "set_matlab_root": lambda: _set_matlab_root(params.get("root", "")),
        "detect_installations": lambda: detect_matlab_installations(),
    }
    
    # 这些命令不需要 MATLAB 就能运行
    NO_MATLAB_NEEDED = {"check", "set_project", "scan_project", "read_m_file", 
                         "read_mat_file", "read_simulink", "get_config", "set_matlab_root",
                         "detect_installations"}
    
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
            sys.stdout.write(json.dumps(result, ensure_ascii=False) + '\n')
            sys.stdout.flush()
            continue
        
        result = handle_command(cmd_data)
        sys.stdout.write(json.dumps(result, ensure_ascii=False) + '\n')
        sys.stdout.flush()
    
    # stdin 关闭，退出
    if _matlab_engine:
        try: _matlab_engine.quit()
        except: pass


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
