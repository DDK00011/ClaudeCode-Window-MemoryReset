@echo off
:: ════════════════════════════════════════════════════════════════════
::  idle(idleMinutes+ 무활동, CPU 율<임계) / orphan 프로세스만 종료 + 메모리 회수
::  활성 세션은 idleMinutes 안에 CPU 를 쓰므로 후보에서 제외됨 → 보존.
::  먼저 Run-IdleDryRun.bat 으로 대상을 확인한 뒤 실행하길 권장.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -IdleOnly
exit /b %ERRORLEVEL%
