@echo off
:: Unregister background activity tracking task (UAC elevation → administrator privileges)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Track-Schedule.ps1" -Remove
