# Initial development log — 2026-04-19

> This document is an internal log written during the initial development of MemoryReset v1.0.
> It records the motivation, design decisions, multi-stage review results, and verification matrix.

## Motivation

- **Issue**: memory bottleneck causing available RAM to drop to 3~5%
- **Cause**: Antigravity (VS Code fork) uses the Claude Code extension to spawn 12 sessions per phase → 100+ `claude.exe` processes run concurrently
- **Measured (at the time of work)**:
  - Claude CLI 67 (Antigravity extension path) → **31.6 GB**
  - Antigravity main application 32 → **6.6 GB**
  - Claude CLI standalone 1 instance → 0.5 GB
  - npm global CLI 1 instance → 0.7 GB
  - **Total 39.4 GB / 101 processes recoverable**
- **Existing solution limitation**: reboot → force-kill all work
- **Goal**: safely terminate **only** Claude Code + Antigravity and eliminate Windows recovery delay (Standby List / File Cache)

## Deliverables (`.\`)

| File | Role |
|------|------|
| `MemoryReset.ps1` | main script (573 lines, UTF-8 BOM, PowerShell 5.1+) |
| `Run.bat` | double click launcher (automatic UAC elevation) |
| `Run-DryRun.bat` | dry run launcher (no actual termination/recovery) |
| `Test-Patterns.ps1` | pattern verification only (no actual termination) |
| `README.md` | usage guide |
| `docs/2026-04-19-initial-development.md` | this work record |

## Design decisions

### 1. Format: single PowerShell script
- No installation/compilation needed, runs immediately on any Windows 10/11
- Can later evolve into a system tray GUI(C# WPF) (not pursued at this stage)

### 2. Recovery pipeline (5 stages)
```
[1] CloseMainWindow              ← graceful save opportunity (8-second wait)
[2] taskkill /T /F               ← remaining process tree force-kill
[3] EmptyWorkingSet              ← all processes working set → demote to standby
[4] SetSystemFileCacheSize(-1,-1)← system file cache trim
[5] FlushModifiedList → PurgeStandbyList ← dirty pages flush then standby recovery
```
**Key insight**: In step 5, call `MemoryFlushModifiedList` *immediately before* `PurgeStandbyList` → dirty pages move to standby and are recovered together, further improving recovery rate (Round 2 Codex review applied)

### 3. P/Invoke APIs
| DLL | Function | Purpose |
|-----|------|------|
| `psapi.dll` | `EmptyWorkingSet` | Empty process working set |
| `kernel32.dll` | `SetSystemFileCacheSize` | File cache trim |
| `kernel32.dll` | `OpenProcess` | Handle acquisition (PROCESS_SET_QUOTA alone is sufficient) |
| `ntdll.dll` | `NtSetSystemInformation` | Standby List cleanup (SystemMemoryListInformation=80) |
| `advapi32.dll` | `OpenProcessToken` / `LookupPrivilegeValue` / `AdjustTokenPrivileges` | Enable `SeProfileSingleProcessPrivilege` |

### 4. Claude Desktop preservation (safety critical)
The following coexist on user systems:
- **Claude Code CLI** (kill target): `\.antigravity\extensions\anthropic.claude-code-*\`, `\Claude\claude-code\`, `\npm\node_modules\@anthropic-ai\claude-code\`
- **Claude Desktop app** (preserved): `\WindowsApps\Claude_*\`, `\AnthropicClaude\app-*\`, `\Programs\claude-desktop\`, `\Program Files\Claude\`

→ Whitelist(installation paths) + explicit blacklist dual safeguard.
→ Measured verification: all Desktop app 9/9 PIDs accurately excluded from termination targets.

## Round 1 — Self review + live environment verification

### Issues found (4 cases, all fixed)

1. **CRITICAL: `^claude\.exe$` also matches Claude Desktop**
   → Whitelist (CLI installation paths) + blacklist (`\WindowsApps\Claude_`) introduced
2. **`AdjustTokenPrivileges` then `ERROR_NOT_ALL_ASSIGNED` not detected**
   → Split into `EnablePrivilegeChecked`, explicit `Marshal.GetLastWin32Error()` call + timing preserved in comments
3. **`Get-Process | .Handle` requires `PROCESS_ALL_ACCESS` → protected process failure**
   → Split into `EmptyWorkingSetByPid(uint pid)`, use `OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION)`
4. **`taskkill` exit 128 (already terminated) classified as failure**
   → Display separately as `[GONE]`, exclude from failure count

### Verification
- Run `Test-Patterns.ps1`: Claude Desktop **9/9 preserved**, own PID exclusion PASS
- Recoverable amount measured: **39.4 GB / 101 processes**

## Round 2 — Codex independent review + further improvements

### Codex review results
- **P0 (nonfunctional)**: 0 cases — core logic verified
- **P1 (correctness)**: 3 cases (all OK, some strengthened)
- **P2 (improvements)**: many — selectively applied

### Items verified against external sources (Process Hacker phnt headers / MSDN)
- `SystemMemoryListInformation = 80` (0x50) — exact
- `MemoryPurgeStandbyList = 4` — exact
- `EmptyWorkingSet` permission = `PROCESS_SET_QUOTA` + (`PROCESS_QUERY_INFORMATION` | `PROCESS_QUERY_LIMITED_INFORMATION`) — correct signature
- `SetSystemFileCacheSize((SIZE_T)-1, (SIZE_T)-1, 0)` — Windows 10 documented behavior
- `SeProfileSingleProcessPrivilege` is the required permission for Standby Purge — correctly pre-enabled

### Improvements applied (3 cases)

1. **Modified Page List Flush added** (largest recovery effect)
   - `MemoryFlushModifiedList = 3` enum added
   - `FlushModifiedPageList()` API added
   - Call **immediately before** Standby Purge in `Invoke-MemoryRecovery`
2. **NTSTATUS-friendly message mapping**
   - `Format-NTStatus` helper function added
   - `0xC0000022` → `STATUS_ACCESS_DENIED (administrator privileges not elevated?)` etc
3. **Claude Desktop blacklist strengthened**
   - `\Programs\claude-desktop\`, `\Program Files\Claude\Claude.exe$`, `\Program Files (x86)\Claude\Claude.exe$` added
   - Covers direct installation / Squirrel / 32-bit compatibility

### Deferred
- `MemoryEmptyWorkingSets = 2` (NT bulk call): overlaps with EmptyWorkingSet loop, effectiveness unverified
- Recovery history CSV logging: planned for the system tray GUI stage

## Operations guide (summary)

```cmd
:: General run (interactive confirmation)
.\Run.bat

:: Pre-check only
.\Run-DryRun.bat

:: Automation
powershell -File .\MemoryReset.ps1 -SkipConfirmation -KeepAlive
```

## Future improvements (optional)

- [ ] System tray GUI (C# WPF, NotifyIcon) — automatic available RAM threshold trigger
- [ ] Recovery history CSV logging + trends
- [ ] Option to preserve only specific sessions with a PID/title whitelist
- [ ] Task Scheduler integration (for example: auto-run every 30 minutes)
- [ ] Disable Antigravity extension itself → prevent respawn after termination (currently simple rerun recommended)

## Verification matrix

| Item | Result | Verification method |
|------|------|-----------|
| UTF-8 BOM | OK | verify bytes 0xEF 0xBB 0xBF |
| PowerShell 5.1 parse | error 0 | `[Parser]::ParseFile` |
| C# Add-Type compilation | OK | separate compilation attempt |
| Claude Desktop preservation | 9/9 PASS | measured — 0 included in termination targets |
| Exclude own PID | PASS | Test-Patterns.ps1 |
| Whitelist matching | 101 (39.4GB) | correctly classified across all 4 categories |
| Codex independent review P0 | 0 | external source verification by general-purpose agent |

## References

- [MS Docs — EmptyWorkingSet](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset)
- [MS Docs — SetSystemFileCacheSize](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-setsystemfilecachesize)
- [Process Hacker / System Informer phnt header](https://github.com/winsiderss/systeminformer/blob/master/phnt/include/ntexapi.h)
- [Geoff Chappell — SYSTEM_INFORMATION_CLASS](https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi/system_information_class.htm)
