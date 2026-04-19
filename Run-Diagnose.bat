@echo off
:: Memory diagnostics only (no recovery, UAC not required)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Diagnose %*
exit /b %ERRORLEVEL%
