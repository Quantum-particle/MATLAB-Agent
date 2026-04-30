@echo off
chcp 65001 >nul 2>&1
title MATLAB Agent
echo.
echo   MATLAB Agent - 请在 Git Bash 中启动
echo   =====================================
echo.
echo   启动命令:
echo     bash ensure-running.sh
echo.
echo   Engine 预计 20-30 秒就绪。
echo.
echo   如无 Git Bash，安装: https://git-scm.com/
echo.
pause
exit /b 1
