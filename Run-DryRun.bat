@echo off
:: Mode that previews target processes only without termination/recovery
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -DryRun
exit /b %ERRORLEVEL%
