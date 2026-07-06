# MemoryReset

> A PowerShell script that recovers available Windows RAM **without rebooting**.
> Safely clears remaining memory usage from Claude Code / Codex task processes that GUI IDEs such as Antigravity / VS Code launch through extensions·terminals.

---

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?logo=windows)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Status: stable](https://img.shields.io/badge/Status-stable-success)

## Real-world result

| Measurement point | Memory usage | Situation |
|-----------|---------------|------|
| Before running | **95%** | Claude/Codex CLI + helpers = 100+ processes, ~39 GB used |
| After running | **31%** | Completed CLI task processes terminated + Standby/File Cache recovered |
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
| 1 | Claude/Codex CLI graceful exit | `CloseMainWindow()` + wait |
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

:: 3. Deep recovery [v1.1+] — Memory Compression flush + System WS + network cache
Run-Deep.bat

:: Diagnostics only [v1.1+] — view memory distribution/top memory-consuming processes
Run-Diagnose.bat

:: Start system tray daemon [v1.2+] — stay in system tray, alert at 90%
Tray.bat

:: Register system tray auto-start at Windows boot (no UAC required)
Tray-AutoStart-Register.bat
```

Or directly in PowerShell:

```powershell
# Standard run
.\MemoryReset.ps1

# Deep recovery — minimize gap with reboot
.\MemoryReset.ps1 -Deep

# Maximum recovery — Tier A + shell restart (desktop flickers for 1~2 seconds)
.\MemoryReset.ps1 -Deep -IncludeShell

# For automation/scheduler
.\MemoryReset.ps1 -Deep -SkipConfirmation -KeepAlive

# Diagnostics only
.\MemoryReset.ps1 -Diagnose
```

| Option | Meaning | Default |
|------|------|--------|
| `-GracefulTimeoutSec <n>` | Wait after CloseMainWindow (seconds) | `8` |
| `-DryRun` | List targets only without termination/recovery (no UAC required) | off |
| `-Deep` | **[v1.1+]** Memory Compression flush + System WS empty + DNS/NetBIOS/ARP cache | off |
| `-IncludeShell` | **[v1.1+]** Explorer + Windows Search restart (`-Deep` automatically enabled) | off |
| `-Diagnose` | **[v1.1+]** Memory distribution diagnostics only (no UAC required) | off |
| `-SkipConfirmation` | Skip Y/n prompt | off |
| `-KeepAlive` | Exit immediately after completion without waiting for key input | off |

### Recommended scenarios by mode

| Situation | Recommended command |
|------|-----------|
| Routine memory recovery | `Run.bat` |
| Cleanup cumulative caches on a PC left running for days | `Run-Deep.bat` |
| When you want a near-reboot experience | `MemoryReset.ps1 -Deep -IncludeShell` |
| See what is occupying memory before recovery | `Run-Diagnose.bat` |
| Preview only which processes will be terminated | `Run-DryRun.bat` |

> **Note**: Memory Compression Store and Standby List can accumulate several GB on a PC that has been running for days. `-Deep` flushes both to narrow the gap with a reboot. However, kernel pool / GPU driver / page file area leaks fundamentally require a reboot (1 per week recommended).

## Target identification rules

**Claude Code CLI** (only `claude.exe` or `node.exe` in the following paths):
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- `claude.exe` with the `--output-format stream-json` argument
- `node.exe` with `@anthropic-ai/claude-code` in the command line

**Never terminate** (GUI apps):
- `Antigravity.exe` and GUI helper under `%LOCALAPPDATA%\Programs\Antigravity\` / `%LOCALAPPDATA%\Google\Antigravity\`
- IDE hosts such as `Code.exe` / Cursor / Windsurf
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
| Low recovery amount | Other apps besides Claude/Codex CLI are holding memory → check holding processes with `Run-DryRun.bat` |
| Garbled non-ASCII characters | Switch the console font to a Unicode font such as `Consolas` / `Cascadia Mono` |
| Script does not launch | File is blocked — right-click file → Properties → check "Unblock" |

## System tray daemon [v1.2+]

```cmd
Tray.bat                          :: Start system tray (hidden window)
Tray-AutoStart-Register.bat       :: Register auto-start at boot
Tray-AutoStart-Unregister.bat     :: Unregister auto-start
```

- **Always resident**: Memory usage icon in the notification area beside the clock
- **Threshold alert**: BalloonTip when memory usage reaches the threshold (default 90%) — **does not auto recover** (guarantees user choice, prevents work loss)
- **Right-click menu**: basic/deep/maximum recovery / diagnostics / dry run / recovery history / threshold settings / exit
- **Single instance**: Prevent duplicate runs with mutex
- **Save settings**: `tray-settings.json` (threshold/polling interval/cooldown)
- **Daemon itself needs no administrator privileges** — auto-elevates via UAC when recovery triggers

## Recovery history (CSV) [v1.2+]

Automatically recorded in `recovery-history.csv` on every recovery run:

| Column | Meaning |
|------|------|
| Timestamp | yyyy-MM-dd HH:mm:ss |
| Mode | basic / deep / deep+shell |
| BeforeFreeMB / AfterFreeMB | Available MB before/after recovery |
| RecoveredMB | Recovery amount (may be negative — when other apps are holding memory) |
| BeforePctFree / AfterPctFree | Available % before/after recovery |
| ProcessesKilled | Number of terminated Claude/Codex CLI processes |
| RuntimeSec | Execution duration |

Open from the system tray menu → "View recovery history" in Excel/Notepad. You can make a data-based decision on which mode is most effective on your system.

## Activity tracking + idle cleanup [v1.4+]

**Problem**: `-OrphansOnly` catches only orphan processes whose parent IDE has died, but on Windows it is more common for **idle `claude.exe` processes to accumulate while the IDE extension host remains alive** (children do not cascade-terminate even after closing the window/tab). v1.4 safely recovers them based on **"unused time"**.

**Key safety principle**: even active claude sessions have CPU 0% while waiting for input. So killing based only on "CPU is low now" kills active sessions. v1.4 **accumulates activity history over time**, cleaning up only those with **continuous inactivity** of `idleMinutes` — active sessions are preserved because they must use CPU during that period.

**1) Register background tracking** (default 5-minute interval, records CPU snapshots only — never terminates):

```cmd
Track-Register.bat            :: Register -TrackActivity in Task Scheduler (UAC elevation)
Track-Unregister.bat          :: Unregister
```

**2) Telegram alerts when threshold exceeded**: If you put the bot token/chat_id in `tracker-settings.json`, you receive Telegram alerts when idle/orphan processes exceed thresholds (count/memory/RAM%). The alert tick itself does not terminate anything, and the registered auto cleanup task handles them every 3 hours with `-IdleOnly`.

**3) Register auto cleanup / clean up now**:

```cmd
Cleanup-Schedule.ps1          :: Register every 3 hours -IdleOnly auto cleanup
Run-IdleDryRun.bat            :: Preview idle/orphan cleanup targets (no termination)
Run-IdleCleanup.bat           :: Actual termination + memory recovery
```

| Settings (`tracker-settings.json`) | Meaning | Default |
|---|---|---|
| `idleMinutes` | Mark as idle if continuously inactive for this time (minutes) + below CPU rate | `60` |
| `cpuThresholdPct` | Minimum CPU rate(%) considered activity | `0.5` |
| `trackIntervalMin` | Tracking(snapshot) interval(minutes) | `5` |
| `alert.idleCountThreshold` | Alert if idle/orphan count ≥ this value | `10` |
| `alert.idleMemMBThreshold` | Alert if total idle/orphan memory(MB) ≥ this value | `4096` |
| `alert.ramPctThreshold` | Alert if idle/orphan use ≥ this % of total RAM | `10` |
| `alert.cooldownMin` | Minimum re-alert interval(minutes) | `30` |

> **Security**: `tracker-settings.json` is blocked from commits via `.gitignore` because it contains the bot token. Copy and fill out the template `tracker-settings.example.json`. Do not hardcode tokens in source/CLI.
>
> `-TrackActivity` runs unattended **without administrator privileges** because it is read-only(CPU query + alerts). `-IdleOnly` cleanup elevates via UAC for termination+recovery.

## One-click full cleanup (including byproducts) [v1.4.1+]

```cmd
Run-PurgeAll.bat              :: Terminate all claude/Codex CLI + descendant byproducts + standby purge
```

`-IncludeDescendants` also terminates the **descendant process tree**(byproducts such as `conhost`·`bash`·`node`·`pwsh`·`python`·`cmd` launched by the session) for target claude/Codex CLI processes. `Run-PurgeAll.bat` adds deep recovery(`-Deep`: working set + file cache + Memory Compression flush + standby purge) to perform a **near-reboot cleanup** all at once.

> Shells launched directly by the user are not claude descendants, so they are **not touched**. To preserve a specific session, use with `-Interactive` or `-KeepPids "PID"`, and descendants of preserved sessions are automatically excluded (because preserved claude is not the tree root).
>
> ⚠ Running `Run-PurgeAll.bat` alone **terminates all active claude sessions too** — a Y/n confirmation appears before termination.

## Future improvements (Roadmap)

- [ ] Custom system tray icon design (currently Windows default icon)
- [ ] Recovery history trend chart (PowerShell + Chart.js)
- [ ] Option to preserve only specific sessions with a PID/title whitelist
- [ ] Message localization (i18n)
- [ ] CI: PSScriptAnalyzer + automatic PARSE verification

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
