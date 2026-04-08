# -*- coding: utf-8 -*-
"""
MATLAB Bridge v3.0 - 持久化 MATLAB 会话服务

运行模式: 作为常驻进程运行，通过 stdin/stdout JSON 行协议通信。
Node.js 启动此进程后保持运行，通过管道发送命令、接收结果。

启动:
  python matlab_bridge.py --server

通信协议:
  每行一个 JSON 对象，输入为命令，输出为结果。
  输入: {"action": "run_code", "params": {"code": "x = 42;"}}
  输出: {"status": "ok", "stdout": "x = 42", "open_figures": 0}

版本: 3.0.1 (2026-04-08)
"""

import sys
import os
import json
import re
import traceback
from pathlib import Path
from datetime import datetime

# 强制 UTF-8
if sys.stdin.encoding != 'utf-8':
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
if sys.stdout.encoding != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if sys.stderr.encoding != 'utf-8':
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# MATLAB Engine
MATLAB_ROOT = r"D:\Program Files(x86)\MATLAB2023b"
_project_dir = None
_matlab_engine = None


def setup_matlab_engine():
    engine_path = os.path.join(MATLAB_ROOT, "extern", "engines", "python")
    if os.path.exists(engine_path) and engine_path not in sys.path:
        sys.path.insert(0, engine_path)
    import matlab.engine
    return matlab.engine


def get_engine():
    """获取或创建 MATLAB Engine（在常驻进程中保持）"""
    global _matlab_engine
    if _matlab_engine is not None:
        try:
            _matlab_engine.eval("1+1;", nargout=0)
            return _matlab_engine
        except:
            _matlab_engine = None
    
    matlab_engine_module = setup_matlab_engine()
    _matlab_engine = matlab_engine_module.start_matlab()
    
    try:
        _matlab_engine.eval("warning('off', 'Simulink:Engine:MdlFileShadowing');", nargout=0)
        _matlab_engine.eval("warning('off', 'Simulink:LoadSave:MaskedSystemWarning');", nargout=0)
        _matlab_engine.eval("set(0, 'DefaultFigureVisible', 'on');", nargout=0)
    except:
        pass
    
    return _matlab_engine


def set_project_dir(dir_path):
    global _project_dir
    dir_path = os.path.abspath(dir_path)
    if not os.path.exists(dir_path):
        return {"status": "error", "message": f"目录不存在: {dir_path}"}
    _project_dir = dir_path
    eng = get_engine()
    dir_safe = dir_path.replace('\\', '/')
    eng.eval(f"cd('{dir_safe}');", nargout=0)
    eng.eval(f"addpath('{dir_safe}');", nargout=0)
    return {"status": "ok", "project_dir": dir_path}


def get_project_dir():
    return _project_dir or "D:/MATLAB_Workspace"


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
    eng = get_engine()
    file_path = os.path.abspath(file_path).replace('\\', '/')
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


def read_simulink_model(model_path):
    eng = get_engine()
    model_path = os.path.abspath(model_path).replace('\\', '/')
    try:
        model_name = os.path.splitext(os.path.basename(model_path))[0]
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


# ============= 代码执行（核心：持久化工作区）============
def execute_script(script_path, output_dir=None):
    eng = get_engine()
    if not os.path.exists(script_path):
        return {"status": "error", "message": f"文件不存在: {script_path}"}
    
    script_path = os.path.abspath(script_path)
    script_dir = os.path.dirname(script_path)
    script_name = os.path.splitext(os.path.basename(script_path))[0]
    
    if script_name.startswith('_'):
        return {"status": "error", "message": f"函数名不能以下划线开头: {script_name}"}
    
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
        return {"status": "ok", "stdout": matlab_output.strip(), "script_path": script_path, "open_figures": fig_count}
    except Exception as e:
        error_msg = re.sub(r'<[^>]+>', '', str(e))
        return {"status": "error", "message": f"MATLAB 脚本执行错误: {error_msg}", "script_path": script_path}


def run_code(code, show_output=True):
    """在持久化工作区中直接执行 MATLAB 代码"""
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
        return {"status": "ok", "stdout": output_str, "open_figures": fig_count}
    except Exception as e:
        error_msg = re.sub(r'<[^>]+>', '', str(e))
        return {"status": "error", "message": f"MATLAB 执行错误: {error_msg}"}


def _count_figures(eng):
    try:
        return int(eng.eval("length(findall(0, 'Type', 'figure'));", nargout=1))
    except:
        return 0


# ============= 工作区管理 =============
def get_workspace_vars():
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
        return {"status": "ok", "variables": result}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def save_workspace(file_path=None):
    eng = get_engine()
    if not file_path:
        file_path = os.path.join(get_project_dir(), "workspace.mat")
    file_path = os.path.abspath(file_path).replace('\\', '/')
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    try:
        eng.eval(f"save('{file_path}');", nargout=0)
        return {"status": "ok", "message": f"工作区已保存", "path": file_path}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def load_workspace(file_path):
    eng = get_engine()
    file_path = os.path.abspath(file_path).replace('\\', '/')
    try:
        eng.eval(f"load('{file_path}');", nargout=0)
        return {"status": "ok", "message": f"工作区已加载"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def clear_workspace():
    eng = get_engine()
    try:
        eng.eval("clear all; close all;", nargout=0)
        return {"status": "ok", "message": "工作区已清空"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ============= Simulink =============
def create_simulink_model(model_name, model_path=None):
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
        save_path = (model_path or os.path.join(get_project_dir(), model_name)).replace('\\', '/')
        eng.save_system(model_name, save_path, nargout=0)
        return {"status": "ok", "message": f"模型 '{model_name}' 创建成功", "model_path": save_path}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def run_simulink(model_name, stop_time="10"):
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
                "stdout": str(sim_output).strip() if sim_output else "", "open_figures": fig_count}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def open_simulink_model(model_name):
    eng = get_engine()
    try:
        eng.eval(f"open_system('{model_name}');", nargout=0)
        return {"status": "ok", "message": f"模型 '{model_name}' 已打开"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ============= 图形 =============
def list_figures():
    eng = get_engine()
    try:
        fig_info = eng.eval("evalc('figs = findall(0, ''Type'', ''figure''); for i = 1:length(figs), fprintf(''Figure %d: %s\\n'', figs(i).Number, figs(i).Name); end;')", nargout=1)
        figures = [l.strip() for l in str(fig_info).strip().split('\n') if l.strip()] if fig_info else []
        return {"status": "ok", "figures": figures}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def close_all_figures():
    eng = get_engine()
    try:
        eng.eval("close all;", nargout=0)
        return {"status": "ok", "message": "所有图形已关闭"}
    except Exception as e:
        return {"status": "error", "message": str(e)}


# ============= 安装检查 =============
def check_installation():
    checks = {
        "matlab_root_exists": os.path.exists(MATLAB_ROOT),
        "matlab_exe_exists": os.path.exists(os.path.join(MATLAB_ROOT, "bin", "matlab.exe")),
        "engine_path_exists": os.path.exists(os.path.join(MATLAB_ROOT, "extern", "engines", "python")),
        "python_version": sys.version,
        "matlab_root": MATLAB_ROOT,
        "project_dir": _project_dir,
        "engine_active": _matlab_engine is not None,
    }
    try:
        setup_matlab_engine()
        checks["engine_importable"] = True
    except:
        checks["engine_importable"] = False
    
    all_ok = checks.get("engine_importable", False) and checks["matlab_exe_exists"]
    checks["status"] = "ok" if all_ok else "warning"
    return checks


# ============= 命令分发 =============
def handle_command(cmd_data: dict):
    action = cmd_data.get("action", "")
    params = cmd_data.get("params", {})
    
    handlers = {
        "check": lambda: check_installation(),
        "start": lambda: (get_engine(), {"status": "ok", "message": "MATLAB Engine 已启动（持久化）"}),
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
    }
    
    handler = handlers.get(action)
    if handler is None:
        return {"status": "error", "message": f"未知命令: {action}"}
    try:
        return handler()
    except Exception as e:
        return {"status": "error", "message": f"处理命令时出错: {str(e)}", "detail": traceback.format_exc()}


def _stop_engine():
    global _matlab_engine
    if _matlab_engine:
        try: _matlab_engine.quit()
        except: pass
        _matlab_engine = None
    return {"status": "ok", "message": "MATLAB Engine 已停止"}


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
    sys.stderr.write("[MATLAB Bridge] Server mode started. Engine will persist.\n")
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
