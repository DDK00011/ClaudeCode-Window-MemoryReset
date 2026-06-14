@echo off
:: 백그라운드 활동 추적 작업 해제 (UAC 승격 → 관리자 권한)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Track-Schedule.ps1" -Remove
