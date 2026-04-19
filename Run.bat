@echo off
:: ════════════════════════════════════════════════════════════════════
::  Memory Reset — double-click launcher
::  PowerShell script automatically elevates UAC internally.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" %*
exit /b %ERRORLEVEL%
