#!/bin/bash
# ensure-running.sh - MATLAB Agent 确保服务运行脚本 (v11.9)
# 用途: Git Bash 原生启动，确保 MATLAB Agent 服务器在后台运行
# 返回: exit 0 = 服务可用, exit 1 = 不可用
#
# 用法:
#   在 app/ 目录下:  bash ensure-running.sh
#   从 skill 根目录: bash app/ensure-running.sh
#
# [v11.9] TCP Bridge 方案: 先启动 Python Bridge (--tcp-server)，
# 再启动 Node.js 服务器。Bridge 独立运行于 bash & 后台进程，
# Node.js 通过 TCP 连接通信，避免 Node.js spawn() 导致 MATLAB
# Engine Exit status: 3 的根本问题。
#
# [v11.4.2] 替代 ensure-running.bat 的 Git Bash 原生方案。
# Windows CMD 的 start /B 会共享控制台，导致 MATLAB Engine 的
# "Simple server" 无法启动。bash 的 & 后台运行无此问题。

set -euo pipefail

# [v12.1 BUGFIX #40] Cleanup handler for graceful shutdown (INT/TERM only, NOT normal exit)
cleanup() {
    local exit_code=$?
    echo "[MATLAB Agent] Cleaning up..."
    if [ -n "${BRIDGE_PID:-}" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
        kill "$BRIDGE_PID" 2>/dev/null || true
        echo "[MATLAB Agent] Bridge process $BRIDGE_PID terminated"
    fi
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        echo "[MATLAB Agent] Server process $SERVER_PID terminated"
    fi
    exit $exit_code
}
trap cleanup INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=3000
HEALTH_URL="http://localhost:${PORT}/api/health"
LOG_FILE="${TEMP:-/tmp}/matlab-agent-out.log"
PID_FILE="${SCRIPT_DIR}/.matlab_agent_pid"
MAX_SERVER_WAIT=60
MAX_WARMUP_WAIT=300  # v11.8.1: increased from 90 to allow full engine startup (120+2+120)

# v11.9: Bridge TCP 相关路径
BRIDGE_DATA_DIR="${SCRIPT_DIR}/data"
BRIDGE_PORT_FILE="${BRIDGE_DATA_DIR}/matlab-bridge.port"
BRIDGE_PID_FILE="${BRIDGE_DATA_DIR}/matlab-bridge.pid"
BRIDGE_LOG="${TEMP:-/tmp}/matlab-bridge-out.log"
BRIDGE_SCRIPT="${SCRIPT_DIR}/matlab-bridge/matlab_bridge.py"

# ===== 颜色输出 =====
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[MATLAB Agent]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[MATLAB Agent]${NC} $1"; }
log_error() { echo -e "${RED}[MATLAB Agent]${NC} $1"; }
log_step()  { echo -e "${CYAN}[MATLAB Agent]${NC} $1"; }

# ===== Python 路径检测 =====
PYTHON_CMD=""
if command -v python &>/dev/null; then
    PYTHON_CMD="python"
elif command -v python3 &>/dev/null; then
    PYTHON_CMD="python3"
fi

# Helper: parse JSON field
json_get() {
    local json="$1" field="$2" default="${3:-unknown}"
    if [ -z "$json" ] || [ -z "$PYTHON_CMD" ]; then
        echo "$default"
        return
    fi
    echo "$json" | "$PYTHON_CMD" -c "import sys,json; m=json.load(sys.stdin).get('matlab',{}); print(m.get('$field','$default'))" 2>/dev/null || echo "$default"
}

# ===== 清理函数 =====
cleanup_pid_file() {
    rm -f "${PID_FILE}"
}

# ===== Step 1: 检查服务是否已在运行 =====
log_step "Step 1: Checking if service is already running..."

if curl -s --connect-timeout 3 "${HEALTH_URL}" > /dev/null 2>&1; then
    HEALTH_JSON=$(curl -s "${HEALTH_URL}" 2>/dev/null || echo '{}')
    WARMUP=$(json_get "$HEALTH_JSON" "warmup" "unknown")
    READY=$(json_get "$HEALTH_JSON" "ready" "False")

    log_info "Service already running at ${HEALTH_URL}"
    log_info "  Warmup: ${WARMUP}, Ready: ${READY}"

    if [ "$READY" = "True" ]; then
        log_info "Engine is ready. Nothing to do."
        exit 0
    elif [ "$WARMUP" = "failed" ]; then
        log_warn "Engine warmup previously failed. Server functional (CLI fallback)."
    else
        log_info "Engine still warming up..."
    fi
    exit 0
fi

# ===== Step 2: 清理残留进程 =====
log_step "Step 2: Cleaning residual processes..."

# v11.9: 先清理 Bridge 进程（读 PID 文件）
if [ -f "${BRIDGE_PID_FILE}" ]; then
    OLD_BRIDGE_PID=$(cat "${BRIDGE_PID_FILE}" 2>/dev/null || echo "")
    if [ -n "$OLD_BRIDGE_PID" ] && [ "$OLD_BRIDGE_PID" != "0" ]; then
        # 检查进程是否存活
        if tasklist 2>/dev/null | grep -q "$OLD_BRIDGE_PID" 2>/dev/null; then
            log_warn "Killing residual bridge process (PID ${OLD_BRIDGE_PID})"
            taskkill //F //PID "$OLD_BRIDGE_PID" > /dev/null 2>&1 || true
        fi
    fi
    rm -f "${BRIDGE_PID_FILE}" "${BRIDGE_PORT_FILE}"
fi

# 清理 Node.js 端口 3000
KILLED=0
LISTENING_PIDS=$(netstat -ano 2>/dev/null | grep ":${PORT} " | grep "LISTENING" | awk '{print $NF}' || echo "")
for pid in $LISTENING_PIDS; do
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        log_warn "Killing residual process on port ${PORT} (PID ${pid})"
        taskkill //F //PID "$pid" > /dev/null 2>&1 || true
        KILLED=$((KILLED + 1))
    fi
done

if [ $KILLED -gt 0 ]; then
    log_info "Waiting for port ${PORT} to be released..."
    for i in $(seq 1 8); do
        sleep 1
        if ! netstat -ano 2>/dev/null | grep ":${PORT} " | grep "LISTENING" > /dev/null 2>&1; then
            log_info "Port ${PORT} is clean"
            break
        fi
        if [ $i -eq 8 ]; then
            log_warn "Port ${PORT} still occupied after 8s. Proceeding anyway..."
        fi
    done
else
    log_info "Port ${PORT} is clean"
fi

# v11.9: 不再粗暴杀所有 Python/MATLAB 进程（bridge PID 已在上面处理）
# Node.js spawn 的 Python 进程如果存在，也会在上面通过端口清理被处理

# ===== Step 3: 确保 node_modules 存在 =====
log_step "Step 3: Checking node_modules..."

cd "${SCRIPT_DIR}"
if [ ! -d "node_modules" ]; then
    log_info "Installing dependencies..."
    if ! npm install --production > /dev/null 2>&1; then
        log_error "FATAL: npm install failed"
        exit 1
    fi
    log_info "Dependencies installed"
else
    log_info "node_modules exists"
fi

# ===== Step 4: 启动 Python Bridge (TCP 模式) =====
log_step "Step 4: Starting Python Bridge in TCP server mode..."

# v11.9: 读取 MATLAB_ROOT 配置
# Node.js controller 的配置目录是 skills/matlab-agent/data/（向上两层）
# Bridge 的数据目录是 app/data/（端口文件/PID 文件）
SKILL_DATA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/data"
# Python 需要 Windows 原生路径 — Git Bash 的 /c/ 路径 Python 不识别
if command -v cygpath &>/dev/null; then
    SKILL_DATA_DIR_WIN=$(cygpath -w "${SKILL_DATA_DIR}")
else
    SKILL_DATA_DIR_WIN=$(echo "${SKILL_DATA_DIR}" | sed 's|^/\([a-z]\)/|\U\1:/|')
fi
MATLAB_ROOT_VAL=""
CONFIG_FILE="${SKILL_DATA_DIR_WIN}\\matlab-config.json"
if [ -f "${SKILL_DATA_DIR}/matlab-config.json" ] && [ -n "$PYTHON_CMD" ]; then
    MATLAB_ROOT_VAL=$("$PYTHON_CMD" -c "import json; print(json.load(open(r'${SKILL_DATA_DIR_WIN}\matlab-config.json')).get('matlab_root',''))" 2>/dev/null || echo "")
fi

# 确保 data 目录存在
mkdir -p "${BRIDGE_DATA_DIR}"

# 启动 Bridge（bash & 后台运行，独立进程上下文，MATLAB Engine 可以正常启动）
MATLAB_ROOT="${MATLAB_ROOT_VAL}" "$PYTHON_CMD" "${BRIDGE_SCRIPT}" --tcp-server > "${BRIDGE_LOG}" 2>&1 &
BRIDGE_PID=$!
log_info "Bridge PID: ${BRIDGE_PID} (log: ${BRIDGE_LOG})"

# 等待 Bridge 端口文件出现（最多 30 秒）
BRIDGE_READY=0
for i in $(seq 1 30); do
    if [ -f "${BRIDGE_PORT_FILE}" ]; then
        BRIDGE_PORT=$(cat "${BRIDGE_PORT_FILE}" 2>/dev/null || echo "")
        if [ -n "$BRIDGE_PORT" ]; then
            # 验证端口可连接
            if "$PYTHON_CMD" -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', $BRIDGE_PORT)); s.close()" 2>/dev/null; then
                log_info "Bridge ready on 127.0.0.1:${BRIDGE_PORT} (${i}s)"
                BRIDGE_READY=1
                break
            fi
        fi
    fi

    # 检查 Bridge 进程是否还活着
    if ! kill -0 "${BRIDGE_PID}" 2>/dev/null; then
        log_error "Bridge process (PID ${BRIDGE_PID}) died during startup!"
        log_error "Check log: ${BRIDGE_LOG}"
        # 不退出 — Node.js 有 spawn fallback
        break
    fi

    sleep 1
done

if [ $BRIDGE_READY -eq 0 ]; then
    log_warn "Bridge not ready after 30s. Node.js will use spawn fallback."
    log_warn "Check bridge log: ${BRIDGE_LOG}"
fi

# ===== Step 5: 后台启动 Node.js 服务器 =====
log_step "Step 5: Starting Node.js server in background..."

# v11.9: Node.js 通过 TCP 连接 Bridge（不需要 spawn Python）
npx tsx server/index.ts > "${LOG_FILE}" 2>&1 &
SERVER_PID=$!

echo "${SERVER_PID}" > "${PID_FILE}"
log_info "Server PID: ${SERVER_PID} (saved to ${PID_FILE})"

# ===== Step 6: 轮询等待服务器启动 =====
log_step "Step 6: Waiting for server to start (max ${MAX_SERVER_WAIT}s)..."

WAITED=0
while [ $WAITED -lt $MAX_SERVER_WAIT ]; do
    sleep 2
    WAITED=$((WAITED + 2))

    if curl -s --connect-timeout 3 "${HEALTH_URL}" > /dev/null 2>&1; then
        log_info "Server ready at ${HEALTH_URL} (${WAITED}s)"
        break
    fi

    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        log_error "Server process (PID ${SERVER_PID}) died during startup!"
        log_error "Check log: ${LOG_FILE}"
        cleanup_pid_file
        exit 1
    fi

    if [ $WAITED -ge $MAX_SERVER_WAIT ]; then
        log_error "Server start timeout (${MAX_SERVER_WAIT}s)"
        log_error "Check log: ${LOG_FILE}"
        cleanup_pid_file
        exit 1
    fi
done

# ===== Step 7: 等待 MATLAB Engine 预热 =====
log_step "Step 7: Waiting for MATLAB Engine warmup (max ${MAX_WARMUP_WAIT}s)..."

WARMUP_WAITED=0
while [ $WARMUP_WAITED -lt $MAX_WARMUP_WAIT ]; do
    sleep 3
    WARMUP_WAITED=$((WARMUP_WAITED + 3))

    HEALTH_JSON=$(curl -s "${HEALTH_URL}" 2>/dev/null || echo '{}')
    WARMUP=$(json_get "$HEALTH_JSON" "warmup" "unknown")
    READY=$(json_get "$HEALTH_JSON" "ready" "False")

    if [ "$READY" = "True" ]; then
        log_info "MATLAB Engine ready! (${WARMUP_WAITED}s)"

        # 显示引擎信息
        STATUS_JSON=$(curl -s "http://localhost:${PORT}/api/matlab/status?quick=true" 2>/dev/null || echo '{}')
        if [ -n "$PYTHON_CMD" ] && [ -n "$STATUS_JSON" ] && [ "$STATUS_JSON" != "{}" ]; then
            echo "$STATUS_JSON" | "$PYTHON_CMD" -c "
import sys,json
d=json.load(sys.stdin)
for k in ['matlab_version_hint','matlab_root','connection_mode','engine_active']:
    v = d.get(k, '?')
    print(f'  {k}: {v}')
" 2>/dev/null
        fi
        exit 0
    fi

    if [ "$WARMUP" = "failed" ]; then
        ERROR=$(json_get "$HEALTH_JSON" "error" "unknown")
        log_warn "MATLAB Engine warmup failed: ${ERROR}"
        log_warn "Server is still functional (CLI fallback mode)."
        exit 0
    fi

    if [ $((WARMUP_WAITED % 15)) -eq 0 ]; then
        log_info "Warmup in progress... (${WARMUP_WAITED}/${MAX_WARMUP_WAIT}s) status=${WARMUP}"
    fi
done

log_warn "MATLAB Engine warmup timeout (${MAX_WARMUP_WAIT}s)"
log_warn "Server is still functional. Engine may start later in background."
exit 0
