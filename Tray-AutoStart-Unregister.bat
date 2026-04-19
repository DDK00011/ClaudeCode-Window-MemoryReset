@echo off
:: Unregister Memory Reset Tray from Startup
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tray-AutoStart.ps1" -Remove
pause
