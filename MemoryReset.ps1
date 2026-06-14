#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Code 와 Antigravity 를 안전하게 종료하고 Windows RAM 을 회수합니다.

.DESCRIPTION
    Windows 는 종료된 프로세스의 메모리를 즉시 free list 로 반환하지 않고
    Standby List / File Cache 에 남기는 경향이 있어 가용량 회복이 더딥니다.
    이 스크립트는 다음 5단계로 회수율을 끌어올립니다.

      1) Claude Code / Antigravity 프로세스 graceful 종료 (CloseMainWindow)
      2) Timeout 후 잔존 프로세스 트리 강제 종료 (taskkill /T /F)
      3) 남은 모든 프로세스의 Working Set 비우기 (EmptyWorkingSet, PROCESS_SET_QUOTA)
      4) System File Cache 트림 (SetSystemFileCacheSize)
      5) Modified Page List flush → Standby List 정리 (NtSetSystemInformation)
         * flush 를 purge 직전에 호출하여 dirty 페이지까지 회수

.PARAMETER GracefulTimeoutSec
    CloseMainWindow 후 대기할 시간 (초). 기본 8초.

.PARAMETER DryRun
    실제 종료/회수 없이 대상 프로세스만 표시.

.PARAMETER SkipConfirmation
    Y/n 프롬프트를 건너뜁니다 (자동화/스케줄러용).

.PARAMETER KeepAlive
    완료 후 키 입력 대기 없이 즉시 종료.

.PARAMETER Deep
    [v1.1+] Tier A 추가 회수 — Memory Compression Store flush + System Working Set empty + 네트워크 캐시 정리.
    재부팅과의 차이를 좁히기 위한 안전한 추가 단계.

.PARAMETER IncludeShell
    [v1.1+] Tier B 추가 — Explorer.exe + Windows Search 서비스 재시작.
    데스크톱이 1~2초 깜빡이며 열린 탐색기 창이 닫힘. -Deep 와 함께 사용.

.PARAMETER Diagnose
    [v1.1+] 회수 없이 진단만 수행 — 메모리 리스트 분포, 압축 store, 상위 점유 프로세스 표시.
    [v1.3+] 좀비 분석 추가 — claude.exe 의 부모 IDE 생존 여부 분류.
    UAC 불필요.

.PARAMETER KeepPids
    [v1.3+] 종료 대상에서 제외할 PID (콤마 구분 문자열). 활성 세션 보존용.
    예: -KeepPids "1234,5678,9012"

.PARAMETER Interactive
    [v1.3+] 종료 전 PID 별 보존 선택 프롬프트 표시. -SkipConfirmation 무시 (사용자 입력이 핵심).

.PARAMETER OrphansOnly
    [v1.3+] 부모 IDE extension host 가 죽은 claude.exe / node.exe 만 대상 (안전 모드).
    활성 IDE 의 자식 프로세스는 절대 건드리지 않음.

.EXAMPLE
    .\MemoryReset.ps1                                     # 기본 회수
    .\MemoryReset.ps1 -DryRun                             # 사전 확인
    .\MemoryReset.ps1 -Diagnose                           # 메모리 분석 + 좀비 분석
    .\MemoryReset.ps1 -Deep                               # Tier A 추가
    .\MemoryReset.ps1 -Deep -IncludeShell                 # Tier A + B
    .\MemoryReset.ps1 -SkipConfirmation -KeepAlive        # 자동화
    .\MemoryReset.ps1 -OrphansOnly                        # [v1.3+] 좀비(부모 죽음) 만 정리
    .\MemoryReset.ps1 -Interactive                        # [v1.3+] PID 선택 종료
    .\MemoryReset.ps1 -KeepPids "1234,5678"               # [v1.3+] 명시 PID 보존
    .\MemoryReset.ps1 -OrphansOnly -SkipConfirmation      # [v1.3+] 자동 좀비 정리

.NOTES
    관리자 권한 항상 필요 (모든 모드). 미보유 시 자동 UAC 승격 시도.
    [v1.1.2 변경] DryRun / Diagnose 도 UAC 강제 — 보호 프로세스 정확 측정 + 보안 가시성.
    [v1.3.0 추가] -KeepPids / -Interactive / -OrphansOnly — 활성 세션 보존 + 좀비 선별 종료.
    [v1.3.0 추가] -Diagnose 에 좀비 분석 (부모 IDE 생존 여부 별 claude.exe 분류).
    [v1.3.0 추가] VS Code 확장 (.vscode\extensions) 화이트리스트 명시 — 분류 정확도 ↑.
#>

[CmdletBinding()]
param(
    [int]$GracefulTimeoutSec = 8,
    [switch]$DryRun,
    [switch]$SkipConfirmation,
    [switch]$KeepAlive,

    # v1.1 추가 ─────────────────────────────────────────────
    [switch]$Deep,           # Tier A: Memory Compression flush + System WS empty + 네트워크 캐시
    [switch]$IncludeShell,   # Tier B: Explorer.exe + Windows Search 재시작 (Deep 와 함께 사용)
    [switch]$Diagnose,       # 회수 전 메모리 분포 상세 표시

    # v1.3 추가 ─────────────────────────────────────────────
    # KeepPids: comma-separated string (e.g. "1234,5678") for safe round-trip across UAC elevation.
    # PowerShell auto-binds both "1234,5678" and 1234,5678 syntax → string is most robust.
    [string]$KeepPids = '',  # 종료 대상에서 제외할 PID (콤마 구분). 예: -KeepPids "1234,5678"
    [switch]$Interactive,    # 종료 전 PID 별 선택 프롬프트 (보존할 것 선택)
    [switch]$OrphansOnly,    # IDE extension host 가 죽은 claude.exe 만 대상 (안전 모드)

    # v1.4 추가 ─────────────────────────────────────────────
    [switch]$TrackActivity,  # 백그라운드 추적 1-tick: CPU 스냅샷 기록 + 임계초과 시 텔레그램 알림. 종료 안 함, UAC 불필요.
    [switch]$IdleOnly,       # idle(idleMinutes+ 무활동) / orphan 프로세스만 정리 대상 (활성 세션 보존)
    [switch]$IncludeDescendants  # 종료 대상 claude/Antigravity 의 자손 트리(conhost/bash/node/pwsh/python 등 부산물)도 함께 종료
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ════════════════════════════════════════════════════════════════════
# 0. [v1.3.0 보안] 입력 검증 — UAC 승격 전, 그 어떤 코드 실행보다 먼저.
#    -KeepPids 값은 UAC 라운드트립을 거쳐 elevated PowerShell 의 명령행에 들어감.
#    허용: 숫자 / 콤마 / space / tab 만. \s 전체 (\n,\r,\f,\v 포함) 는 명령행 parsing
#    혼동 위험 → 명시적 [\d, \t] 로 제한.
# ════════════════════════════════════════════════════════════════════
if ($KeepPids -and $KeepPids -notmatch '^[\d, \t]*$') {
    Write-Host "[X] -KeepPids 값에 허용되지 않는 문자 포함." -ForegroundColor Red
    Write-Host "    허용: 숫자 / 콤마 / space / tab 만. 예: -KeepPids `"1234,5678,9012`"" -ForegroundColor Yellow
    Write-Host ("    제공: '{0}'" -f ($KeepPids -replace '[\r\n]', '\n')) -ForegroundColor DarkGray
    exit 1
}

# ════════════════════════════════════════════════════════════════════
# 1. 관리자 권한 검사 + 자동 승격
# ════════════════════════════════════════════════════════════════════
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin) -and -not $TrackActivity) {
    # v1.4: -TrackActivity 는 read-only(CPU 스냅샷) + 알림만 → admin 불필요. 스케줄러가 5분마다
    #       무인 실행하므로 UAC 팝업이 뜨면 안 됨. 이 경우 승격을 건너뛰고 그대로 추적 수행.
    # v1.1.2: 사용자 요청에 따라 UAC 항상 강제 (DryRun / Diagnose 도 admin 권한 사용)
    # 이유:
    #   - Diagnose 가 "Memory Compression" 프로세스 enumerate / 다른 사용자 프로세스 조회 가능
    #   - DryRun 이 보호 프로세스의 정확한 메모리 측정 가능
    #   - 사용자가 매 실행 시 UAC 확인 (보안 가시성)
    Write-Host "[!] 관리자 권한이 필요합니다. UAC 승격을 시도합니다..." -ForegroundColor Yellow
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
        Write-Host "[X] 승격 실패: $_" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# IncludeShell 은 Deep 없이는 무의미 — 자동 활성화
if ($IncludeShell -and -not $Deep) {
    Write-Host "[i] -IncludeShell 단독 사용 — -Deep 도 자동 활성화" -ForegroundColor DarkGray
    $Deep = $true
}

# ════════════════════════════════════════════════════════════════════
# 2. Win32 API P/Invoke 정의
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

    // SYSTEM_MEMORY_LIST_COMMAND (Process Hacker / phnt 헤더 검증)
    public const int  SystemMemoryListInformation        = 80;
    public const int  MemoryEmptyWorkingSets             = 2;  // 모든 프로세스 working set 비우기 (NT 레벨)
    public const int  MemoryFlushModifiedList            = 3;  // dirty 페이지 → standby 로 flush (purge 전 호출 시 회수율 ↑)
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
# 3. NTSTATUS 친화적 디코딩
# ════════════════════════════════════════════════════════════════════
function Format-NTStatus {
    param([uint32]$Status)
    $name = switch ($Status) {
        0x00000000 { 'STATUS_SUCCESS' }
        0xC0000022 { 'STATUS_ACCESS_DENIED (관리자 권한 미승격?)' }
        0xC0000061 { 'STATUS_PRIVILEGE_NOT_HELD (SeProfileSingleProcessPrivilege 미보유)' }
        0xC0000005 { 'STATUS_ACCESS_VIOLATION' }
        0xC000000D { 'STATUS_INVALID_PARAMETER' }
        0xC0000002 { 'STATUS_NOT_IMPLEMENTED (이 Windows 버전에서 미지원)' }
        default    { 'UNKNOWN' }
    }
    '0x{0:X8} ({1})' -f $Status, $name
}

# ════════════════════════════════════════════════════════════════════
# 4. 메모리 상태 표시
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
    Write-Host (" 전체:   {0,8:N0} MB" -f $m.TotalMB)
    Write-Host (" 사용중: {0,8:N0} MB" -f $m.UsedMB)
    Write-Host (" 가용:   {0,8:N0} MB ({1}%)" -f $m.FreeMB, $m.PctFree) -ForegroundColor $color
    return $m
}

# ════════════════════════════════════════════════════════════════════
# 5.0. Orphan / Extension-host 판별 헬퍼 (v1.3+)
# ════════════════════════════════════════════════════════════════════
function Test-IsClaudeOrphan {
    # claude.exe / node.exe 의 부모 (IDE extension host 또는 셸 spawner) 가 살아있지 않으면 orphan.
    # Windows 는 부모 죽어도 자식 cascade 종료 안 함 → orphan 누적 → 메모리 누수의 핵심 원인.
    # PID 재사용 위험: 부모 PID 가 살아있어도 그 PID 가 legitimate spawner 가 아닌 다른 프로세스로 재할당된 경우 orphan.
    # v1.3 강화: 합법 spawner 화이트리스트에 cmd/pwsh/powershell/bash/wsl/explorer 추가 — node.exe 가
    #            npm script / 터미널 / cmd wrapper 로 떠 있는 정상 케이스를 orphan 으로 오분류하지 않도록.
    param($ClaudeProc, $AllProcs)
    $parent = $AllProcs | Where-Object { $_.ProcessId -eq $ClaudeProc.ParentProcessId } | Select-Object -First 1
    if (-not $parent) { return $true }
    return ($parent.Name -notmatch '(?i)^(Code|Antigravity|claude|cursor|windsurf|cmd|pwsh|powershell|bash|wsl|explorer|conhost)\.exe$')
}

function ConvertFrom-KeepPidsString {
    # "1234,5678,9012" → [uint32[]]
    # v1.3 강화: TryParse (overflow 방지) + invalid 경고 + array wrap (single-element unwrap 방지)
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
        Write-Host (" [!] -KeepPids 잘못된 항목 무시 ({0}개): {1}" -f $invalid.Count, ($invalid -join ', ')) -ForegroundColor Yellow
    }
    # ,$valid → PS 의 pipeline unwrap 방지 (단일 요소도 array 로 유지)
    return ,$valid
}

# ════════════════════════════════════════════════════════════════════
# 5. 대상 프로세스 식별
#    핵심 안전장치: Claude Desktop 앱은 절대 매칭 금지 (다중 설치 경로 블랙리스트).
#    오직 CLI / Antigravity 확장 / 표준 Node 패키지만 종료 대상.
#    v1.3: -ExcludePids 로 보존, -OnlyOrphans 로 좀비만 선별.
#    v1.4: -IncludeDescendants 로 종료 대상의 자손 트리(claude 가 띄운 부산물)까지 포함.
# ════════════════════════════════════════════════════════════════════
function Get-DescendantPids {
    # RootPids 의 모든 자손 PID 를 BFS 로 수집 (프로세스 트리 walk). 스냅샷($AllProcs) 기준.
    # claude/Antigravity 가 spawn 한 conhost/bash/node/pwsh/python 등 "부산물"을 식별하는 데 사용.
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
    # 호출측이 @() 로 감싸므로 단순 배열 반환 (,@() 이중 wrap 금지)
    return $result.ToArray()
}

function Get-TargetProcesses {
    # reason: 화이트리스트 매칭 + 블랙리스트 + filter 통합 — 30줄 초과 불가피.
    # 분리 시 매칭 규칙이 2곳에 흩어져 유지보수 비용 ↑.
    param(
        [uint32[]]$ExcludePids = @(),
        [switch]$OnlyOrphans,
        [switch]$IncludeDescendants
    )
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue

    # ── Claude Code CLI 식별 ──
    # 화이트리스트(설치 경로) 기반: 아래 위치에서 실행되는 claude.exe/node.exe 만 대상.
    #   1) %USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\         [v1.3+ anchored]
    #   2) %USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\              [v1.3+ anchored]
    #   3) %USERPROFILE%\.vscode\extensions\anthropic.claude-code-*\              [v1.3+ anchored]
    #   4) Claude\claude-code\<version>\claude.exe                                 (path contains)
    #   5) npm\node_modules\@anthropic-ai\claude-code\                             (npm global)
    #   6) node.exe with @anthropic-ai/claude-code in command line
    #   7) claude.exe with --output-format stream-json + known path                [v1.3+ AND-gated]
    # 명시적 블랙리스트: Claude Desktop 앱의 알려진 모든 설치 경로 → 절대 매칭 금지.
    # v1.3 보안: IDE 확장 경로는 %USERPROFILE% prefix 강제 — C:\evil\.vscode\... 위장 차단.
    $userHomeExt = @(
        (Join-Path $env:USERPROFILE '.antigravity\extensions\anthropic.claude-code-'),
        (Join-Path $env:USERPROFILE '.cursor\extensions\anthropic.claude-code-'),
        (Join-Path $env:USERPROFILE '.vscode\extensions\anthropic.claude-code-')
    )
    # 단독 신뢰 가능한 다른 위치 패턴 (anchored — path 의 substring 이 아니라 prefix/structural match)
    $knownPathRegex = '(?i)(\\Claude\\claude-code\\|\\npm\\node_modules\\@anthropic-ai\\claude-code\\)'

    $claude = $allProcs | Where-Object {
        $exe = if ($_.ExecutablePath) { $_.ExecutablePath } else { '' }
        $cmd = if ($_.CommandLine)    { $_.CommandLine }    else { '' }

        # 블랙리스트: Claude Desktop 앱은 무조건 제외 (MSIX / Squirrel / 직접설치 / OS-wide)
        if ($exe -match '(?i)\\WindowsApps\\Claude_')                                    { return $false }
        if ($exe -match '(?i)\\AnthropicClaude\\.*?\\Claude\.exe$' -and $cmd -notmatch '(?i)claude-code') { return $false }
        if ($exe -match '(?i)\\Programs\\claude-desktop\\.*?\\Claude\.exe$')             { return $false }
        if ($exe -match '(?i)\\Program Files\\Claude\\Claude\.exe$')                     { return $false }
        if ($exe -match '(?i)\\Program Files \(x86\)\\Claude\\Claude\.exe$')             { return $false }

        # 화이트리스트
        # (a) IDE 확장 경로 — %USERPROFILE% prefix anchored (case-insensitive StartsWith)
        $isUserExt = $false
        if ($exe) {
            foreach ($prefix in $userHomeExt) {
                if ($exe.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $isUserExt = $true; break }
            }
        }
        # (b) 다른 알려진 path pattern (npm global / standalone)
        $isKnownPath = ($exe -match $knownPathRegex)
        # (c) CLI 시그니처 인수 — 단독으로 신뢰 불가 (v1.3 보안). path 신호와 AND 결합.
        $hasCliSignature = ($cmd -match '(?i)--output-format\s+stream-json') -and ($isUserExt -or $isKnownPath)

        ($_.Name -match '(?i)^claude\.exe$' -and ($isUserExt -or $isKnownPath -or $hasCliSignature)) -or
        ($_.Name -eq 'node.exe' -and $cmd -match '(?i)@anthropic-ai[\\/]claude-code')
    }

    # ── Antigravity 식별 ──
    # 정확한 설치 경로: %LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe
    # ExecutablePath 기준이 가장 안전 (모든 helper/renderer 포함).
    $antigravity = $allProcs | Where-Object {
        ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') -or
        ($_.ExecutablePath -match '(?i)\\Google\\Antigravity\\') -or
        ($_.Name -match '(?i)^Antigravity(\.exe)?$' -and $_.ExecutablePath -match '(?i)Antigravity')
    }

    # 중복 제거 + 자기 자신(현재 PowerShell) 제외
    $self = $PID
    $merged = @($claude) + @($antigravity) |
        Where-Object { $_.ProcessId -ne $self } |
        Sort-Object ProcessId -Unique

    # v1.3: -ExcludePids — 사용자가 명시한 PID 는 종료 대상에서 제외 (활성 세션 보존)
    if ($ExcludePids.Count -gt 0) {
        $merged = $merged | Where-Object { $ExcludePids -notcontains $_.ProcessId }
    }

    # v1.3: -OnlyOrphans — IDE extension host 가 죽은 claude.exe/node.exe 만 남김.
    # Antigravity 본체 (.exe 자체) 는 IDE 자체이므로 orphan 개념 무관 → 안전을 위해 OnlyOrphans 모드에서 제외.
    if ($OnlyOrphans) {
        $merged = $merged | Where-Object {
            $_.Name -match '(?i)^(claude|node)\.exe$' -and (Test-IsClaudeOrphan -ClaudeProc $_ -AllProcs $allProcs)
        }
    }

    # v1.4: -IncludeDescendants — 종료 대상의 자손 트리(claude 가 spawn 한 conhost/bash/node/pwsh/python 등)를 추가.
    # self / ExcludePids 제외. KeepPids 로 보존된 claude 는 이미 $merged 에서 빠졌으므로 그 자손도 root 가 아니어서 자동 보존됨.
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
# 6. 프로세스 종료 (Graceful → Wait → Force tree-kill)
# ════════════════════════════════════════════════════════════════════
function Stop-TargetProcesses {
    param(
        [array]$Processes,
        [int]$TimeoutSec = 8,
        [switch]$DryRun
    )

    if ($Processes.Count -eq 0) {
        Write-Host "[i] 종료할 대상 프로세스가 없습니다." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "── [1/4] Graceful 종료 시도 (CloseMainWindow) ──" -ForegroundColor Cyan
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
                Write-Host "  ·   No window     → $tag (다음 단계에서 강제 종료)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host " [!] Graceful 실패: $tag — $_" -ForegroundColor Yellow
        }
    }

    if ($DryRun) { return }

    Write-Host ""
    Write-Host "── [2/4] ${TimeoutSec}초 대기 (저장/정리 시간 확보) ──" -ForegroundColor Cyan
    for ($i = $TimeoutSec; $i -gt 0; $i--) {
        Write-Host -NoNewline ("`r 남은 시간: {0,2} 초 " -f $i)
        Start-Sleep -Seconds 1
    }
    Write-Host "`r 대기 완료.            "

    Write-Host ""
    Write-Host "── [3/4] 잔존 프로세스 트리 강제 종료 (taskkill /T /F) ──" -ForegroundColor Cyan
    $survivors = $Processes | Where-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    }

    if ($survivors.Count -eq 0) {
        Write-Host " [OK] 모든 프로세스가 graceful 종료됨." -ForegroundColor Green
        return
    }

    foreach ($p in $survivors) {
        $tag = "$($p.Name) (PID=$($p.ProcessId))"
        $null = & taskkill.exe /F /T /PID $p.ProcessId 2>&1
        # 0=success, 128=process already gone (cascaded by parent kill) → both OK
        if ($LASTEXITCODE -eq 0) {
            Write-Host " [KILL] $tag" -ForegroundColor Yellow
        } elseif ($LASTEXITCODE -eq 128) {
            Write-Host " [GONE] $tag (이미 종료됨)" -ForegroundColor DarkGray
        } else {
            Write-Host " [X] taskkill 실패: $tag (exit=$LASTEXITCODE)" -ForegroundColor Red
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 7. 메모리 회수 (EmptyWorkingSet + FileCache + Flush + Purge)
# ════════════════════════════════════════════════════════════════════
function Invoke-MemoryRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [4/4] 메모리 회수 ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] EmptyWorkingSet / ClearFileSystemCache / PurgeStandbyList 호출 예정" -ForegroundColor DarkGray
        return
    }

    # 0) 필수 권한 사전 확인 (Standby Purge / FileCache 정리에 필요)
    $privReport = @{
        'SeProfileSingleProcessPrivilege' = [MemoryAPI]::EnablePrivilegeChecked('SeProfileSingleProcessPrivilege')
        'SeIncreaseQuotaPrivilege'        = [MemoryAPI]::EnablePrivilegeChecked('SeIncreaseQuotaPrivilege')
    }
    foreach ($k in $privReport.Keys) {
        $rc = $privReport[$k]
        $msg = switch ($rc) {
            0 { '[OK]   ' + $k }
            1 { '[!] OpenProcessToken 실패: ' + $k }
            2 { '[!] LookupPrivilegeValue 실패: ' + $k }
            3 { '[!] AdjustTokenPrivileges API 실패: ' + $k }
            4 { '[!] 권한 미보유 (NOT_ALL_ASSIGNED): ' + $k + ' — 관리자 권한이라도 SeProfileSingleProcess 가 없을 수 있음. 로컬 보안 정책 확인 필요.' }
        }
        $color = if ($rc -eq 0) { 'DarkGray' } else { 'Yellow' }
        Write-Host " · $msg" -ForegroundColor $color
    }

    # 6-1. 모든 프로세스 작업 집합 비우기 (PROCESS_SET_QUOTA 최소 권한)
    Write-Host -NoNewline " · 작업 집합 비우는 중 ..."
    $ok = 0; $fail = 0
    Get-Process | ForEach-Object {
        try {
            if ([MemoryAPI]::EmptyWorkingSetByPid([uint32]$_.Id)) { $ok++ } else { $fail++ }
        } catch { $fail++ }
    }
    Write-Host " [OK] 성공 $ok / 접근불가 $fail" -ForegroundColor Green

    # 6-2. 파일 시스템 캐시 트림
    Write-Host -NoNewline " · System File Cache 트림 ..."
    $r = [MemoryAPI]::ClearFileSystemCache()
    if ($r) { Write-Host " [OK]" -ForegroundColor Green }
    else    { Write-Host " [!] 실패 (Win32Error=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" -ForegroundColor Yellow }

    # 6-3. Modified Page List flush (dirty 페이지 → standby 로 이동, purge 직전에 호출)
    Write-Host -NoNewline " · Modified Page List flush ..."
    $rcFlush = [MemoryAPI]::FlushModifiedPageList()
    if ($rcFlush -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} (계속 진행)" -f (Format-NTStatus $rcFlush)) -ForegroundColor Yellow
    }

    # 6-4. Standby List 정리 (핵심 — 이 단계가 가장 큰 회수 효과)
    Write-Host -NoNewline " · Standby List 정리 ..."
    $rc = [MemoryAPI]::PurgeStandbyList($false)
    if ($rc -eq 0) {
        Write-Host " [OK] (전체 standby 정리)" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0} → 저우선만 재시도" -f (Format-NTStatus $rc)) -ForegroundColor Yellow
        $rc2 = [MemoryAPI]::PurgeStandbyList($true)
        if ($rc2 -eq 0) {
            Write-Host "   재시도 [OK] (저우선 standby 정리됨)" -ForegroundColor Green
        } else {
            Write-Host ("   재시도 실패 NTSTATUS={0}" -f (Format-NTStatus $rc2)) -ForegroundColor Red
            Write-Host "   원인 후보: 관리자 권한 미승격 / SeProfileSingleProcessPrivilege 미보유 (보안 정책 확인)" -ForegroundColor DarkYellow
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 6.4. 좀비 분석 — claude.exe 의 부모 (extension host) 생존 여부 분류 [v1.3+]
#      "확실한 좀비 (부모 죽음)" vs "활성 그룹 (부모 IDE alive)" 분리.
# ════════════════════════════════════════════════════════════════════
function Show-ZombieAnalysis {
    # reason: host 그루핑 + 분류 + 출력 + 요약이 한 UI 흐름 — 분리 시 출력 순서 깨짐.
    Write-Host ""
    Write-Host "── 좀비 분석 (Zombie Analysis) [v1.3+] ──" -ForegroundColor Cyan

    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $targets  = @(Get-TargetProcesses)   # v1.3 안전: pipeline unwrap 방지
    $claudes  = @($targets | Where-Object { $_.Name -match '(?i)^(claude|node)\.exe$' })

    if ($claudes.Count -eq 0) {
        Write-Host " (분석할 claude.exe / node.exe 프로세스 없음)" -ForegroundColor DarkGray
        return
    }

    # 부모 PID 별 그룹화 — 같은 extension host 에서 spawn 된 claude 들이 묶임
    $byHost = $claudes | Group-Object ParentProcessId | Sort-Object { [int]$_.Name }

    $orphans = @()
    foreach ($g in $byHost) {
        $hostPid  = $g.Name
        $hostProc = $allProcs | Where-Object { $_.ProcessId -eq [int]$hostPid } | Select-Object -First 1
        $totalMB  = [math]::Round((($g.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)

        if (-not $hostProc) {
            Write-Host (" [DEAD] 부모 PID {0,-6} — claude {1}개 / {2} MB → 전부 orphan" -f $hostPid, $g.Count, $totalMB) -ForegroundColor Red
            $orphans += $g.Group
        } elseif ($hostProc.Name -notmatch '(?i)^(Code|Antigravity|claude|cursor|windsurf|cmd|pwsh|powershell|bash|wsl|explorer|conhost)\.exe$') {
            Write-Host (" [REUSED] 부모 PID {0,-6} [{1}] PID 재사용 — claude {2}개 / {3} MB" -f $hostPid, $hostProc.Name, $g.Count, $totalMB) -ForegroundColor Red
            $orphans += $g.Group
        } else {
            Write-Host (" [OK]   부모 PID {0,-6} [{1}] — claude {2}개 / {3} MB" -f $hostPid, $hostProc.Name, $g.Count, $totalMB) -ForegroundColor Yellow
        }

        # 상위 3개 자식 PID/WS 표시
        $shown = 0
        foreach ($p in ($g.Group | Sort-Object WorkingSetSize -Descending)) {
            if ($shown -lt 3) {
                Write-Host ("     -> PID={0,-7} WS={1,7} MB" -f $p.ProcessId, [math]::Round($p.WorkingSetSize/1MB,1)) -ForegroundColor DarkGray
                $shown++
            }
        }
        if ($g.Count -gt 3) {
            Write-Host ("     -> ... 외 {0}개" -f ($g.Count - 3)) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    if ($orphans.Count -gt 0) {
        $orphanMB = [math]::Round((($orphans | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" [!] 확실한 좀비: {0}개 / {1} MB" -f $orphans.Count, $orphanMB) -ForegroundColor Red
        Write-Host "    → 안전 종료:  .\MemoryReset.ps1 -OrphansOnly" -ForegroundColor Yellow
    } else {
        Write-Host " [OK] 부모 죽은 orphan 없음 (모든 claude.exe 의 부모 IDE alive)" -ForegroundColor Green
        Write-Host "      → 활성 세션 수보다 claude.exe 가 많다면 IDE 내부 잉여:" -ForegroundColor DarkGray
        Write-Host '        .\MemoryReset.ps1 -Interactive          (PID 선택 종료)'         -ForegroundColor DarkGray
        Write-Host '        .\MemoryReset.ps1 -KeepPids "PID1,PID2" (보존할 PID 지정)'      -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════════════
# 6.5. -Diagnose: 회수 전 메모리 분포 상세 표시
# ════════════════════════════════════════════════════════════════════
function Show-MemoryDiagnostics {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║                메모리 진단 (Diagnostics)                  ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    # 1. PerfCounter 기반 메모리 리스트 분포
    Write-Host ""
    Write-Host "── 메모리 리스트 분포 ──" -ForegroundColor Cyan
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
        Write-Host " [!] PerfCounter 조회 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. Memory Compression Store
    Write-Host ""
    Write-Host "── Memory Compression Store ──" -ForegroundColor Cyan
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        Write-Host (" · MemoryCompression 활성화: {0}" -f $mm.MemoryCompression)
        $compProc = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
        if ($compProc) {
            $compMB = [math]::Round($compProc.WorkingSet64 / 1MB, 1)
            Write-Host (" · 'Memory Compression' 프로세스 사용량: {0,8:N1} MB" -f $compMB) -ForegroundColor Yellow
            Write-Host "   → -Deep 모드로 flush 가능"
        } else {
            # "Memory Compression" 은 보호된 시스템 프로세스 — 관리자 권한 없으면 enumerate 실패가 정상
            $hint = if (Test-IsAdmin) { '일부 Windows 빌드에서 숨겨진 시스템 프로세스' }
                    else              { '관리자 권한 필요 (현재 read-only 모드)' }
            Write-Host " · 'Memory Compression' 프로세스 직접 측정 불가 ($hint)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] MMAgent 조회 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3. 상위 점유 프로세스 Top 15 (working set 기준)
    Write-Host ""
    Write-Host "── 점유 상위 프로세스 Top 15 (Working Set 기준) ──" -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 |
        ForEach-Object {
            $wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
            $cmMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
            Write-Host (" · {0,-30} PID={1,-7} WS={2,8} MB  Commit={3,8} MB" -f $_.ProcessName, $_.Id, $wsMB, $cmMB)
        }

    # 4. 종료 대상 프로세스 카운트 (실제 회수 가능량 미리보기)
    Write-Host ""
    Write-Host "── 종료 대상 프로세스 (Claude/Antigravity) ──" -ForegroundColor Cyan
    $targets = @(Get-TargetProcesses)   # v1.3 안전: pipeline unwrap 방지
    if ($targets.Count -eq 0) {
        Write-Host " (없음)" -ForegroundColor DarkGray
    } else {
        $tWS = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" · 총 {0} 개 프로세스 / Working Set 합계 {1:N1} MB 회수 가능" -f $targets.Count, $tWS)
    }

    # 5. v1.3+: 좀비 분석 — 확실한 좀비(부모 죽음) vs 활성(부모 IDE alive) 분리
    Show-ZombieAnalysis

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  진단 완료. 회수를 진행하려면 -Diagnose 없이 재실행.       ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
}

# ════════════════════════════════════════════════════════════════════
# 7-A. Tier A: 깊은 회수 (-Deep)
#      Memory Compression Store flush + System Working Set + 네트워크 캐시
# ════════════════════════════════════════════════════════════════════
function Invoke-DeepRecovery {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep] Tier A — 추가 회수 ──" -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host " [DRY] MMAgent 재시작 / System WS / 네트워크 캐시 호출 예정" -ForegroundColor DarkGray
        return
    }

    # A1. Memory Compression Store flush
    #     원리: MemoryCompression 을 disable 했다가 다시 enable 하면 압축된 페이지가 해제됨
    #     주의 1: 압축 해제 시 일시적 메모리 spike → 가용 RAM < 1GB 면 skip (OOM 방지)
    #     주의 2: Disable 성공 후 Enable 실패 시 시스템에 압축 기능 영구 비활성화 → try/finally 필수
    Write-Host -NoNewline " · Memory Compression Store flush ..."
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        if (-not $mm.MemoryCompression) {
            Write-Host " [skip] 이미 비활성화 상태" -ForegroundColor DarkGray
        } else {
            # 안전 가드: 가용 메모리 1GB 미만이면 압축 해제 spike 위험
            $os = Get-CimInstance Win32_OperatingSystem
            $availMB = [math]::Round($os.FreePhysicalMemory / 1024)
            if ($availMB -lt 1024) {
                Write-Host (" [skip] 가용 RAM 부족 ({0} MB < 1024 MB) — 압축 해제 spike 위험" -f $availMB) -ForegroundColor Yellow
            } else {
                $disabled = $false
                try {
                    Disable-MMAgent -MemoryCompression -ErrorAction Stop
                    $disabled = $true
                    # Decompress 백그라운드 작업 대기 — GB 단위 store 면 짧을 수 있으나 1500ms 가 합리적 균형
                    Start-Sleep -Milliseconds 1500
                } finally {
                    # CRITICAL: Disable 후 어떤 일이 있어도 Enable 보장 (시스템 보호)
                    if ($disabled) {
                        try {
                            Enable-MMAgent -MemoryCompression -ErrorAction Stop
                            Write-Host " [OK] (압축 페이지 해제됨)" -ForegroundColor Green
                        } catch {
                            # 이중 실패 — 사용자에게 강력히 알림
                            Write-Host ""
                            Write-Host " [CRITICAL] MemoryCompression Re-Enable 실패!" -ForegroundColor Red
                            Write-Host "   수동 복구 필요: PowerShell 관리자 권한으로 'Enable-MMAgent -MemoryCompression' 실행" -ForegroundColor Red
                            Write-Host "   또는 PC 재부팅 시 자동 복구됨" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host " [!] 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # A2. System-wide Working Set empty (NT 레벨 일괄)
    #     6-1 의 per-process 루프(PROCESS_SET_QUOTA 권한 부족으로 보호 프로세스 skip 됨)를
    #     커널 모드에서 보완. RAMMap 의 "Empty Working Sets" 와 동일 동작.
    Write-Host -NoNewline " · System Working Set empty (NT) ..."
    $rcWs = [MemoryAPI]::InvokeMemoryListCommand([MemoryAPI]::MemoryEmptyWorkingSets)
    if ($rcWs -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host (" [!] NTSTATUS={0}" -f (Format-NTStatus $rcWs)) -ForegroundColor Yellow
    }

    # A3. 네트워크 캐시 정리 (DNS / NetBIOS / ARP)
    Write-Host -NoNewline " · DNS 캐시 ..."
    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host -NoNewline " · NetBIOS 캐시 ..."
    $null = & nbtstat.exe -R 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] nbtstat exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }

    Write-Host -NoNewline " · ARP 캐시 ..."
    $null = & netsh.exe interface ip delete arpcache 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [!] netsh exit=$LASTEXITCODE" -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-B. Tier B: 셸 재시작 (-IncludeShell)
#      Explorer.exe + Windows Search 재시작 — 200~500MB 추가 회수
#      주의: 데스크톱이 1~2초 깜빡임, 열린 탐색기 창 닫힘
# ════════════════════════════════════════════════════════════════════
function Invoke-ShellRestart {
    param([switch]$DryRun)

    Write-Host ""
    Write-Host "── [Deep+Shell] Tier B — 셸 재시작 ──" -ForegroundColor Cyan
    Write-Host "  ! 데스크톱이 잠시 깜빡이며 열린 탐색기 창이 닫힙니다." -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host " [DRY] explorer.exe + WSearch 재시작 예정" -ForegroundColor DarkGray
        return
    }

    # B1. Explorer.exe 재시작
    #     주의 1: 셸 확장이 많은 시스템은 재시작에 5초+ 소요됨 → 최대 15초 폴링
    #     주의 2: 관리자 PS 에서 Start-Process explorer 하면 explorer 가 elevated 컨텍스트로 시작되어
    #             일반 앱(드래그앤드롭, IME 등)이 권한 부족 겪을 수 있음.
    #             따라서 Windows 의 자동 셸 재시작(winlogon 이 user token 으로 시작)에만 의존.
    #             자동 재시작 실패 시 수동 시작 안 하고 사용자에게 가이드만 표시.
    Write-Host -NoNewline " · Explorer 재시작 ..."
    try {
        $explorers = Get-Process -Name explorer -ErrorAction SilentlyContinue
        $beforeMB = if ($explorers) { [math]::Round((($explorers | Measure-Object WorkingSet64 -Sum).Sum / 1MB), 1) } else { 0 }
        if ($explorers) {
            $explorers | Stop-Process -Force -ErrorAction Stop
        }

        # Windows 의 자동 셸 재시작 polling (최대 15초 대기)
        $restartedByWindows = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
                $restartedByWindows = $true
                break
            }
        }

        if ($restartedByWindows) {
            Write-Host (" [OK] Windows 자동 재시작 완료 (이전 사용량 {0} MB)" -f $beforeMB) -ForegroundColor Green
        } else {
            # 의도적으로 elevated explorer.exe 직접 실행하지 않음 (권한 컨텍스트 오염 방지).
            # 사용자에게 안전한 복구 방법 안내.
            Write-Host (" [!] Windows 가 자동 재시작 못함 (이전 사용량 {0} MB)" -f $beforeMB) -ForegroundColor Yellow
            Write-Host "   → Ctrl+Shift+Esc → 작업관리자 → 파일 → '새 작업 실행' → explorer 입력 (관리자 체크 해제)" -ForegroundColor DarkYellow
            Write-Host "   → 또는 로그오프/재로그인" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # B2. Windows Search 서비스 재시작
    Write-Host -NoNewline " · Windows Search 재시작 ..."
    try {
        $svc = Get-Service -Name WSearch -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Restart-Service -Name WSearch -Force -ErrorAction Stop
            Write-Host " [OK]" -ForegroundColor Green
        } else {
            Write-Host " [skip] 서비스가 실행 중이 아님 ($($svc.Status))" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host " [!] $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-C. CSV 회수 이력 로깅
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

    # 컬럼 의미 명확화:
    #   Used* = 사용 메모리 (메모리 사용량)
    #   Free* = 가용 메모리 (회수 후 늘어나는 값)
    #   FreedMB = 회수된 양 = UsedBefore - UsedAfter (= AfterFree - BeforeFree, 양수면 회수 성공)
    $usedBefore = $TotalMB - $BeforeFreeMB
    $usedAfter  = $TotalMB - $AfterFreeMB

    $row = [PSCustomObject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Mode             = $Mode
        TotalMB          = $TotalMB
        UsedBeforeMB     = $usedBefore
        UsedAfterMB      = $usedAfter
        FreedMB          = $usedBefore - $usedAfter      # 양수 = 회수 성공
        BeforeFreeMB     = $BeforeFreeMB
        AfterFreeMB      = $AfterFreeMB
        BeforePctFree    = $BeforePctFree
        AfterPctFree     = $AfterPctFree
        FreedPctP        = [math]::Round($AfterPctFree - $BeforePctFree, 2)  # 가용 % 증가폭 (+면 회수)
        ProcessesKilled  = $ProcessesKilled
        RuntimeSec       = [math]::Round($RuntimeSec, 1)
    }

    # CSV 파일 락 (Excel 등으로 열려 있는 경우) 대응 — 최대 3회 재시도 + fallback 파일
    $maxRetry = 3
    for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
        try {
            if ($isNew) {
                $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            } else {
                $row | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
            }
            return  # 성공
        } catch {
            if ($attempt -lt $maxRetry) {
                Start-Sleep -Milliseconds (300 * $attempt)  # 점진 backoff
            } else {
                # 최종 실패 — 일자별 fallback 파일에 append (동시초 충돌 방지)
                # Filename: recovery-history-fallback-YYYYMMDD.csv  → 같은 날 fallback 은 모두 한 파일에 누적
                Write-Host " [!] CSV 로그 기록 실패 (락 또는 권한): $($_.Exception.Message)" -ForegroundColor DarkYellow
                $fallbackName = 'recovery-history-fallback-' + (Get-Date -Format 'yyyyMMdd') + '.csv'
                $fallback = Join-Path (Split-Path $logPath -Parent) $fallbackName
                $fallbackIsNew = -not (Test-Path $fallback)
                # fallback 도 락 가능 — 짧은 재시도
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
                    Write-Host (" [i] 대체 파일에 기록: {0}" -f (Split-Path $fallback -Leaf)) -ForegroundColor DarkGray
                } else {
                    # 마지막 수단: 고유 GUID 파일명 (충돌 절대 회피, 재구성 시 합치면 됨)
                    $unique = Join-Path (Split-Path $logPath -Parent) ('recovery-history-emergency-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,4)) + '.csv')
                    try {
                        $row | Export-Csv -Path $unique -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
                        Write-Host (" [i] 비상 파일에 기록: {0}" -f (Split-Path $unique -Leaf)) -ForegroundColor DarkGray
                    } catch {
                        Write-Host " [!] 모든 기록 시도 실패 (CSV 로그 누락)" -ForegroundColor DarkYellow
                    }
                }
            }
        }
    }
}

# ════════════════════════════════════════════════════════════════════
# 7-Z. [v1.4.0] 활동 추적 + idle 판정 + 텔레그램 알림
#   백그라운드 추적(-TrackActivity): 타겟 프로세스의 CPU 스냅샷을 주기적으로 기록하여
#   "N분 연속 무활동"을 안전하게 판정. 활성 세션은 idleMinutes 안에 반드시 CPU 를 쓰므로
#   오탐(활성 세션 종료) 없이 버려진 세션만 식별. 이 모드는 절대 프로세스를 죽이지 않음 —
#   임계 초과 시 텔레그램으로 알림만 보내고, 실제 정리(kill)는 사용자가 수동 실행.
# ════════════════════════════════════════════════════════════════════
function Write-TrackerLog {
    param([string]$Message)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path (Join-Path $PSScriptRoot 'tracker.log') -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 로그 기록 실패는 의도적으로 무시 — 로깅이 추적/알림 자체를 막아선 안 됨.
    }
}

function ConvertTo-HashtableDeep {
    # ConvertFrom-Json (PSCustomObject) → 중첩 hashtable. PS 5.1 은 -AsHashtable 미지원이라 직접 변환.
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
    # $Target 에 없거나 null 인 키를 $Default 로 채움 (중첩 PSCustomObject 재귀). 설정 파일 누락 키 방어.
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
        Write-TrackerLog "tracker-settings.json 로드 실패 — 기본값 사용: $($_.Exception.Message)"
        return $defaults
    }
}

function Get-ActivityStatePath { Join-Path $PSScriptRoot 'activity-state.json' }
function Get-TrackerStatePath  { Join-Path $PSScriptRoot 'tracker-state.json' }

function Read-ActivityState {
    $path = Get-ActivityStatePath
    if (-not (Test-Path $path)) { return @{ version = 1; updatedAt = ''; processes = @{} } }
    try {
        $obj = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $h = ConvertTo-HashtableDeep $obj
        if ($null -eq $h)           { $h = @{} }
        if ($null -eq $h.processes) { $h.processes = @{} }
        return $h
    } catch {
        Write-TrackerLog "activity-state.json 로드 실패 — 새 상태로 시작: $($_.Exception.Message)"
        return @{ version = 1; updatedAt = ''; processes = @{} }
    }
}

function Write-ActivityState {
    param($State)
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -Path (Get-ActivityStatePath) -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-TrackerLog "activity-state.json 저장 실패: $($_.Exception.Message)"
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
    } catch { Write-TrackerLog "tracker-state.json 저장 실패: $($_.Exception.Message)" }
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
    # reason: 스냅샷 4분기(신규/기존갱신/PID재사용리셋/소멸제거)를 한 흐름에서 — 분리 시 state 일관성 깨짐.
    # 각 타겟의 CPU 누적초(Get-Process.CPU) delta 로 직전 간격 CPU 율을 계산, 임계 이상이면 lastActiveAt 갱신.
    param($Settings)
    $now    = Get-Date
    $nowIso = $now.ToString('o')
    $nCores = Get-LogicalCoreCount
    $state  = Read-ActivityState
    if ($null -eq $state.processes) { $state.processes = @{} }

    $targets = @(Get-TargetProcesses)
    $gp = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $gp[[int]$_.Id] = $_ }

    $seen = @{}
    foreach ($t in $targets) {
        $procId = [int]$t.ProcessId
        $seen["$procId"] = $true
        $proc     = $gp[$procId]
        $cpuSec   = if ($proc -and $null -ne $proc.CPU) { [double]$proc.CPU } else { $null }
        $creation = if ($t.CreationDate) { ([datetime]$t.CreationDate).ToString('o') } else { '' }
        $key      = "$procId"
        $entry    = $state.processes[$key]

        if ($entry -and $entry.creationDate -eq $creation) {
            # 동일 프로세스(PID+생성시각 일치) — CPU delta 로 활동 여부 판정
            if ($null -ne $cpuSec -and $null -ne $entry.lastCpuSec) {
                $lastSeen = ConvertTo-DateTimeSafe $entry.lastSeenAt
                $dSec = if ($lastSeen) { ($now - $lastSeen).TotalSeconds } else { 0 }
                if ($dSec -gt 0) {
                    $dCpu = $cpuSec - [double]$entry.lastCpuSec
                    if ($dCpu -lt 0) { $dCpu = 0 }
                    $ratePct = ($dCpu / $dSec / $nCores) * 100
                    $entry.lastCpuRatePct = [math]::Round($ratePct, 3)
                    if ($ratePct -ge [double]$Settings.cpuThresholdPct) { $entry.lastActiveAt = $nowIso }
                }
            }
            if ($null -ne $cpuSec) { $entry.lastCpuSec = $cpuSec }
            $entry.lastSeenAt = $nowIso
            $entry.name       = [string]$t.Name
            $entry.wsBytes    = [long]$t.WorkingSetSize
            $entry.ppid       = [int]$t.ParentProcessId
            $state.processes[$key] = $entry
        } else {
            # 신규 또는 PID 재사용(생성시각 불일치) → 이력 리셋, baseline 등록
            $state.processes[$key] = @{
                name           = [string]$t.Name
                creationDate   = $creation
                firstTrackedAt = $nowIso
                lastActiveAt   = $nowIso
                lastCpuSec     = $cpuSec
                lastCpuRatePct = $null
                lastSeenAt     = $nowIso
                wsBytes        = [long]$t.WorkingSetSize
                ppid           = [int]$t.ParentProcessId
            }
        }
    }

    # 소멸한 PID 제거 (Remove 중 컬렉션 수정 방지 위해 키 복사)
    foreach ($k in @($state.processes.Keys)) {
        if (-not $seen[$k]) { $state.processes.Remove($k) }
    }
    $state.updatedAt = $nowIso
    Write-ActivityState $state
    return $state
}

function Test-ProcessIdle {
    # 안전 판정: (1)추적 시작 후 idleMinutes 경과(관측충분) AND (2)마지막 활동 후 idleMinutes 경과
    #            AND (3)직전 간격 CPU 율 < 임계. 하나라도 불충족 → 보존(false). 활성 세션 오탐 방지.
    param($Entry, $Settings, $Now)
    if (-not $Entry) { return $false }
    $first  = ConvertTo-DateTimeSafe $Entry.firstTrackedAt
    $active = ConvertTo-DateTimeSafe $Entry.lastActiveAt
    if (-not $first -or -not $active) { return $false }
    $idleMin = [double]$Settings.idleMinutes
    if (($Now - $first).TotalMinutes  -lt $idleMin) { return $false }   # 관측 부족 → 보존
    if (($Now - $active).TotalMinutes -lt $idleMin) { return $false }   # 최근 활동 → 보존
    if ($null -ne $Entry.lastCpuRatePct -and [double]$Entry.lastCpuRatePct -ge [double]$Settings.cpuThresholdPct) { return $false }
    return $true
}

function Get-ReclaimCandidates {
    # idle(추적 기반 1시간+ 무활동) ∪ orphan(부모 IDE 죽음) 후보 목록(PSCustomObject[]).
    param($Settings)
    $now      = Get-Date
    $state    = Read-ActivityState
    $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $targets  = @(Get-TargetProcesses)
    $result   = @()
    foreach ($t in $targets) {
        $entry    = $state.processes["$([int]$t.ProcessId)"]
        $isIdle   = Test-ProcessIdle -Entry $entry -Settings $Settings -Now $now
        $isOrphan = ($t.Name -match '(?i)^(claude|node)\.exe$') -and (Test-IsClaudeOrphan -ClaudeProc $t -AllProcs $allProcs)
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
    # 호출측이 항상 @() 로 감싸므로 단순 반환 (,@() 이중 wrap 금지 — 중첩 배열 버그 유발)
    return $result
}

function Send-TelegramMessage {
    param([string]$Token, [string]$ChatId, [string]$Text)
    if (-not $Token -or -not $ChatId) {
        Write-TrackerLog "텔레그램 발송 생략 — token 또는 chatId 미설정"
        return $false
    }
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # JSON + UTF-8 bytes 로 전송 — 해시 -Body 는 PS 5.1 에서 한글/이모지를 ASCII 로 깨뜨림.
        $json  = @{ chat_id = $ChatId; text = $Text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/sendMessage" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 12 -ErrorAction Stop
        return $true
    } catch {
        Write-TrackerLog "텔레그램 발송 실패: $($_.Exception.Message)"
        return $false
    }
}

function Format-AlertMessage {
    param($Candidates, $MemMB, $RamPct, $Ram)
    $idleN   = @($Candidates | Where-Object { $_.IsIdle }).Count
    $orphanN = @($Candidates | Where-Object { $_.IsOrphan }).Count
    $lines = @()
    $lines += "🧹 <b>MemoryReset — 정리 후보 누적 알림</b>"
    $lines += ""
    $lines += "정리 후보: <b>$($Candidates.Count)개</b> / <b>$MemMB MB</b> (RAM 의 $RamPct%)"
    $lines += "· idle (idleMinutes+ 무활동, CPU 율&lt;임계): $idleN 개"
    $lines += "· 고아 (부모 IDE 죽음): $orphanN 개"
    $lines += "· 현재 가용 RAM: $($Ram.FreeMB) MB ($($Ram.PctFree)%)"
    $top = @($Candidates | Sort-Object WsMB -Descending | Select-Object -First 5)
    if ($top.Count -gt 0) {
        $lines += ""
        $lines += "<b>상위 점유</b>:"
        foreach ($p in $top) {
            $tag = if ($p.IsOrphan) { ' [orphan]' } elseif ($p.IsIdle) { ' [idle]' } else { '' }
            $lines += "  PID $($p.ProcessId)  $($p.Name)  $($p.WsMB)MB$tag"
        }
    }
    $lines += ""
    $lines += "미리보기: <code>Run-IdleDryRun.bat</code>"
    $lines += "수동 정리: <code>Run-IdleCleanup.bat</code>"
    return ($lines -join "`n")
}

function Invoke-ActivityTracking {
    # 백그라운드 추적 1-tick: 스냅샷 갱신 → 정리후보 산출 → 임계 초과 시 텔레그램 알림.
    # 절대 프로세스를 종료하지 않음(read-only + 알림 전용). 작업 스케줄러가 trackIntervalMin 간격으로 호출.
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
                Write-TrackerLog "텔레그램 알림 발송됨 (candidates=$count)"
            }
        } else {
            Write-TrackerLog "쿨다운 활성 — 알림 생략"
        }
    }
    return $candidates
}

# ════════════════════════════════════════════════════════════════════
# 8. Main
# ════════════════════════════════════════════════════════════════════
try { $Host.UI.RawUI.WindowTitle = 'Memory Reset — Claude Code & Antigravity' } catch {}

# 실행 시간 측정 시작
$script:startTime = Get-Date

# v1.4: -TrackActivity — 백그라운드 추적 1-tick (배너/UI 없이, kill 없이). 작업 스케줄러가 주기 호출.
#       CPU 스냅샷 갱신 → 정리후보 산출 → 임계 초과 시 텔레그램 알림만 보내고 종료.
if ($TrackActivity) {
    Write-TrackerLog "=== TrackActivity tick ==="
    $cand = @(Invoke-ActivityTracking)
    Write-Host ("[tracker] reclaim candidates = {0}" -f $cand.Count) -ForegroundColor DarkGray
    exit 0
}

Clear-Host
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      Memory Reset  —  Claude Code & Antigravity          ║" -ForegroundColor Cyan
Write-Host "║      (graceful kill + working-set + standby purge)       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($DryRun)   { Write-Host "[i] DRY-RUN 모드 — 실제 종료/회수 없음" -ForegroundColor Magenta }
if ($Diagnose) { Write-Host "[i] DIAGNOSE 모드 — 진단만 수행 (read-only)" -ForegroundColor Magenta }
if ($Deep)     { Write-Host "[i] DEEP 모드 — Tier A (Memory Compression flush + System WS + 네트워크 캐시) 추가" -ForegroundColor Magenta }
if ($IncludeShell) { Write-Host "[!] SHELL 재시작 모드 — 데스크톱이 잠시 깜빡입니다 (Tier B)" -ForegroundColor Yellow }
# v1.3+
if ($OrphansOnly)  { Write-Host "[i] ORPHANS-ONLY 모드 — 부모 IDE 죽은 claude.exe / node.exe 만 대상" -ForegroundColor Magenta }
if ($Interactive)  { Write-Host "[i] INTERACTIVE 모드 — 종료 전 PID 별 보존 선택" -ForegroundColor Magenta }
if ($Interactive -and $DryRun) {
    Write-Host "[!] -DryRun + -Interactive 조합 — Interactive 프롬프트는 DryRun 시 무시됩니다 (실제 종료 안 함)" -ForegroundColor Yellow
}

# Diagnose 모드는 진단만 출력하고 종료
if ($Diagnose) {
    Show-MemoryDiagnostics
    if (-not $KeepAlive) {
        Write-Host ""
        Write-Host "[i] 아무 키나 누르면 창이 닫힙니다."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit 0
}

$before = Show-MemoryStatus -Label "현재 메모리 상태"

# v1.3: KeepPids 파싱 (CSV 문자열 → [uint32[]])
$excludePidsArray = ConvertFrom-KeepPidsString -Csv $KeepPids
if ($excludePidsArray.Count -gt 0) {
    Write-Host ""
    Write-Host (" [i] 보존 PID ({0}개): {1}" -f $excludePidsArray.Count, ($excludePidsArray -join ', ')) -ForegroundColor Cyan
}

Write-Host ""
Write-Host "── 종료 대상 프로세스 ──" -ForegroundColor Cyan
if ($IncludeDescendants) { Write-Host "[i] INCLUDE-DESCENDANTS 모드 — claude/Antigravity 자손 트리(conhost/bash/node/pwsh/python 부산물)도 함께 종료" -ForegroundColor Magenta }
$targets = @(Get-TargetProcesses -ExcludePids $excludePidsArray -OnlyOrphans:$OrphansOnly -IncludeDescendants:$IncludeDescendants)

# v1.4: -IdleOnly — 추적 기반 idle(idleMinutes+ 무활동) / orphan 후보로만 종료 대상 한정.
#       활성 세션은 idleMinutes 안에 CPU 를 쓰므로 후보에서 제외됨 → 활성 보존.
if ($IdleOnly) {
    $idleSettings = Get-TrackerSettings
    $idleCand = @(Get-ReclaimCandidates -Settings $idleSettings)
    $idlePids = @($idleCand | ForEach-Object { $_.ProcessId })
    $targets  = @($targets | Where-Object { $idlePids -contains $_.ProcessId })
    if ($idleCand.Count -eq 0) {
        Write-Host " [i] idle/orphan 후보 없음 — 추적 이력이 idleMinutes 이상 누적되어야 판정됩니다." -ForegroundColor DarkGray
        Write-Host "     (스케줄러로 -TrackActivity 를 돌리고 있는지, 누적 시간이 충분한지 확인하세요.)" -ForegroundColor DarkGray
    }
}

if ($targets.Count -eq 0) {
    Write-Host " (대상 없음 — Standby List 정리만 수행됩니다)" -ForegroundColor DarkGray
} else {
    # 카테고리별 그룹: Antigravity / Claude Code CLI 분류
    $categorize = {
        param($p)
        if ($p.ExecutablePath -match '(?i)\\Programs\\Antigravity\\')                              { return 'Antigravity' }
        if ($p.ExecutablePath -match '(?i)\\\.antigravity\\extensions')                            { return 'Claude(Antigravity ext)' }
        if ($p.ExecutablePath -match '(?i)\\\.cursor\\extensions')                                 { return 'Claude(Cursor ext)' }
        if ($p.ExecutablePath -match '(?i)\\\.vscode\\extensions')                                 { return 'Claude(VS Code ext)' }
        if ($p.ExecutablePath -match '(?i)\\npm\\node_modules\\@anthropic-ai\\claude-code')        { return 'Claude(npm global)' }
        if ($p.ExecutablePath -match '(?i)\\Claude\\claude-code\\')                                { return 'Claude(standalone)' }
        if ($p.Name -eq 'node.exe')                                                                { return 'Claude(node)' }
        return '기타(unknown)'
    }

    $grouped = $targets | Group-Object { & $categorize $_ } | Sort-Object Name
    $grandTotal = 0
    foreach ($g in $grouped) {
        $catTotalMB = [math]::Round((($g.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        $grandTotal += $catTotalMB
        Write-Host ("`n  ▶ [{0}]  {1}개  /  {2:N1} MB" -f $g.Name, $g.Count, $catTotalMB) -ForegroundColor Yellow
        # 처음 3개만 상세 표시 (PID/경로), 나머지는 요약
        $shown = 0
        foreach ($p in ($g.Group | Sort-Object WorkingSetSize -Descending)) {
            if ($shown -lt 3) {
                $memMB = [math]::Round($p.WorkingSetSize / 1MB, 1)
                $path  = if ($p.ExecutablePath) { $p.ExecutablePath } else { '<경로없음>' }
                # 경로가 너무 길면 축약
                if ($path.Length -gt 70) { $path = '...' + $path.Substring($path.Length - 67) }
                Write-Host ("     PID={0,-7} WS={1,7} MB  {2}" -f $p.ProcessId, $memMB, $path) -ForegroundColor DarkGray
                $shown++
            }
        }
        if ($g.Count -gt 3) {
            Write-Host ("     ... 외 {0}개 동일 경로" -f ($g.Count - 3)) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Write-Host (" ── 총 합계: {0:N1} MB  ({1} 개 프로세스)" -f $grandTotal, $targets.Count) -ForegroundColor Cyan

    # Claude Desktop 앱이 보존되었는지 확인 표시 (안전성 검증용)
    $desktopApp = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
        Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
    if ($desktopApp) {
        $dCount = @($desktopApp).Count
        $dMB = [math]::Round((($desktopApp | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
        Write-Host (" ── 보존 (종료 안 함): Claude Desktop 앱 {0}개 / {1:N1} MB" -f $dCount, $dMB) -ForegroundColor Green
    }
}

# v1.3: Interactive 모드 — 종료 전 보존 PID 선택 (-SkipConfirmation 무시 — 사용자 입력이 핵심)
if ($Interactive -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    Write-Host "── [Interactive] 보존할 PID 선택 ──" -ForegroundColor Cyan
    Write-Host "  위 목록에서 살릴 PID 를 콤마로 입력. 빈 입력 = 전부 종료 (기본)" -ForegroundColor DarkGray
    $userInput = Read-Host "  보존할 PID (예: 1234,5678)"
    $keepInteractive = ConvertFrom-KeepPidsString -Csv $userInput
    if ($keepInteractive.Count -gt 0) {
        $targets = @($targets | Where-Object { $keepInteractive -notcontains $_.ProcessId })
        Write-Host (" [i] 보존: {0}개 PID — 남은 종료 대상: {1}개" -f $keepInteractive.Count, $targets.Count) -ForegroundColor Green
        if ($targets.Count -eq 0) {
            Write-Host " [i] 종료할 프로세스 없음. Standby List 정리만 진행." -ForegroundColor DarkGray
        }
    } else {
        Write-Host " [i] 보존 PID 없음 — 전부 종료 진행." -ForegroundColor DarkGray
    }
}

if (-not $SkipConfirmation -and -not $DryRun -and $targets.Count -gt 0) {
    Write-Host ""
    $confirm = Read-Host "위 프로세스를 종료하고 메모리 회수를 진행할까요? [Y/n]"
    if ($confirm -match '^[nN]') {
        Write-Host "[i] 사용자 취소." -ForegroundColor DarkGray
        if (-not $KeepAlive) {
            Write-Host "[i] 아무 키나 누르면 종료..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
        exit 0
    }
}

Stop-TargetProcesses -Processes $targets -TimeoutSec $GracefulTimeoutSec -DryRun:$DryRun
Invoke-MemoryRecovery -DryRun:$DryRun

# v1.1: 옵션 단계
if ($Deep)         { Invoke-DeepRecovery -DryRun:$DryRun }
if ($IncludeShell) { Invoke-ShellRestart -DryRun:$DryRun }

$after = Show-MemoryStatus -Label "회수 후 메모리 상태"

if (-not $DryRun) {
    $recovered = $after.FreeMB - $before.FreeMB
    $pctChange = $after.PctFree - $before.PctFree
    $sign = if ($recovered -ge 0) { '+' } else { '' }
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host (" 회수된 RAM: {0}{1:N0} MB   ({2}{3:N1}%p)" -f $sign, $recovered, $sign, $pctChange) -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

    # CSV 회수 이력 기록 (v1.2+)
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
    Write-Host (" [i] 회수 이력 기록: recovery-history.csv (실행 {0:N1} 초)" -f $elapsed) -ForegroundColor DarkGray
}

if (-not $KeepAlive) {
    Write-Host ""
    Write-Host "[i] 완료. 아무 키나 누르면 창이 닫힙니다."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
