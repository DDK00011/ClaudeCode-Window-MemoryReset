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
    No UAC required.

.EXAMPLE
    .\MemoryReset.ps1                                     # default recovery
    .\MemoryReset.ps1 -DryRun                             # precheck
    .\MemoryReset.ps1 -Diagnose                           # Memory analysis only
    .\MemoryReset.ps1 -Deep                               # Tier A addition
    .\MemoryReset.ps1 -Deep -IncludeShell                 # Tier A + B
    .\MemoryReset.ps1 -SkipConfirmation -KeepAlive        # automation

.NOTES
    Administrator privileges always required (all modes). Automatically attempts UAC elevation if unavailable.
    [v1.1.2 change] Force UAC also for DryRun / Diagnose — accurate measurement of protected processes + security visibility.
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
    [switch]$Diagnose        # Show detailed memory distribution before recovery
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ════════════════════════════════════════════════════════════════════
# 1. Administrator privileges check + automatic elevation
# ════════════════════════════════════════════════════════════════════
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
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
# 5. Identify target processes
#    Core safety guard: never match Claude Desktop app (blacklist for multiple install paths).
#    Only CLI / Antigravity extensions / standard Node packages are termination targets.
# ════════════════════════════════════════════════════════════════════
function Get-TargetProcesses {
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue

    # ── Identify Claude Code CLI ──
    # Whitelist(install paths) based: only target claude.exe/node.exe run from locations below.
    #   1) %USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\
    #   2) %USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\
    #   3) %APPDATA%\Claude\claude-code\<version>\claude.exe
    #   4) %APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe (npm global)
    #   5) node.exe with @anthropic-ai/claude-code in command line
    #   6) claude.exe with --output-format stream-json (CLI signature arg)
    # Explicit blacklist: all known install paths for Claude Desktop app → never match.
    $claude = $allProcs | Where-Object {
        $exe = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
        $cmd = if ($_.CommandLine)    { $_.CommandLine }    else { '' }

        # Blacklist: always exclude Claude Desktop app (MSIX / Squirrel / direct install / OS-wide)
        if ($exe -match '(?i)\\WindowsApps\\Claude_')                                    { return $false }
        if ($exe -match '(?i)\\AnthropicClaude\\.*?\\Claude\.exe$' -and $cmd -notmatch '(?i)claude-code') { return $false }
        if ($exe -match '(?i)\\Programs\\claude-desktop\\.*?\\Claude\.exe$')             { return $false }
        if ($exe -match '(?i)\\Program Files\\Claude\\Claude\.exe$')                     { return $false }
        if ($exe -match '(?i)\\Program Files \(x86\)\\Claude\\Claude\.exe$')             { return $false }

        # Whitelist: CLI path or signature argument
        ($_.Name -match '(?i)^claude\.exe$' -and (
            $exe -match '(?i)\\\.antigravity\\extensions\\anthropic\.claude-code-' -or
            $exe -match '(?i)\\\.cursor\\extensions\\anthropic\.claude-code-' -or
            $exe -match '(?i)\\Claude\\claude-code\\' -or
            $exe -match '(?i)\\claude-code\\.*?\\claude\.exe$' -or
            $exe -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code\\' -or
            $cmd -match '(?i)--output-format\s+stream-json'
        )) -or
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

    # Deduplicate + exclude self (current PowerShell)
    $self = $PID
    $merged = @($claude) + @($antigravity) |
        Where-Object { $_.ProcessId -ne $self } |
        Sort-Object ProcessId -Unique

    return $merged
}

# ════════════════════════════════════════════════════════════════════
# 6. Process termination (Graceful → Wait → Force tree-kill)
# ════════════════════════════════════════════════════════════════════
function Stop-TargetProcesses {
    param(
        [array]$Processes,
        [int]$TimeoutSec = 8,
        [switch]$DryRun
    )

    if ($Processes.Count -eq 0) {
        Write-Host "[i] No target processes to terminate." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "── [1/4] Attempt graceful exit (CloseMainWindow) ──" -ForegroundColor Cyan
    foreach ($p in $Processes) {
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        if ($DryRun) {
            Write-Host " [DRY] CloseMainWindow → $tag" -ForegroundColor DarkGray
            continue
        }

        try {
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                $null = $proc.CloseMainWindow()
                Write-Host " [OK] CloseMainWindow → $tag" -ForegroundColor Green
            } else {
                Write-Host "  ·   No window     → $tag (force terminate in next step)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host " [!] Graceful failed: $tag — $_" -ForegroundColor Yellow
        }
    }

    if ($DryRun) { return }

    Write-Host ""
    Write-Host "── [2/4] Wait ${TimeoutSec} seconds (allow time for saving/cleanup) ──" -ForegroundColor Cyan
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

    if ($survivors.Count -eq 0) {
        Write-Host " [OK] All processes completed a graceful exit." -ForegroundColor Green
        return
    }

    foreach ($p in $survivors) {
        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        $null = & taskkill.exe /F /T /PID $p.ProcessId 2>&1
        # 0=success, 128=process already gone (cascaded by parent kill) → both OK
        if ($LASTEXITCODE -eq 0) {
            Write-Host " [KILL] $tag" -ForegroundColor Yellow
        } elseif ($LASTEXITCODE -eq 128) {
            Write-Host " [GONE] $tag (already terminated)" -ForegroundColor DarkGray
        } else {
            Write-Host " [X] taskkill failed: $tag (exit=$LASTEXITCODE)" -ForegroundColor Red
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
    $targets = Get-TargetProcesses
    if ($targets.Count -eq 0) {
        Write-Host " (none)" -ForegroundColor DarkGray
    } else {
        $tWS = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" · Total {0} processes / Working Set total {1:N1} MB recoverable" -f $targets.Count, $tWS)
    }

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
        [int]$BeforeFreeMB,
        [int]$AfterFreeMB,
        [double]$BeforePctFree,
        [double]$AfterPctFree,
        [int]$ProcessesKilled,
        [double]$RuntimeSec
    )

    $logPath = Join-Path $PSScriptRoot 'recovery-history.csv'
    $isNew   = -not (Test-Path $logPath)

    $row = [PSCustomObject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = $Mode
        BeforeFreeMB     = $BeforeFreeMB
        AfterFreeMB      = $AfterFreeMB
        RecoveredMB      = $AfterFreeMB - $BeforeFreeMB
        BeforePctFree    = $BeforePctFree
        AfterPctFree     = $AfterPctFree
        RecoveredPctP    = [math]::Round($AfterPctFree - $BeforePctFree, 2)
        ProcessesKilled  = $ProcessesKilled
        RuntimeSec       = [math]::Round($RuntimeSec, 1)
    }

    try {
        if ($isNew) {
            $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
        } else {
            $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -Append
        }
    } catch {
        # Logging failures do not affect recovery itself — warn quietly only
        Write-Host " [!] Failed to write CSV log: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ════════════════════════════════════════════════════════════════════
# 8. Main
# ════════════════════════════════════════════════════════════════════
try { $Host.UI.RawUI.WindowTitle = 'Memory Reset — Claude Code & Antigravity' } catch {}

# Start runtime measurement
$script:startTime = Get-Date

Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Memory Reset  —  Claude Code & Antigravity          ║" -ForegroundColor Cyan
Write-Host "║      (graceful kill + working-set + standby purge)       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun)   { Write-Host "[i] DRY-RUN mode — no actual termination/recovery" -ForegroundColor Magenta }
if ($Diagnose) { Write-Host "[i] DIAGNOSE mode — diagnostics only (read-only)" -ForegroundColor Magenta }
if ($Deep)     { Write-Host "[i] DEEP mode — Tier A (Memory Compression flush + System WS + network cache) added" -ForegroundColor Magenta }
if ($IncludeShell) { Write-Host "[!] SHELL restart mode — desktop briefly flickers (Tier B)" -ForegroundColor Yellow }

# Diagnose mode outputs diagnostics only, then exits
if ($Diagnose) {
    Show-MemoryDiagnostics
    if (-not $KeepAlive) {
        Write-Host ""
        Write-Host "[i] Press any key to close the window."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit 0
}

$before = Show-MemoryStatus -Label "Current memory status"

Write-Host ""
Write-Host "── Processes to terminate ──" -ForegroundColor Cyan
$targets = Get-TargetProcesses
if ($targets.Count -eq 0) {
    Write-Host " (No targets — only Standby List cleanup will run)" -ForegroundColor DarkGray
} else {
    # Group by category: Antigravity / Claude Code CLI
    $categorize = {
        param($p)
        if ($p.ExecutablePath -match '(?i)\\Programs\\Antigravity\\')                              { return 'Antigravity' }
        if ($p.ExecutablePath -match '(?i)\\\.antigravity\\extensions')                            { return 'Claude(Antigravity ext)' }
        if ($p.ExecutablePath -match '(?i)\\\.cursor\\extensions')                                 { return 'Claude(Cursor ext)' }
        if ($p.ExecutablePath -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code')        { return 'Claude(npm global)' }
        if ($p.ExecutablePath -match '(?i)\\Claude\\claude-code\\')                                { return 'Claude(standalone)' }
        if ($p.Name -eq 'node.exe')                                                                { return 'Claude(node)' }
        return 'Other(unknown)'
    }

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

if (-not $SkipConfirmation -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    $confirm = Read-Host "Terminate the processes above and perform memory recovery? [Y/n]"
    if ($confirm -match '^[nN]') {
        Write-Host "[i] Cancelled by user." -ForegroundColor DarkGray
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
        -BeforeFreeMB     $before.FreeMB `
        -AfterFreeMB      $after.FreeMB `
        -BeforePctFree    $before.PctFree `
        -AfterPctFree     $after.PctFree `
        -ProcessesKilled  $targets.Count `
        -RuntimeSec       $elapsed
    Write-Host (" [i] Recovery history recorded: recovery-history.csv (run {0:N1} seconds)" -f $elapsed) -ForegroundColor DarkGray
}

if (-not $KeepAlive) {
    Write-Host ""
    Write-Host "[i] Complete. Press any key to close the window."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
