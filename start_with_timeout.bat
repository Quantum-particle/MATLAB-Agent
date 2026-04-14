@echo off
REM start_with_timeout.bat (root) - 带超时的启动脚本
REM 委托到 app/ensure-running.bat
call "%~dp0app\ensure-running.bat" %*
