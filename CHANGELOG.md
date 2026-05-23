# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-05-23

Selective termination + zombie analysis — preserve active sessions, kill only what is dead or excess.

### Added — Selective termination
- **`-KeepPids "<csv>"`** — comma-separated PID list excluded from termination. Use when you want to preserve known-active Claude Code sessions and clean only the rest. Example: `MemoryReset.ps1 -KeepPids "1234,5678"`.
- **`-Interactive`** — after the kill-target list prints, prompts for "preserve which PIDs?" interactively. Overrides `-SkipConfirmation` (user input is the point). Empty input = kill all (current behavior).
- **`-OrphansOnly`** — kills only `claude.exe` / `node.exe` whose parent IDE extension host is dead (true zombies). Antigravity main processes are excluded from this mode by design (they ARE the IDE, not a child of one). Safest mode — never touches active sessions.

### Added — Zombie analysis (`-Diagnose` mode)
- New `Show-ZombieAnalysis` function groups `claude.exe` by `ParentProcessId` and classifies each parent as:
  - **`[OK]`** — parent is an alive IDE host (`Code.exe`, `Antigravity.exe`, `claude.exe`, `cursor.exe`, `windsurf.exe`)
  - **`[DEAD]`** — parent PID no longer exists → all children are confirmed orphans
  - **`[REUSED]`** — parent PID exists but the process is not an IDE host → PID was recycled, children are orphans
- Surfaces an exact "confirmed zombie count + MB" with a copy-paste-ready `-OrphansOnly` recommendation.
- When no orphans are found but `claude.exe` count exceeds active sessions, suggests `-Interactive` / `-KeepPids` for the IDE-internal-excess case.

### Added — VS Code extension path (explicit)
- Whitelist now includes `%USERPROFILE%\.vscode\extensions\anthropic.claude-code-*\` — previously matched only via the `--output-format stream-json` command-line signature, which categorized as "기타(unknown)".
- New category: `'Claude(VS Code ext)'` in the categorizer for clearer DryRun / Diagnose output.

### Changed
- `Get-TargetProcesses` signature: now accepts `-ExcludePids [uint32[]]` and `-OnlyOrphans [switch]`. Backward compatible — both parameters default to "no filter" so existing callers behave identically.
- UAC elevation argument forwarding (line ~88) now propagates `-KeepPids`, `-Interactive`, `-OrphansOnly` across the privilege boundary.

### Added — Helpers
- `Test-IsClaudeOrphan` — boolean test for "is this claude.exe an orphan?" considering both dead-parent and PID-reuse cases.
- `ConvertFrom-KeepPidsString` — robust CSV → `[uint32[]]` parser, tolerates whitespace and invalid entries silently.

### Why this release
Diagnosis on production user environment (DDR4 64 GB, simultaneous VS Code + Antigravity) revealed:
- claude.exe **本体** (300–400 MB each) is the dominant memory consumer, not the grandchild `node.exe` MCP servers (60 MB each).
- Active IDE chat tabs spawn claude.exe, but the IDE's extension host frequently fails to cascade-kill on tab-close (Windows `TerminateProcess` is non-recursive). Result: 4–7 orphan `claude.exe` accumulate per IDE within a normal work session.
- Existing v1.2.x killed everything — including active sessions the user wanted to keep. v1.3 adds the selective scalpel.

### Security hardening (Round 2 — independent agent review)
- **P0: `-KeepPids` command injection** — value flows through `Start-Process -Verb RunAs -ArgumentList` to re-elevate. Pre-v1.3.0-final, no input validation existed: `-KeepPids '1234"; Start-Process calc.exe; #'` could execute arbitrary code in the elevated PowerShell. Fix: regex whitelist `^[\d,\s]*$` enforced **before** any UAC elevation, at the very top of the script (line ~73). Reject + exit 1 on any non-digit/comma/space character.
- **P0: Whitelist path bypass** — `\\\.vscode\\extensions\\anthropic\.claude-code-` matched anywhere in the path, so `C:\evil\.vscode\extensions\anthropic.claude-code-fake\claude.exe` (user-writable!) was killable by admin. Fix: IDE extension paths now require `%USERPROFILE%` prefix via `String.StartsWith(..., OrdinalIgnoreCase)` — no substring matches. Spoofed `claude.exe` in user-writable locations outside `%USERPROFILE%\.{vscode,cursor,antigravity}\extensions\anthropic.claude-code-*\` cannot trigger an admin kill.
- **P0: CLI signature alone insufficient** — `--output-format stream-json` previously allowed killing any `claude.exe` regardless of path. Fix: signature is now AND-gated with path requirement (`isUserExt -or isKnownPath` must hold).
- **P1: `ConvertFrom-KeepPidsString` overflow & unwrap** — was using bare `[uint32]$t` cast (throws on overflow) and pipeline-style `Where-Object` (PowerShell unwraps single-element returns to scalar). Fix: `[uint32]::TryParse` for safe parsing + `,$valid` array-wrap + Yellow warning for invalid entries (user sees typos instead of silent drop).
- **P1: `Test-IsClaudeOrphan` over-aggressive orphan flag** — only IDE process names (Code/Antigravity/...) counted as legitimate parents. Legitimate `node.exe` spawned via `cmd.exe` / `pwsh.exe` / `bash.exe` (npm scripts, terminal-invoked CLI) was wrongly flagged orphan → could be killed under `-OrphansOnly`. Fix: parent whitelist extended to `cmd|pwsh|powershell|bash|wsl|explorer|conhost`.
- **P1: Null-safe `@()` wrapping** — `$targets = Get-TargetProcesses ...` called 3 times in the script; if the pipeline yielded zero results, `$targets.Count` worked on PS 5.1 but threw on strict-mode hosts. Now `@(Get-TargetProcesses ...)` everywhere.
- **P1: `-Interactive` + `-DryRun` silent skip warning** — combination silently bypassed the Interactive prompt (Read-Host inside `if (-not $DryRun)`). Now prints a Yellow `[!]` warning explaining the precedence.

### Known limitations (not fixed in v1.3.0 — future work)
- **Graceful-kill race window**: between `Get-CimInstance` enumeration and `taskkill /F /T`, 8 seconds elapse for graceful shutdown. A target PID could theoretically be freed and reassigned by the OS, causing `taskkill` to act on an unrelated process. Pre-existing risk (v1.0+), not introduced by v1.3. Mitigation: re-verify PID identity by process name + start-time before kill — deferred to v1.4.
- **Tray daemon does not currently expose v1.3 flags**: `-KeepPids` / `-Interactive` / `-OrphansOnly` are accessible only via CLI. Tray menu integration deferred to v1.4.

## [1.2.1] — 2026-04-19

Hardening patch — addresses Round 1 self-review and Round 2 independent agent review of the v1.2.0 tray daemon.

### Fixed (Round 1 — self-review)
- **P0: `MessageBox` called before `Add-Type`** — second tray instance would throw `TypeNotFound` instead of showing the friendly "already running" dialog. Moved assembly load to the very top.
- **`Global\` mutex** → `Local\` for user-session scope (avoids privilege issues; correct semantic for per-user singleton).
- **Reflection-based `OnTick` invocation** for immediate first tick was fragile across .NET versions. Replaced with a named `Invoke-MemoryTick` function called directly + bound to timer.
- **No debug log** — added `Write-TrayLog` (file-based, `tray-debug.log`) so silent timer failures are traceable.
- **Left-click `ShowContextMenu` reflection** now has a fallback to `ContextMenuStrip.Show(Cursor.Position)` when reflection fails.
- **CSV file lock** (Excel etc.) — added 3-attempt retry with progressive backoff and a daily-rolling fallback file (`recovery-history-fallback-YYYYMMDD.csv`). Prevents history loss when the main file is locked.

### Fixed (Round 2 — independent agent review)
- **STA threading**: `Tray.bat` now passes `-Sta` to `powershell.exe`. PS 5.1 default is MTA but WinForms / NotifyIcon / InputBox require STA — caused intermittent hang risk on certain dialogs. ([MS Docs - STA](https://learn.microsoft.com/en-us/dotnet/api/system.stathreadattribute))
- **CSV column name confusion**: previous `RecoveredMB` was technically correct (Free delta) but ambiguous against the natural reading "amount of memory recovered" (= Used reduction). Schema renamed/expanded:
  - Added `TotalMB`, `UsedBeforeMB`, `UsedAfterMB`, `FreedMB` (= UsedBefore − UsedAfter, positive = success)
  - Renamed `RecoveredPctP` → `FreedPctP`
- **Fallback CSV same-second collision**: previous fallback used `yyyyMMdd-HHmmss` and `Export-Csv` without `-Append` — two simultaneous fallbacks could overwrite each other. Now: daily-rolling fallback file with `-Append`, plus an "emergency" file with milliseconds + GUID fragment as last resort. Zero collision risk.

### Improved — Test-Patterns.ps1
- Added 12 new smoke tests for v1.2 / v1.2.1 (Tray Add-Type ordering, mutex scope, Tick separation, debug log, CSV lock guards, STA flag, CSV schema, fallback collision avoidance, .gitignore privacy).
- Total: 26 PASS / 0 FAIL / 0 WARN on user's environment.

### Privacy
- `.gitignore` strengthened to block all `*.csv`, `tray-settings.json`, `tray-state.json`, `*.log`, `*.json.bak`, and broader credential patterns. Personal recovery history will not be committed.

## [1.2.0] — 2026-04-19

GUI + observability — system tray daemon, threshold notifications, recovery history.

### Added — System tray daemon (`MemoryReset-Tray.ps1`)
- Always-on PowerShell daemon with `NotifyIcon` in the Windows notification area.
- Periodic memory polling (default 30s) with live tooltip updates ("Memory: 67% used (43/64 GB)").
- **Threshold notification (default 90%)**: shows a Windows BalloonTip when memory usage hits the threshold. Does NOT auto-recover — user retains full control. Cooldown 10 minutes between alerts.
- Right-click context menu: 기본 회수 / 깊은 회수 / 최대 회수 (Deep+Shell) / 진단 / 드라이런 / 회수 이력 / 설정 / 종료.
- All recovery actions delegate to `MemoryReset.ps1` so UAC elevation flows through the same path.
- Single-instance protection via global mutex (no duplicate trays).
- Settings persisted to `tray-settings.json` (threshold, polling interval, cooldown).
- **Tray daemon itself runs without admin** — only the recovery action triggers UAC.

### Added — Auto-start
- `Tray-AutoStart.ps1` toggles registration in the Windows user Startup folder. No admin needed.
- `Tray-AutoStart-Register.bat` / `Tray-AutoStart-Unregister.bat` double-click helpers.

### Added — CSV recovery history (`recovery-history.csv`)
- Every recovery run appends a row: Timestamp, Mode (basic/deep/deep+shell), Before/After Free MB, Recovered MB, Before/After % Free, Processes Killed, Runtime Sec.
- File created automatically on first run, in the same folder as the script.
- Tray menu has "회수 이력 보기 (CSV)" — opens the file in the default CSV handler (Excel) or Notepad.

### Added — Launchers
- `Tray.bat` — starts the tray daemon hidden (no console window).

### Notes
- Tray icon uses `System.Drawing.SystemIcons::Information` (Windows built-in). Future v1.3 may add custom icon.
- BalloonTip is Windows 7+ compatible; Windows 10+ shows it as a native Action Center toast.
- Notification is **observation only** — per user requirement, no auto-reboot or auto-recovery (work loss risk too high).

## [1.1.2] — 2026-04-19

### Changed
- **UAC always required** (per user request): `-DryRun` and `-Diagnose` no longer skip UAC elevation. Rationale:
  - `-Diagnose` can now enumerate the "Memory Compression" minimal process and inspect protected processes
  - `-DryRun` measures protected process memory accurately
  - Consistent UAC visibility on every run (security awareness)
- The auto-elevation block now forwards `-DryRun` and `-Diagnose` flags as well.

## [1.1.1] — 2026-04-19

Hardening patch — addresses safety issues found in Round 1 self-review and Round 2 independent agent review.

### Fixed
- **MMAgent re-enable guarantee** (`Invoke-DeepRecovery`): wrap `Disable-MMAgent` → `Enable-MMAgent` in `try/finally` so the system never ends up with Memory Compression permanently disabled on script crash. On dual failure, prints a `[CRITICAL]` recovery instruction instead of leaving the user with a degraded system.
- **OOM safety guard for Memory Compression flush**: skips A1 when available RAM < 1024 MB. Decompressing the compression store can transiently spike memory; this prevents pushing a near-full system over the edge.
- **Explorer restart elevation hazard**: previously, when the script ran elevated and Windows failed to auto-restart Explorer, the script launched `explorer.exe` itself — but that started Explorer with the elevated token, breaking drag-and-drop / IME / shell extensions for normal apps. Now: extends Windows auto-restart polling to 15s and, on failure, displays user-actionable recovery steps (Task Manager → New Task → uncheck admin) instead of starting Explorer in the wrong context.
- **MMAgent decompression wait**: bumped from 800ms to 1500ms to better cover GB-scale compression stores.

### Improved
- `Show-MemoryDiagnostics` Memory Compression message: now distinguishes between "admin needed" and "Windows build hides it" cases.
- `Invoke-DeepRecovery` comment on NT command 2 now explains *why* it complements the per-process loop (covers protected processes that PROCESS_SET_QUOTA cannot open).
- `Test-Patterns.ps1` now includes smoke tests for v1.1 functions, parameters, and the v1.1.1 safety guards (try/finally, OOM guard, polling loop, elevation guard, decompression wait).

### Notes
- All changes are internal hardening; CLI surface (flags, launchers) is unchanged from 1.1.0.

## [1.1.0] — 2026-04-19

Closing the gap with reboot — additional reclamation tiers for stale caches.

### Added
- **`-Deep` flag (Tier A)**: Memory Compression Store flush (via MMAgent toggle) + System-wide Working Set empty (NT-level, command 2) + DNS / NetBIOS / ARP cache flush. Closes the largest practical gap with a fresh reboot.
- **`-IncludeShell` flag (Tier B)**: Restarts `explorer.exe` and the Windows Search service. Reclaims 200~500 MB of accumulated shell/indexer caches. Auto-implies `-Deep`.
- **`-Diagnose` flag**: Read-only memory analysis — perf counter breakdown (Standby Cache by priority, Modified Page List, Free & Zero, Cache), Memory Compression Store status, top 15 processes by working set + commit charge, and target process preview. UAC not required.
- New launchers: `Run-Deep.bat`, `Run-Diagnose.bat`.
- SYNOPSIS now documents the new flags with usage examples.

### Notes
- `-Deep` is safe and recommended. The Memory Compression flush briefly spikes RAM during decompression but happens *after* the standby purge so headroom is available.
- `-IncludeShell` causes a 1~2 second desktop flicker. Open Explorer windows close. Avoid during a presentation.
- Display adapter reset (Tier C in design notes) is intentionally NOT shipped — too risky for users running games / video / streaming. Use `Win+Ctrl+Shift+B` keyboard shortcut manually if needed.

## [1.0.0] — 2026-04-19

Initial public release.

### Added
- 5-stage memory reclamation pipeline: graceful close → force kill → empty working set → file cache trim → flush + standby purge.
- Win32 P/Invoke wrappers for `EmptyWorkingSet`, `SetSystemFileCacheSize`, `NtSetSystemInformation`, and the privilege-token APIs.
- Auto-elevation via UAC (skipped for `-DryRun` mode since it has no destructive operations).
- Multi-path Claude Desktop blacklist preserving the user's standalone Claude app across MSIX, Squirrel, direct-install, and OS-wide installations.
- Whitelist-based Claude CLI detection: Antigravity extension, Cursor extension, npm global, standalone, and the `--output-format stream-json` argument signature.
- Antigravity main + helper detection via `%LOCALAPPDATA%\Programs\Antigravity\` install path.
- Friendly NTSTATUS decoder for common error codes (`STATUS_PRIVILEGE_NOT_HELD`, `STATUS_ACCESS_DENIED`, etc.).
- `taskkill` exit code 128 (process already gone) treated as success rather than failure.
- `Test-Patterns.ps1` for pattern verification without termination.
- `Run.bat` / `Run-DryRun.bat` double-click launchers.
- Dual-language README (Korean + English) with reproducible reclamation result.

### Validated
- Real-world: 95% memory usage → 31% on Windows 10 LTSC 2021 (build 19044, 21H2) with DDR4 64 GB RAM, 101 target processes (~40 GB reclaimed). Run time ~15 seconds.
- Claude Desktop preservation: 9/9 PIDs preserved across all measured runs.
- API correctness verified against Process Hacker / System Informer phnt headers, MSDN, and Geoff Chappell's ntoskrnl reference.
