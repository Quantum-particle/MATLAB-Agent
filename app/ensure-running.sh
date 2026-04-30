#!/bin/bash
# ensure-running.sh - MATLAB Agent 确保服务运行脚本 (v11.4.2)
# 用途: Git Bash 原生启动，确保 MATLAB Agent 服务器在后台运行
# 返回: exit 0 = 服务可用, exit 1 = 不可用
#
# 用法:
#   在 app/ 目录下:  bash ensure-running.sh
#   从 skill 根目录: bash app/ensure-running.sh
#
# [v11.4.2] 替代 ensure-running.bat 的 Git Bash 原生方案。
# Windows CMD 的 start /B 会共享控制台，导致 MATLAB Engine 的
# "Simple server" 无法启动。bash 的 & 后台运行无此问题。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=3000
HEALTH_URL="http://localhost:${PORT}/api/health"
LOG_FILE="${TEMP:-/tmp}/matlab-agent-out.log"
PID_FILE="${SCRIPT_DIR}/.matlab_agent_pid"
MAX_SERVER_WAIT=60
MAX_WARMUP_WAIT=90

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

# ===== Step 2: 清理端口 3000 上的残留进程 =====
log_step "Step 2: Cleaning port ${PORT}..."

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

# 清理残留 MATLAB/Python 进程
for proc in "MATLAB.exe" "python.exe"; do
    PIDS=$(tasklist 2>/dev/null | grep -i "$proc" | awk '{print $2}' || echo "")
    for pid in $PIDS; do
        if [ -n "$pid" ]; then
            taskkill //F //PID "$pid" > /dev/null 2>&1 || true
        fi
    done
done

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

# ===== Step 4: 后台启动服务器（bash & 方式，无 console 共享） =====
log_step "Step 4: Starting server in background (bash native & operator)..."

# [v11.4.2] Use bash & (not CMD start /B) for true background execution.
# start /B shares the CMD console, which prevents MATLAB Engine from
# creating its "Simple server" for process communication.
npx tsx server/index.ts > "${LOG_FILE}" 2>&1 &
SERVER_PID=$!

echo "${SERVER_PID}" > "${PID_FILE}"
log_info "Server PID: ${SERVER_PID} (saved to ${PID_FILE})"

# ===== Step 5: 轮询等待服务器启动 =====
log_step "Step 5: Waiting for server to start (max ${MAX_SERVER_WAIT}s)..."

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

# ===== Step 6: 等待 MATLAB Engine 预热 =====
log_step "Step 6: Waiting for MATLAB Engine warmup (max ${MAX_WARMUP_WAIT}s)..."

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
