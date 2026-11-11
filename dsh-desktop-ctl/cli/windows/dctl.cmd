@echo off
rem dctl.cmd — Windows 命令行入口：把参数原样转给同目录的 dctl.ps1。
rem 有 PowerShell 7（pwsh）就用它（UTF-8 更省心），否则用系统自带的 5.1。
rem 退出码原样返回，方便脚本里 if errorlevel 判断。
setlocal
set "PS=powershell.exe"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0dctl.ps1" %*
exit /b %ERRORLEVEL%
