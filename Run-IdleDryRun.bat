@echo off
:: ════════════════════════════════════════════════════════════════════
::  Preview idle(idleMinutes+ inactivity, CPU rate<threshold) / orphan process cleanup targets
::  No actual termination. Candidate appears only after tracking history(activity-state.json) accumulates for idleMinutes or more.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -IdleOnly -DryRun
exit /b %ERRORLEVEL%
