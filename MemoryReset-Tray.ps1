#Requires -Version 5.1
<#
.SYNOPSIS
    Memory Reset system tray daemon — memory monitoring + threshold alerts + quick recovery.

.DESCRIPTION
    Runs as an icon in the Windows notification area and does the following:

      · Check memory usage every 30 seconds (real time display in tooltip)
      · Show a BalloonTip alert when threshold(default 90%) is reached — no auto recovery, user decides
      · Right click menu: standard recovery / deep recovery / diagnostics / view history / threshold settings / exit
      · Single instance guarantee (mutex)
      · Delegate recovery work to MemoryReset.ps1 (automatic UAC elevation)

    Settings are stored in tray-settings.json in the same folder.

.NOTES
    Running Tray.bat in a hidden window is recommended.
    The daemon does not require administrator privileges — MemoryReset.ps1 elevates with UAC when recovery is triggered.
#>

[CmdletBinding()]
param()

# ════════════════════════════════════════════════════════════════════
# 1. Load assemblies early (before mutex check — make MessageBox available)
# ════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # InputBox
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ════════════════════════════════════════════════════════════════════
# 2. Single instance mutex
#    Local\ scope (user session) — Global\ may have permission issues
# ════════════════════════════════════════════════════════════════════
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, 'Local\MemoryReset-Tray-Singleton', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Memory Reset Tray is already running.`nCheck the memory icon in the system tray (next to the clock).",
        "Memory Reset",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

# ════════════════════════════════════════════════════════════════════
# 3. Settings (tray-settings.json)
# ════════════════════════════════════════════════════════════════════
$script:scriptDir    = $PSScriptRoot
$script:mainScript   = Join-Path $scriptDir 'MemoryReset.ps1'
$script:settingsPath = Join-Path $scriptDir 'tray-settings.json'
$script:historyPath  = Join-Path $scriptDir 'recovery-history.csv'
$script:logPath      = Join-Path $scriptDir 'tray-debug.log'

# Debug log helper (Tray daemon has hidden console, making silent failure hard to track — write to file)
function Write-TrayLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $script:logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Ignore log failures (no runtime impact)
    }
}
Write-TrayLog "Tray daemon started (PID=$PID)"

$defaultSettings = @{
    AlertThresholdPct = 90    # Memory usage that triggers alert
    CheckIntervalSec  = 30    # Polling interval (seconds)
    AlertCooldownMin  = 10    # Alert cooldown (minutes)
}

function Load-Settings {
    if (Test-Path $script:settingsPath) {
        try {
            $loaded = Get-Content $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $merged = @{}
            foreach ($k in $defaultSettings.Keys) {
                $merged[$k] = if ($null -ne $loaded.$k) { $loaded.$k } else { $defaultSettings[$k] }
            }
            return $merged
        } catch {
            return $defaultSettings.Clone()
        }
    } else {
        return $defaultSettings.Clone()
    }
}

function Save-Settings {
    param([hashtable]$Settings)
    try {
        $Settings | ConvertTo-Json | Set-Content -Path $script:settingsPath -Encoding UTF8
    } catch {
        # Save failures are silent — use default at next boot
    }
}

$script:settings = Load-Settings

# ════════════════════════════════════════════════════════════════════
# 4. Memory measurement helper
# ════════════════════════════════════════════════════════════════════
function Get-MemoryUsage {
    $os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $null }
    $totalMB  = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB   = [math]::Round($os.FreePhysicalMemory   / 1024)
    $usedMB   = $totalMB - $freeMB
    $usedPct  = [math]::Round(($usedMB / $totalMB) * 100, 1)
    [PSCustomObject]@{
        TotalMB  = $totalMB
        UsedMB   = $usedMB
        FreeMB   = $freeMB
        UsedPct  = $usedPct
    }
}

# ════════════════════════════════════════════════════════════════════
# 5. NotifyIcon + Context menu
# ════════════════════════════════════════════════════════════════════
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Text = "Memory Reset (Starting...)"
$icon.Visible = $true

# Recovery action trigger (calls MemoryReset.ps1, automatic UAC elevation)
function Invoke-RecoveryAction {
    param([string]$ExtraArgs = '')
    if (-not (Test-Path $script:mainScript)) {
        $icon.ShowBalloonTip(5000, "Error",
            "MemoryReset.ps1 cannot be found in the same folder.",
            [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:mainScript`"")
    if ($ExtraArgs) { $argList += $ExtraArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) }
    try {
        # MemoryReset.ps1 handles UAC elevation internally
        Start-Process powershell.exe -ArgumentList $argList -ErrorAction Stop
    } catch {
        $icon.ShowBalloonTip(5000, "Launch failed", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# Context menu setup
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System

# Header (current memory — not clickable)
$mnuHeader = $menu.Items.Add("Memory Reset")
$mnuHeader.Enabled = $false
$mnuStatus = $menu.Items.Add("(Measuring memory...)")
$mnuStatus.Enabled = $false
$menu.Items.Add('-') | Out-Null

# Recovery actions
$mnuBasic = $menu.Items.Add("Basic recovery (Basic)")
$mnuBasic.Add_Click({ Invoke-RecoveryAction })

$mnuDeep = $menu.Items.Add("Deep recovery (Deep)")
$mnuDeep.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Deep' })

$mnuDeepShell = $menu.Items.Add("Maximum recovery (Deep + Shell restart)")
$mnuDeepShell.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Deep -IncludeShell' })

$menu.Items.Add('-') | Out-Null

# Diagnostics/history
$mnuDiag = $menu.Items.Add("Diagnostics (Diagnose)")
$mnuDiag.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-Diagnose' })

$mnuDryRun = $menu.Items.Add("Dry run (check targets only)")
$mnuDryRun.Add_Click({ Invoke-RecoveryAction -ExtraArgs '-DryRun' })

$mnuHistory = $menu.Items.Add("View recovery history (CSV)")
$mnuHistory.Add_Click({
    if (Test-Path $script:historyPath) {
        try {
            Start-Process $script:historyPath
        } catch {
            # If there is no CSV association, open in Notepad
            Start-Process notepad.exe -ArgumentList "`"$script:historyPath`""
        }
    } else {
        $icon.ShowBalloonTip(3000, "No history",
            "There are no recovery records. Run recovery 1 time or more, then check again.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$menu.Items.Add('-') | Out-Null

# Settings
$mnuSettings = $menu.Items.Add("Settings (change threshold)")
$mnuSettings.Add_Click({
    $current = $script:settings.AlertThresholdPct
    $input = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Memory usage alert threshold (%, 50~99 recommended)`nCurrent: $current %",
        "Memory Reset — Threshold settings",
        $current.ToString()
    )
    if ($input -match '^\d+$') {
        $val = [int]$input
        if ($val -ge 50 -and $val -le 99) {
            $script:settings.AlertThresholdPct = $val
            Save-Settings -Settings $script:settings
            $icon.ShowBalloonTip(3000, "Settings saved",
                "Alert threshold: $val %",
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

$menu.Items.Add('-') | Out-Null

# Exit
$mnuExit = $menu.Items.Add("Exit")
$mnuExit.Add_Click({
    $icon.Visible = $false
    $icon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$icon.ContextMenuStrip = $menu

# Show quick recovery menu on left click (can change to DoubleClick)
$icon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        # NotifyIcon ShowContextMenu is a private method — reflection workaround (verified on PS 5.1+)
        try {
            $methodInfo = [System.Windows.Forms.NotifyIcon].GetMethod(
                'ShowContextMenu',
                [System.Reflection.BindingFlags]'Instance, NonPublic'
            )
            if ($methodInfo) {
                $methodInfo.Invoke($icon, $null)
            } else {
                # fallback on reflection failure: show menu directly (cursor position)
                $icon.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position)
            }
        } catch {
            Write-TrayLog "Failed to show left click menu: $($_.Exception.Message)" 'WARN'
            try { $icon.ContextMenuStrip.Show([System.Windows.Forms.Cursor]::Position) } catch {}
        }
    }
})

# ════════════════════════════════════════════════════════════════════
# 6. Polling timer — memory check + threshold alert
# ════════════════════════════════════════════════════════════════════
$script:lastAlert = $null

# Extract Tick logic into a named function — immediate call + timer use the same code (remove reflection dependency)
function Invoke-MemoryTick {
    try {
        $m = Get-MemoryUsage
        if ($null -eq $m) {
            Write-TrayLog "Get-MemoryUsage returned null (CIM access failed?)" 'WARN'
            return
        }

        # Update tooltip (NotifyIcon.Text has a maximum of 63 characters — Windows API limit)
        $tooltip = "Memory: {0}% used ({1}/{2} GB)" -f $m.UsedPct, [math]::Round($m.UsedMB/1024,1), [math]::Round($m.TotalMB/1024,1)
        if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 63) }
        $icon.Text = $tooltip

        # Update menu header
        $mnuStatus.Text = (" Used {0}% / Available {1:N0} MB" -f $m.UsedPct, $m.FreeMB)

        # Threshold alert (apply cooldown)
        if ($m.UsedPct -ge $script:settings.AlertThresholdPct) {
            $now = Get-Date
            $shouldAlert = ($null -eq $script:lastAlert) -or
                           (($now - $script:lastAlert).TotalMinutes -ge $script:settings.AlertCooldownMin)
            if ($shouldAlert) {
                $msg = "Memory usage reached {0}%.`nRight click the system tray icon → 'Deep recovery (Deep)' is recommended." -f $m.UsedPct
                $icon.ShowBalloonTip(8000, "Memory threshold alert", $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
                $script:lastAlert = $now
                Write-TrayLog ("Threshold alert triggered: {0}% (threshold {1}%)" -f $m.UsedPct, $script:settings.AlertThresholdPct)
            }
        }
    } catch {
        Write-TrayLog "Tick handling failed: $($_.Exception.Message)" 'ERROR'
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:settings.CheckIntervalSec * 1000
$timer.Add_Tick({ Invoke-MemoryTick })
$timer.Start()

# Measure 1 time immediately (so the user does not wait 30 seconds)
Invoke-MemoryTick

# ════════════════════════════════════════════════════════════════════
# 7. Startup alert + message loop
# ════════════════════════════════════════════════════════════════════
$icon.ShowBalloonTip(3000,
    "Memory Reset Tray started",
    ("Memory monitoring active. Threshold: {0}% / Polling: {1} seconds" -f $script:settings.AlertThresholdPct, $script:settings.CheckIntervalSec),
    [System.Windows.Forms.ToolTipIcon]::Info)

try {
    Write-TrayLog "Entering message loop"
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-TrayLog "Message loop exception: $($_.Exception.Message)" 'ERROR'
} finally {
    Write-TrayLog "Tray daemon terminated (starting cleanup)"
    try { $timer.Stop()    } catch {}
    try { $timer.Dispose() } catch {}
    if ($icon -and $icon.Visible) { $icon.Visible = $false }
    try { $icon.Dispose()  } catch {}
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        try { $mutex.Dispose()      } catch {}
    }
    Write-TrayLog "Tray daemon cleanup complete"
}
