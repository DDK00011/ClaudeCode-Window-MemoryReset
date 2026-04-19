# MemoryReset

> A PowerShell script that recovers available Windows RAM **without rebooting**.
> Claude Code and Antigravity (Google's VS Code fork) safely clear multi-session usage.

---

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?logo=windows)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Status: stable](https://img.shields.io/badge/Status-stable-success)

## Real-world result

| Measurement point | Memory usage | Situation |
|-----------|---------------|------|
| Before running | **95%** | Antigravity 32 + Claude CLI 67 + helpers = 101 processes, ~39 GB in use |
| After running | **31%** | Antigravity and Claude CLI fully terminated + Standby/File Cache reclaimed |
| **Amount recovered** | **−64%p (~40 GB)** | Without rebooting, without affecting other apps (browser·messengers, etc.) |

> **Test environment**: Windows 10 LTSC 2021 (build 19044, based on 21H2) · DDR4 64 GB RAM
> **Runtime**: about 15 seconds (graceful 8 seconds + recovery 7 seconds)

---

## Why it is needed

- **Issue**: Antigravity lets 12 sessions spawn per phase, accumulating 100+ `claude.exe` processes → available RAM drops to 5% or less
- **Windows limitation**: Unlike Linux/macOS, it does not immediately return memory from terminated processes to the free list, keeping it in Standby List / File Cache → available memory recovers slowly
- **Drawback of existing solutions**: rebooting force-kills all tasks

## How it works (5-stage pipeline)

| Stage | Action | API |
|------|------|-----|
| 1 | Graceful exit of Claude CLI / Antigravity | `CloseMainWindow()` + wait |
| 2 | remaining process tree force-kill | `taskkill /F /T` |
| 3 | Empty Working Set of all processes | `EmptyWorkingSet` (psapi) |
| 4 | Trim System File Cache | `SetSystemFileCacheSize(-1, -1, 0)` |
| 5 | Modified Page List flush → Standby List cleanup | `NtSetSystemInformation` (ntdll) |

**Key**: Call `MemoryFlushModifiedList` in Stage 5 immediately before the standby purge → dirty pages move to standby and are then reclaimed together, further improving efficiency

## Safety

- **Claude Desktop app is never terminated** — preserved by a blacklist of multiple installation paths (`\WindowsApps\Claude_*`, `\AnthropicClaude\*\Claude.exe`, `\Programs\claude-desktop\*`, `\Program Files\Claude\Claude.exe`)
- **Self PID exclusion** — PID filter so the script does not kill itself
- **Graceful first** — give 8 seconds for a graceful exit before force kill
- **Dry-run mode** — preview which processes will be terminated with `Run-DryRun.bat`

## Quick start

```cmd
:: 1. Pre-check (no actual termination)
Run-DryRun.bat

:: 2. Main run (UAC prompt → approve)
Run.bat
```

Or directly in PowerShell:

```powershell
# Standard run
.\MemoryReset.ps1

# For automation/scheduler
.\MemoryReset.ps1 -SkipConfirmation -KeepAlive

# Options
.\MemoryReset.ps1 -GracefulTimeoutSec 12 -DryRun
```

| Option | Meaning | Default |
|------|------|--------|
| `-GracefulTimeoutSec <n>` | Wait after CloseMainWindow (seconds) | `8` |
| `-DryRun` | List targets only without termination/recovery (no UAC required) | off |
| `-SkipConfirmation` | Skip Y/n prompt | off |
| `-KeepAlive` | Exit immediately after completion without waiting for key input | off |

## Target identification rules

**Claude Code CLI** (only `claude.exe` or `node.exe` in the following paths):
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- `claude.exe` with the `--output-format stream-json` argument
- `node.exe` with `@anthropic-ai/claude-code` in the command line

**Antigravity** (all `*.exe` in the following paths):
- `%LOCALAPPDATA%\Programs\Antigravity\`
- `%LOCALAPPDATA%\Google\Antigravity\`
- → Electron GPU/Renderer/Utility helpers and language servers included automatically

**Never terminate** (Claude Desktop app):
- `\WindowsApps\Claude_*` (MSIX install)
- `\AnthropicClaude\app-*\Claude.exe` (Squirrel install)
- `\Programs\claude-desktop\*\Claude.exe` (direct install)
- `\Program Files\Claude\Claude.exe` (OS-wide install)

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (included with Windows)
- Administrator privileges (script automatically attempts UAC elevation)

## Troubleshooting

| Symptom | Cause / Fix |
|------|-------------|
| `NTSTATUS=0xC0000061` (Standby Purge) | Missing `SeProfileSingleProcessPrivilege` → check local security policy (`secpol.msc` → Local Policies → User Rights Assignment) |
| `NTSTATUS=0xC0000022` | Not elevated to administrator privileges → re-approve UAC |
| Low recovery amount | Other apps besides Antigravity / Claude Code are in use → check processes in use with `Run-DryRun.bat` |
| Garbled non-ASCII characters | Switch the console font to a Unicode font such as `Consolas` / `Cascadia Mono` |
| Script does not launch | File is blocked — right-click file → Properties → check "Unblock" |

## Future improvements (Roadmap)

- [ ] System tray GUI (C# WPF, NotifyIcon) — automatic available RAM threshold trigger
- [ ] recovery history CSV logging + trend chart
- [ ] Option to preserve only specific sessions with a PID/title whitelist
- [ ] Task Scheduler integration (for example: auto-run every 30 minutes)
- [ ] Message localization (i18n)

## Contribution / security reports

- Contribution guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Vulnerability report: [SECURITY.md](SECURITY.md)
- Development journal: [docs/2026-04-19-initial-development.md](docs/2026-04-19-initial-development.md)

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- API references verified against [MS Docs](https://learn.microsoft.com/en-us/windows/win32/api/), [Process Hacker / System Informer phnt headers](https://github.com/winsiderss/systeminformer/blob/master/phnt/include/ntexapi.h), and [Geoff Chappell's research](https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi/system_information_class.htm).
- Inspired by Sysinternals RAMMap's standby-list purge technique.

## Disclaimer

This script forcibly terminates processes and manipulates kernel memory lists. While extensively validated (zero false positives on Claude Desktop preservation across 9 PIDs in production environment), use at your own risk. **Always run `Run-DryRun.bat` first** to verify targets in your environment.
