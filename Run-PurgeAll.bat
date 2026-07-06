@echo off
:: ════════════════════════════════════════════════════════════════════
::  One-click full cleanup (reboot feel) — UAC elevation
::  All claude / Codex CLI + descendant tree(conhost/bash/node/pwsh/python/cmd etc
::  session-launched "byproducts") are terminated, then deep memory recovery is performed:
::    empty working set + trim file cache + Memory Compression flush + standby purge.
::
::  [Caution] All active claude sessions will also terminate. Y/n confirmation appears before termination.
::         To keep only specific sessions, use with -Interactive / -KeepPids as below:
::         MemoryReset.ps1 -Deep -IncludeDescendants -Interactive
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Deep -IncludeDescendants
exit /b %ERRORLEVEL%
