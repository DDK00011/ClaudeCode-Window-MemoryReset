#Requires -Version 5.1
<#
.SYNOPSIS
    Safely terminates Claude Code and Antigravity and recovers Windows RAM.

.DESCRIPTION
    Windows does not immediately return memory from terminated processes to the free list and
    tends to retain it in the Standby List / File Cache and slows available memory recovery.
    This script increases recovery rate through the following 5 steps.

      1) Gracefully terminate Claude Code / Antigravity processes (CloseMainWindow)
      2) Force-kill the remaining process tree after timeout (taskkill /T /F)
      3) Empty Working Set for all remaining processes (EmptyWorkingSet, PROCESS_SET_QUOTA)
      4) System File Cache trim (SetSystemFileCacheSize)
      5) Modified Page List flush → Standby List cleanup (NtSetSystemInformation)
         * call flush immediately before purge to reclaim even dirty pages

.PARAMETER GracefulTimeoutSec
    Time to wait after CloseMainWindow (seconds). Default 8 seconds.

.PARAMETER DryRun
    Show only target processes without actual termination/recovery.

.PARAMETER SkipConfirmation
    Skip Y/n prompt (for automation/scheduler).

.PARAMETER KeepAlive
    Exit immediately after completion without waiting for key input.

.PARAMETER Deep
    [v1.1+] Tier A additional recovery — Memory Compression Store flush + System Working Set empty + network cache cleanup.
    Safe additional steps to narrow the gap with reboot.

.PARAMETER IncludeShell
    [v1.1+] Tier B additional — Explorer.exe + Windows Search service restart.
    Desktop flickers for 1~2 seconds and open Explorer windows close. Use with -Deep.

.PARAMETER Diagnose
    [v1.1+] Run diagnostics only without recovery — show memory list distribution, compression store, top consuming processes.
    [v1.3+] Added orphan analysis — classify claude.exe by parent IDE survival.
    No UAC required.

.PARAMETER KeepPids
    [v1.3+] PID to exclude from termination targets (comma-separated string). To preserve active sessions.
    Example: -KeepPids "1234,5678,9012"

.PARAMETER Interactive
    [v1.3+] Show prompt to select each PID to preserve before termination. Ignore -SkipConfirmation (user input is essential).

.PARAMETER OrphansOnly
    [v1.3+] Target only claude.exe / node.exe with dead parent IDE extension host (safe mode).
    Never touch child processes of active IDE.

.EXAMPLE
    .\MemoryReset.ps1                                     # default recovery
    .\MemoryReset.ps1 -DryRun                             # precheck
    .\MemoryReset.ps1 -Diagnose                           # memory analysis + orphan analysis
    .\MemoryReset.ps1 -Deep                               # Tier A addition
    .\MemoryReset.ps1 -Deep -IncludeShell                 # Tier A + B
    .\MemoryReset.ps1 -SkipConfirmation -KeepAlive        # automation
    .\MemoryReset.ps1 -OrphansOnly                        # [v1.3+] cleanup only orphans (dead parents)
    .\MemoryReset.ps1 -Interactive                        # [v1.3+] PID selection termination
    .\MemoryReset.ps1 -KeepPids "1234,5678"               # [v1.3+] explicit PID preservation
    .\MemoryReset.ps1 -OrphansOnly -SkipConfirmation      # [v1.3+] automatic orphan cleanup

.NOTES
    Administrator privileges always required (all modes). Automatically attempts UAC elevation if unavailable.
    [v1.1.2 change] Force UAC also for DryRun / Diagnose — accurate measurement of protected processes + security visibility.
    [v1.3.0 added] -KeepPids / -Interactive / -OrphansOnly — preserve active sessions + selective orphan termination.
    [v1.3.0 added] Orphan analysis in -Diagnose (classify claude.exe by parent IDE survival).
    [v1.3.0 added] Explicit VS Code extension (.vscode\extensions) whitelist — classification accuracy ↑.
#>

[CmdletBinding()]
param(
    [int]$GracefulTimeoutSec = 8,
    [switch]$DryRun,
    [switch]$SkipConfirmation,
    [switch]$KeepAlive,

    # v1.1 added ─────────────────────────────────────────────
    [switch]$Deep,           # Tier A: Memory Compression flush + System WS empty + network cache
    [switch]$IncludeShell,   # Tier B: Explorer.exe + Windows Search restart (use with Deep)
    [switch]$Diagnose,       # detailed memory distribution display before recovery

    # v1.3 added ─────────────────────────────────────────────
    # KeepPids: comma-separated string (e.g. "1234,5678") for safe round-trip across UAC elevation.
    # PowerShell auto-binds both "1234,5678" and 1234,5678 syntax → string is most robust.
    [string]$KeepPids = '',  # PID to exclude from termination targets (comma-separated). Example: -KeepPids "1234,5678"
    [switch]$Interactive,    # prompt to select each PID before termination (select items to preserve)
    [switch]$OrphansOnly,    # target only claude.exe with dead IDE extension host (safe mode)

    # v1.4 added ─────────────────────────────────────────────
    [switch]$TrackActivity,  # background tracking 1-tick: record CPU snapshot + Telegram alert if threshold exceeded. Does not terminate, no UAC required.
    [switch]$IdleOnly,       # only idle(idleMinutes+ inactivity) / orphan processes are cleanup targets (preserve active sessions)
    [switch]$IncludeDescendants  # Also terminate descendant tree (conhost/bash/node/pwsh/python and other byproducts) of target claude/Antigravity
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ════════════════════════════════════════════════════════════════════
# 0. [v1.3.0 security] Input validation — before UAC elevation, before executing any code.
#    -KeepPids value enters elevated PowerShell command line through UAC round trip.
#    Allowed: numbers / commas / space / tab only. All \s (\n,\r,\f,\v included) risks command line parsing
#    confusion risk → restrict to explicit [\d, \t].
# ════════════════════════════════════════════════════════════════════
if ($KeepPids -and $KeepPids -notmatch '^[\d, \t]*$') {
    Write-Host "[X] -KeepPids value contains disallowed characters." -ForegroundColor Red
    Write-Host "    Allowed: numbers / commas / space / tab only. Example: -KeepPids `"1234,5678,9012`"" -ForegroundColor Yellow
    Write-Host ("    Provided: '{0}'" -f ($KeepPids -replace '[\r\n]', '\n')) -ForegroundColor DarkGray
    exit 1
}

# ════════════════════════════════════════════════════════════════════
# 1. Administrator privileges check + automatic elevation
# ════════════════════════════════════════════════════════════════════
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin) -and -not $TrackActivity) {
    # v1.4: -TrackActivity is read-only(CPU snapshot) + alerts only → no admin required. Scheduler runs every 5 minutes
    #       Runs unattended, so no UAC popup must appear. In this case skip elevation and track directly.
    # v1.1.2: Force UAC always per user request (DryRun / Diagnose also use administrator privileges)
    # Reason:
    #   - Diagnose can enumerate "Memory Compression" processes / view other user processes
    #   - DryRun can accurately measure memory of protected processes
    #   - User confirms UAC each run (security visibility)
    Write-Host "[!] Administrator privileges required. Attempting UAC elevation..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DryRun)            { $argList += '-DryRun' }
    if ($SkipConfirmation)  { $argList += '-SkipConfirmation' }
    if ($KeepAlive)         { $argList += '-KeepAlive' }
    if ($Deep)              { $argList += '-Deep' }
    if ($IncludeShell)      { $argList += '-IncludeShell' }
    if ($Diagnose)          { $argList += '-Diagnose' }
    if ($Interactive)       { $argList += '-Interactive' }
    if ($OrphansOnly)       { $argList += '-OrphansOnly' }
    if ($IdleOnly)          { $argList += '-IdleOnly' }
    if ($IncludeDescendants){ $argList += '-IncludeDescendants' }
    if ($KeepPids)          { $argList += @('-KeepPids', "`"$KeepPids`"") }
    if ($PSBoundParameters.ContainsKey('GracefulTimeoutSec')) {
        $argList += @('-GracefulTimeoutSec', $GracefulTimeoutSec)
    }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
    } catch {
        Write-Host "[X] Elevation failed: $_" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# IncludeShell is meaningless without Deep — auto-enable
if ($IncludeShell -and -not $Deep) {
    Write-Host "[i] -IncludeShell used alone — -Deep is also auto-enabled" -ForegroundColor DarkGray
    $Deep = $true
}

# ════════════════════════════════════════════════════════════════════
# 2. Win32 API P/Invoke definitions
# ════════════════════════════════════════════════════════════════════
$signature = @'
using System;
using System.Runtime.InteropServices;

public static class MemoryAPI {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetSystemFileCacheSize(IntPtr MinimumFileCacheSize, IntPtr MaximumFileCacheSize, int Flags);

    [DllImport("ntdll.dll")]
    public static extern uint NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAll, ref TOKEN_PRIVILEGES NewState, uint Length, IntPtr Prev, IntPtr Ret);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public int  PrivilegeCount;
        public long Luid;
        public int  Attributes;
    }

    public const uint SE_PRIVILEGE_ENABLED        = 0x00000002;
    public const uint TOKEN_QUERY                 = 0x0008;
    public const uint TOKEN_ADJUST_PRIVILEGES     = 0x0020;

    public const uint PROCESS_QUERY_INFORMATION   = 0x0400;
    public const uint PROCESS_QUERY_LIMITED_INFO  = 0x1000;
    public const uint PROCESS_SET_QUOTA           = 0x0100;

    // SYSTEM_MEMORY_LIST_COMMAND (Process Hacker / phnt header verified)
    public const int  SystemMemoryListInformation        = 80;
    public const int  MemoryEmptyWorkingSets             = 2;  // empty all process working sets (NT level)
    public const int  MemoryFlushModifiedList            = 3;  // flush dirty pages → standby (higher recovery rate when called before purge)
    public const int  MemoryPurgeStandbyList             = 4;
    public const int  MemoryPurgeLowPriorityStandbyList  = 5;

    public const int  ERROR_NOT_ALL_ASSIGNED             = 1300;

    // Returns: 0 = success, 1 = OpenProcessToken failed, 2 = LookupPrivilegeValue failed,
    //          3 = AdjustTokenPrivileges API failed, 4 = privilege not held (ERROR_NOT_ALL_ASSIGNED)
    public static int EnablePrivilegeChecked(string privilege) {
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                return 1;

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Attributes     = (int)SE_PRIVILEGE_ENABLED;
            if (!LookupPrivilegeValue(null, privilege, out tp.Luid))
                return 2;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return 3;

            // CRITICAL: GetLastWin32Error MUST be called immediately after AdjustTokenPrivileges,
            // before any other P/Invoke. AdjustTokenPrivileges returns TRUE even when ERROR_NOT_ALL_ASSIGNED
            // is the actual outcome — only GetLastError reveals the real status.
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_ALL_ASSIGNED) return 4;

            return 0;
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    public static bool EnablePrivilege(string privilege) {
        return EnablePrivilegeChecked(privilege) == 0;
    }

    // Empty working set with minimal access rights — works on more processes than .Handle (PROCESS_ALL_ACCESS).
    // Returns: true on success, false on failure (process is protected or already dead).
    public static bool EmptyWorkingSetByPid(uint pid) {
        IntPtr h = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFO, false, pid);
        if (h == IntPtr.Zero) return false;
        try {
            return EmptyWorkingSet(h) != 0;
        } finally {
            CloseHandle(h);
        }
    }

    public static uint InvokeMemoryListCommand(int command) {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        EnablePrivilege("SeIncreaseQuotaPrivilege");

        IntPtr ptr = Marshal.AllocHGlobal(sizeof(int));
        try {
            Marshal.WriteInt32(ptr, command);
            return NtSetSystemInformation(SystemMemoryListInformation, ptr, sizeof(int));
        } finally {
            Marshal.FreeHGlobal(ptr);
        }
    }

    public static uint FlushModifiedPageList() {
        return InvokeMemoryListCommand(MemoryFlushModifiedList);
    }

    public static uint PurgeStandbyList(bool lowPriorityOnly) {
        return InvokeMemoryListCommand(lowPriorityOnly ? MemoryPurgeLowPriorityStandbyList : MemoryPurgeStandbyList);
    }

    public static bool ClearFileSystemCache() {
        EnablePrivilege("SeIncreaseQuotaPrivilege");
        return SetSystemFileCacheSize((IntPtr)(-1), (IntPtr)(-1), 0);
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'MemoryAPI').Type) {
    Add-Type -TypeDefinition $signature -Language CSharp
}

# ════════════════════════════════════════════════════════════════════
# 3. NTSTATUS friendly decoding
# ════════════════════════════════════════════════════════════════════
function Format-NTStatus {
    param([uint32]$Status)
    $name = switch ($Status) {
        0x00000000 { 'STATUS_SUCCESS' }
        0xC0000022 { 'STATUS_ACCESS_DENIED (administrator privileges not elevated?)' }
        0xC0000061 { 'STATUS_PRIVILEGE_NOT_HELD (SeProfileSingleProcessPrivilege not held)' }
        0xC0000005 { 'STATUS_ACCESS_VIOLATION' }
        0xC000000D { 'STATUS_INVALID_PARAMETER' }
        0xC0000002 { 'STATUS_NOT_IMPLEMENTED (unsupported on this Windows version)' }
        default    { 'UNKNOWN' }
    }
    '0x{0:X8} ({1})' -f $Status, $name
}

# ════════════════════════════════════════════════════════════════════
# 4. Memory status display
# ════════════════════════════════════════════════════════════════════
function Get-MemoryStatus {
    $os      = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024)
    $usedMB  = $totalMB - $freeMB
    $pctFree = [math]::Round(($freeMB / $totalMB) * 100, 1)

    [PSCustomObject]@{
        TotalMB = $totalMB
        UsedMB  = $usedMB
        FreeMB  = $freeMB
        PctFree = $pctFree
    }
}

function Show-MemoryStatus {
    param([string]$Label)
    $m = Get-MemoryStatus
    $color = if ($m.PctFree -lt 10)      { 'Red' }
             elseif ($m.PctFree -lt 25)  { 'Yellow' }
             else                        { 'Green' }
    Write-Host ""
    Write-Host "── $Label ──" -ForegroundColor Cyan
    Write-Host (" Total:      {0,8:N0} MB" -f $m.TotalMB)
    Write-Host (" Used:       {0,8:N0} MB" -f $m.UsedMB)
    Write-Host (" Available:  {0,8:N0} MB ({1}%)" -f $m.FreeMB, $m.PctFree) -ForegroundColor $color
    return $m
}

# ════════════════════════════════════════════════════════════════════
# 5.0. Orphan / Extension-host detection helpers (v1.3+)
# ════════════════════════════════════════════════════════════════════
function Test-IsClaudeOrphan {
    # The parent of claude.exe / node.exe (IDE extension host or shell spawner) is orphan if not alive.
    # Windows does not terminate children in cascade when parent dies → orphan buildup → main cause of memory leaks.
    # PID reuse risk: even if parent PID is alive, it is orphan when that PID is reassigned to another process instead of a legitimate spawner.
    # v1.3 hardened: add cmd/pwsh/powershell/bash/wsl/explorer to legitimate spawner whitelist — node.exe
    #            so normal cases where node.exe runs through npm script / terminal / cmd wrapper are not misclassified as orphan.
    param($ClaudeProc, $AllProcs)
    $parent = $AllProcs | Where-Object { $_.ProcessId -eq $ClaudeProc.ParentProcessId } | Select-Object -First 1
    if (-not $parent) { return $true }
    return ($parent.Name -notmatch '(?i)^(Code|Antigravity|claude|cursor|windsurf|codex|node_repl|node|cmd|pwsh|powershell|bash|wsl|explorer|conhost)\.exe$')
}

function ConvertFrom-KeepPidsString {
    # "1234,5678,9012" → [uint32[]]
    # v1.3 hardened: TryParse (prevent overflow) + invalid warning + array wrap (prevent single-element unwrap)
    param([string]$Csv)
    if (-not $Csv) { return ,@() }
    $valid   = @()
    $invalid = @()
    foreach ($t in ($Csv -split ',')) {
        $trimmed = $t.Trim()
        if (-not $trimmed) { continue }
        $parsed = [uint32]0
        if ([uint32]::TryParse($trimmed, [ref]$parsed)) {
            $valid += $parsed
        } else {
            $invalid += $trimmed
        }
    }
    if ($invalid.Count -gt 0) {
        Write-Host (" [!] Ignore invalid -KeepPids entries ({0} items): {1}" -f $invalid.Count, ($invalid -join ', ')) -ForegroundColor Yellow
    }
    # ,$valid → prevent PS pipeline unwrap (keep a single element as array too)
    return ,$valid
}

function Test-IsCodexProcess {
    param($Proc)
    if (-not $Proc) { return $false }
    $exe = if ($Proc.ExecutablePath) { $Proc.ExecutablePath } else { '' }
    $cmd = if ($Proc.CommandLine)    { $Proc.CommandLine }    else { '' }
    return (
        ($Proc.Name -match '(?i)^codex\.exe$' -and ($exe -match '(?i)\\@openai\\codex\\' -or $cmd -match '(?i)@openai[\\/]codex')) -or
        ($Proc.Name -match '(?i)^node_repl\.exe$' -and $exe -match '(?i)\\OpenAI\\Codex\\') -or
        ($Proc.Name -eq 'node.exe' -and $cmd -match '(?i)@openai[\\/]codex')
    )
}

# ════════════════════════════════════════════════════════════════════
# 5. Identify target processes
#    Core safety guard: never match Claude Desktop app (blacklist for multiple install paths).
#    Only CLI / Antigravity extensions / standard Node packages are termination targets.
#    v1.3: preserve with -ExcludePids, select only orphans with -OnlyOrphans.
#    v1.4: include descendant tree (byproducts spawned by claude) in termination targets with -IncludeDescendants.
# ════════════════════════════════════════════════════════════════════
function Get-DescendantPids {
    # Collect all descendant PIDs of RootPids with BFS (process tree walk). Based on snapshot($AllProcs).
    # Used to identify "byproducts" such as conhost/bash/node/pwsh/python spawned by claude/Antigravity.
    param([int[]]$RootPids, $AllProcs)
    $childMap = @{}
    foreach ($pr in $AllProcs) {
        $pp = [int]$pr.ParentProcessId
        if (-not $childMap.ContainsKey($pp)) { $childMap[$pp] = [System.Collections.Generic.List[int]]::new() }
        $childMap[$pp].Add([int]$pr.ProcessId)
    }
    $result = [System.Collections.Generic.List[int]]::new()
    $seen   = @{}
    $queue  = [System.Collections.Queue]::new()
    foreach ($r in $RootPids) { $queue.Enqueue([int]$r) }
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($childMap.ContainsKey($cur)) {
            foreach ($c in $childMap[$cur]) {
                if (-not $seen.ContainsKey($c)) {
                    $seen[$c] = $true
                    $result.Add($c)
                    $queue.Enqueue($c)
                }
            }
        }
    }
    # Caller wraps with @(), so return plain array (no ,@() double wrap)
    return $result.ToArray()
}

function Get-CodexRootPids {
    param($AllProcs)
    $codexPids = @($AllProcs | Where-Object { Test-IsCodexProcess $_ } | ForEach-Object { [int]$_.ProcessId })
    if ($codexPids.Count -eq 0) { return @() }

    $byPid = @{}
    foreach ($ap in $AllProcs) { $byPid[[int]$ap.ProcessId] = $ap }
    $roots = @{}

    foreach ($cpid in $codexPids) {
        $cur = $byPid[[int]$cpid]
        $root = $cur
        while ($cur) {
            $parent = $byPid[[int]$cur.ParentProcessId]
            if (-not $parent -or -not (Test-IsCodexProcess $parent)) { break }
            $root = $parent
            $cur = $parent
        }
        if ($root) { $roots[[int]$root.ProcessId] = $true }
    }
    return @($roots.Keys | ForEach-Object { [int]$_ })
}

function Get-ActiveCodexProtectedPids {
    param($AllProcs, $State, $Settings, $Now)
    $activeRoots = @()
    foreach ($rootPid in @(Get-CodexRootPids -AllProcs $AllProcs)) {
        $entry = if ($State -and $State.processes) { $State.processes["$rootPid"] } else { $null }
        if (-not (Test-ProcessIdle -Entry $entry -Settings $Settings -Now $Now)) {
            $activeRoots += [int]$rootPid
        }
    }
    if ($activeRoots.Count -eq 0) { return @() }

    $protected = @{}
    foreach ($rootPid in $activeRoots) { $protected[[int]$rootPid] = $true }
    foreach ($dpid in @(Get-DescendantPids -RootPids $activeRoots -AllProcs $AllProcs)) {
        $protected[[int]$dpid] = $true
    }
    return @($protected.Keys | ForEach-Object { [int]$_ })
}

function Get-TargetProcesses {
    # reason: whitelist matching + blacklist + integrated filter — over 30 lines unavoidable.
    # Splitting scatters matching rules across 2 places, increasing maintenance cost ↑.
    param(
        [uint32[]]$ExcludePids = @(),
        [switch]$OnlyOrphans,
        [switch]$IncludeDescendants
    )
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue

    # ── Identify Claude Code CLI ──
    # Whitelist(install paths) based: only target claude.exe/node.exe run from locations below.
    #   1) %USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\         [v1.3+ anchored]
    #   2) %USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\              [v1.3+ anchored]
    #   3) %USERPROFILE%\.vscode\extensions\anthropic.claude-code-*\              [v1.3+ anchored]
    #   4) Claude\claude-code\<version>\claude.exe                                 (path contains)
    #   5) npm\node_modules\@anthropic-ai\claude-code\                             (npm global)
    #   6) node.exe with @anthropic-ai/claude-code in command line
    #   7) claude.exe with --output-format stream-json + known path                [v1.3+ AND-gated]
    # Explicit blacklist: all known install paths for Claude Desktop app → never match.
    # v1.3 security: force %USERPROFILE% prefix for IDE extension paths — block C:\evil\.vscode\... spoofing.
    $userHomeExt = @(
        (Join-Path $env:USERPROFILE '.antigravity\extensions\anthropic.claude-code-'),
        (Join-Path $env:USERPROFILE '.cursor\extensions\anthropic.claude-code-'),
        (Join-Path $env:USERPROFILE '.vscode\extensions\anthropic.claude-code-')
    )
    # Other standalone trusted location patterns (anchored — prefix/structural match rather than path substring)
    $knownPathRegex = '(?i)(\\Claude\\claude-code\\|\\npm\\node_modules\\@anthropic-ai\\claude-code\\)'

    $claude = $allProcs | Where-Object {
        $exe = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
        $cmd = if ($_.CommandLine)    { $_.CommandLine }    else { '' }

        # Blacklist: always exclude Claude Desktop app (MSIX / Squirrel / direct install / OS-wide)
        if ($exe -match '(?i)\\WindowsApps\\Claude_')                                    { return $false }
        if ($exe -match '(?i)\\AnthropicClaude\\.*?\\Claude\.exe$' -and $cmd -notmatch '(?i)claude-code') { return $false }
        if ($exe -match '(?i)\\Programs\\claude-desktop\\.*?\\Claude\.exe$')             { return $false }
        if ($exe -match '(?i)\\Program Files\\Claude\\Claude\.exe$')                     { return $false }
        if ($exe -match '(?i)\\Program Files \(x86\)\\Claude\\Claude\.exe$')             { return $false }

        # Whitelist
        # (a) IDE extension path — %USERPROFILE% prefix anchored (case-insensitive StartsWith)
        $isUserExt = $false
        if ($exe) {
            foreach ($prefix in $userHomeExt) {
                if ($exe.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $isUserExt = $true; break }
            }
        }
        # (b) other known path pattern (npm global / standalone)
        $isKnownPath = ($exe -match $knownPathRegex)
        # (c) CLI signature arguments — cannot trust alone (v1.3 security). Combine with path signal using AND.
        $hasCliSignature = ($cmd -match '(?i)--output-format\s+stream-json') -and ($isUserExt -or $isKnownPath)

        ($_.Name -match '(?i)^claude\.exe$' -and ($isUserExt -or $isKnownPath -or $hasCliSignature)) -or
        ($_.Name -eq 'node.exe' -and $cmd -match '(?i)@anthropic-ai[\\/]claude-code')
    }

    # ── Antigravity identification ──
    # Exact installation path: %LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe
    # ExecutablePath is safest (includes every helper/renderer).
    $antigravity = $allProcs | Where-Object {
        ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') -or
        ($_.ExecutablePath -match '(?i)\\Google\\Antigravity\\') -or
        ($_.Name -match '(?i)^Antigravity(\.exe)?$' -and $_.ExecutablePath -match '(?i)Antigravity')
    }

    # ── Identify Codex CLI ──
    # Include in cleanup targets, but preserve if "in progress" by activity tracking status before actual termination.
    $codexRootPids = @(Get-CodexRootPids -AllProcs $allProcs)
    $codex = $allProcs | Where-Object { $codexRootPids -contains [int]$_.ProcessId }

    # Deduplicate + exclude self (current PowerShell)
    $self = $PID
    $merged = @($claude) + @($antigravity) + @($codex) |
        Where-Object { $_.ProcessId -ne $self } |
        Sort-Object ProcessId -Unique

    # v1.3: -ExcludePids — exclude user-specified PIDs from termination targets (preserve active sessions)
    if ($ExcludePids.Count -gt 0) {
        $merged = $merged | Where-Object { $ExcludePids -notcontains $_.ProcessId }
    }

    # v1.3: -OnlyOrphans — retain only claude.exe/node.exe where IDE extension host has died.
    # Antigravity main app (.exe itself) is the IDE, so orphan concept does not apply → excluded in OnlyOrphans mode for safety.
    if ($OnlyOrphans) {
        $merged = $merged | Where-Object {
            (-not (Test-IsCodexProcess $_)) -and
            $_.Name -match '(?i)^(claude|node)\.exe$' -and
            (Test-IsClaudeOrphan -ClaudeProc $_ -AllProcs $allProcs)
        }
    }

    # v1.4: -IncludeDescendants — add descendant tree (conhost/bash/node/pwsh/python and similar byproducts spawned by claude) to termination targets.
    # self / ExcludePids excluded. claude preserved by KeepPids is already removed from $merged, so descendants are also automatically preserved because not roots.
    if ($IncludeDescendants) {
        $merged = @($merged)
        if ($merged.Count -gt 0) {
            $rootPids = @($merged | ForEach-Object { [int]$_.ProcessId })
            $descPids = @(Get-DescendantPids -RootPids $rootPids -AllProcs $allProcs)
            if ($descPids.Count -gt 0) {
                $descProcs = $allProcs | Where-Object {
                    ($descPids -contains [int]$_.ProcessId) -and
                    ([int]$_.ProcessId -ne $self) -and
                    ($ExcludePids.Count -eq 0 -or $ExcludePids -notcontains $_.ProcessId)
                }
                $merged = @($merged) + @($descProcs) | Sort-Object ProcessId -Unique
            }
        }
    }

    return $merged
}

# ════════════════════════════════════════════════════════════════════
# 6. Process termination (Graceful → Wait → Force tree-kill)
# ════════════════════════════════════════════════════════════════════
function Write-RunLog {
    param([string]$Message)
    try {
        # ponytail: append-only log; add rotation if memoryreset.log grows enough to matter.
        $line = "[{0}] PID={1} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Message
        Add-Content -Path (Join-Path $PSScriptRoot 'memoryreset.log') -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Failed log writes must not block cleanup/recovery itself.
    }
}

function Stop-TargetProcesses {
    param(
        [array]$Processes,
        [int]$TimeoutSec = 8,
        [switch]$DryRun
    )

    if ($Processes.Count -eq 0) {
        Write-Host "[i] No target processes to terminate." -ForegroundColor DarkGray
        Write-RunLog "stop: no target processes"
        return
    }

    Write-RunLog ("stop: start targets={0} dryRun={1} timeoutSec={2}" -f $Processes.Count, [bool]$DryRun, $TimeoutSec)
    $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $codexSettings = Get-TrackerSettings
    $codexState = Update-ActivityState -Settings $codexSettings
    $activeCodexPids = @(Get-ActiveCodexProtectedPids -AllProcs $allProcs -State $codexState -Settings $codexSettings -Now (Get-Date))
    Write-RunLog ("stop: activeCodexProtected={0}" -f $activeCodexPids.Count)
    if ($activeCodexPids.Count -gt 0) {
        $Processes = @($Processes | Where-Object {
            $procId = [int]$_.ProcessId
            if ($activeCodexPids -contains $procId) {
                Write-Host " [SKIP] Preserve active Codex session → $($_.Name) (PID=$($_.ProcessId))" -ForegroundColor Green
                Write-RunLog ("skip: active-codex pid={0} name={1}" -f $_.ProcessId, $_.Name)
                return $false
            }
            $descPids = @(Get-DescendantPids -RootPids @($procId) -AllProcs $allProcs)
            $hasCodexChild = @($descPids | Where-Object { $activeCodexPids -contains [int]$_ }).Count -gt 0
            if ($hasCodexChild) {
                Write-Host " [SKIP] Preserve active Codex descendant → $($_.Name) (PID=$($_.ProcessId))" -ForegroundColor Green
                Write-RunLog ("skip: active-codex-descendant pid={0} name={1}" -f $_.ProcessId, $_.Name)
                return $false
            }
            return $true
        })
        Write-RunLog ("stop: targetsAfterCodexGuard={0}" -f $Processes.Count)
        if ($Processes.Count -eq 0) {
            Write-Host "[i] No target processes to terminate after preserving Codex." -ForegroundColor DarkGray
            Write-RunLog "stop: all targets skipped by Codex guard"
            return
        }
    }

    Write-Host ""
    Write-Host "── [1/4] Attempt graceful exit (CloseMainWindow) ──" -ForegroundColor Cyan
    Write-RunLog "stop: graceful close phase"
    foreach ($p in $Processes) {
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-RunLog ("gone-before-close pid={0} name={1}" -f $p.ProcessId, $p.Name)
            continue
        }

        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        if ($DryRun) {
            Write-Host " [DRY] CloseMainWindow → $tag" -ForegroundColor DarkGray
            Write-RunLog ("dry-close pid={0} name={1}" -f $p.ProcessId, $p.Name)
            continue
        }

        try {
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $null = $proc.CloseMainWindow()
                Write-Host " [OK] CloseMainWindow → $tag" -ForegroundColor Green
                Write-RunLog ("close-main-window pid={0} name={1}" -f $p.ProcessId, $p.Name)
            } else {
                Write-Host "  ·   No window     → $tag (force terminate in next step)" -ForegroundColor DarkGray
                Write-RunLog ("no-window pid={0} name={1}" -f $p.ProcessId, $p.Name)
            }
        } catch {
            Write-Host " [!] Graceful failed: $tag — $_" -ForegroundColor Yellow
            Write-RunLog ("close-failed pid={0} name={1} error={2}" -f $p.ProcessId, $p.Name, $_.Exception.Message)
        }
    }

    if ($DryRun) {
        Write-RunLog "stop: dry-run complete"
        return
    }

    Write-Host ""
    Write-Host "── [2/4] Wait ${TimeoutSec} seconds (allow time for saving/cleanup) ──" -ForegroundColor Cyan
    Write-RunLog ("stop: wait seconds={0}" -f $TimeoutSec)
    for ($i = $TimeoutSec; $i -gt 0; $i--) {
        Write-Host -NoNewline ("`r Time remaining: {0,2} seconds " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host "`r Wait complete.            "

    Write-Host ""
    Write-Host "── [3/4] remaining process tree force-kill (taskkill /T /F) ──" -ForegroundColor Cyan
    $survivors = $Processes | Where-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    }
    Write-RunLog ("stop: survivors={0}" -f @($survivors).Count)

    if ($survivors.Count -eq 0) {
        Write-Host " [OK] All processes completed a graceful exit." -ForegroundColor Green
        Write-RunLog "stop: all processes closed gracefully"
        return
    }

    $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $codexState = Update-ActivityState -Settings $codexSettings
    $activeCodexPids = @(Get-ActiveCodexProtectedPids -AllProcs $allProcs -State $codexState -Settings $codexSettings -Now (Get-Date))

    foreach ($p in $survivors) {
        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        $descPids = @(Get-DescendantPids -RootPids @([int]$p.ProcessId) -AllProcs $allProcs)
        $hasCodexChild = @($descPids | Where-Object { $activeCodexPids -contains [int]$_ }).Count -gt 0
        if ($hasCodexChild) {
            Write-Host " [SKIP] $tag (Preserve active Codex descendant)" -ForegroundColor Green
            Write-RunLog ("skip-force: active-codex-descendant pid={0} name={1}" -f $p.ProcessId, $p.Name)
            continue
        } else {
            $null = & taskkill.exe /F /T /PID $p.ProcessId 2>&1
        }
        # 0=success, 128=process already gone (cascaded by parent kill) → both OK
        if ($LASTEXITCODE -eq 0) {
            Write-Host " [KILL] $tag" -ForegroundColor Yellow
            Write-RunLog ("taskkill-ok pid={0} name={1}" -f $p.ProcessId, $p.Name)
        } elseif ($LASTEXITCODE -eq 128) {
            Write-Host " [GONE] $tag (already terminated)" -ForegroundColor DarkGray
            Write-RunLog ("taskkill-gone pid={0} name={1}" -f $p.ProcessId, $p.Name)
        } else {
            Write-Host " [X] taskkill failed: $tag (exit=$LASTEXITCODE)" -ForegroundColor Red
            Write-RunLog ("taskkill-failed pid={0} name={1} exit={2}" -f $p.ProcessId, $p.Name, $LASTEXITCODE)
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 7. Memory recovery (EmptyWorkingSet + FileCache + Flush + Purge)
# ════════════════════════════════════════════════════════════════════
function Invoke-MemoryRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [4/4] Memory recovery ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] EmptyWorkingSet / ClearFileSystemCache / PurgeStandbyList calls planned" -ForegroundColor DarkGray
        return
    }

    # 0) Required permission precheck (needed for Standby Purge / FileCache cleanup)
    $privReport = @{
        'SeProfileSingleProcessPrivilege' = [MemoryAPI]::EnablePrivilegeChecked('SeProfileSingleProcessPrivilege')
        'SeIncreaseQuotaPrivilege'        = [MemoryAPI]::EnablePrivilegeChecked('SeIncreaseQuotaPrivilege')
    }
    foreach ($k in $privReport.Keys) {
        $rc = $privReport[$k]
        $msg = switch ($rc) {
            0 { '[OK]   ' + $k }
            1 { '[!] OpenProcessToken failed: ' + $k }
            2 { '[!] LookupPrivilegeValue failed: ' + $k }
            3 { '[!] AdjustTokenPrivileges API failed: ' + $k }
            4 { '[!] Permission not held (NOT_ALL_ASSIGNED): ' + $k + ' — SeProfileSingleProcess may be unavailable even with administrator privileges. Check local security policy.' }
        }
        $color = if ($rc -eq 0) { 'DarkGray' } else { 'Yellow' }
        Write-Host " · $msg" -ForegroundColor $color
    }

    # 6-1. Empty working sets for all processes (minimum PROCESS_SET_QUOTA permission)
    Write-Host -NoNewline " · Clearing working sets ..."
    $ok = 0; $fail = 0
    Get-Process | ForEach-Object {
        try {
            if ([MemoryAPI]::EmptyWorkingSetByPid([uint32]$_.Id)) { $ok++ } else { $fail++ }
        } catch { $fail++ }
    }
    Write-Host " [OK] succeeded $ok / inaccessible $fail" -ForegroundColor Green

    # 6-2. File system cache trim
    Write-Host -NoNewline " · System File Cache trim ..."
    $r = [MemoryAPI]::ClearFileSystemCache()
    if ($r) { Write-Host " [OK]" -ForegroundColor Green }
    else    { Write-Host " [!] failed (Win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" -ForegroundColor Yellow }

    # 6-3. Modified Page List flush (dirty pages → move to standby, call immediately before purge)
    Write-Host -NoNewline " · Modified Page List flush ..."
    $rcFlush = [MemoryAPI]::FlushModifiedPageList()
    if ($rcFlush -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} (continuing)" -f (Format-NTStatus $rcFlush)) -ForegroundColor Yellow
    }

    # 6-4. Standby List cleanup (key — this step has the greatest recovery effect)
    Write-Host -NoNewline " · Standby List cleanup ..."
    $rc = [MemoryAPI]::PurgeStandbyList($false)
    if ($rc -eq 0) {
        Write-Host " [OK] (all standby cleared)" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} → retry low priority only" -f (Format-NTStatus $rc)) -ForegroundColor Yellow
        $rc2 = [MemoryAPI]::PurgeStandbyList($true)
        if ($rc2 -eq 0) {
            Write-Host "   Retry [OK] (low priority standby cleared)" -ForegroundColor Green
        } else {
            Write-Host ("   Retry failed NTSTATUS={0}" -f (Format-NTStatus $rc2)) -ForegroundColor Red
            Write-Host "   Candidate causes: administrator privileges not elevated / SeProfileSingleProcessPrivilege unavailable (check security policy)" -ForegroundColor DarkYellow
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 6.4. Zombie analysis — claude.exe parent (extension host) survival status classification [v1.3+]
#      "Definite zombies (parent dead)" vs "active groups (parent IDE alive)" separate.
# ════════════════════════════════════════════════════════════════════
function Show-ZombieAnalysis {
    # reason: host grouping + classification + output + summary form one UI flow — separating breaks output order.
    Write-Host ""
    Write-Host "── Zombie analysis [v1.3+] ──" -ForegroundColor Cyan

    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $targets  = @(Get-TargetProcesses)   # v1.3 safety: prevent pipeline unwrap
    $claudes  = @($targets | Where-Object { $_.Name -match '(?i)^(claude|node)\.exe$' })

    if ($claudes.Count -eq 0) {
        Write-Host " (No claude.exe / node.exe processes to analyze)" -ForegroundColor DarkGray
        return
    }

    # Group by parent PID — claude instances spawned from the same extension host are grouped
    $byHost = $claudes | Group-Object ParentProcessId | Sort-Object { [int]$_.Name }

    $orphans = @()
    foreach ($g in $byHost) {
        $hostPid  = $g.Name
        $hostProc = $allProcs | Where-Object { $_.ProcessId -eq [int]$hostPid } | Select-Object -First 1
        $totalMB  = [math]::Round((($g.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)

        if (-not $hostProc) {
            Write-Host (" [DEAD] parent PID {0,-6} — claude {1} / {2} MB → all are orphan" -f $hostPid, $g.Count, $totalMB) -ForegroundColor Red
            $orphans += $g.Group
        } elseif ($hostProc.Name -notmatch '(?i)^(Code|Antigravity|claude|cursor|windsurf|codex|node_repl|node|cmd|pwsh|powershell|bash|wsl|explorer|conhost)\.exe$') {
            Write-Host (" [REUSED] parent PID {0,-6} [{1}] PID reused — claude {2} / {3} MB" -f $hostPid, $hostProc.Name, $g.Count, $totalMB) -ForegroundColor Red
            $orphans += $g.Group
        } else {
            Write-Host (" [OK]   parent PID {0,-6} [{1}] — claude {2} / {3} MB" -f $hostPid, $hostProc.Name, $g.Count, $totalMB) -ForegroundColor Yellow
        }

        # Show top 3 child PID/WS
        $shown = 0
        foreach ($p in ($g.Group | Sort-Object WorkingSetSize -Descending)) {
            if ($shown -lt 3) {
                Write-Host ("     -> PID={0,-7} WS={1,7} MB" -f $p.ProcessId, [math]::Round($p.WorkingSetSize/1MB,1)) -ForegroundColor DarkGray
                $shown++
            }
        }
        if ($g.Count -gt 3) {
            Write-Host ("     -> ... {0} more" -f ($g.Count - 3)) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if ($orphans.Count -gt 0) {
        $orphanMB = [math]::Round((($orphans | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" [!] Definite zombies: {0} / {1} MB" -f $orphans.Count, $orphanMB) -ForegroundColor Red
        Write-Host "    → Safe termination:  .\MemoryReset.ps1 -OrphansOnly" -ForegroundColor Yellow
    } else {
        Write-Host " [OK] No orphan from dead parent (all claude.exe parents IDE alive)" -ForegroundColor Green
        Write-Host "      → If more claude.exe than active sessions, excess inside IDE:" -ForegroundColor DarkGray
        Write-Host '        .\MemoryReset.ps1 -Interactive          (select PID to terminate)'         -ForegroundColor DarkGray
        Write-Host '        .\MemoryReset.ps1 -KeepPids "PID1,PID2" (specify PID to preserve)'      -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════════════
# 6.5. -Diagnose: Show detailed memory distribution before recovery
# ════════════════════════════════════════════════════════════════════
function Show-MemoryDiagnostics {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║                    Memory Diagnostics                     ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    # 1. Memory list distribution based on PerfCounter
    Write-Host ""
    Write-Host "── Memory list distribution ──" -ForegroundColor Cyan
    try {
        $counters = @(
            '\Memory\Available MBytes',
            '\Memory\Cache Bytes',
            '\Memory\Modified Page List Bytes',
            '\Memory\Standby Cache Normal Priority Bytes',
            '\Memory\Standby Cache Reserve Bytes',
            '\Memory\Standby Cache Core Bytes',
            '\Memory\Free & Zero Page List Bytes'
        )
        $samples = (Get-Counter -Counter $counters -ErrorAction Stop).CounterSamples
        foreach ($s in $samples) {
            $name = ($s.Path -replace '.+\\Memory\\', '')
            $val  = if ($name -eq 'Available MBytes') { '{0,8:N0} MB' -f $s.CookedValue }
                    else { '{0,8:N0} MB' -f ($s.CookedValue / 1MB) }
            Write-Host (" · {0,-44} {1}" -f $name, $val)
        }
    } catch {
        Write-Host " [!] PerfCounter query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. Memory Compression Store
    Write-Host ""
    Write-Host "── Memory Compression Store ──" -ForegroundColor Cyan
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        Write-Host (" · MemoryCompression active: {0}" -f $mm.MemoryCompression)
        $compProc = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
        if ($compProc) {
            $compMB = [math]::Round($compProc.WorkingSet64 / 1MB, 1)
            Write-Host (" · 'Memory Compression' process usage: {0,8:N1} MB" -f $compMB) -ForegroundColor Yellow
            Write-Host "   → Can flush in -Deep mode"
        } else {
            # "Memory Compression" is a protected system process — enumerate failure is normal without administrator privileges
            $hint = if (Test-IsAdmin) { 'Hidden system process on some Windows builds' }
                    else              { 'Administrator privileges required (currently read-only mode)' }
            Write-Host " · Cannot directly measure 'Memory Compression' process ($hint)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] MMAgent query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3. Top memory-using processes Top 15 (working set basis)
    Write-Host ""
    Write-Host "── Top memory-using processes Top 15 (Working Set basis) ──" -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 |
        ForEach-Object {
            $wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
            $cmMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
            Write-Host (" · {0,-30} PID={1,-7} WS={2,8} MB  Commit={3,8} MB" -f $_.ProcessName, $_.Id, $wsMB, $cmMB)
        }

    # 4. Count of processes to terminate (actual recoverable amount preview)
    Write-Host ""
    Write-Host "── Target processes to terminate (Claude/Antigravity) ──" -ForegroundColor Cyan
    $targets = @(Get-TargetProcesses)   # v1.3 safety: prevent pipeline unwrap
    if ($targets.Count -eq 0) {
        Write-Host " (none)" -ForegroundColor DarkGray
    } else {
        $tWS = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" · Total {0} processes / Working Set total {1:N1} MB recoverable" -f $targets.Count, $tWS)
    }

    # 5. v1.3+: orphan analysis — confirmed orphan(parent death) vs active(parent IDE alive) separation
    Show-ZombieAnalysis

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  Done. Re-run without -Diagnose to reclaim.                ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
}

# ════════════════════════════════════════════════════════════════════
# 7-A. Tier A: deep recovery (-Deep)
#      Memory Compression Store flush + System Working Set + network cache
# ════════════════════════════════════════════════════════════════════
function Invoke-DeepRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep] Tier A — additional recovery ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] MMAgent restart / System WS / network cache call planned" -ForegroundColor DarkGray
        return
    }

    # A1. Memory Compression Store flush
    #     Principle: MemoryCompression is disabled then enabled again to release compressed pages
    #     Note 1: decompression causes a temporary memory spike → if available RAM < 1GB skip (prevent OOM)
    #     Note 2: after Disable succeeds if Enable fails the system compression feature stays permanently disabled → try/finally required
    Write-Host -NoNewline " · Memory Compression Store flush ..."
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        if (-not $mm.MemoryCompression) {
            Write-Host " [skip] already disabled" -ForegroundColor DarkGray
        } else {
            # safety guard: decompression spike risk if available memory is below 1GB
            $os = Get-CimInstance Win32_OperatingSystem
            $availMB = [math]::Round($os.FreePhysicalMemory / 1024)
            if ($availMB -lt 1024) {
                Write-Host (" [skip] insufficient available RAM ({0} MB < 1024 MB) — decompression spike risk" -f $availMB) -ForegroundColor Yellow
            } else {
                $disabled = $false
                try {
                    Disable-MMAgent -MemoryCompression -ErrorAction Stop
                    $disabled = $true
                    # Wait for Decompress background work — GB store may be brief but 1500ms is a reasonable balance
                    Start-Sleep -Milliseconds 1500
                } finally {
                    # CRITICAL: after Disable always guarantee Enable (system protection)
                    if ($disabled) {
                        try {
                            Enable-MMAgent -MemoryCompression -ErrorAction Stop
                            Write-Host " [OK] (compressed pages released)" -ForegroundColor Green
                        } catch {
                            # double failure — strongly alert user
                            Write-Host ""
                            Write-Host " [CRITICAL] MemoryCompression Re-Enable failed!" -ForegroundColor Red
                            Write-Host "   Manual recovery required: run 'Enable-MMAgent -MemoryCompression' in PowerShell with administrator privileges" -ForegroundColor Red
                            Write-Host "   Or reboot PC for automatic recovery" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host " [!] failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # A2. System-wide Working Set empty (NT level bulk)
    #     the 6-1 per-process loop(PROCESS_SET_QUOTA permission missing causes protected process skip)
    #     Supplemented in kernel mode. Same behavior as RAMMap "Empty Working Sets".
    Write-Host -NoNewline " · System Working Set empty (NT) ..."
    $rcWs = [MemoryAPI]::InvokeMemoryListCommand([MemoryAPI]::MemoryEmptyWorkingSets)
    if ($rcWs -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0}" -f (Format-NTStatus $rcWs)) -ForegroundColor Yellow
    }

    # A3. network cache cleanup (DNS / NetBIOS / ARP)
    Write-Host -NoNewline " · DNS cache ..."
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host -NoNewline " · NetBIOS cache ..."
    $null = & nbtstat.exe -R 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] nbtstat exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }

    Write-Host -NoNewline " · ARP cache ..."
    $null = & netsh.exe interface ip delete arpcache 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] netsh exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-B. Tier B: shell restart (-IncludeShell)
#      Explorer.exe + Windows Search restart — 200~500MB additional recovery
#      Note: desktop flickers for 1~2 seconds, open File Explorer windows close
# ════════════════════════════════════════════════════════════════════
function Invoke-ShellRestart {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep+Shell] Tier B — shell restart ──" -ForegroundColor Cyan
    Write-Host "  ! Desktop briefly flickers and open File Explorer windows close." -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host " [DRY] explorer.exe + WSearch restart planned" -ForegroundColor DarkGray
        return
    }

    # B1. Explorer.exe restart
    #     Note 1: systems with many shell extensions may take 5 seconds+ to restart → poll up to 15 seconds
    #     Note 2: in administrator PS Start-Process starts explorer in elevated context
    #             regular apps(drag and drop, IME etc) may lack permission.
    #             Therefore rely only on Windows automatic shell restart(winlogon starts with user token).
    #             On automatic restart failure do not start manually and only show user guidance.
    Write-Host -NoNewline " · Explorer restart ..."
    try {
        $explorers = Get-Process -Name explorer -ErrorAction SilentlyContinue
        $beforeMB = if ($explorers) { [math]::Round((($explorers | Measure-Object WorkingSet64 -Sum).Sum / 1MB), 1) } else { 0 }
        if ($explorers) {
            $explorers | Stop-Process -Force -ErrorAction Stop
        }

        # Windows automatic shell restart polling (wait up to 15 seconds)
        $restartedByWindows = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
                $restartedByWindows = $true
                break
            }
        }

        if ($restartedByWindows) {
            Write-Host (" [OK] Windows automatic restart complete (previous usage {0} MB)" -f $beforeMB) -ForegroundColor Green
        } else {
            # intentionally not launching elevated explorer.exe directly (preventing permission context contamination).
            # provide safe recovery instructions to user.
            Write-Host (" [!] Windows could not automatically restart (previous usage {0} MB)" -f $beforeMB) -ForegroundColor Yellow
            Write-Host "   → Ctrl+Shift+Esc → Task Manager → File → 'Run new task' → enter explorer (uncheck administrator)" -ForegroundColor DarkYellow
            Write-Host "   → Or log out/log in" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # B2. Windows Search service restart
    Write-Host -NoNewline " · Windows Search restart ..."
    try {
        $svc = Get-Service -Name WSearch -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Restart-Service -Name WSearch -Force -ErrorAction Stop
            Write-Host " [OK]" -ForegroundColor Green
        } else {
            Write-Host " [skip] service is not running ($($svc.Status))" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-C. CSV recovery history logging
# ════════════════════════════════════════════════════════════════════
function Write-RecoveryLog {
    param(
        [string]$Mode,
        [int]$TotalMB,
        [int]$BeforeFreeMB,
        [int]$AfterFreeMB,
        [double]$BeforePctFree,
        [double]$AfterPctFree,
        [int]$ProcessesKilled,
        [double]$RuntimeSec
    )

    $logPath = Join-Path $PSScriptRoot 'recovery-history.csv'
    $isNew   = -not (Test-Path $logPath)

    # clarify column meanings:
    #   Used* = used memory (memory usage)
    #   Free* = available memory (increases after recovery)
    #   FreedMB = amount recovered = UsedBefore - UsedAfter (= AfterFree - BeforeFree, positive means recovery succeeded)
    $usedBefore = $TotalMB - $BeforeFreeMB
    $usedAfter  = $TotalMB - $AfterFreeMB

    $row = [PSCustomObject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = $Mode
        TotalMB          = $TotalMB
        UsedBeforeMB     = $usedBefore
        UsedAfterMB      = $usedAfter
        FreedMB          = $usedBefore - $usedAfter      # positive = recovery succeeded
        BeforeFreeMB     = $BeforeFreeMB
        AfterFreeMB      = $AfterFreeMB
        BeforePctFree    = $BeforePctFree
        AfterPctFree     = $AfterPctFree
        FreedPctP        = [math]::Round($AfterPctFree - $BeforePctFree, 2)  # available % increase (+ means recovery)
        ProcessesKilled  = $ProcessesKilled
        RuntimeSec       = [math]::Round($RuntimeSec, 1)
    }

    # CSV file lock (when open in Excel, etc.) handling — retry up to 3 times + fallback file
    $maxRetry = 3
    for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
        try {
            if ($isNew) {
                $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            } else {
                $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
            }
            return  # success
        } catch {
            if ($attempt -lt $maxRetry) {
                Start-Sleep -Milliseconds (300 * $attempt)  # progressive backoff
            } else {
                # final failure — append to date-based fallback file (prevent same-second collisions)
                # Filename: recovery-history-fallback-YYYYMMDD.csv  → all same-day fallback entries accumulate in one file
                Write-Host " [!] CSV log write failed (lock or permission): $($_.Exception.Message)" -ForegroundColor DarkYellow
                $fallbackName = 'recovery-history-fallback-' + (Get-Date -Format 'yyyyMMdd') + '.csv'
                $fallback = Join-Path (Split-Path $logPath -Parent) $fallbackName
                $fallbackIsNew = -not (Test-Path $fallback)
                # fallback can also be locked — brief retry
                $fbOk = $false
                for ($fbAttempt = 1; $fbAttempt -le 3; $fbAttempt++) {
                    try {
                        if ($fallbackIsNew) {
                            $row | Export-Csv -Path $fallback -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                        } else {
                            $row | Export-Csv -Path $fallback -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
                        }
                        $fbOk = $true
                        break
                    } catch {
                        Start-Sleep -Milliseconds (200 * $fbAttempt)
                    }
                }
                if ($fbOk) {
                    Write-Host (" [i] Written to fallback file: {0}" -f (Split-Path $fallback -Leaf)) -ForegroundColor DarkGray
                } else {
                    # last resort: unique GUID filename (avoid collisions entirely, combine during reconstruction)
                    $unique = Join-Path (Split-Path $logPath -Parent) ('recovery-history-emergency-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,4)) + '.csv')
                    try {
                        $row | Export-Csv -Path $unique -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                        Write-Host (" [i] Written to emergency file: {0}" -f (Split-Path $unique -Leaf)) -ForegroundColor DarkGray
                    } catch {
                        Write-Host " [!] All write attempts failed (CSV log missing)" -ForegroundColor DarkYellow
                    }
                }
            }
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-Z. [v1.4.0] activity tracking + idle detection + Telegram alert
#   Background tracking(-TrackActivity): periodically records CPU snapshots of target processes to
#   safely determine "N consecutive minutes of inactivity". Active sessions always use CPU within idleMinutes, so
#   identifies only abandoned sessions without false positives(active session termination). This mode never kills processes —
#   when the threshold is exceeded, sends only a Telegram alert, and the user manually runs actual cleanup(kill).
# ════════════════════════════════════════════════════════════════════
function Write-TrackerLog {
    param([string]$Message)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path (Join-Path $PSScriptRoot 'tracker.log') -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Log write failures are intentionally ignored — logging must not block tracking/alerts.
    }
}

function ConvertTo-HashtableDeep {
    # ConvertFrom-Json (PSCustomObject) → nested hashtable. PS 5.1 does not support -AsHashtable, so convert manually.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-HashtableDeep $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($InputObject -is [object[]]) {
        return ,@($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }
    return $InputObject
}

function ConvertTo-DateTimeSafe {
    param([string]$Text)
    if (-not $Text) { return $null }
    try {
        return [datetime]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
}

function Merge-DefaultSettings {
    # Fill missing or null keys in $Target from $Default (recursive nested PSCustomObject). Guard against missing settings file keys.
    param($Target, $Default)
    if ($null -eq $Target) { return $Default }
    foreach ($p in $Default.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$p.Name]
        if (-not $existing -or $null -eq $existing.Value) {
            $Target | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        } elseif ($p.Value -is [System.Management.Automation.PSCustomObject]) {
            $null = Merge-DefaultSettings $Target.$($p.Name) $p.Value
        }
    }
    return $Target
}

function Get-TrackerSettings {
    $defaults = [PSCustomObject]@{
        idleMinutes      = 60
        cpuThresholdPct  = 0.5
        trackIntervalMin = 5
        alert = [PSCustomObject]@{
            enabled            = $false
            telegramBotToken   = ''
            telegramChatId     = ''
            ramPctThreshold    = 10
            idleCountThreshold = 10
            idleMemMBThreshold = 4096
            cooldownMin        = 30
        }
    }
    $path = Join-Path $PSScriptRoot 'tracker-settings.json'
    if (-not (Test-Path $path)) { return $defaults }
    try {
        $loaded = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Merge-DefaultSettings $loaded $defaults)
    } catch {
        Write-TrackerLog "Failed to load tracker-settings.json — using defaults: $($_.Exception.Message)"
        return $defaults
    }
}

function Get-ActivityStatePath { Join-Path $PSScriptRoot 'activity-state.json' }
function Get-TrackerStatePath  { Join-Path $PSScriptRoot 'tracker-state.json' }

function Read-ActivityState {
    $path = Get-ActivityStatePath
    if (-not (Test-Path $path)) { return @{ version = 1; updatedAt = ''; processes = @{} } }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $obj = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $h = ConvertTo-HashtableDeep $obj
            if ($null -eq $h)           { $h = @{} }
            if ($null -eq $h.processes) { $h.processes = @{} }
            return $h
        } catch {
            if ($attempt -eq 0) { Start-Sleep -Milliseconds 100; continue }
            Write-TrackerLog "Failed to load activity-state.json — starting with new state: $($_.Exception.Message)"
            return @{ version = 1; updatedAt = ''; processes = @{} }
        }
    }
}

function Write-ActivityState {
    param($State)
    $path = Get-ActivityStatePath
    $tmp = "$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } catch {
        Write-TrackerLog "Failed to save activity-state.json: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Read-TrackerState {
    $path = Get-TrackerStatePath
    if (-not (Test-Path $path)) { return @{ lastAlertAt = '' } }
    try {
        $obj = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = ConvertTo-HashtableDeep $obj
        if ($null -eq $h) { $h = @{ lastAlertAt = '' } }
        return $h
    } catch { return @{ lastAlertAt = '' } }
}

function Write-TrackerState {
    param($State)
    try {
        ($State | ConvertTo-Json -Depth 4) | Set-Content -Path (Get-TrackerStatePath) -Encoding UTF8 -ErrorAction Stop
    } catch { Write-TrackerLog "Failed to save tracker-state.json: $($_.Exception.Message)" }
}

function Get-LogicalCoreCount {
    if (-not $script:nLogicalCores) {
        try { $script:nLogicalCores = [int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors }
        catch { $script:nLogicalCores = [Environment]::ProcessorCount }
        if (-not $script:nLogicalCores -or $script:nLogicalCores -lt 1) { $script:nLogicalCores = 1 }
    }
    return $script:nLogicalCores
}

function Update-ActivityState {
    # reason: handles 4 snapshot branches(new/existing update/PID reuse reset/terminated removal) in one flow — splitting breaks state consistency.
    # Calculate the previous interval CPU rate from each target cumulative CPU seconds(Get-Process.CPU) delta, update lastActiveAt when at or above threshold.
    # Save I/O counters for diagnostics only. Do not reset idle time solely from background IPC/sleep-resume I/O.
    param($Settings)
    $now    = Get-Date
    $nowIso = $now.ToString('o')
    $nCores = Get-LogicalCoreCount
    $state  = Read-ActivityState
    if ($null -eq $state.processes) { $state.processes = @{} }

    $targets = @(Get-TargetProcesses)
    $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $cimByPid = @{}
    foreach ($p in $allProcs) { $cimByPid[[int]$p.ProcessId] = $p }
    $gp = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $gp[[int]$_.Id] = $_ }

    $seen = @{}
    foreach ($t in $targets) {
        $procId = [int]$t.ProcessId
        $seen["$procId"] = $true
        $treePids = if (Test-IsCodexProcess $t) {
            @($procId) + @(Get-DescendantPids -RootPids @($procId) -AllProcs $allProcs)
        } else {
            @($procId)
        }
        $cpuSec = $null
        $ioOps = [UInt64]0
        $ioBytes = [UInt64]0
        foreach ($treePid in $treePids) {
            $proc = $gp[[int]$treePid]
            if ($proc -and $null -ne $proc.CPU) {
                if ($null -eq $cpuSec) { $cpuSec = [double]0 }
                $cpuSec += [double]$proc.CPU
            }
            $cim = $cimByPid[[int]$treePid]
            if ($cim) {
                $ioOps += [UInt64]$cim.ReadOperationCount + [UInt64]$cim.WriteOperationCount + [UInt64]$cim.OtherOperationCount
                $ioBytes += [UInt64]$cim.ReadTransferCount + [UInt64]$cim.WriteTransferCount + [UInt64]$cim.OtherTransferCount
            }
        }
        $creation = if ($t.CreationDate) { ([datetime]$t.CreationDate).ToString('o') } else { '' }
        $key      = "$procId"
        $entry    = $state.processes[$key]

        if ($entry -and $entry.creationDate -eq $creation) {
            # Same process(PID+creation time matches) — determine activity from CPU delta, update I/O diagnostics only
            $legacyEntry = -not $entry.activityModel
            $legacyRepaired = $false
            $cpuActive = $false
            if ($legacyEntry -and $entry.lastActiveAt -eq $entry.lastSeenAt -and $null -ne $entry.lastCpuRatePct) {
                $first = ConvertTo-DateTimeSafe $entry.firstTrackedAt
                $legacySeen = ConvertTo-DateTimeSafe $entry.lastSeenAt
                if ($first -and $legacySeen -and (($legacySeen - $first).TotalMinutes -ge [double]$Settings.idleMinutes) -and ([double]$entry.lastCpuRatePct -lt [double]$Settings.cpuThresholdPct)) {
                    $entry.lastActiveAt = $entry.firstTrackedAt
                    $legacyRepaired = $true
                }
            }
            if ($null -ne $cpuSec -and $null -ne $entry.lastCpuSec) {
                $lastSeen = ConvertTo-DateTimeSafe $entry.lastSeenAt
                $dSec = if ($lastSeen) { ($now - $lastSeen).TotalSeconds } else { 0 }
                if ($dSec -gt 0) {
                    $dCpu = $cpuSec - [double]$entry.lastCpuSec
                    if ($dCpu -lt 0) { $dCpu = 0 }
                    $ratePct = ($dCpu / $dSec / $nCores) * 100
                    $entry.lastCpuRatePct = [math]::Round($ratePct, 3)
                    if ($ratePct -ge [double]$Settings.cpuThresholdPct) {
                        $entry.lastActiveAt = $nowIso
                        $cpuActive = $true
                    }
                }
            }
            if ($null -ne $cpuSec) { $entry.lastCpuSec = $cpuSec }
            $entry.lastIoOps   = $ioOps
            $entry.lastIoBytes = $ioBytes
            $entry.lastSeenAt = $nowIso
            $entry.name       = [string]$t.Name
            $entry.wsBytes    = [long]$t.WorkingSetSize
            $entry.ppid       = [int]$t.ParentProcessId
            if ((-not $legacyEntry) -or $legacyRepaired -or $cpuActive) {
                $entry.activityModel = 'cpu-tree-v2'
            }
            $state.processes[$key] = $entry
        } else {
            # New or PID reuse(creation time mismatch) → reset history, register baseline
            $state.processes[$key] = @{
                name           = [string]$t.Name
                creationDate   = $creation
                firstTrackedAt = $nowIso
                lastActiveAt   = $nowIso
                lastCpuSec     = $cpuSec
                lastCpuRatePct = $null
                lastIoOps      = $ioOps
                lastIoBytes    = $ioBytes
                lastSeenAt     = $nowIso
                wsBytes        = [long]$t.WorkingSetSize
                ppid           = [int]$t.ParentProcessId
                activityModel  = 'cpu-tree-v2'
            }
        }
    }

    # Remove terminated PID (copy keys to avoid collection modification during Remove)
    foreach ($k in @($state.processes.Keys)) {
        if (-not $seen[$k]) { $state.processes.Remove($k) }
    }
    $state.updatedAt = $nowIso
    Write-ActivityState $state
    return $state
}

function Test-ProcessIdle {
    # Safe determination: (1)idleMinutes elapsed since tracking started(sufficient observation) AND (2)idleMinutes elapsed since last activity
    #            AND (3)previous interval CPU rate < threshold. Codex updates lastActiveAt with CPU across the tree.
    #            Any unmet condition → preserve(false). Prevent active session false positives.
    param($Entry, $Settings, $Now)
    if (-not $Entry) { return $false }
    $first  = ConvertTo-DateTimeSafe $Entry.firstTrackedAt
    $active = ConvertTo-DateTimeSafe $Entry.lastActiveAt
    if (-not $first -or -not $active) { return $false }
    $idleMin = [double]$Settings.idleMinutes
    if (($Now - $first).TotalMinutes  -lt $idleMin) { return $false }   # insufficient observation → preserve
    if (($Now - $active).TotalMinutes -lt $idleMin) { return $false }   # recent activity → preserve
    if ($null -ne $Entry.lastCpuRatePct -and [double]$Entry.lastCpuRatePct -ge [double]$Settings.cpuThresholdPct) { return $false }
    return $true
}

function Get-ReclaimCandidates {
    # Candidate list of idle(tracking-based 1 hour+ inactivity) ∪ orphan(parent IDE terminated)(PSCustomObject[]).
    param($Settings)
    $now      = Get-Date
    $state    = Read-ActivityState
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $targets  = @(Get-TargetProcesses)
    $result   = @()
    foreach ($t in $targets) {
        $entry    = $state.processes["$([int]$t.ProcessId)"]
        $isIdle   = Test-ProcessIdle -Entry $entry -Settings $Settings -Now $now
        $isOrphan = (-not (Test-IsCodexProcess $t)) -and
                    ($t.Name -match '(?i)^(claude|node)\.exe$') -and
                    (Test-IsClaudeOrphan -ClaudeProc $t -AllProcs $allProcs)
        if ($isIdle -or $isOrphan) {
            $idleMin = $null
            if ($entry -and $entry.lastActiveAt) {
                $a = ConvertTo-DateTimeSafe $entry.lastActiveAt
                if ($a) { $idleMin = [math]::Round(($now - $a).TotalMinutes, 1) }
            }
            $result += [PSCustomObject]@{
                ProcessId = [int]$t.ProcessId
                Name      = [string]$t.Name
                WsMB      = [math]::Round($t.WorkingSetSize / 1MB, 1)
                IsIdle    = $isIdle
                IsOrphan  = $isOrphan
                IdleMin   = $idleMin
            }
        }
    }
    # Callers always wrap with @(), so return directly (,@() double wrapping prohibited — causes nested array bugs)
    return $result
}

function Send-TelegramMessage {
    param([string]$Token, [string]$ChatId, [string]$Text)
    if (-not $Token -or -not $ChatId) {
        Write-TrackerLog "Telegram send skipped — token or chatId not set"
        return $false
    }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # Send as JSON + UTF-8 bytes — hash -Body breaks text/emojis into ASCII in PS 5.1.
        $json  = @{ chat_id = $ChatId; text = $Text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/sendMessage" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 12 -ErrorAction Stop
        return $true
    } catch {
        Write-TrackerLog "Telegram send failed: $($_.Exception.Message)"
        return $false
    }
}

function Format-AlertMessage {
    param($Candidates, $MemMB, $RamPct, $Ram)
    $idleN   = @($Candidates | Where-Object { $_.IsIdle }).Count
    $orphanN = @($Candidates | Where-Object { $_.IsOrphan }).Count
    $lines = @()
    $lines += "🧹 <b>MemoryReset — accumulated cleanup candidate alert</b>"
    $lines += ""
    $lines += "Cleanup candidates: <b>$($Candidates.Count)</b> / <b>$MemMB MB</b> ($RamPct% of RAM)"
    $lines += "· idle (idleMinutes+ inactivity, CPU rate&lt;threshold): $idleN"
    $lines += "· orphan (parent IDE terminated): $orphanN"
    $lines += "· current available RAM: $($Ram.FreeMB) MB ($($Ram.PctFree)%)"
    $top = @($Candidates | Sort-Object WsMB -Descending | Select-Object -First 5)
    if ($top.Count -gt 0) {
        $lines += ""
        $lines += "<b>Top memory use</b>:"
        foreach ($p in $top) {
            $tag = if ($p.IsOrphan) { ' [orphan]' } elseif ($p.IsIdle) { ' [idle]' } else { '' }
            $lines += "  PID $($p.ProcessId)  $($p.Name)  $($p.WsMB)MB$tag"
        }
    }
    $lines += ""
    $lines += "Preview: <code>Run-IdleDryRun.bat</code>"
    $lines += "Auto cleanup: <code>ClaudeCodeMemoryCleanup</code> task runs <code>-IdleOnly</code> every 3 hours"
    $lines += "Immediate cleanup: <code>Run-IdleCleanup.bat</code>"
    return ($lines -join "`n")
}

function Invoke-ActivityTracking {
    # Background tracking 1-tick: update snapshot → derive cleanup candidates → Telegram alert on threshold exceedance.
    # Never terminate processes(read-only + alerts only). Task Scheduler invokes at trackIntervalMin intervals.
    $settings = Get-TrackerSettings
    $null = Update-ActivityState -Settings $settings
    $now  = Get-Date

    $candidates = @(Get-ReclaimCandidates -Settings $settings)
    $count = $candidates.Count
    $memMB = if ($count -gt 0) { [math]::Round((@($candidates | Measure-Object WsMB -Sum).Sum), 1) } else { 0 }
    $ram   = Get-MemoryStatus
    $ramPct = if ($ram.TotalMB -gt 0) { [math]::Round($memMB / $ram.TotalMB * 100, 1) } else { 0 }

    $a = $settings.alert
    $trigger = ($count -ge [int]$a.idleCountThreshold) -or
               ($memMB -ge [double]$a.idleMemMBThreshold) -or
               ($ramPct -ge [double]$a.ramPctThreshold)

    Write-TrackerLog ("tick: candidates={0} memMB={1} ramPct={2}% trigger={3} alertEnabled={4}" -f $count, $memMB, $ramPct, $trigger, $a.enabled)

    if ($a.enabled -and $trigger) {
        $tstate = Read-TrackerState
        $lastAlert = ConvertTo-DateTimeSafe $tstate.lastAlertAt
        $cooled = (-not $lastAlert) -or (($now - $lastAlert).TotalMinutes -ge [double]$a.cooldownMin)
        if ($cooled) {
            $msg = Format-AlertMessage -Candidates $candidates -MemMB $memMB -RamPct $ramPct -Ram $ram
            if (Send-TelegramMessage -Token $a.telegramBotToken -ChatId $a.telegramChatId -Text $msg) {
                $tstate.lastAlertAt = $now.ToString('o')
                Write-TrackerState $tstate
                Write-TrackerLog "Telegram alert sent (candidates=$count)"
            }
        } else {
            Write-TrackerLog "Cooldown active — alert skipped"
        }
    }
    return $candidates
}

# ════════════════════════════════════════════════════════════════════
# 8. Main
# ════════════════════════════════════════════════════════════════════
try { $Host.UI.RawUI.WindowTitle = 'Memory Reset — Claude Code & Antigravity' } catch {}

# Start runtime measurement
$script:startTime = Get-Date

# v1.4: -TrackActivity — background tracking 1-tick (no banner/UI, no kill). Task Scheduler invokes periodically.
#       Update CPU snapshot → derive cleanup candidates → send only a Telegram alert on threshold exceedance, then exit.
if ($TrackActivity) {
    Write-TrackerLog "=== TrackActivity tick ==="
    $cand = @(Invoke-ActivityTracking)
    Write-Host ("[tracker] reclaim candidates = {0}" -f $cand.Count) -ForegroundColor DarkGray
    exit 0
}

$runModes = @()
foreach ($m in @('DryRun','Diagnose','Deep','IncludeShell','OrphansOnly','Interactive','IdleOnly','IncludeDescendants')) {
    if ((Get-Variable -Name $m -ValueOnly)) { $runModes += $m }
}
if ($runModes.Count -eq 0) { $runModes = @('basic') }
Write-RunLog ("=== run start modes={0} admin={1} script={2}" -f ($runModes -join ','), (Test-IsAdmin), $PSCommandPath)

Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Memory Reset  —  Claude Code & Antigravity          ║" -ForegroundColor Cyan
Write-Host "║      (graceful kill + working-set + standby purge)       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun)   { Write-Host "[i] DRY-RUN mode — no actual termination/recovery" -ForegroundColor Magenta }
if ($Diagnose) { Write-Host "[i] DIAGNOSE mode — diagnostics only (read-only)" -ForegroundColor Magenta }
if ($Deep)     { Write-Host "[i] DEEP mode — Tier A (Memory Compression flush + System WS + network cache) added" -ForegroundColor Magenta }
if ($IncludeShell) { Write-Host "[!] SHELL restart mode — desktop briefly flickers (Tier B)" -ForegroundColor Yellow }
# v1.3+
if ($OrphansOnly)  { Write-Host "[i] ORPHANS-ONLY mode — only claude.exe / node.exe with dead parent IDE" -ForegroundColor Magenta }
if ($Interactive)  { Write-Host "[i] INTERACTIVE mode — choose PID to preserve before termination" -ForegroundColor Magenta }
if ($Interactive -and $DryRun) {
    Write-Host "[!] -DryRun + -Interactive combination — Interactive prompt is ignored in DryRun (no actual termination)" -ForegroundColor Yellow
}

# Diagnose mode outputs diagnostics only, then exits
if ($Diagnose) {
    Write-RunLog "diagnose: start"
    Show-MemoryDiagnostics
    Write-RunLog "diagnose: complete"
    if (-not $KeepAlive) {
        Write-Host ""
        Write-Host "[i] Press any key to close the window."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit 0
}

$before = Show-MemoryStatus -Label "Current memory status"

# v1.3: KeepPids parsing (CSV string → [uint32[]])
$excludePidsArray = ConvertFrom-KeepPidsString -Csv $KeepPids
if ($excludePidsArray.Count -gt 0) {
    Write-Host ""
    Write-Host (" [i] Preserved PID count ({0}): {1}" -f $excludePidsArray.Count, ($excludePidsArray -join ', ')) -ForegroundColor Cyan
    Write-RunLog ("keepPids: count={0} pids={1}" -f $excludePidsArray.Count, ($excludePidsArray -join ','))
}

Write-Host ""
Write-Host "── Processes to terminate ──" -ForegroundColor Cyan
if ($IncludeDescendants) { Write-Host "[i] INCLUDE-DESCENDANTS mode — also terminate descendant tree (conhost/bash/node/pwsh/python byproducts) of claude/Antigravity" -ForegroundColor Magenta }
$categorize = {
    param($p)
    if ($p.ExecutablePath -match '(?i)\\Programs\\Antigravity\\')                              { return 'Antigravity' }
    if ($p.ExecutablePath -match '(?i)\\\.antigravity\\extensions')                            { return 'Claude(Antigravity ext)' }
    if ($p.ExecutablePath -match '(?i)\\\.cursor\\extensions')                                 { return 'Claude(Cursor ext)' }
    if ($p.ExecutablePath -match '(?i)\\\.vscode\\extensions')                                 { return 'Claude(VS Code ext)' }
    if ($p.ExecutablePath -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code')        { return 'Claude(npm global)' }
    if ($p.ExecutablePath -match '(?i)\\Claude\\claude-code\\')                                { return 'Claude(standalone)' }
    if ($p.ExecutablePath -match '(?i)\\(@openai\\codex|OpenAI\\Codex)\\')                     { return 'Codex' }
    if ($p.Name -match '(?i)^node_repl\.exe$')                                                 { return 'Codex(runtime)' }
    if ($p.Name -eq 'node.exe')                                                                { return 'Claude(node)' }
    return 'Other(unknown)'
}
$targets = @(Get-TargetProcesses -ExcludePids $excludePidsArray -OnlyOrphans:$OrphansOnly -IncludeDescendants:$IncludeDescendants)
Write-RunLog ("targets: rawCount={0} includeDescendants={1} orphansOnly={2}" -f $targets.Count, [bool]$IncludeDescendants, [bool]$OrphansOnly)

# v1.4: -IdleOnly — only tracking based idle(idleMinutes+ inactivity) / orphan candidates are termination targets.
#       Active sessions use CPU within idleMinutes, so excluded from candidates → active preserved.
$idleCand = @()
if ($IdleOnly) {
    $idleSettings = Get-TrackerSettings
    $null = Update-ActivityState -Settings $idleSettings
    $idleCand = @(Get-ReclaimCandidates -Settings $idleSettings)
    $idlePids = @($idleCand | ForEach-Object { $_.ProcessId })
    $targets  = @($targets | Where-Object { $idlePids -contains $_.ProcessId })
    Write-RunLog ("targets: idleCandidates={0} filteredCount={1} idleMinutes={2} cpuThresholdPct={3}" -f $idleCand.Count, $targets.Count, $idleSettings.idleMinutes, $idleSettings.cpuThresholdPct)
    if ($idleCand.Count -eq 0) {
        Write-Host " [i] no idle/orphan candidates — tracking history must accumulate for idleMinutes or more for classification." -ForegroundColor DarkGray
        Write-Host "     (Check whether -TrackActivity runs via Task Scheduler and whether enough time has accumulated.)" -ForegroundColor DarkGray
    }
}

$reasonByPid = @{}
foreach ($c in $idleCand) { $reasonByPid[[int]$c.ProcessId] = $c }
Write-RunLog ("targets: finalCount={0}" -f $targets.Count)
foreach ($t in ($targets | Sort-Object ProcessId)) {
    $r = $reasonByPid[[int]$t.ProcessId]
    $reason = if ($r) { "idle=$($r.IsIdle) orphan=$($r.IsOrphan) idleMin=$($r.IdleMin)" } elseif ($IdleOnly) { "idleOnlyReason=missing" } else { "reason=selected" }
    $path = if ($t.ExecutablePath) { [string]$t.ExecutablePath } else { '<none>' }
    $path = $path -replace '[\r\n]', ' '
    $creation = if ($t.CreationDate) { ([datetime]$t.CreationDate).ToString('o') } else { '' }
    Write-RunLog ("target: pid={0} ppid={1} name={2} category={3} wsMB={4} creation={5} {6} path={7}" -f $t.ProcessId, $t.ParentProcessId, $t.Name, (& $categorize $t), ([math]::Round($t.WorkingSetSize / 1MB, 1)), $creation, $reason, $path)
}

if ($targets.Count -eq 0) {
    Write-Host " (No targets — only Standby List cleanup will run)" -ForegroundColor DarkGray
} else {
    $grouped = $targets | Group-Object { & $categorize $_ } | Sort-Object Name
    $grandTotal = 0
    foreach ($g in $grouped) {
        $catTotalMB = [math]::Round((($g.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        $grandTotal += $catTotalMB
        Write-Host ("`n  ▶ [{0}]  {1} items  /  {2:N1} MB" -f $g.Name, $g.Count, $catTotalMB) -ForegroundColor Yellow
        # Show details for first 3 only (PID/path), summarize the rest
        $shown = 0
        foreach ($p in ($g.Group | Sort-Object WorkingSetSize -Descending)) {
            if ($shown -lt 3) {
                $memMB = [math]::Round($p.WorkingSetSize / 1MB, 1)
                $path  = if ($p.ExecutablePath) { $p.ExecutablePath } else { '<No path>' }
                # Shorten path if too long
                if ($path.Length -gt 70) { $path = '...' + $path.Substring($path.Length - 67) }
                Write-Host ("     PID={0,-7} WS={1,7} MB  {2}" -f $p.ProcessId, $memMB, $path) -ForegroundColor DarkGray
                $shown++
            }
        }
        if ($g.Count -gt 3) {
            Write-Host ("     ... {0} more with same path" -f ($g.Count - 3)) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host (" ── Grand total: {0:N1} MB  ({1} processes)" -f $grandTotal, $targets.Count) -ForegroundColor Cyan

    # Verify that Claude Desktop app is preserved (for safety verification)
    $desktopApp = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
        Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
    if ($desktopApp) {
        $dCount = @($desktopApp).Count
        $dMB = [math]::Round((($desktopApp | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" ── Preserved (not terminated): Claude Desktop app {0} / {1:N1} MB" -f $dCount, $dMB) -ForegroundColor Green
    }
}

# v1.3: Interactive mode — select preserved PID before termination (-SkipConfirmation ignored — user input is key)
if ($Interactive -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    Write-Host "── [Interactive] Select PID to preserve ──" -ForegroundColor Cyan
    Write-Host "  Enter PID to keep from the list above, separated by commas. Empty input = terminate all (default)" -ForegroundColor DarkGray
    $userInput = Read-Host "  PID to preserve (example: 1234,5678)"
    $keepInteractive = ConvertFrom-KeepPidsString -Csv $userInput
    if ($keepInteractive.Count -gt 0) {
        $targets = @($targets | Where-Object { $keepInteractive -notcontains $_.ProcessId })
        Write-Host (" [i] Preserved: {0} PID — remaining termination targets: {1}" -f $keepInteractive.Count, $targets.Count) -ForegroundColor Green
        Write-RunLog ("interactive: preserved={0} remaining={1} pids={2}" -f $keepInteractive.Count, $targets.Count, ($keepInteractive -join ','))
        if ($targets.Count -eq 0) {
            Write-Host " [i] No processes to terminate. Only Standby List cleanup proceeds." -ForegroundColor DarkGray
        }
    } else {
        Write-Host " [i] No preserved PID — terminate all." -ForegroundColor DarkGray
        Write-RunLog "interactive: preserve none"
    }
}

if (-not $SkipConfirmation -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    $confirm = Read-Host "Terminate the processes above and perform memory recovery? [Y/n]"
    if ($confirm -match '^[nN]') {
        Write-Host "[i] Cancelled by user." -ForegroundColor DarkGray
        Write-RunLog "run cancelled by user"
        if (-not $KeepAlive) {
            Write-Host "[i] Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        exit 0
    }
}

Stop-TargetProcesses -Processes $targets -TimeoutSec $GracefulTimeoutSec -DryRun:$DryRun
Invoke-MemoryRecovery -DryRun:$DryRun

# v1.1: Optional steps
if ($Deep)         { Invoke-DeepRecovery -DryRun:$DryRun }
if ($IncludeShell) { Invoke-ShellRestart -DryRun:$DryRun }

$after = Show-MemoryStatus -Label "Memory status after recovery"

if (-not $DryRun) {
    $recovered = $after.FreeMB - $before.FreeMB
    $pctChange = $after.PctFree - $before.PctFree
    $sign = if ($recovered -ge 0) { '+' } else { '' }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host (" Recovered RAM: {0}{1:N0} MB   ({2}{3:N1}%p)" -f $sign, $recovered, $sign, $pctChange) -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # CSV recovery history record (v1.2+)
    $modeTag = if ($Deep -and $IncludeShell) { 'deep+shell' }
               elseif ($Deep)                { 'deep' }
               else                          { 'basic' }
    $elapsed = ((Get-Date) - $script:startTime).TotalSeconds
    Write-RecoveryLog `
        -Mode             $modeTag `
        -TotalMB          $before.TotalMB `
        -BeforeFreeMB     $before.FreeMB `
        -AfterFreeMB      $after.FreeMB `
        -BeforePctFree    $before.PctFree `
        -AfterPctFree     $after.PctFree `
        -ProcessesKilled  $targets.Count `
        -RuntimeSec       $elapsed
    Write-Host (" [i] Recovery history recorded: recovery-history.csv (run {0:N1} seconds)" -f $elapsed) -ForegroundColor DarkGray
    Write-RunLog ("recovery: mode={0} targets={1} beforeFreeMB={2} afterFreeMB={3} recoveredMB={4} elapsedSec={5:N1}" -f $modeTag, $targets.Count, $before.FreeMB, $after.FreeMB, $recovered, $elapsed)
    Write-RunLog "=== run complete ==="
} else {
    Write-RunLog ("dry-run complete targets={0}" -f $targets.Count)
    Write-RunLog "=== run complete ==="
}

if (-not $KeepAlive) {
    Write-Host ""
    Write-Host "[i] Complete. Press any key to close the window."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
