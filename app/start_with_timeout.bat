@echo off
cd /d "%~dp0"
echo [%time%] Starting npx tsx server/index.ts ...
echo [%time%] Timeout: 60 seconds
start /b /wait cmd /c "npx tsx server/index.ts > server_startup.log 2>&1"
echo [%time%] Process exited
