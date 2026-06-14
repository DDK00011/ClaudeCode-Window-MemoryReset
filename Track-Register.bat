@echo off
:: ════════════════════════════════════════════════════════════════════
::  백그라운드 활동 추적을 작업 스케줄러에 등록 (UAC 승격 → 관리자 권한)
::  trackIntervalMin(기본 5분) 간격으로 -TrackActivity 무인 실행.
::  CPU 스냅샷만 기록 + 임계 초과 시 텔레그램 알림. 프로세스 종료 없음.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Track-Schedule.ps1"
