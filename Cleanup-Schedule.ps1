#Requires -Version 5.1
<#
.SYNOPSIS
    MemoryReset 자동 정리(-IdleOnly)를 Windows 작업 스케줄러에 등록/해제.

.DESCRIPTION
    IntervalHours(기본 3) 간격으로 -IdleOnly -SkipConfirmation 를 무인(창 숨김) 실행한다.
    idle(idleMinutes+ 무활동, CPU 율<임계) / orphan(부모 죽음) 프로세스만 종료 → 활성 세션은 보존.
    종료(kill)에는 관리자 권한이 필요하므로 RunLevel Highest 로 등록(로그인 세션에서 UAC 없이 승격).
    등록/해제 자체에도 관리자 권한이 필요하므로 자동으로 UAC 승격한다.

    * 전제: 감시 작업(Track-Schedule.ps1)이 함께 돌아 activity-state.json 이 idleMinutes 이상
      누적돼야 idle 판정이 가능. 그 전에는 orphan(부모 죽음) 만 정리된다.

.PARAMETER Remove
    작업 해제 (기본은 등록).

.PARAMETER IntervalHours
    실행 간격(시간). 기본 3.

.EXAMPLE
    .\Cleanup-Schedule.ps1                 # 3시간 간격 등록
    .\Cleanup-Schedule.ps1 -IntervalHours 6
    .\Cleanup-Schedule.ps1 -Remove         # 해제
#>
[CmdletBinding()]
param([switch]$Remove, [int]$IntervalHours = 3)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$taskName   = 'ClaudeCodeMemoryCleanup'
$scriptPath = Join-Path $PSScriptRoot 'MemoryReset.ps1'
$runnerPath = Join-Path $PSScriptRoot 'Run-Hidden.vbs'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 작업 스케줄러 등록/해제는 관리자 권한 필요 → 자동 승격
if (-not (Test-IsAdmin)) {
    Write-Host "[!] 작업 스케줄러 등록/해제에는 관리자 권한이 필요합니다. UAC 승격을 시도합니다..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    if ($PSBoundParameters.ContainsKey('IntervalHours')) { $argList += @('-IntervalHours', $IntervalHours) }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch { Write-Host "[X] 승격 실패: $_" -ForegroundColor Red; exit 1 }
    exit 0
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] 자동 정리 작업 해제됨: $taskName" -ForegroundColor Green
    } catch {
        Write-Host "[i] 해제할 작업이 없거나 실패: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host ""; Read-Host "Enter 로 종료" | Out-Null
    exit 0
}

# ── 등록 ──
if (-not (Test-Path $scriptPath) -or -not (Test-Path $runnerPath)) {
    Write-Host "[X] MemoryReset.ps1 또는 Run-Hidden.vbs 를 같은 폴더에서 찾을 수 없음" -ForegroundColor Red
    exit 1
}
if ($IntervalHours -lt 1) { $IntervalHours = 3 }

try {
    $argStr   = "//B //NoLogo `"$runnerPath`" -IdleOnly -SkipConfirmation -KeepAlive"
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $argStr
    $trigger  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
                    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
    # RunLevel Highest: -IdleOnly 종료(kill)에 관리자 권한 필요.
    # Interactive: 로그인 세션에서 실행(사용자가 관리자 그룹이면 UAC 팝업 없이 승격).
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    # ExecutionTimeLimit: 혹시 멈춰도 15분 후 강제 종료 (무인 작업이 좀비화되지 않도록)
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Host "[OK] 자동 정리 작업 등록됨: $taskName" -ForegroundColor Green
    Write-Host ("    → {0}시간 간격으로 -IdleOnly 무인 실행 (창 숨김)" -f $IntervalHours) -ForegroundColor DarkGray
    Write-Host "    → idle(무활동) / orphan(부모 죽음) 프로세스만 종료 + 메모리 회수. 활성 세션 보존." -ForegroundColor DarkGray
    Write-Host "    → 감시(Track-Schedule.ps1)가 함께 돌아야 idle 판정 이력이 쌓입니다." -ForegroundColor DarkGray
    Write-Host "    → 해제: .\Cleanup-Schedule.ps1 -Remove" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] 작업 등록 실패: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""; Read-Host "Enter 로 종료" | Out-Null
