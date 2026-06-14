@echo off
:: ════════════════════════════════════════════════════════════════════
::  Register background activity tracking in Task Scheduler (UAC elevation → administrator privileges)
::  Run -TrackActivity unattended at trackIntervalMin(default 5 minutes) intervals.
::  Record CPU snapshots only + send Telegram alerts when the threshold is exceeded. No process termination.
:: ════════════════════════════════════════════════════════════════════
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Track-Schedule.ps1"
