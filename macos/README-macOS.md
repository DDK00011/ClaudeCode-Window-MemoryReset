# MemoryReset — macOS port

> zsh script that safely cleans up remaining processes accumulated by Claude Code / Codex CLI and recovers RAM.
> macOS port of the Windows version([MemoryReset.ps1](../MemoryReset.ps1)).

![zsh](https://img.shields.io/badge/zsh-5.9%2B-green)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

---

## Read this first — macOS differs from Windows in the nature of the problem

The core value of the Windows version was **"the issue where memory from terminated processes is stuck in the Standby List and does not return"** through the kernel
API was force-recovery. **macOS does not have that issue.** When a process is killed, its pages
immediately return to the free list.

So the value of this port lies elsewhere:

| | Windows version | macOS version |
|---|---|---|
| **Primary recovery source** | Standby List / File Cache purge (kernel API) | **Terminate accumulated claude/codex processes** |
| **Secondary recovery source** | EmptyWorkingSet, Memory Compression flush | File cache `purge(8)` |
| **Administrator privileges** | **Always required** (all modes use UAC elevation) | **Not needed to terminate processes.** sudo only for `purge` |

On macOS, what actually consumes RAM is **abandoned but still running CLI processes**. This script
focuses on finding and killing them precisely.

### Measured results (actual leak caught by this code during development)

| Item | Value |
|---|---|
| Discovered orphan trees | **4 processes / 1,345 MB** |
| Identity | old version(`2.1.208`) daemon left behind `bg-pty-host` + `bg-spare` tree when it died |
| Active session impact | **None** (current `2.1.209` session and the script's own ancestor chain preserved) |

> Measurement environment: macOS 26 (Darwin 25.3), Apple Silicon, 16 GB RAM

---

## Windows → macOS mapping table (honest version)

| Windows version step | macOS counterpart | Notes |
|---|---|---|
| `CloseMainWindow()` | `SIGTERM` | |
| `taskkill /F /T` | `SIGKILL` + descendant tree BFS | |
| `EmptyWorkingSet` (psapi) | **No equivalent** | macOS automatically reduces the working set when needed. Unnecessary. |
| `SetSystemFileCacheSize` | `purge(8)` | sudo required |
| `NtSetSystemInformation` → `MemoryPurgeStandbyList` | `purge(8)` | macOS has no Standby List itself |
| `NtSetSystemInformation` → `MemoryFlushModifiedList` | **No equivalent** | |
| Memory Compression flush (`Disable/Enable-MMAgent`) | **No equivalent** | macOS has no public API that flushes the compressed store |
| `Clear-DnsClientCache` | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | |
| `nbtstat -R` / `netsh ... arpcache` | Not applicable | NetBIOS does not exist on macOS |
| Restart Explorer.exe | `killall Finder` + `killall Dock` | launchd automatically restarts |
| Task Scheduler | **launchd** (`~/Library/LaunchAgents`) | |
| System tray (NotifyIcon) | **Menu bar** (NSStatusItem, Swift) | |
| UAC elevation | **Unnecessary** (termination works without sudo) | Only `purge` uses sudo |

**"No equivalent" was not forced into an imitation.** Kernel operations that do not exist on macOS were not falsely implemented
Instead, we stated that they do not exist and retained only steps that actually work.

---

## Installation — Moving to another Mac

```bash
git clone -b macos-port git@github.com:DDK00011/ClaudeCode-Window-MemoryReset.git
cd ClaudeCode-Window-MemoryReset/macos
./setup.sh
```

`setup.sh` does not terminate anything. It checks the environment, cleans up execution permissions and quarantine attributes,
validates 45 safety rules, then shows **that Mac's actual status** and guides you through the next steps.
You can also double click `Setup.command` in Finder.

| Option | Additional action |
|---|---|
| `./setup.sh` | Checks + tests + diagnostics only |
| `./setup.sh --with-menubar` | + Build/run menu bar app |
| `./setup.sh --with-launchd` | + Register background tracking agent |
| `./setup.sh --all` | All |

### Things to do again on each Mac (Important)

| Item | Reason |
|---|---|
| **Build menu bar app** | Binaries are not committed (architecture-dependent). Build on each Mac with `./build-menubar.sh` |
| **Register launchd** | **Absolute paths** are embedded in the plist. If you moved the folder, run `./install-launchd.sh` **again** |
| **Run `--dry-run` first** | The claude installation type (native / npm / IDE extension) can vary by Mac. If 0 targets appear, see below |

> **If you received it as a zip**: macOS adds `com.apple.quarantine`, blocking double-clicking `.command`.
> `setup.sh` removes it automatically. If received via `git clone`, it is not added in the first place.

### When 0 targets appear

This port's identification rules cover **native installs** (`~/.local/share/claude/`) and npm/IDE extension installs.
If you use claude but still get 0, the installation type is different, so check the output below and report it in an issue:

```bash
ps -axo pid,ppid,rss,command | grep -iE 'claude|codex' | grep -v grep
```

---

## Quick start

```bash
cd macos

# 1. First, check what is detected (does not kill anything, no sudo required)
./memoryreset.sh --diagnose

# 2. Preview what will be killed
./memoryreset.sh --dry-run

# 3. Safest actual cleanup — only orphans with dead parents
./memoryreset.sh --orphans-only

# 4. Deep recovery (process termination + file cache purge + DNS flush)
./memoryreset.sh --deep
```

To double-click in Finder, use `.command` files (equivalent of Windows `.bat`):

| File | Action |
|---|---|
| `Run-Diagnose.command` | Diagnostics only |
| `Run-DryRun.command` | Preview |
| `Run-Orphans.command` | Safely clean up orphans only |
| `Run.command` | Default recovery |
| `Run-Deep.command` | Deep recovery |
| `Run-IdleDryRun.command` | idle/orphan cleanup preview |
| `Run-IdleCleanup.command` | Actual idle/orphan cleanup |
| `Run-PurgeAll.command` | Full cleanup (including descendants) |

---

## Options

| Option | Meaning | Default |
|---|---|---|
| `--dry-run` | Show targets only, without termination or recovery | off |
| `--diagnose` | Memory distribution + zombie analysis only (read-only) | off |
| `--deep` | Add `purge(8)` + DNS cache flush | off |
| `--include-shell` | Restart Finder + Dock (`--deep` automatically enabled) | off |
| `--orphans-only` | Only orphan targets with dead parents (**safe mode**) | off |
| `--idle-only` | Target only idle(cumulative inactivity) / orphans (preserve active sessions) | off |
| `--interactive` | Choose whether to preserve each PID before termination | off |
| `--keep-pids "1,2"` | Preserve specified PIDs | — |
| `--include-descendants` | Terminate target descendant trees (byproducts) too | off |
| `--track-activity` | Tracking 1-tick (CPU snapshot + alert, **does not terminate**) | off |
| `--graceful-timeout N` | Wait seconds after SIGTERM | `8` |
| `--skip-confirmation` | Skip Y/n prompt | off |
| `--no-purge` | Skip `purge(8)` — never uses sudo | off |

### Recommendations by scenario

| Situation | Command |
|---|---|
| I want to see what is using memory | `--diagnose` |
| Safely clean up only confirmed leaks | `--orphans-only` |
| Clean up abandoned sessions (preserve active ones) | `--idle-only` |
| Cleanup close to a reboot | `--deep --include-descendants` |

---

## Safeguards

### 1. Never terminate Claude Desktop app

`/Applications/Claude.app` (and `~/Applications/Claude.app`) is blocked by blacklist.
`--enable-feature=@anthropic-ai/claude-code` Even if disguised with an argument like this, the blacklist wins first.
GUI IDE main apps(VS Code / Cursor / Windsurf / Antigravity / Codex.app) are also protected.

### 2. Exclude itself + **entire ancestor chain** (macOS-only safeguard)

Windows version excludes only its own `$PID`. Directly porting it to macOS is **dangerous** —
This script normally runs in a claude session terminal, so the ancestor chain has claude processes:

```
Script → zsh → claude bg-spare → claude bg-pty-host → claude daemon → launchd
                 └──────────── all termination candidates ────────────┘
```

Without excluding ancestors, it **kills the session that launched it.** So the macOS version follows PPID upward
and adds every ancestor to the preserve list. You can check in `--diagnose` output.

### 3. Redesigned orphan detection for macOS

macOS immediately **reparents children to launchd(PID 1)** when their parent dies. Windows version's
"parent PID missing / PID reused" test does not apply. Instead, there is a much more accurate signal:

| Situation | Determination |
|---|---|
| claude helper(`bg-spare`/`bg-pty-host`) with **PPID=1**, and `claude daemon` is also dead | **orphan** |
| claude helper with PPID=1, **daemon is alive** | **normal** — spawned detached by daemon (v1.5.0) |
| `claude daemon` with PPID=1 | **normal** — inherently detached daemon |
| Parent is alive | **not orphan** (conservative — prevents false positives on active sessions) |

> The Windows version's "orphan if the parent is alive but it is not a normal spawner" rule was **not ported.**
> Using it directly on macOS false-positives every login shell(argv[0] is `-zsh`) and terminal emulator.
> This was a false positive measured during development, so the rule itself was removed.

> **v1.5.0 change**: Measurement confirmed that, while daemon is alive, the PPID of pty-host hosting active sessions is
> 1 (2026-07 false-positive incident), so "verify daemon is alive" was added to helper orphan detection
> condition. Also, on the idle sweep(`--idle-only`) path, processes below initial `minAgeMinutes` (default
> 30 min) are not termination candidates (does not apply to manual `--orphans-only`/default mode).

### 4. Preserve active sessions (`--idle-only`)

claude active sessions are also at 0% CPU while waiting for input. Killing based only on "low CPU now" kills active sessions.
So it **accumulates activity history over time** and cleans up only sessions with **continuous** inactivity for `idleMinutes`.
Active sessions necessarily use CPU during that time, so they are preserved. (Same principle as Windows version)

In v1.5.0, this determination was substantially revised:

- **CPU rate is based on a single core.** Previously, it was divided by the total core count (with 10 cores, every 5 minutes
  15 CPU seconds were required), so API-wait-heavy sessions were forever classified as "inactive". Now the threshold
  `cpuThresholdPct 0.5` = 1.5 CPU seconds per 5 minutes. Claude also sums descendant tree CPU like Codex.
- **Reset history on command-line changes** — When a `bg-spare` pre-launched by daemon becomes the session host,
  argv changes, but it previously inherited several hours of idle history, killing a "just opened session".
- **Sleep time is not idle** — When an observation gap(sleep/tracker stopped) exceeds 3 times the tracking interval,
  it advances the idle clock by that amount. Right after boot, the sweep itself is skipped for `idleMinutes`.
- **Free-memory gate** — If available RAM is at least `minFreePct`(default 25%), cleanup is skipped entirely.
- **Protected list** — Processes matching the `protected` array(command-line partial match) in `tracker-settings.json`
  are never auto-terminated (for persistent listeners/services).

### 5. Verification

```bash
./test-patterns.sh     # Test 45 classification rules (including zsh pitfall regression guard) — does not touch real processes
```

Verify Claude Desktop preservation / IDE main app preservation / orphan detection / classification with synthetic command lines.

---

## Target identification rules

**Claude Code CLI** (any one of the following):
- `~/.local/share/claude/...` (native install — `versions/*`, `ClaudeCode.app`)
- `~/.local/bin/claude` (native symbolic link)
- argv[0] is `claude bg-*` / `claude pty-*`, and command line has the `/tmp/cc-daemon-<uid>/` socket path
- `.../node_modules/@anthropic-ai/claude-code/...` (npm global/local)
- `~/.vscode/extensions/anthropic.claude-code-*` (same for Cursor / Antigravity / Windsurf)
- `~/.claude/local/...`

**Codex CLI**: `codex` binary, `Codex.app/Contents/Resources/...`'s `node_repl`, `@openai/codex`

**Never terminate**: `/Applications/Claude.app`, GUI IDE main apps, `Codex.app/Contents/MacOS/`, own ancestor chain

---

## Background tracking + auto cleanup (launchd)

This is equivalent to the Windows version's Task Scheduler(`Track-Register.bat` / `Cleanup-Schedule.ps1`).

```bash
./install-launchd.sh                      # Register tracking + auto cleanup (cleanup default 3 hours)
./install-launchd.sh --interval-min 90    # Run auto cleanup at 1 hour 30 minute intervals
./install-launchd.sh --status             # Check status
./install-launchd.sh --remove             # Unregister both
```

> To change the interval, **just register it again** — `install-launchd.sh` overwrites the existing plist and
> reloads it. No separate unregistration is needed.

Registered items:

| LaunchAgent | Interval | Action |
|---|---|---|
| `com.claudecode.memoryreset.tracker` | `trackIntervalMin` (default 5 minutes) | Logs CPU snapshots + sends Telegram alerts when the threshold is exceeded. **Never terminates** |
| `com.claudecode.memoryreset.cleanup` | default 3 hours (change with `--interval-min`) | `--idle-only` — terminates idle/orphans only. Preserves active sessions |

**The cleanup interval and `idleMinutes` are different values** — easy to confuse, so keep them separate:

| | Meaning | Default |
|---|---|---|
| Cleanup interval (`--interval-min`) | How **often it checks** | 180 minutes |
| `idleMinutes` (settings file) | How **long it must be idle** before termination | 60 minutes |

In other words, `--interval-min 90` + `idleMinutes 60` = **checks every 90 minutes and terminates only sessions inactive for over 60 minutes**.
Even with a shorter cleanup interval, sessions inactive for less than 60 minutes are never terminated.

> **sudo is not needed.** LaunchAgent runs with user permissions. root is not needed to terminate processes.
> cleanup is registered with `--no-purge` because it runs unattended (it would wait forever if a sudo prompt appears).

`idle` classification requires tracking history to accumulate for at least `idleMinutes` (default 60 minutes). Until then, only orphans are cleaned up.

---

## Menu bar app (Windows system tray counterpart)

```bash
./build-menubar.sh --run          # Build + run
./build-menubar.sh --autostart    # Register auto-start at login
./build-menubar.sh --unregister   # Unregister
```

- Persistent 🟢/🟡/🔴 + memory usage display in the menu bar
- Alert when the threshold (default 90%) is reached — **does not recover automatically** (guarantees user choice, prevents work loss)
- Menu: basic/deep/maximum recovery · orphans only · idle only · diagnostics · dry run · history · threshold settings · exit
- Choosing recovery opens Terminal.app to show progress (same as the Windows version opening a console window)
- Single instance (flock)
- Settings: `menubar-settings.json`

> `swiftc` (Xcode Command Line Tools) is required: `xcode-select --install`
> Even without it, **all features are available through the CLI** — the menu bar is optional.

---

## Telegram alerts

```bash
cp tracker-settings.example.json tracker-settings.json
# Fill in telegramBotToken / telegramChatId and set alert.enabled to true
```

| Setting | Meaning | Default |
|---|---|---|
| `idleMinutes` | Classify as idle after this time (minutes) of consecutive inactivity | `60` |
| `cpuThresholdPct` | Minimum CPU rate(%) considered activity | `0.5` |
| `trackIntervalMin` | Tracking snapshot interval (minutes) | `5` |
| `alert.idleCountThreshold` | Alert if idle/orphan count ≥ this value | `10` |
| `alert.idleMemMBThreshold` | Alert if idle/orphan total memory (MB) ≥ this value | `4096` |
| `alert.ramPctThreshold` | Alert if idle/orphans use ≥ this % of total RAM | `10` |
| `alert.cooldownMin` | Minimum re-alert interval(minutes) | `30` |

> `tracker-settings.json` contains a bot token, so commits are blocked by `.gitignore`.

---

## Use purge without a password (optional)

`purge(8)` requires root privileges. If you do not want to enter a password each time, add it to sudoers:

```bash
echo "$(whoami) ALL=(root) NOPASSWD: /usr/sbin/purge" | sudo tee /etc/sudoers.d/memoryreset-purge
sudo chmod 440 /etc/sudoers.d/memoryreset-purge
```

> This one line permits **only** `/usr/sbin/purge` without a password. To revert it
> `sudo rm /etc/sudoers.d/memoryreset-purge`.
>
> You do not need to register it — use `--no-purge`, or leave it alone and it will ask for a password only during interactive runs.
> **Process termination (= most of the amount recovered) works without sudo.**

---

## Generated files

| File | Contents | git |
|---|---|---|
| `recovery-history.csv` | Recovery history (same schema as the Windows version) | ignored |
| `activity-state.tsv` | Activity tracking state (Windows version JSON → changed to shell-safe TSV) | ignored |
| `tracker-state.tsv` | Last alert time (cooldown) | ignored |
| `memoryreset.log` / `tracker.log` | Execution logs | ignored |
| `tracker-settings.json` | Settings + bot token | **ignored (token protection)** |
| `menubar-settings.json` | Menu bar threshold settings | ignored |

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `--idle-only` catches nothing | Tracking history must accumulate for `idleMinutes`. Check that the tracker is running with `./install-launchd.sh --status` |
| `purge` asks for a password | This is normal. Skip it with `--no-purge` or add the sudoers entry above |
| Menu bar app does not appear | Run `xcode-select --install`, then `./build-menubar.sh --run`. Check `menubar.err.log` |
| Amount recovered is low | Use `--diagnose` to check what is using memory. Apps other than claude (such as Chrome) may be using it |
| An active session was terminated | Use `--orphans-only` / `--idle-only` / `--interactive`. Default execution without options terminates **all** CLI sessions (Y/n confirmation is shown) |

---

## Summary of differences from Windows

1. **sudo is rarely needed** — user permissions are enough to terminate processes. Only `purge` is an exception.
2. **There is no kernel memory manipulation step** — macOS has no Standby List, nor a compressed store flush API.
3. **Orphan determination differs** — based on PPID=1 reparenting. The Windows spawner whitelist was removed because it caused false positives.
4. **It preserves its own ancestor chain** — a required macOS safety measure (not in the Windows version).
5. **The state file is TSV** — only internal state uses TSV because writing JSON safely in the shell is difficult. The settings file remains JSON.
6. **`-IncludeShell` restarts Finder/Dock** — handles Explorer restart.

## License

MIT — same as the original. See [LICENSE](../LICENSE).
