# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
