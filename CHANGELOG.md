# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — 2026-04-19

GUI + observability — system tray daemon, threshold notifications, recovery history.

### Added — System tray daemon (`MemoryReset-Tray.ps1`)
- Always-on PowerShell daemon with `NotifyIcon` in the Windows notification area.
- Periodic memory polling (default 30s) with live tooltip updates ("Memory: 67% used (43/64 GB)").
- **Threshold notification (default 90%)**: shows a Windows BalloonTip when memory usage hits the threshold. Does NOT auto-recover — user retains full control. Cooldown 10 minutes between alerts.
- Right-click context menu: Basic recovery / Deep recovery / Maximum recovery (Deep+Shell) / Diagnostics / Dry run / Recovery history / Settings / Exit.
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
- Tray menu has "View recovery history (CSV)" — opens the file in the default CSV handler (Excel) or Notepad.

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
- README with reproducible reclamation result.

### Validated
- Real-world: 95% memory usage → 31% on Windows 10 LTSC 2021 (build 19044, 21H2) with DDR4 64 GB RAM, 101 target processes (~40 GB reclaimed). Run time ~15 seconds.
- Claude Desktop preservation: 9/9 PIDs preserved across all measured runs.
- API correctness verified against Process Hacker / System Informer phnt headers, MSDN, and Geoff Chappell's ntoskrnl reference.
