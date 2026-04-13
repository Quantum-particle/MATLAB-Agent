@echo off
REM ensure-running.bat - MATLAB Agent 确保服务运行脚本
REM 用途: AI agent 调用此脚本，确保 MATLAB Agent 服务器在后台运行
REM 返回: 退出码 0 = 服务可用, 1 = 不可用
REM 用法: cmd /c "C:\Users\<USERNAME>\.workbuddy\skills\matlab-agent\app\ensure-running.bat"

chcp 65001 >nul 2>&1
cd /d "%~dp0"

REM Step 1: 检查服务是否已在运行（用 PowerShell 检测，避免 curl 输入重定向问题）
powershell -Command "try { $null = Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -UseBasicParsing -TimeoutSec 3; exit 0 } catch { exit 1 }" >nul 2>&1
if %errorlevel% equ 0 (
    echo [MATLAB Agent] Service already running at http://localhost:3000
    exit /b 0
)

REM Step 2: 彻底清理端口 3000 上的残留进程（启动前必须确保环境干净！）
set KILLED=0
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":3000 " ^| findstr "LISTENING" 2^>nul') do (
    echo [MATLAB Agent] Killing residual process on port 3000 (PID %%a)
    taskkill /F /PID %%a >nul 2>&1
    set /a KILLED+=1
)

REM 等待端口释放并确认
if %KILLED% gtr 0 (
    echo [MATLAB Agent] Waiting for port 3000 to be released...
    for /L %%i in (1,1,8) do (
        timeout /t 1 >nul
        netstat -ano | findstr ":3000 " | findstr "LISTENING" >nul 2>&1
        if errorlevel 1 goto port_clean
    )
    echo [MATLAB Agent] WARN: Port 3000 still occupied, proceeding anyway...
) else (
    echo [MATLAB Agent] Port 3000 is clean
)
:port_clean

REM Step 3: 确保 node_modules 存在
if not exist "node_modules" (
    echo [MATLAB Agent] Installing dependencies...
    call npm install --production >nul 2>&1
    if %errorlevel% neq 0 (
        echo [MATLAB Agent] FATAL: npm install failed
        exit /b 1
    )
)

REM Step 4: 后台启动服务器
echo [MATLAB Agent] Starting server...
start /B cmd /c "npx tsx server/index.ts > "%TEMP%\matlab-agent-out.log" 2>&1"

REM Step 5: 轮询等待（最多 60 秒）
set WAITED=0
:wait_loop
timeout /t 2 >nul
set /a WAITED+=2
powershell -Command "try { $null = Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -UseBasicParsing -TimeoutSec 3; exit 0 } catch { exit 1 }" >nul 2>&1
if %errorlevel% equ 0 (
    echo [MATLAB Agent] Server ready at http://localhost:3000 (%WAITED%s^)
    exit /b 0
)
if %WAITED% geq 60 (
    echo [MATLAB Agent] Server start timeout (60s^). Check: %TEMP%\matlab-agent-out.log
    exit /b 1
)
goto wait_loop
