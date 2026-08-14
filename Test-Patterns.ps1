# Test script for pattern verification (does not actually terminate)
# Read MemoryReset.ps1 and extract and run only the Get-TargetProcesses function — safety verification tool.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:testFailures = 0
function Write-TestFailure {
    param([string]$Message)
    $script:testFailures++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

# Read MemoryReset.ps1 in the same folder and extract the function definition
$mainScript = Join-Path $PSScriptRoot 'MemoryReset.ps1'
if (-not (Test-Path $mainScript)) {
    Write-Host "[ERR] Cannot find MemoryReset.ps1 in the same folder: $mainScript" -ForegroundColor Red
    exit 1
}
$src = Get-Content $mainScript -Raw -Encoding UTF8
# Get-TargetProcesses + dependent helper extraction
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    Write-Host "Script parsing failed" -ForegroundColor Red
    $errors | Format-List
    exit 1
}
foreach ($fnName in @('Test-IsClaudeOrphan','Test-IsCodexProcess','Get-DescendantPids','Get-CodexRootPids','Get-TargetProcesses')) {
    $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    if (-not $fnAst) {
        Write-Host "Function extraction failed: $fnName" -ForegroundColor Red
        exit 1
    }
    if ($fnName -eq 'Get-TargetProcesses') { $funcDef = $fnAst.Extent.Text }
    Invoke-Expression $fnAst.Extent.Text
}

$targets = Get-TargetProcesses

Write-Host "== Termination target classification =="
$targets | Group-Object {
    if ($_.ExecutablePath -match '(?i)\\\.antigravity\\extensions') { 'Claude CLI (Antigravity extension)' }
    elseif ($_.ExecutablePath -match '(?i)\\Claude\\claude-code\\') { 'Claude CLI (standalone)' }
    elseif (Test-IsCodexProcess $_) { 'Codex CLI' }
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
    Write-TestFailure "Claude Desktop included in termination targets!"
    $inTargets | Select-Object Name, ProcessId, ExecutablePath | Format-List
}

Write-Host ""
Write-Host "== GUI IDE preservation verification =="
$guiInTargets = $targets | Where-Object {
    $_.Name -match '(?i)^(Antigravity|Code|Cursor|Windsurf)\.exe$' -or
    $_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\|\\Google\\Antigravity\\|\\Microsoft VS Code\\|\\Programs\\Microsoft VS Code\\'
}
'GUI IDE termination target count: {0}' -f @($guiInTargets).Count
if (@($guiInTargets).Count -eq 0 -and
    $funcDef -notmatch '(?i)\\Programs\\Antigravity\\|\\Google\\Antigravity\\|Antigravity\(\\.exe\)\?') {
    Write-Host "[PASS] Antigravity/VS Code GUI IDEs are excluded from termination targets" -ForegroundColor Green
} else {
    Write-TestFailure "GUI IDE included in termination targets or Antigravity app matching remains"
    $guiInTargets | Select-Object Name, ProcessId, ExecutablePath | Format-List
}

Write-Host ""
Write-Host "== Total =="
$totalMB = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
'Recoverable on termination (working set basis): {0:N1} MB ({1} processes)' -f $totalMB, @($targets).Count

Write-Host ""
Write-Host "== 'Other' category details (check unexpected matches) =="
$unknown = $targets | Where-Object {
    $_.ExecutablePath -notmatch '(?i)\\\.antigravity\\extensions' -and
    $_.ExecutablePath -notmatch '(?i)\\Claude\\claude-code\\' -and
    -not (Test-IsCodexProcess $_) -and
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
    Write-TestFailure "Self included in targets!"
}

Write-Host ""
Write-Host "== Active session preservation verification =="
if ($src -match '(?ms)^function\s+Test-IsCodexProcess\b' -and $src -match '(?ms)^function\s+Get-CodexRootPids\b' -and $src.Contains('@openai[\\/]codex') -and $src -match 'node_repl') {
    Write-Host "[PASS] Codex CLI identification/root helper present" -ForegroundColor Green
} else {
    Write-TestFailure "Codex CLI identification/root helper missing"
}
if ($src -match '(?ms)^function\s+Get-ActiveProtectedPids\b' -and $src -match 'active session preserved') {
    Write-Host "[PASS] Claude/Codex shared active guard present" -ForegroundColor Green
} else {
    Write-TestFailure "Claude/Codex shared active guard missing"
}
$activeGuard = $src.IndexOf('active session preserved →')
$closeMainWindow = $src.IndexOf('CloseMainWindow()')
if ($activeGuard -ge 0 -and $closeMainWindow -ge 0 -and $activeGuard -lt $closeMainWindow) {
    Write-Host "[PASS] active session tree protected before CloseMainWindow" -ForegroundColor Green
} else {
    Write-TestFailure "active session tree protection applies only after CloseMainWindow"
}
if ($src -match '(?ms)remaining process tree.*?Update-ActivityState.*?Get-ActiveProtectedPids.*?\$treePids\s*=\s*@\(\[int\]\$p\.ProcessId\)\s*\+.*?taskkill\.exe') {
    Write-Host "[PASS] force kill immediately before root+descendant active snapshot recalculation" -ForegroundColor Green
} else {
    Write-TestFailure "root+descendant active snapshot recalculation missing immediately before force kill"
}
if ($src -match 'lastIoOps' -and $src -match 'lastIoBytes' -and $src -match '\$treePids\s*=\s*@\(\$procId\)\s*\+\s*@\(Get-DescendantPids' -and $src -notmatch '(?ms)\$treePids\s*=\s*if\s*\(Test-IsCodexProcess' -and $src -notmatch 'lastIoOps[^\r\n]*lastActiveAt' -and $src -notmatch 'lastIoBytes[^\r\n]*lastActiveAt') {
    Write-Host "[PASS] Claude/Codex tree CPU activity tracking + I/O diagnostic records present" -ForegroundColor Green
} else {
    Write-TestFailure "Claude/Codex tree CPU tracking or I/O-only idle protection missing"
}
if ($src -match "activityModel\s*=\s*'cpu-tree-v2'" -and $src -match '\$legacyEntry' -and $src -match '\$legacyRepaired' -and $src -match '\$cpuActive' -and $src -match 'lastActiveAt -eq \$entry\.lastSeenAt' -and $src -match 'lastCpuRatePct -lt \[double\]\$Settings\.cpuThresholdPct') {
    Write-Host "[PASS] legacy I/O-only lastActiveAt correction present" -ForegroundColor Green
} else {
    Write-TestFailure "legacy I/O-only lastActiveAt correction missing"
}
if ($src -match '\$legacySeen\s*=\s*ConvertTo-DateTimeSafe \$entry\.lastSeenAt' -and $src -notmatch '\$seen\s*=\s*ConvertTo-DateTimeSafe \$entry\.lastSeenAt') {
    Write-Host "[PASS] Update-ActivityState `$seen PID hash table not overwritten" -ForegroundColor Green
} else {
    Write-TestFailure "Update-ActivityState `$seen variable collision risk"
}
$legacyIoStateCheck = & {
    foreach ($fnName in @('Test-IsCodexProcess','Get-DescendantPids','ConvertTo-HashtableDeep','ConvertTo-DateTimeSafe','Get-LogicalCoreCount','Read-ActivityState','Write-ActivityState','Update-ActivityState','Test-ProcessIdle','Get-ReclaimCandidates')) {
        $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
        Invoke-Expression $fnAst.Extent.Text
    }
    $tmp = Join-Path $env:TEMP 'memoryreset-legacy-io-test.json'
    $now = Get-Date
    $created = $now.AddHours(-6).ToString('o')
    $first = $now.AddHours(-5).ToString('o')
    $seenAt = $now.AddMinutes(-5).ToString('o')
    $settings = [pscustomobject]@{ idleMinutes = 180; cpuThresholdPct = 0.1; trackIntervalMin = 30 }
    function Get-ActivityStatePath { $tmp }
    function Get-TargetProcesses { @([pscustomobject]@{ ProcessId = 1234; ParentProcessId = 1; Name = 'node.exe'; CommandLine = 'node @openai/codex/bin/codex.js'; ExecutablePath = 'C:\node\node.exe'; CreationDate = $created; WorkingSetSize = 1048576 }) }
    function Get-CimInstance {
        param([Parameter(Position=0)][string]$ClassName, [string]$Filter)
        if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ NumberOfLogicalProcessors = 4 } }
        return @([pscustomobject]@{ ProcessId = 1234; ParentProcessId = 1; Name = 'node.exe'; CommandLine = 'node @openai/codex/bin/codex.js'; ExecutablePath = 'C:\node\node.exe'; CreationDate = $created; WorkingSetSize = 1048576; ReadOperationCount = 2; WriteOperationCount = 0; OtherOperationCount = 0; ReadTransferCount = 2; WriteTransferCount = 0; OtherTransferCount = 0 })
    }
    function Get-Process { @([pscustomobject]@{ Id = 1234; CPU = $script:mockCpu }) }
    try {
        @{ version = 1; updatedAt = $seenAt; processes = @{ '1234' = @{ name = 'node.exe'; creationDate = $created; firstTrackedAt = $first; lastActiveAt = $seenAt; lastCpuSec = 10.0; lastCpuRatePct = 0.0; lastIoOps = 1; lastIoBytes = 1; lastSeenAt = $seenAt; wsBytes = 1048576; ppid = 1 } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        $script:mockCpu = 10.0
        $null = Update-ActivityState -Settings $settings
        $fixed = Read-ActivityState
        $fixedEntry = $fixed.processes['1234']
        $fixedCandidates = @(Get-ReclaimCandidates -Settings $settings)

        @{ version = 1; updatedAt = $seenAt; processes = @{ '1234' = @{ name = 'node.exe'; creationDate = $created; firstTrackedAt = $first; lastActiveAt = $now.AddMinutes(-30).ToString('o'); lastCpuSec = 10.0; lastCpuRatePct = 0.0; lastIoOps = 1; lastIoBytes = 1; lastSeenAt = $seenAt; wsBytes = 1048576; ppid = 1 } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        $null = Update-ActivityState -Settings $settings
        $ambiguousEntry = (Read-ActivityState).processes['1234']

        return (($fixedCandidates.Count -eq 1) -and ($fixedEntry.activityModel -eq 'cpu-tree-v2') -and (-not $ambiguousEntry.activityModel))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
if ($legacyIoStateCheck) {
    Write-Host "[PASS] legacy I/O-only state correction behavior verified" -ForegroundColor Green
} else {
    Write-TestFailure "legacy I/O-only state correction behavior failed"
}
$claudeTreeActivityCheck = & {
    foreach ($fnName in @('Test-IsCodexProcess','Get-DescendantPids','Get-CodexRootPids','Get-ActiveProtectedPids','ConvertTo-HashtableDeep','ConvertTo-DateTimeSafe','Get-LogicalCoreCount','Read-ActivityState','Write-ActivityState','Update-ActivityState','Test-ProcessIdle')) {
        $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
        Invoke-Expression $fnAst.Extent.Text
    }
    $tmp = Join-Path $env:TEMP "memoryreset-claude-tree-test-$PID.json"
    $now = Get-Date
    $created = $now.AddHours(-6).ToString('o')
    $seenAt = $now.AddMinutes(-1).ToString('o')
    $settings = [pscustomobject]@{ idleMinutes = 180; cpuThresholdPct = 0.1; trackIntervalMin = 30 }
    $script:mockTreeTarget = [pscustomobject]@{ ProcessId = 4100; ParentProcessId = 1; Name = 'claude.exe'; CommandLine = 'claude'; ExecutablePath = 'C:\Users\M\.vscode\extensions\anthropic.claude-code-test\claude.exe'; CreationDate = $created; WorkingSetSize = 1048576 }
    $script:mockTreeProcs = @(
        [pscustomobject]@{ ProcessId = 4100; ParentProcessId = 1; Name = 'claude.exe'; CommandLine = 'claude'; ExecutablePath = $script:mockTreeTarget.ExecutablePath; CreationDate = $created; WorkingSetSize = 1048576; ReadOperationCount = 0; WriteOperationCount = 0; OtherOperationCount = 0; ReadTransferCount = 0; WriteTransferCount = 0; OtherTransferCount = 0 },
        [pscustomobject]@{ ProcessId = 4101; ParentProcessId = 4100; Name = 'bash.exe'; CommandLine = 'bash test'; ExecutablePath = 'C:\Program Files\Git\bin\bash.exe'; CreationDate = $created; WorkingSetSize = 1048576; ReadOperationCount = 0; WriteOperationCount = 0; OtherOperationCount = 0; ReadTransferCount = 0; WriteTransferCount = 0; OtherTransferCount = 0 }
    )
    function Get-ActivityStatePath { $tmp }
    function Get-TargetProcesses { @($script:mockTreeTarget) }
    function Get-CimInstance {
        param([Parameter(Position=0)][string]$ClassName, [string]$Filter)
        if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ NumberOfLogicalProcessors = 4 } }
        return $script:mockTreeProcs
    }
    function Get-Process { @([pscustomobject]@{ Id = 4100; CPU = 10.0 }, [pscustomobject]@{ Id = 4101; CPU = 4.0 }) }
    try {
        @{ version = 1; updatedAt = $seenAt; processes = @{ '4100' = @{ name = 'claude.exe'; creationDate = $created; firstTrackedAt = $now.AddHours(-5).ToString('o'); lastActiveAt = $now.AddHours(-4).ToString('o'); lastCpuSec = 10.0; lastCpuRatePct = 0.0; lastIoOps = 0; lastIoBytes = 0; lastSeenAt = $seenAt; wsBytes = 1048576; ppid = 1; activityModel = 'cpu-tree-v2' } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        $script:nLogicalCores = 4
        $state = Update-ActivityState -Settings $settings
        $entry = $state.processes['4100']
        $protected = @(Get-ActiveProtectedPids -AllProcs $script:mockTreeProcs -State $state -Settings $settings -Now (Get-Date) -AdditionalRootPids @(4100))
        $positiveDeltaOk = (($entry.lastCpuSec -eq 14.0) -and ([double]$entry.lastCpuRatePct -ge 0.1) -and ($protected -contains 4100) -and ($protected -contains 4101))

        @{ version = 1; updatedAt = $seenAt; processes = @{ '4100' = @{ name = 'claude.exe'; creationDate = $created; firstTrackedAt = $now.AddHours(-5).ToString('o'); lastActiveAt = $now.AddHours(-4).ToString('o'); lastCpuSec = 100.0; lastCpuRatePct = 0.0; lastIoOps = 0; lastIoBytes = 0; lastSeenAt = $seenAt; wsBytes = 1048576; ppid = 1; activityModel = 'cpu-tree-v2' } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
        $state = Update-ActivityState -Settings $settings
        $entry = $state.processes['4100']
        $protected = @(Get-ActiveProtectedPids -AllProcs $script:mockTreeProcs -State $state -Settings $settings -Now (Get-Date) -AdditionalRootPids @(4100))
        $treeRegressionOk = (((Get-Date) - (ConvertTo-DateTimeSafe $entry.lastActiveAt)).TotalSeconds -lt 5 -and ($protected -contains 4100))
        return ($positiveDeltaOk -and $treeRegressionOk)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name mockTreeTarget,mockTreeProcs -Scope Script -ErrorAction SilentlyContinue
    }
}
if ($claudeTreeActivityCheck) {
    Write-Host "[PASS] Claude descendant CPU increase/replacement linked to root+descendant protection" -ForegroundColor Green
} else {
    Write-TestFailure "Claude descendant CPU activity protection behavior failed"
}
$stopActiveRaceCheck = & {
    foreach ($fnName in @('ConvertTo-DateTimeSafe','Stop-TargetProcesses')) {
        $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
        Invoke-Expression $fnAst.Extent.Text
    }
    $created = (Get-Date).AddHours(-6).ToString('o')
    $script:mockStopRoot = [pscustomobject]@{ ProcessId = 4100; ParentProcessId = 1; Name = 'claude.exe'; CreationDate = $created; MainWindowHandle = [IntPtr]::Zero }
    $script:mockStopChild = [pscustomobject]@{ ProcessId = 4101; ParentProcessId = 4100; Name = 'bash.exe'; CreationDate = $created }
    $script:mockStopNewChild = [pscustomobject]@{ ProcessId = 4102; ParentProcessId = 4100; Name = 'wsl.exe'; CreationDate = $created }
    function Write-RunLog {}
    function Get-TrackerSettings { [pscustomobject]@{ idleMinutes = 180; cpuThresholdPct = 0.1 } }
    function Update-ActivityState { @{ version = 1; processes = @{} } }
    function Get-CimInstance {
        param([Parameter(Position=0)][string]$ClassName, [string]$Filter)
        $script:mockCimCall++
        if ($script:mockTreeChange -and $script:mockCimCall -ge 3) { return @($script:mockStopRoot, $script:mockStopNewChild) }
        return @($script:mockStopRoot, $script:mockStopChild)
    }
    function Get-DescendantPids { param([int[]]$RootPids, $AllProcs) @($AllProcs | Where-Object { $RootPids -contains [int]$_.ParentProcessId } | ForEach-Object { [int]$_.ProcessId }) }
    function Get-ActiveProtectedPids {
        $index = $script:mockGuardCall
        $script:mockGuardCall++
        if ($index -eq 0) { return $script:mockFirstProtected }
        return $script:mockSecondProtected
    }
    function Get-Process { param([int]$Id, [string]$ErrorAction) if ($Id -eq 4100) { $script:mockStopRoot } }
    function taskkill.exe { $script:mockTaskkillCalled = $true }
    $cases = @(
        [pscustomobject]@{ First = @(4100); Second = @(); Calls = 1; TreeChange = $false },
        [pscustomobject]@{ First = @(4101); Second = @(); Calls = 1; TreeChange = $false },
        [pscustomobject]@{ First = @(); Second = @(4100); Calls = 2; TreeChange = $false },
        [pscustomobject]@{ First = @(); Second = @(4101); Calls = 2; TreeChange = $false },
        [pscustomobject]@{ First = @(); Second = @(); Calls = 2; TreeChange = $true }
    )
    try {
        foreach ($case in $cases) {
            $script:mockFirstProtected = @($case.First)
            $script:mockSecondProtected = @($case.Second)
            $script:mockGuardCall = 0
            $script:mockCimCall = 0
            $script:mockTreeChange = $case.TreeChange
            $script:mockTaskkillCalled = $false
            Stop-TargetProcesses -Processes @($script:mockStopRoot) -TimeoutSec 0 -ProtectActive *> $null
            if ($script:mockTaskkillCalled -or $script:mockGuardCall -ne $case.Calls) { return $false }
        }
        return $true
    } finally {
        Remove-Variable -Name mockStopRoot,mockStopChild,mockStopNewChild,mockFirstProtected,mockSecondProtected,mockGuardCall,mockCimCall,mockTreeChange,mockTaskkillCalled -Scope Script -ErrorAction SilentlyContinue
    }
}
if ($stopActiveRaceCheck) {
    Write-Host "[PASS] root·descendant activation/tree changes immediately before pre-close/force block taskkill" -ForegroundColor Green
} else {
    Write-TestFailure "Active session taskkill blocking failed immediately before termination"
}
if ($src -match 'Start-Sleep -Milliseconds 100' -and $src -match 'Move-Item -LiteralPath \$tmp -Destination \$path -Force') {
    Write-Host "[PASS] activity-state read retry + atomic replace save" -ForegroundColor Green
} else {
    Write-TestFailure "activity-state simultaneous read/write protection missing"
}
if (($src | Select-String -Pattern 'Update-ActivityState -Settings \$idleSettings' -AllMatches).Matches.Count -gt 0 -and
    ($src | Select-String -Pattern 'Update-ActivityState -Settings \$activitySettings' -AllMatches).Matches.Count -ge 2 -and
    $src -match 'Stop-TargetProcesses[^\r\n]*-ProtectActive:\$IdleOnly') {
    Write-Host "[PASS] activity snapshot updated before IdleOnly selection/termination/force" -ForegroundColor Green
} else {
    Write-TestFailure "activity snapshot update missing immediately before cleanup"
}
if (($src | Select-String -Pattern '-not \(Test-IsCodexProcess \$_\)' -AllMatches).Matches.Count -gt 0 -and
    ($src | Select-String -Pattern '-not \(Test-IsCodexProcess \$t\)' -AllMatches).Matches.Count -gt 0) {
    Write-Host "[PASS] Codex orphan processes use idle determination only instead of immediate termination" -ForegroundColor Green
} else {
    Write-TestFailure "Codex orphan immediate termination exclusion guard missing"
}
if ($src -notmatch '(?ms)function\s+Get-CodexRootPids\b.*?return ,@\(\)' -and
    $src -notmatch '(?ms)function\s+Get-ActiveProtectedPids\b.*?return ,@\(\)') {
    Write-Host "[PASS] empty array return double-wrap absent" -ForegroundColor Green
} else {
    Write-TestFailure "active helper contains return ,@() — empty array can appear as 1 element"
}
if ($src -notmatch '(?im)^\s*\$pid\s*=') {
    Write-Host "[PASS] PowerShell automatic variable `$PID not overwritten" -ForegroundColor Green
} else {
    Write-TestFailure "`$pid assignment found — conflicts with PowerShell automatic variable `$PID"
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
        Write-TestFailure "Missing function definition: $fn"
    }
}

# 2. Check new parameter declarations
$expectedParams = @('Deep', 'IncludeShell', 'Diagnose')
foreach ($p in $expectedParams) {
    $pattern = '\[switch\]\$' + $p + '\b'
    if ($src -match $pattern) {
        Write-Host "[PASS] Parameter definition: -$p" -ForegroundColor Green
    } else {
        Write-TestFailure "Missing parameter: -$p"
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
    Write-TestFailure "Missing Write-RecoveryLog function"
}

# 8-1. Main log for hidden scheduled task execution tracking
if ($src -match '(?ms)^function\s+Write-RunLog\b' -and $src -match 'memoryreset\.log' -and $src -match 'target: pid=' -and $src -match 'taskkill-ok') {
    Write-Host "[PASS] Main execution file log present: memoryreset.log records target/termination result" -ForegroundColor Green
} else {
    Write-TestFailure "Missing main execution log — difficult to trace scheduled cleanup cause"
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
        Write-TestFailure "Tray Add-Type order error — MessageBox may fail on a second instance"
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
    Write-TestFailure "MemoryReset-Tray.ps1 file not found"
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
        Write-TestFailure "Missing function: $fn"
    }
}

# 16. New parameter declarations
foreach ($p in @('TrackActivity','IdleOnly')) {
    if ($src -match ('\[switch\]\$' + $p + '\b')) {
        Write-Host "[PASS] Parameter: -$p" -ForegroundColor Green
    } else {
        Write-TestFailure "Missing parameter: -$p"
    }
}

# 17. -TrackActivity excludes UAC elevation (prevents UAC popups during unattended 5 minute runs)
if ($src -match '-not\s+\(Test-IsAdmin\)\s+-and\s+-not\s+\$TrackActivity') {
    Write-Host "[PASS] -TrackActivity excluded from UAC elevation (safe for unattended runs)" -ForegroundColor Green
} else {
    Write-TestFailure "-TrackActivity triggers UAC elevation — Task Scheduler popup risk every 5 minutes"
}

# 18. [Security] Do not hardcode Telegram bot tokens — must load only from the settings file
if ($src -match '\d{8,}:[A-Za-z0-9_-]{30,}') {
    Write-TestFailure "Bot token format string found in source — hardcoded secret risk!"
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
        Write-TestFailure "tracker-settings.json token file unprotected — commit risk!"
    }
}

# 22. example template exists (for commits without tokens)
if (Test-Path (Join-Path $PSScriptRoot 'tracker-settings.example.json')) {
    Write-Host "[PASS] tracker-settings.example.json template exists" -ForegroundColor Green
} else {
    Write-Host "[WARN] example template missing" -ForegroundColor Yellow
}

# 23. Task Scheduler/launcher scripts exist
foreach ($script in @('Track-Schedule.ps1','Cleanup-Schedule.ps1','Run-Hidden.vbs','Track-Register.bat','Track-Unregister.bat','Run-IdleDryRun.bat','Run-IdleCleanup.bat')) {
    if (Test-Path (Join-Path $PSScriptRoot $script)) {
        Write-Host "[PASS] Script exists: $script" -ForegroundColor Green
    } else {
        Write-TestFailure "Missing script: $script"
    }
}

# 24. Task Scheduler registration uses wscript wrapper to prevent console focus theft
$trackSrc = Get-Content (Join-Path $PSScriptRoot 'Track-Schedule.ps1') -Raw
$cleanupSrc = Get-Content (Join-Path $PSScriptRoot 'Cleanup-Schedule.ps1') -Raw
if ($trackSrc -match "New-ScheduledTaskAction -Execute 'wscript\.exe'" -and
    $trackSrc -match 'Run-Hidden\.vbs' -and
    $cleanupSrc -match "New-ScheduledTaskAction -Execute 'wscript\.exe'" -and
    $cleanupSrc -match 'Run-Hidden\.vbs') {
    Write-Host "[PASS] Task Scheduler registration uses hidden wscript wrapper" -ForegroundColor Green
} else {
    Write-TestFailure "Task Scheduler registration risks reverting to direct powershell.exe execution"
}

# 25. Auto cleanup interval/Telegram guidance text synchronization
if ($cleanupSrc -match '\[int\]\$IntervalHours\s*=\s*3' -and $src -match 'ClaudeCodeMemoryCleanup.+every 3 hours') {
    Write-Host "[PASS] Auto cleanup default 3 hours + Telegram guidance synchronization" -ForegroundColor Green
} else {
    Write-TestFailure "Auto cleanup interval and Telegram guidance text mismatch"
}

# ════════════════════════════════════════════════════════════════════
# v1.4.1 Byproduct(descendant tree) cleanup smoke test
# ════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "== v1.4.1 Byproduct(descendant tree) cleanup smoke test =="

if ($src -match '(?ms)^function\s+Get-DescendantPids\b') {
    Write-Host "[PASS] Function definition: Get-DescendantPids" -ForegroundColor Green
} else { Write-TestFailure "Get-DescendantPids missing" }

if ($src -match '\[switch\]\$IncludeDescendants\b') {
    Write-Host "[PASS] Parameter: -IncludeDescendants" -ForegroundColor Green
} else { Write-TestFailure "-IncludeDescendants missing" }

# Get-DescendantPids must return a flat array (,@() double wrap prohibited — bug where desc becomes a single int[] element)
if ($src -match 'return \$result\.ToArray\(\)' -and $src -notmatch 'return ,\$result\.ToArray\(\)') {
    Write-Host "[PASS] Get-DescendantPids returns a flat array (no double wrap)" -ForegroundColor Green
} else { Write-Host "[WARN] Get-DescendantPids return format not verified" -ForegroundColor Yellow }

# IncludeDescendants guards excluding self / ExcludePids
if ($src -match '-ne \$self' -and $src -match 'ExcludePids -notcontains') {
    Write-Host "[PASS] Descendant collection has self / KeepPids exclusion guards" -ForegroundColor Green
} else { Write-Host "[WARN] Descendant exclusion guard not verified" -ForegroundColor Yellow }

if (Test-Path (Join-Path $PSScriptRoot 'Run-PurgeAll.bat')) {
    Write-Host "[PASS] Run-PurgeAll.bat (one click full cleanup) exists" -ForegroundColor Green
} else { Write-TestFailure "Run-PurgeAll.bat missing" }

if ($script:testFailures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $script:testFailures) -ForegroundColor Red
    exit 1
}
