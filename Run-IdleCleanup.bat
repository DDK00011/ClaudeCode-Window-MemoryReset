@echo off
:: ════════════════════════════════════════════════════════════════════
::  idle(idleMinutes+ inactivity, CPU rate<threshold) / terminate orphan processes only + memory recovery
::  Active sessions use CPU within idleMinutes, so excluded from candidates → preserved.
::  Recommended: check targets with Run-IdleDryRun.bat first, then run.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -IdleOnly
exit /b %ERRORLEVEL%
