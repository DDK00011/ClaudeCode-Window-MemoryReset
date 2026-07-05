#Requires -Version 5.1
<#
.SYNOPSIS
    Register/unregister MemoryReset background activity tracking(-TrackActivity) in Windows Task Scheduler.

.DESCRIPTION
    The task that runs -TrackActivity unattended(hidden window) at the trackIntervalMin interval in tracker-settings.json is
    created. -TrackActivity is read-only — it records CPU snapshots and sends Telegram alerts
    only when the threshold is exceeded, and does not terminate any process. Actual cleanup(kill) is manually run by the user with Run-IdleCleanup.bat.
    Task registration/unregistration requires administrator privileges, so it automatically requests UAC elevation.

.PARAMETER Remove
    Unregister task (registration is default).

.EXAMPLE
    .\Track-Schedule.ps1            # Register (trackIntervalMin interval)
    .\Track-Schedule.ps1 -Remove    # Unregister
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

# Task Scheduler registration/unregistration requires administrator privileges → elevate automatically
if (-not (Test-IsAdmin)) {
    Write-Host "[!] Task Scheduler registration/unregistration requires administrator privileges. Attempting UAC elevation..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch { Write-Host "[X] Elevation failed: $_" -ForegroundColor Red; exit 1 }
    exit 0
}

if ($Remove) {
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Host "[OK] Tracking task unregistered: $taskName" -ForegroundColor Green
    } catch {
        Write-Host "[i] No task to unregister or operation failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host ""; Read-Host "Press Enter to exit" | Out-Null
    exit 0
}

# ── Registration ──
if (-not (Test-Path $scriptPath)) {
    Write-Host "[X] Cannot find MemoryReset.ps1 in the same folder: $scriptPath" -ForegroundColor Red
    exit 1
}

# Read trackIntervalMin from settings (default 5)
$interval = 5
$cfg = Join-Path $PSScriptRoot 'tracker-settings.json'
if (Test-Path $cfg) {
    try {
        $v = (Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).trackIntervalMin
        if ($v -is [int] -or ($v -as [int])) { if ([int]$v -ge 1) { $interval = [int]$v } }
    } catch { Write-Host "[i] trackIntervalMin read failed — using default 5 min" -ForegroundColor DarkGray }
}

try {
    $argStr   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -TrackActivity"
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
    $trigger  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
                    -RepetitionInterval (New-TimeSpan -Minutes $interval) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
    # LIMITED: -TrackActivity does not require admin(read-only). Interactive: in logged-in session CPU can be queried.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Host "[OK] Tracking task registered: $taskName" -ForegroundColor Green
    Write-Host ("    → Every {0} min run -TrackActivity unattended (window hidden)" -f $interval) -ForegroundColor DarkGray
    Write-Host "    → CPU snapshots only + Telegram alert when threshold exceeded. Process termination handled by auto cleanup/manual cleanup." -ForegroundColor DarkGray
    Write-Host "    → Auto cleanup: Cleanup-Schedule.ps1 (default 3 hours). Immediate cleanup: Run-IdleDryRun.bat → Run-IdleCleanup.bat" -ForegroundColor DarkGray
    Write-Host "    → Unregister: Track-Unregister.bat" -ForegroundColor DarkGray
} catch {
    Write-Host "[X] Task registration failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""; Read-Host "Press Enter to exit" | Out-Null
