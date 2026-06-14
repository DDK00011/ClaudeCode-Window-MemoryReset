@echo off
:: ════════════════════════════════════════════════════════════════════
::  idle(idleMinutes+ 무활동, CPU 율<임계) / orphan 프로세스 정리 대상 미리보기
::  실제 종료 없음. 추적 이력(activity-state.json)이 idleMinutes 이상 누적돼야 후보가 잡힘.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -IdleOnly -DryRun
exit /b %ERRORLEVEL%
