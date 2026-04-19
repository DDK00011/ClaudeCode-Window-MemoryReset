@echo off
:: Deep recovery: Tier A (Memory Compression flush + System WS + network cache)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Deep %*
exit /b %ERRORLEVEL%
