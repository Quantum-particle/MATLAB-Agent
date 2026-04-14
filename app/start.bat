@echo off
chcp 65001 >nul 2>&1
title MATLAB Agent - One-Click Start (v5.2)

echo.
echo ============================================================
echo   MATLAB Agent - One-Click Start (v5.2)
echo ============================================================
echo.

REM ====== 0. 切换到脚本所在目录（自动定位 app/） ======
cd /d "%~dp0"

REM ====== 1. 检查 node 是否可用 ======
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo [FATAL] Node.js not found! Please install Node.js 18+
    echo         Download: https://nodejs.org/
    pause
    exit /b 1
)
echo [OK] Node.js found

REM ====== 2. 检查并安装 node_modules ======
if not exist "node_modules" (
    echo [WARN] node_modules not found, running npm install...
    call npm install --production 2>&1
    if %errorlevel% neq 0 (
        echo [FATAL] npm install failed! Check network and try again.
        pause
        exit /b 1
    )
    echo [OK] npm install completed
) else (
    echo [OK] node_modules exists
)

REM ====== 3. 检查 Python 是否可用 ======
where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [WARN] Python not found! Engine API mode unavailable, will use CLI fallback.
    echo         For best experience, install Python 3.9+
) else (
    echo [OK] Python found
)

REM ====== 4. 检查 MATLAB 配置 ======
REM 注意：matlab-controller.ts 的 CONFIG_DIR 是 path.join(__dirname, '..', '..', 'data')
REM 即 skills/matlab-agent/data/，不是 app/data/！
REM 启动时 ensureDataDirSync() 会自动迁移 app/data/ 下的旧配置
if not exist "..\data\matlab-config.json" (
    echo [WARN] MATLAB not configured yet. Will prompt after server starts.
) else (
    echo [OK] MATLAB config found
)

REM ====== 5. 彻底清理端口 3000 上的旧进程（最优先！启动前必须确保环境干净！） ======
echo [INFO] Scanning port 3000 for residual processes...
set KILLED=0
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":3000 " ^| findstr "LISTENING" 2^>nul') do (
    echo [INFO] Killing old process on port 3000 (PID %%a)
    taskkill /F /PID %%a >nul 2>&1
    set /a KILLED+=1
)

REM 杀掉 TIME_WAIT / CLOSE_WAIT 状态的残留连接进程
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":3000 " ^| findstr /V "LISTENING" 2^>nul') do (
    REM 只杀非0的PID（0是系统空闲进程，不能杀）
    if %%a neq 0 (
        taskkill /F /PID %%a >nul 2>&1
    )
)

REM 等待端口释放并确认
if %KILLED% gtr 0 (
    echo [INFO] Waiting for port 3000 to be released...
    set PORT_FREE=0
    for /L %%i in (1,1,10) do (
        timeout /t 1 >nul 2>nul
        netstat -ano | findstr ":3000 " | findstr "LISTENING" >nul 2>nul
        if errorlevel 1 (
            set PORT_FREE=1
            goto port_released
        )
        echo     Waiting for port release... (%%i/10s^)
    )
    :port_released
    if "%PORT_FREE%"=="1" (
        echo [OK] Port 3000 is clean and available
    ) else (
        echo [WARN] Port 3000 still occupied after 10s! Proceeding anyway...
        echo         If startup fails, manually kill the process:
        echo         netstat -ano ^| findstr ":3000" ^| findstr "LISTENING"
    )
) else (
    echo [OK] Port 3000 is clean - no residual processes found
)

REM ====== 6. 后台启动服务器 ======
echo [INFO] Starting MATLAB Agent server...
start /B npx tsx server/index.ts > "%TEMP%\matlab-agent-out.log" 2>&1

REM ====== 7. 轮询等待服务器启动（用 PowerShell 替代 curl，避免输入重定向问题） ======
echo [INFO] Waiting for server to start (max 30s)...
set WAITED=0
set MAX_WAIT=30

:wait_server
timeout /t 1 >nul 2>nul
set /a WAITED+=1
REM 使用 2>nul 而不是 >nul 2>&1，避免 cmd /c 调用时的输入重定向错误
powershell -NoProfile -Command "try { $null = Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -UseBasicParsing -TimeoutSec 3; exit 0 } catch { exit 1 }" 2>nul
if %errorlevel% equ 0 goto server_up
if %WAITED% geq %MAX_WAIT% goto server_timeout
echo     Waiting... (%WAITED%/%MAX_WAIT%s)
goto wait_server

:server_up
echo [OK] Server is up (%WAITED%s)

REM ====== 8. 检查 MATLAB 配置 ======
powershell -NoProfile -Command "try { $r = Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/config' -TimeoutSec 5; if ($r.matlab_root) { exit 0 } else { exit 1 } } catch { exit 1 }" 2>nul
if %errorlevel% neq 0 (
    echo.
    echo ============================================================
    echo   MATLAB not configured! First-time setup:
    echo.
    echo   Your MATLAB install path examples:
    echo     D:\Program Files\MATLAB\R2023b
    echo     D:\Program Files^(x86^)\MATLAB2023b
    echo     C:\Program Files\MATLAB\R2024a
    echo.
    echo   Configure via quickstart API (use ConvertTo-Json):
    echo     POST http://localhost:3000/api/matlab/quickstart
    echo     $b = @{matlabRoot='YOUR_PATH';projectDir='YOUR_PROJECT'} ^| ConvertTo-Json -Compress
    echo     Invoke-RestMethod -Uri 'http://localhost:3000/api/matlab/quickstart' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
    echo ============================================================
    echo.
    goto show_status
)

echo [OK] MATLAB configured

REM ====== 9. 等待 MATLAB Engine 预热 ======
echo [INFO] Waiting for MATLAB Engine warmup (up to 90s)...
set WARMUP_WAITED=0
set MAX_WARMUP=90

:wait_warmup
timeout /t 3 >nul 2>nul
set /a WARMUP_WAITED+=3

powershell -NoProfile -Command "try { $r = Invoke-RestMethod -Uri 'http://localhost:3000/api/health' -TimeoutSec 5; if ($r.matlab.ready -eq $true) { exit 0 } elseif ($r.matlab.warmup -eq 'failed') { exit 2 } else { exit 1 } } catch { exit 1 }" 2>nul
if %errorlevel% equ 0 goto warmup_done
if %errorlevel% equ 2 (
    echo [WARN] MATLAB Engine warmup failed - CLI fallback mode active
    echo        Server is still functional, but variables won't persist between commands.
    goto show_status
)
if %WARMUP_WAITED% geq %MAX_WARMUP% (
    echo [WARN] MATLAB Engine warmup timeout (%MAX_WARMUP%s)
    echo        Server is still functional. Engine may still be starting in background.
    goto show_status
)
echo     Warmup... (%WARMUP_WAITED%/%MAX_WARMUP%s)
goto wait_warmup

:warmup_done
echo [OK] MATLAB Engine ready! (%WARMUP_WAITED%s)

:show_status
echo.
echo ============================================================
echo   MATLAB Agent Status:
echo     Server:  http://localhost:3000
echo     Health:  http://localhost:3000/api/health
echo     Config:  http://localhost:3000/api/matlab/config
echo     Log:     %TEMP%\matlab-agent-out.log
echo.
echo   Quick Start API (use ConvertTo-Json, do NOT inline JSON in -Body):
echo     POST http://localhost:3000/api/matlab/quickstart
echo     $b = @{matlabRoot='YOUR_PATH';projectDir='YOUR_PROJECT'} ^| ConvertTo-Json -Compress
echo     Invoke-RestMethod -Uri '...' -Method POST -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($b))
echo ============================================================
echo.
echo Server running in background. Closing this window won't stop it.
timeout /t 10 >nul 2>nul
exit /b 0

:server_timeout
echo [FATAL] Server failed to start within %MAX_WAIT%s
echo         Check log: %TEMP%\matlab-agent-out.log
type "%TEMP%\matlab-agent-out.log" 2>nul
pause
exit /b 1
