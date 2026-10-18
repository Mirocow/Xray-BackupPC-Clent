@echo off
rem Double-click installer: asks for administrator rights and runs install.ps1
rem regardless of the PowerShell execution policy.
net session >nul 2>&1 || (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
