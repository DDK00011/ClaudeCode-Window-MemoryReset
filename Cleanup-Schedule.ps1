#Requires -Version 5.1
<#
.SYNOPSIS
    Register/unregister MemoryReset auto cleanup(-IdleOnly) with Windows Task Scheduler.

.DESCRIPTION
    Run -IdleOnly -SkipConfirmation unattended(hidden window) at IntervalHours(default 3) intervals.
    Terminate only idle(idleMinutes+ inactivity, CPU rate<threshold) / orphan(parent dead) processes → preserve active sessions.
    Termination(kill) requires administrator privileges, so register at RunLevel Highest (elevation without UAC in the login session).
    Registration/unregistration also requires administrator privileges, so request UAC elevation automatically.

    * Prerequisite: tracking task(Track-Schedule.ps1) must also run, and activity-state.json must accumulate idleMinutes or more
      accumulate for at least idleMinutes before idle can be determined. Before then, only orphan(parent dead) is cleaned up.

.PARAMETER Remove
    Unregister task (registration is default).

.PARAMETER IntervalHours
    Execution interval(hours). Default 3.

.EXAMPLE
    .\Cleanup-Schedule.ps1                 # Register every 3 hours
    .\Cleanup-Schedule.ps1 -IntervalHours 6
    .\Cleanup-Schedule.ps1 -Remove         # Unregister
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

# Task Scheduler registration/unregistration requires administrator privileges → elevate automatically
if (-not (Test-IsAdmin)) {
    Write-Host "[!] Task Scheduler registration/unregistration requires administrator privileges. Attempting UAC elevation..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    if ($PSBoundParameters.ContainsKey('IntervalHours')) { $argList += @('-IntervalHours', $IntervalHours) }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch { Write-Host "[X] Elevation failed: $_" -ForegroundColor Red; exit 1 }
    exit 0
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] Auto cleanup task unregistered: $taskName" -ForegroundColor Green
    } catch {
        Write-Host "[i] No task to unregister or operation failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host ""; Read-Host "Press Enter to exit" | Out-Null
    exit 0
}

# ── Registration ──
if (-not (Test-Path $scriptPath) -or -not (Test-Path $runnerPath)) {
    Write-Host "[X] Cannot find MemoryReset.ps1 or Run-Hidden.vbs in the same folder" -ForegroundColor Red
    exit 1
}
if ($IntervalHours -lt 1) { $IntervalHours = 3 }

try {
    $argStr   = "//B //NoLogo `"$runnerPath`" -IdleOnly -SkipConfirmation -KeepAlive"
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $argStr
    $trigger  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
                    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
    # RunLevel Highest: -IdleOnly termination(kill) requires administrator privileges.
    # Interactive: run in the login session(elevate without a UAC prompt if user is in administrator group).
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    # ExecutionTimeLimit: force-kill after 15 minutes if stalled (prevents unattended task from becoming an orphan)
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Host "[OK] Auto cleanup task registered: $taskName" -ForegroundColor Green
    Write-Host ("    → Run -IdleOnly unattended every {0} hours (hidden window)" -f $IntervalHours) -ForegroundColor DarkGray
    Write-Host "    → Terminate only idle(inactivity) / orphan(parent dead) processes + reclaim memory. Preserve active sessions." -ForegroundColor DarkGray
    Write-Host "    → Tracking(Track-Schedule.ps1) must run too so idle determination history accumulates." -ForegroundColor DarkGray
    Write-Host "    → Unregister: .\Cleanup-Schedule.ps1 -Remove" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] Task registration failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""; Read-Host "Press Enter to exit" | Out-Null
