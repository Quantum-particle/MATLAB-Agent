#!/usr/bin/env python3
"""
matlab-agent 工作环境初始化 (v11.4.4)
=========================================
用途: 设置 MATLAB Agent 的工作目录，触发 sl_toolbox 自动挂载
原理: 通过临时文件传递 workspace 路径到 bridge，绕过 HTTP JSON 中文编码问题
门控: 未初始化前，所有 POST /api/matlab/run 被阻止

用法:
  python setup_workspace.py <workspace目录>
  python setup_workspace.py D:/MyProject/Matlab_Workspace
  python setup_workspace.py .                    # 当前目录
  python setup_workspace.py %CD%                 # CMD 当前目录
  python setup_workspace.py $PWD                 # Bash 当前目录

也可设置环境变量作为默认值:
  export MATLAB_AGENT_WORKSPACE=D:/MyProject/...
  python setup_workspace.py
"""
import sys, json, urllib.request, os


def setup(workspace: str, host: str = "http://localhost:3000"):
    # 规范化路径
    workspace = os.path.abspath(workspace).replace("\\", "/")

    # 验证目录存在
    if not os.path.isdir(workspace):
        print(f"[ERROR] 目录不存在: {workspace}", file=sys.stderr)
        sys.exit(2)

    # 通过 HTTP POST 发送（Python urllib 原生 UTF-8，无编码问题）
    data = json.dumps({"workspace": workspace}).encode("utf-8")
    req = urllib.request.Request(
        f"{host}/api/matlab/setup",
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"}
    )
    try:
        resp = urllib.request.urlopen(req)
        result = json.loads(resp.read().decode("utf-8"))
        if result.get("status") == "ok":
            print(f"[OK] workspace: {result.get('project_dir', workspace)}")
            print(f"[OK] sl_toolbox: {result.get('sl_toolbox', '?')}")
            print(f"[OK] isolation: {result.get('workspace_isolation', '?')}")
            print(f"[OK] mode: {result.get('connection_mode', '?')}")
        else:
            print(f"[FAIL] {result.get('message', result)}", file=sys.stderr)
            sys.exit(3)
        return result
    except urllib.error.URLError as e:
        print(f"[ERROR] 无法连接 matlab-agent 服务 ({host}): {e}", file=sys.stderr)
        sys.exit(4)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python setup_workspace.py <workspace目录>", file=sys.stderr)
        print("示例: python setup_workspace.py D:/MyProject/MatlabCode", file=sys.stderr)
        print("      python setup_workspace.py .", file=sys.stderr)
        print("\nworkspace 目录必须由用户显式指定，不可自动推断。", file=sys.stderr)
        sys.exit(1)
    setup(sys.argv[1])
