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

# ════════════════════════════════════════════════════════════════════
# v1.4 activity tracking / idle classification / Telegram alert smoke test
# ════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "== v1.4 activity tracking / idle classification / Telegram smoke test =="

# 15. New function definitions exist
$v14fn = @('Update-ActivityState','Test-ProcessIdle','Get-ReclaimCandidates','Send-TelegramMessage','Invoke-ActivityTracking','Get-TrackerSettings','ConvertTo-HashtableDeep')
foreach ($fn in $v14fn) {
    if ($src -match "(?ms)^function\s+$fn\b") {
        Write-Host "[PASS] Function definition: $fn" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Function missing: $fn" -ForegroundColor Red
    }
}

# 16. New parameter declarations
foreach ($p in @('TrackActivity','IdleOnly')) {
    if ($src -match ('\[switch\]\$' + $p + '\b')) {
        Write-Host "[PASS] Parameter: -$p" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Parameter missing: -$p" -ForegroundColor Red
    }
}

# 17. -TrackActivity excludes UAC elevation (prevents UAC popups during unattended 5 minute runs)
if ($src -match '-not\s+\(Test-IsAdmin\)\s+-and\s+-not\s+\$TrackActivity') {
    Write-Host "[PASS] -TrackActivity excluded from UAC elevation (safe for unattended runs)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] -TrackActivity triggers UAC elevation — popup risk every 5 minutes in Task Scheduler" -ForegroundColor Red
}

# 18. [Security] Do not hardcode Telegram bot tokens — must load only from the settings file
if ($src -match '\d{8,}:[A-Za-z0-9_-]{30,}') {
    Write-Host "[FAIL] Bot token pattern found in source — secret hardcoding risk!" -ForegroundColor Red
} else {
    Write-Host "[PASS] No hardcoded bot token in source (loaded only from tracker-settings.json)" -ForegroundColor Green
}

# 19. [Safety] 3 guard fields for idle classification (sufficient observation firstTrackedAt + inactivity lastActiveAt + CPU rate lastCpuRatePct)
if ($src -match 'firstTrackedAt' -and $src -match 'lastActiveAt' -and $src -match 'lastCpuRatePct') {
    Write-Host "[PASS] 3 guard fields for idle classification exist (sufficient observation/inactivity/CPU rate)" -ForegroundColor Green
} else {
    Write-Host "[WARN] idle classification guard fields not verified" -ForegroundColor Yellow
}

# 20. PID reuse protection — distinguish new/same process by comparing creationDate
if ($src -match 'creationDate' -and $src -match 'CreationDate') {
    Write-Host "[PASS] PID reuse protection (check creationDate match)" -ForegroundColor Green
} else {
    Write-Host "[WARN] PID reuse protection not verified" -ForegroundColor Yellow
}

# 21. .gitignore precisely protects tracker-settings.json(tokens) without inline comments
$giPath = Join-Path $PSScriptRoot '.gitignore'
if (Test-Path $giPath) {
    $giFix = Get-Content $giPath -Raw
    if ($giFix -match '(?m)^tracker-settings\.json\s*$') {
        Write-Host "[PASS] .gitignore precisely protects tracker-settings.json (no inline comments)" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] tracker-settings.json token file unprotected — commit risk!" -ForegroundColor Red
    }
}

# 22. example template exists (for commits without tokens)
if (Test-Path (Join-Path $PSScriptRoot 'tracker-settings.example.json')) {
    Write-Host "[PASS] tracker-settings.example.json template exists" -ForegroundColor Green
} else {
    Write-Host "[WARN] example template missing" -ForegroundColor Yellow
}

# 23. Task Scheduler/launcher scripts exist
foreach ($script in @('Track-Schedule.ps1','Track-Register.bat','Track-Unregister.bat','Run-IdleDryRun.bat','Run-IdleCleanup.bat')) {
    if (Test-Path (Join-Path $PSScriptRoot $script)) {
        Write-Host "[PASS] Script exists: $script" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Script missing: $script" -ForegroundColor Red
    }
}

# ════════════════════════════════════════════════════════════════════
# v1.4.1 Byproduct(descendant tree) cleanup smoke test
# ════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "== v1.4.1 Byproduct(descendant tree) cleanup smoke test =="

if ($src -match '(?ms)^function\s+Get-DescendantPids\b') {
    Write-Host "[PASS] Function definition: Get-DescendantPids" -ForegroundColor Green
} else { Write-Host "[FAIL] Get-DescendantPids missing" -ForegroundColor Red }

if ($src -match '\[switch\]\$IncludeDescendants\b') {
    Write-Host "[PASS] Parameter: -IncludeDescendants" -ForegroundColor Green
} else { Write-Host "[FAIL] -IncludeDescendants missing" -ForegroundColor Red }

# Get-DescendantPids must return a flat array (,@() double wrap prohibited — bug where desc becomes a single int[] element)
if ($src -match 'return \$result\.ToArray\(\)' -and $src -notmatch 'return ,\$result\.ToArray\(\)') {
    Write-Host "[PASS] Get-DescendantPids returns a flat array (no double wrap)" -ForegroundColor Green
} else { Write-Host "[WARN] Get-DescendantPids return format not verified" -ForegroundColor Yellow }

# IncludeDescendants guards excluding self / ExcludePids
if ($src -match 'ProcessId\) -ne \$self' -and $src -match 'ExcludePids -notcontains') {
    Write-Host "[PASS] Descendant collection has self / KeepPids exclusion guards" -ForegroundColor Green
} else { Write-Host "[WARN] Descendant exclusion guard not verified" -ForegroundColor Yellow }

if (Test-Path (Join-Path $PSScriptRoot 'Run-PurgeAll.bat')) {
    Write-Host "[PASS] Run-PurgeAll.bat (one click full cleanup) exists" -ForegroundColor Green
} else { Write-Host "[FAIL] Run-PurgeAll.bat missing" -ForegroundColor Red }
