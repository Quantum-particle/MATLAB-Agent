@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0app"
echo [%time%] Starting MATLAB Agent server...
echo [%time%] Working dir: %cd%
start /B cmd /c "npx tsx server/index.ts > "%TEMP%\matlab-agent-out.log" 2>&1"
echo [%time%] Server launched in background
echo [%time%] Log: %TEMP%\matlab-agent-out.log
echo [%time%] API: http://localhost:3000/api/health
