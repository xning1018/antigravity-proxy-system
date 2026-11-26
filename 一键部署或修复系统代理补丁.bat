@echo off
chcp 65001 >nul
setlocal
set "SCRIPT="
if exist "%~dp0deploy.ps1" set "SCRIPT=%~dp0deploy.ps1"
if not defined SCRIPT if exist "%LOCALAPPDATA%\antigravity-proxy-system\deploy.ps1" set "SCRIPT=%LOCALAPPDATA%\antigravity-proxy-system\deploy.ps1"
if not defined SCRIPT (
    echo [ERROR] deploy.ps1 not found. Please run this script from the extracted package directory first.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Setup
echo.
pause