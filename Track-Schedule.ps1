#Requires -Version 5.1
<#
.SYNOPSIS
    MemoryReset 백그라운드 활동 추적(-TrackActivity)을 Windows 작업 스케줄러에 등록/해제.

.DESCRIPTION
    tracker-settings.json 의 trackIntervalMin 간격으로 -TrackActivity 를 무인(창 숨김) 실행하는
    작업을 만든다. -TrackActivity 는 read-only — CPU 스냅샷을 기록하고 임계 초과 시 텔레그램 알림만
    보낼 뿐, 어떤 프로세스도 종료하지 않는다. 실제 정리(kill)는 사용자가 Run-IdleCleanup.bat 으로 수동 실행.
    작업 등록/해제에는 관리자 권한이 필요하므로 자동으로 UAC 승격한다.

.PARAMETER Remove
    작업 해제 (기본은 등록).

.EXAMPLE
    .\Track-Schedule.ps1            # 등록 (trackIntervalMin 간격)
    .\Track-Schedule.ps1 -Remove    # 해제
#>
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$taskName   = 'ClaudeCodeMemoryTracker'
$scriptPath = Join-Path $PSScriptRoot 'MemoryReset.ps1'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 작업 스케줄러 등록/해제는 관리자 권한 필요 → 자동 승격
if (-not (Test-IsAdmin)) {
    Write-Host "[!] 작업 스케줄러 등록/해제에는 관리자 권한이 필요합니다. UAC 승격을 시도합니다..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch { Write-Host "[X] 승격 실패: $_" -ForegroundColor Red; exit 1 }
    exit 0
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] 추적 작업 해제됨: $taskName" -ForegroundColor Green
    } catch {
        Write-Host "[i] 해제할 작업이 없거나 실패: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host ""; Read-Host "Enter 로 종료" | Out-Null
    exit 0
}

# ── 등록 ──
if (-not (Test-Path $scriptPath)) {
    Write-Host "[X] MemoryReset.ps1 을 같은 폴더에서 찾을 수 없음: $scriptPath" -ForegroundColor Red
    exit 1
}

# trackIntervalMin 을 설정에서 읽음 (기본 5)
$interval = 5
$cfg = Join-Path $PSScriptRoot 'tracker-settings.json'
if (Test-Path $cfg) {
    try {
        $v = (Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).trackIntervalMin
        if ($v -is [int] -or ($v -as [int])) { if ([int]$v -ge 1) { $interval = [int]$v } }
    } catch { Write-Host "[i] trackIntervalMin 읽기 실패 — 기본 5분 사용" -ForegroundColor DarkGray }
}

try {
    $argStr   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -TrackActivity"
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
    $trigger  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
                    -RepetitionInterval (New-TimeSpan -Minutes $interval) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
    # LIMITED: -TrackActivity 는 admin 불필요(read-only). Interactive: 로그인 세션에서 CPU 조회 가능.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Host "[OK] 추적 작업 등록됨: $taskName" -ForegroundColor Green
    Write-Host ("    → {0}분 간격으로 -TrackActivity 무인 실행 (창 숨김)" -f $interval) -ForegroundColor DarkGray
    Write-Host "    → CPU 스냅샷만 기록 + 임계 초과 시 텔레그램 알림. 프로세스 종료는 하지 않음." -ForegroundColor DarkGray
    Write-Host "    → 정리는 수동: Run-IdleDryRun.bat (미리보기) → Run-IdleCleanup.bat (실제)" -ForegroundColor DarkGray
    Write-Host "    → 해제: Track-Unregister.bat" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] 작업 등록 실패: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""; Read-Host "Enter 로 종료" | Out-Null
