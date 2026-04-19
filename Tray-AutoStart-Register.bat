@echo off
:: Register Memory Reset Tray in Windows Startup (user privileges, UAC not required)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tray-AutoStart.ps1"
pause
