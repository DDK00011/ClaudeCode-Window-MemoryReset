# Test script for pattern verification (does not actually terminate)
# Read MemoryReset.ps1 and extract and run only the Get-TargetProcesses function — safety verification tool.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Read MemoryReset.ps1 in the same folder and extract the function definition
$mainScript = Join-Path $PSScriptRoot 'MemoryReset.ps1'
if (-not (Test-Path $mainScript)) {
    Write-Host "[ERR] Cannot find MemoryReset.ps1 in the same folder: $mainScript" -ForegroundColor Red
    exit 1
}
$src = Get-Content $mainScript -Raw -Encoding UTF8
# Extract Get-TargetProcesses function (regex)
if ($src -match '(?ms)function Get-TargetProcesses \{.*?^\}') {
    $funcDef = $Matches[0]
    Invoke-Expression $funcDef
} else {
    Write-Host "Function extraction failed" -ForegroundColor Red
    exit 1
}

$targets = Get-TargetProcesses

Write-Host "== Termination target classification =="
$targets | Group-Object {
    if ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') { 'Antigravity main app' }
    elseif ($_.ExecutablePath -match '(?i)\\\.antigravity\\extensions') { 'Claude CLI (Antigravity extension)' }
    elseif ($_.ExecutablePath -match '(?i)\\Claude\\claude-code\\') { 'Claude CLI (standalone)' }
    elseif ($_.Name -eq 'node.exe') { 'Claude CLI (node)' }
    else { 'Other' }
} | ForEach-Object {
    $ws = [math]::Round((($_.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
    '{0,-40} {1,4} items  {2,10:N1} MB' -f $_.Name, $_.Count, $ws
}

Write-Host ""
Write-Host "== Claude Desktop preservation verification =="
$desktop = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
$inTargets = $targets | Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
'Desktop app PID count: {0}' -f @($desktop).Count
'Count incorrectly included among termination targets: {0}' -f @($inTargets).Count
if (@($inTargets).Count -eq 0) {
    Write-Host "[PASS] Claude Desktop safely preserved" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Claude Desktop is included in termination targets!" -ForegroundColor Red
    $inTargets | Select-Object Name, ProcessId, ExecutablePath | Format-List
}

Write-Host ""
Write-Host "== Total =="
$totalMB = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
'Recoverable on termination (working set basis): {0:N1} MB ({1} processes)' -f $totalMB, @($targets).Count

Write-Host ""
Write-Host "== 'Other' category details (check unexpected matches) =="
$unknown = $targets | Where-Object {
    $_.ExecutablePath -notmatch '(?i)\\Programs\\Antigravity\\' -and
    $_.ExecutablePath -notmatch '(?i)\\\.antigravity\\extensions' -and
    $_.ExecutablePath -notmatch '(?i)\\Claude\\claude-code\\' -and
    $_.Name -ne 'node.exe'
}
if ($unknown) {
    $unknown | Select-Object Name, ProcessId, ExecutablePath, @{N='WS_MB';E={[math]::Round($_.WorkingSetSize/1MB,1)}} | Format-List
} else {
    Write-Host "(None)"
}

Write-Host ""
Write-Host "== Self exclusion verification (current PowerShell PID=$PID) =="
$selfIncluded = $targets | Where-Object { $_.ProcessId -eq $PID }
if ($null -eq $selfIncluded) {
    Write-Host "[PASS] Self excluded" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Self is included in targets!" -ForegroundColor Red
}

# v1.1 new feature smoke test
Write-Host ""
Write-Host "== v1.1 new function/flag smoke test =="

# 1. Check whether new functions are defined in the script
$expectedFunctions = @('Show-MemoryDiagnostics', 'Invoke-DeepRecovery', 'Invoke-ShellRestart')
foreach ($fn in $expectedFunctions) {
    if ($src -match "(?ms)^function\s+$fn\b") {
        Write-Host "[PASS] Function definition present: $fn" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Function definition missing: $fn" -ForegroundColor Red
    }
}

# 2. Check new parameter declarations
$expectedParams = @('Deep', 'IncludeShell', 'Diagnose')
foreach ($p in $expectedParams) {
    $pattern = '\[switch\]\$' + $p + '\b'
    if ($src -match $pattern) {
        Write-Host "[PASS] Parameter definition: -$p" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Parameter missing: -$p" -ForegroundColor Red
    }
}

# 3. v1.1.1 safety guard verification (Round 1 patch tracking)
if ($src -match 'finally\s*\{[\s\S]*?Enable-MMAgent') {
    Write-Host "[PASS] MMAgent Disable→Enable try/finally guard present" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent try/finally guard not confirmed — risk of permanently disabling system compression if Enable fails after Disable" -ForegroundColor Yellow
}

if ($src -match 'availMB\s*-lt\s*1024') {
    Write-Host "[PASS] Decompression spike OOM guard present (skip when available RAM < 1GB)" -ForegroundColor Green
} else {
    Write-Host "[WARN] OOM guard not confirmed" -ForegroundColor Yellow
}

if ($src -match 'restartedByWindows\s*=\s*\$true') {
    Write-Host "[PASS] Explorer restart polling loop present" -ForegroundColor Green
} else {
    Write-Host "[WARN] Explorer polling loop not confirmed — 1.5 seconds may be insufficient on systems with many shell extensions" -ForegroundColor Yellow
}

# 6. v1.1.2 elevation safety: rely only on automatic Explorer restart (Round 2 patch)
if ($src -match 'intentionally\s+not\s+launching\s+elevated\s+explorer\.exe\s+directly') {
    Write-Host "[PASS] Explorer elevation risk avoided (automatic restart only)" -ForegroundColor Green
} else {
    Write-Host "[WARN] elevated explorer auto start guard not confirmed — risk that standard apps lack permissions" -ForegroundColor Yellow
}

# 7. v1.1.2 MMAgent sleep 1500ms (Round 2 patch)
if ($src -match 'Start-Sleep\s+-Milliseconds\s+1500') {
    Write-Host "[PASS] MMAgent decompress wait 1500ms (increased from previous 800ms)" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent sleep 1500ms not confirmed" -ForegroundColor Yellow
}

# v1.2 new feature smoke test
Write-Host ""
Write-Host "== v1.2 tray/CSV smoke test =="

# 8. CSV logging function present
if ($src -match '(?ms)^function\s+Write-RecoveryLog\b') {
    Write-Host "[PASS] CSV logging function definition: Write-RecoveryLog" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Write-RecoveryLog function missing" -ForegroundColor Red
}

# 9. CSV lock/retry guard
if ($src -match 'maxRetry\s*=\s*3' -and $src -match 'fallback') {
    Write-Host "[PASS] CSV file lock retry + fallback guard present" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV lock guard not confirmed" -ForegroundColor Yellow
}

# 10. Tray daemon file present + smoke check
$trayPath = Join-Path $PSScriptRoot 'MemoryReset-Tray.ps1'
if (Test-Path $trayPath) {
    Write-Host "[PASS] MemoryReset-Tray.ps1 file present" -ForegroundColor Green
    $trayContent = Get-Content $trayPath -Raw -Encoding UTF8

    # 10-1. P0 fix verification: Add-Type before mutex check
    $addTypeIdx = $trayContent.IndexOf("Add-Type -AssemblyName System.Windows.Forms")
    $mutexIdx   = $trayContent.IndexOf("New-Object System.Threading.Mutex")
    if ($addTypeIdx -gt 0 -and $mutexIdx -gt 0 -and $addTypeIdx -lt $mutexIdx) {
        Write-Host "[PASS] Tray Add-Type executes before mutex check" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Tray Add-Type order error — MessageBox may fail on second instance" -ForegroundColor Red
    }

    # 10-2. mutex Local\ scope (avoid Global\ permission issue)
    if ($trayContent.Contains("'Local\MemoryReset-Tray-Singleton'")) {
        Write-Host "[PASS] Tray mutex Local\ scope (user session)" -ForegroundColor Green
    } elseif ($trayContent.Contains("'Global\MemoryReset-Tray-Singleton'")) {
        Write-Host "[WARN] Tray mutex Global\ — permission issue possible, Local\ recommended" -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] Tray mutex naming not confirmed" -ForegroundColor Yellow
    }

    # 10-3. Tick function separation (remove reflection dependency)
    if ($trayContent -match '(?ms)^function\s+Invoke-MemoryTick\b') {
        Write-Host "[PASS] Tray Invoke-MemoryTick function separated (no reflection dependency)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Tick function separation not confirmed" -ForegroundColor Yellow
    }

    # 10-4. Debug log helper
    if ($trayContent -match '(?ms)^function\s+Write-TrayLog\b') {
        Write-Host "[PASS] Tray debug log helper present (can track silent failures)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Write-TrayLog not confirmed — difficult to track silent failures" -ForegroundColor Yellow
    }
} else {
    Write-Host "[FAIL] MemoryReset-Tray.ps1 file missing" -ForegroundColor Red
}

# 11. .gitignore personal data protection
$gitignorePath = Join-Path $PSScriptRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $gi = Get-Content $gitignorePath -Raw
    if ($gi -match '\*\.csv' -and $gi -match 'tray-settings') {
        Write-Host "[PASS] .gitignore protects *.csv + tray-settings.json" -ForegroundColor Green
    } else {
        Write-Host "[WARN] .gitignore personal data pattern not confirmed" -ForegroundColor Yellow
    }
}

# v1.2.1 Round 2 patch verification
Write-Host ""
Write-Host "== v1.2.1 Round 2 patch verification =="

# 12. Explicit STA (Tray.bat)
$trayBat = Join-Path $PSScriptRoot 'Tray.bat'
if (Test-Path $trayBat) {
    $batContent = Get-Content $trayBat -Raw
    if ($batContent -match '-Sta\b') {
        Write-Host "[PASS] Tray.bat specifies -Sta flag (WinForms compatibility)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Tray.bat -Sta not confirmed — InputBox etc may hang in MTA environment" -ForegroundColor Yellow
    }
}

# 13. CSV column name clarification: FreedMB / UsedBeforeMB / UsedAfterMB
if ($src -match 'UsedBeforeMB' -and $src -match 'FreedMB') {
    Write-Host "[PASS] CSV schema clear (UsedBefore/UsedAfter/FreedMB)" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV column name clarification not confirmed" -ForegroundColor Yellow
}

# 14. Prevent same-second fallback file collisions (daily consolidation + GUID emergency)
if ($src -match 'recovery-history-fallback-' -and $src -match 'recovery-history-emergency-') {
    Write-Host "[PASS] Prevent CSV fallback same-second collisions (daily consolidation + GUID emergency)" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV fallback collision prevention not verified" -ForegroundColor Yellow
}
