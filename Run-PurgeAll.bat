@echo off
:: ════════════════════════════════════════════════════════════════════
::  원클릭 전체 청소 (재부팅 느낌) — UAC 승격
::  모든 claude / Antigravity + 자손 트리(conhost/bash/node/pwsh/python/cmd 등
::  세션이 띄운 "부산물")를 종료하고, 깊은 메모리 회수까지 수행:
::    working set 비우기 + file cache 트림 + Memory Compression flush + standby purge.
::
::  [주의] 작업 중인 claude 세션도 모두 종료됩니다. 종료 전 Y/n 확인이 표시됩니다.
::         특정 세션만 살리려면 아래처럼 -Interactive / -KeepPids 와 함께 쓰세요:
::         MemoryReset.ps1 -Deep -IncludeDescendants -Interactive
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MemoryReset.ps1" -Deep -IncludeDescendants
exit /b %ERRORLEVEL%
