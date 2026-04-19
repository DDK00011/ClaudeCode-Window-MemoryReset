@echo off
:: Memory Reset Tray daemon — start in hidden window
:: (Only the system tray icon is visible and the console is hidden)
:: -Sta : WinForms / NotifyIcon requires an STA thread (PS 5.1 default is MTA)
chcp 65001 >nul
start "" /b powershell.exe -Sta -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset-Tray.ps1"
exit /b 0
