@echo off
:: Memory Reset Tray daemon — start in hidden window
:: (Only the system tray icon is visible and the console is hidden)
chcp 65001 >nul
start "" /b powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset-Tray.ps1"
exit /b 0
