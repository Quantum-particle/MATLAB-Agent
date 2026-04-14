@echo off
REM start_with_timeout.bat - 带超时的启动脚本
REM 委托到 ensure-running.bat
call "%~dp0ensure-running.bat" %*
