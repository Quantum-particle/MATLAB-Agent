@echo off
chcp 65001 >nul 2>&1
title MATLAB Agent Quick Start

echo.
echo ╔════════════════════════════════════════════════════╗
echo ║   MATLAB Agent - Quick Start                      ║
echo ╚════════════════════════════════════════════════════╝
echo.

cd /d "%~dp0"

REM 检查端口是否已被占用
netstat -ano | findstr ":3000 " | findstr "LISTENING" >nul 2>&1
if %errorlevel%==0 (
    echo [!] 端口 3000 已被占用，MATLAB Agent 可能已在运行
    echo     尝试检查状态...
    curl -s http://localhost:3000/api/health 2>nul
    echo.
    echo.
    echo 如果需要重启，请先关闭现有进程
    timeout /t 5 >nul
    exit /b 0
)

echo [*] 启动 MATLAB Agent 服务器...
start /b cmd /c "npx tsx server/index.ts > server_startup.log 2>&1"

echo [*] 等待服务器启动...
set MAX_WAIT=30
set WAITED=0

:wait_server
timeout /t 1 >nul
set /a WAITED+=1
curl -s http://localhost:3000/api/health >nul 2>&1
if %errorlevel% neq 0 (
    if %WAITED% geq %MAX_WAIT% (
        echo [!] 服务器启动超时 (%MAX_WAIT%秒)
        echo     请检查 server_startup.log
        type server_startup.log
        pause
        exit /b 1
    )
    echo     等待中... (%WAITED%/%MAX_WAIT%s)
    goto wait_server
)

echo [✓] 服务器已启动 (%WAITED%s)

echo [*] 等待 MATLAB Engine 预热...
set MAX_WARMUP=120
set WARMUP_WAITED=0

:wait_warmup
timeout /t 2 >nul
set /a WARMUP_WAITED+=2

REM 检查预热状态
for /f "delims=" %%i in ('curl -s http://localhost:3000/api/matlab/warmup-status 2^>nul') do set WARMUP_RESULT=%%i

echo %WARMUP_RESULT% | findstr /c:"ready" >nul 2>&1
if %errorlevel%==0 (
    echo [✓] MATLAB Engine 预热完成! (总计 %WARMUP_WAITED%s)
    echo.
    echo ╔════════════════════════════════════════════════════╗
    echo ║   MATLAB Agent 已就绪!                            ║
    echo ║                                                    ║
    echo ║   API: http://localhost:3000                       ║
    echo ║   前端: http://localhost:5173 (需另启动)            ║
    echo ╚════════════════════════════════════════════════════╝
    echo.
    echo 服务器在后台运行中。关闭此窗口不会停止服务。
    timeout /t 10 >nul
    exit /b 0
)

echo %WARMUP_RESULT% | findstr /c:"failed" >nul 2>&1
if %errorlevel%==0 (
    echo [!] MATLAB Engine 预热失败
    echo     %WARMUP_RESULT%
    echo     API 服务器仍然可用，但首次 MATLAB 操作会很慢
    timeout /t 5 >nul
    exit /b 0
)

if %WARMUP_WAITED% geq %MAX_WARMUP% (
    echo [!] 预热超时 (%MAX_WARMUP%s)
    echo     API 服务器可用，但 MATLAB Engine 可能仍在启动中
    echo     调用 /api/matlab/warmup-status 查看状态
    timeout /t 5 >nul
    exit /b 0
)

echo     预热中... (%WARMUP_WAITED%/%MAX_WARMUP%s)
goto wait_warmup
