#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# MemoryReset for macOS — Claude Code / Codex CLI cleanup + RAM recovery
#
# macOS port of Windows version(MemoryReset.ps1).
# The kernel API layer has no macOS equivalent or is unnecessary, so it is translated as follows.
#
#   Windows                          macOS
#   ─────────────────────────────    ────────────────────────────────────
#   CloseMainWindow()                SIGTERM
#   taskkill /F /T                   SIGKILL + descendant tree walk
#   EmptyWorkingSet (psapi)          (no equivalent — macOS reclaims automatically)
#   SetSystemFileCacheSize           purge(8)          [sudo required]
#   NtSetSystemInformation
#     MemoryPurgeStandbyList         purge(8)          [sudo required]
#     MemoryFlushModifiedList        (no equivalent)
#   Memory Compression flush         (no equivalent — macOS compression cannot be flushed)
#   Clear-DnsClientCache             dscacheutil -flushcache + killall -HUP mDNSResponder
#   Explorer.exe restart             killall Finder + killall Dock
#   Task Scheduler                   launchd (LaunchAgent)
#
# See README-macOS.md for the detailed mapping.
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch pipe_fail

SCRIPT_DIR="${0:A:h}"
VERSION="1.5.0-macos"

# ── Defaults ───────────────────────────────────────────────────────────
GRACEFUL_TIMEOUT_SEC=8
DRY_RUN=0
SKIP_CONFIRMATION=0
DEEP=0
INCLUDE_SHELL=0
DIAGNOSE=0
KEEP_PIDS=""
INTERACTIVE=0
ORPHANS_ONLY=0
TRACK_ACTIVITY=0
IDLE_ONLY=0
INCLUDE_DESCENDANTS=0
NO_PURGE=0

# ── File paths ────────────────────────────────────────────────────────
SETTINGS_FILE="$SCRIPT_DIR/tracker-settings.json"
STATE_FILE="$SCRIPT_DIR/activity-state.tsv"
TRACKER_STATE_FILE="$SCRIPT_DIR/tracker-state.tsv"
HISTORY_CSV="$SCRIPT_DIR/recovery-history.csv"
RUN_LOG="$SCRIPT_DIR/memoryreset.log"
TRACKER_LOG="$SCRIPT_DIR/tracker.log"

# ── Colors ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m';  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'; C_BOLD=$'\e[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GRAY=""; C_BOLD=""
fi

say()   { print -r -- "$@" }
info()  { print -r -- "${C_GRAY}$*${C_RESET}" }
ok()    { print -r -- "${C_GREEN}$*${C_RESET}" }
warn()  { print -r -- "${C_YELLOW}$*${C_RESET}" }
err()   { print -r -- "${C_RED}$*${C_RESET}" }
head1() { print -r -- "${C_CYAN}$*${C_RESET}" }

# ════════════════════════════════════════════════════════════════════
# 0. Argument parsing
# ════════════════════════════════════════════════════════════════════
usage() {
  cat <<'EOF'
MemoryReset for macOS — Claude Code / Codex CLI cleanup + RAM recovery

Usage: ./memoryreset.sh [options]

  --dry-run              show targets only without termination/recovery (sudo not required)
  --diagnose             memory distribution + orphan analysis only (sudo not required)
  --deep                 additional recovery — purge + DNS cache flush
  --include-shell        restart Finder + Dock (--deep enabled automatically)
  --orphans-only         target only orphans (helper with a dead parent) — safe mode
  --idle-only            target only idle(accumulated inactivity) / orphans — preserve active sessions
  --interactive          select per PID preservation before termination
  --keep-pids "1,2,3"    preserve specified PIDs
  --include-descendants  terminate descendant tree(byproducts) of targets
  --track-activity       track 1-tick (CPU snapshot + Telegram alert at threshold, no termination)
  --graceful-timeout N   wait seconds after SIGTERM (default 8)
  --skip-confirmation    skip Y/n prompt
  --no-purge             skip purge(8) — never use sudo
  -h, --help             this help

Examples:
  ./memoryreset.sh --dry-run                 # preview
  ./memoryreset.sh --diagnose                # memory analysis + orphan analysis
  ./memoryreset.sh --orphans-only            # safely clean up orphans only
  ./memoryreset.sh --idle-only               # clean up idle sessions only
  ./memoryreset.sh --deep                    # termination + purge + DNS flush
  ./memoryreset.sh --deep --include-descendants --skip-confirmation   # full cleanup

Note: Process termination does not require sudo (same user ownership).
      sudo is required only for the purge(8) step, and --no-purge can skip it entirely.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --diagnose)            DIAGNOSE=1 ;;
    --deep)                DEEP=1 ;;
    --include-shell)       INCLUDE_SHELL=1 ;;
    --orphans-only)        ORPHANS_ONLY=1 ;;
    --idle-only)           IDLE_ONLY=1 ;;
    --interactive)         INTERACTIVE=1 ;;
    --include-descendants) INCLUDE_DESCENDANTS=1 ;;
    --track-activity)      TRACK_ACTIVITY=1 ;;
    --skip-confirmation)   SKIP_CONFIRMATION=1 ;;
    --no-purge)            NO_PURGE=1 ;;
    --keep-pids)           KEEP_PIDS="${2:-}"; shift ;;
    --keep-pids=*)         KEEP_PIDS="${1#*=}" ;;
    --graceful-timeout)    GRACEFUL_TIMEOUT_SEC="${2:-8}"; shift ;;
    --graceful-timeout=*)  GRACEFUL_TIMEOUT_SEC="${1#*=}" ;;
    -h|--help)             usage; exit 0 ;;
    *) err "[X] unknown option: $1"; say ""; usage; exit 1 ;;
  esac
  shift
done

# Input validation — same safeguards as Windows version (digits/commas/spaces only)
if [[ -n "$KEEP_PIDS" && ! "$KEEP_PIDS" =~ '^[0-9,[:space:]]*$' ]]; then
  err "[X] --keep-pids value contains disallowed characters."
  warn "    Allowed: digits / commas / spaces. Example: --keep-pids \"1234,5678\""
  exit 1
fi
if [[ ! "$GRACEFUL_TIMEOUT_SEC" =~ '^[0-9]+$' ]]; then
  err "[X] --graceful-timeout must be an integer: '$GRACEFUL_TIMEOUT_SEC'"
  exit 1
fi
(( INCLUDE_SHELL )) && (( ! DEEP )) && { info "[i] --include-shell used alone — automatically enable --deep"; DEEP=1 }

# ════════════════════════════════════════════════════════════════════
# 1. Logging
# ════════════════════════════════════════════════════════════════════
run_log() {
  # Logging failure must not block cleanup/recovery.
  print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] PID=$$ $*" >> "$RUN_LOG" 2>/dev/null || true
}
tracker_log() {
  print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$TRACKER_LOG" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════
# 2. Memory status (based on vm_stat — same accounting as Activity Monitor)
#
#    macOS "in use" = App Memory + Wired + Compressed
#    (Windows FreePhysicalMemory has no direct equivalent so it is reconstructed)
#      App Memory = Anonymous pages − Purgeable
#      Cached Files = File-backed + Purgeable  → reclaimable
#      available = total − in use              → cache is included in available because it is reclaimable
# ════════════════════════════════════════════════════════════════════
typeset -g MEM_TOTAL_MB MEM_APP_MB MEM_WIRED_MB MEM_COMP_MB MEM_CACHED_MB
typeset -g MEM_FREE_MB MEM_USED_MB MEM_AVAIL_MB MEM_PCT_FREE MEM_PCT_USED

mem_stats() {
  local pagesize total_bytes line key val
  typeset -A VM

  pagesize=$(vm_stat 2>/dev/null | head -1 | sed -E 's/.*page size of ([0-9]+) bytes.*/\1/')
  [[ -z "$pagesize" || ! "$pagesize" =~ '^[0-9]+$' ]] && pagesize=4096
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || print 0)

  while IFS= read -r line; do
    key="${line%%:*}"
    val="${line#*:}"
    val="${val//[^0-9]/}"
    [[ -n "$val" ]] && VM[$key]=$val
  done < <(vm_stat 2>/dev/null | tail -n +2)

  local anon=${VM[Anonymous pages]:-0}
  local purge=${VM[Pages purgeable]:-0}
  local wired=${VM[Pages wired down]:-0}
  local comp=${VM[Pages occupied by compressor]:-0}
  local filebacked=${VM[File-backed pages]:-0}
  local freep=${VM[Pages free]:-0}
  local spec=${VM[Pages speculative]:-0}

  local app_pages=$(( anon - purge ));  (( app_pages < 0 )) && app_pages=0
  local cached_pages=$(( filebacked + purge ))
  local free_pages=$(( freep + spec ))
  local used_pages=$(( app_pages + wired + comp ))

  local -F div=$(( 1024.0 * 1024.0 ))
  MEM_TOTAL_MB=$(( total_bytes / div ))
  MEM_APP_MB=$(( app_pages    * pagesize / div ))
  MEM_WIRED_MB=$(( wired      * pagesize / div ))
  MEM_COMP_MB=$(( comp        * pagesize / div ))
  MEM_CACHED_MB=$(( cached_pages * pagesize / div ))
  MEM_FREE_MB=$(( free_pages  * pagesize / div ))
  MEM_USED_MB=$(( used_pages  * pagesize / div ))
  MEM_AVAIL_MB=$(( MEM_TOTAL_MB - MEM_USED_MB ))
  (( MEM_AVAIL_MB < 0 )) && MEM_AVAIL_MB=0

  if (( MEM_TOTAL_MB > 0 )); then
    MEM_PCT_FREE=$(( MEM_AVAIL_MB * 100.0 / MEM_TOTAL_MB ))
    MEM_PCT_USED=$(( MEM_USED_MB  * 100.0 / MEM_TOTAL_MB ))
  else
    MEM_PCT_FREE=0; MEM_PCT_USED=0
  fi
}

show_memory_status() {
  local label="$1"
  mem_stats
  local color=$C_GREEN
  (( MEM_PCT_FREE < 25 )) && color=$C_YELLOW
  (( MEM_PCT_FREE < 10 )) && color=$C_RED
  say ""
  head1 "── $label ──"
  printf " Total:       %8.0f MB\n" $MEM_TOTAL_MB
  printf " App:         %8.0f MB\n" $MEM_APP_MB
  printf " Wired:       %8.0f MB\n" $MEM_WIRED_MB
  printf " Compressed:  %8.0f MB\n" $MEM_COMP_MB
  printf " Cache(recoverable): %5.0f MB\n" $MEM_CACHED_MB
  printf " In use:      %8.0f MB (%.1f%%)\n" $MEM_USED_MB $MEM_PCT_USED
  printf "${color} Available:   %8.0f MB (%.1f%%)${C_RESET}\n" $MEM_AVAIL_MB $MEM_PCT_FREE
}

# ════════════════════════════════════════════════════════════════════
# 3. Process snapshot
#    PROC_CMD[pid] / PROC_PPID[pid] / PROC_RSS[pid](KB) / PROC_CPUT[pid](cumulative CPU seconds)
# ════════════════════════════════════════════════════════════════════
typeset -gA PROC_CMD PROC_PPID PROC_RSS PROC_CPUT
typeset -ga PROC_PIDS

cputime_to_sec() {
  # "12:34.56" → 754.56 ,  "1:02:03" → 3723 ,  "0:00.00" → 0
  local t="$1" h m s rest
  case "$t" in
    *:*:*) h="${t%%:*}"; rest="${t#*:}"; m="${rest%%:*}"; s="${rest#*:}"
           print -- $(( h * 3600 + m * 60 + s )) ;;
    *:*)   m="${t%%:*}"; s="${t#*:}"
           print -- $(( m * 60 + s )) ;;
    *)     print -- 0 ;;
  esac
}

snapshot_processes() {
  PROC_CMD=(); PROC_PPID=(); PROC_RSS=(); PROC_CPUT=(); PROC_PIDS=()
  _DAEMON_ALIVE=""   # daemon liveness cache must match snapshot lifetime
  local pid ppid rss cput cmd
  # command= must be last — the last read variable receives all remaining argv(including spaces).
  while read -r pid ppid rss cput cmd; do
    [[ "$pid" =~ '^[0-9]+$' ]] || continue
    PROC_PIDS+=("$pid")
    PROC_PPID[$pid]="$ppid"
    PROC_RSS[$pid]="$rss"
    PROC_CPUT[$pid]="$(cputime_to_sec "$cput")"
    PROC_CMD[$pid]="$cmd"
  done < <(ps -axo pid=,ppid=,rss=,cputime=,command= 2>/dev/null)
}

# Process start time — for PID reuse detection (Windows CreationDate equivalent)
proc_start_token() {
  local s
  s=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  print -r -- "${s//[[:space:]]/}"
}

# ════════════════════════════════════════════════════════════════════
# 4. Target identification — whitelist / blacklist
#
#    Core safeguard: Claude Desktop app(/Applications/Claude.app) must never match.
#    Claude Code native installation is under ~/.local/share/claude/,
#    helper changes argv[0] to "claude bg-spare" or similar, so identify it by socket path
#    (/tmp/cc-daemon-<uid>/) signature. The two paths never overlap.
# ════════════════════════════════════════════════════════════════════

# Never terminate → blacklist when returning 0(success)
is_blacklisted() {
  local cmd="$1"
  case "$cmd" in
    # Claude Desktop (GUI app) — all installation locations
    /Applications/Claude.app/*)         return 0 ;;
    "$HOME"/Applications/Claude.app/*)  return 0 ;;
    # GUI IDE main app (claude-code launched by an extension is separately matched in the whitelist below)
    /Applications/Visual\ Studio\ Code.app/*) return 0 ;;
    /Applications/Cursor.app/*)               return 0 ;;
    /Applications/Windsurf.app/*)             return 0 ;;
    /Applications/Antigravity.app/*)          return 0 ;;
    # Codex GUI main app (CLI codex / node_repl is targeted, GUI main app is preserved)
    /Applications/Codex.app/Contents/MacOS/*) return 0 ;;
  esac
  return 1
}

is_claude_cli() {
  local cmd="$1"
  is_blacklisted "$cmd" && return 1

  # (a) Native installation paths (~/.local/share/claude/versions/*, ClaudeCode.app, ~/.local/bin/claude)
  case "$cmd" in
    "$HOME"/.local/share/claude/*) return 0 ;;
    "$HOME"/.local/bin/claude|"$HOME"/.local/bin/claude\ *) return 0 ;;
  esac

  # (b) daemon helper — argv[0] is "claude bg-*" / "claude pty-*" and has a daemon socket path
  case "$cmd" in
    claude\ bg-*|claude\ pty-*|claude\ daemon\ *)
      [[ "$cmd" == */tmp/cc-daemon-* || "$cmd" == *"/.claude/daemon"* ]] && return 0
      ;;
  esac

  # (c) npm / IDE extension installation paths
  case "$cmd" in
    *"/node_modules/@anthropic-ai/claude-code/"*)                  return 0 ;;
    *"@anthropic-ai/claude-code"*)                                 return 0 ;;
    "$HOME"/.vscode/extensions/anthropic.claude-code-*)            return 0 ;;
    "$HOME"/.cursor/extensions/anthropic.claude-code-*)            return 0 ;;
    "$HOME"/.antigravity/extensions/anthropic.claude-code-*)       return 0 ;;
    "$HOME"/.windsurf/extensions/anthropic.claude-code-*)          return 0 ;;
    "$HOME"/.claude/local/*)                                       return 0 ;;
  esac

  return 1
}

is_codex_cli() {
  local cmd="$1"
  is_blacklisted "$cmd" && return 1
  case "$cmd" in
    codex|codex\ *)                      return 0 ;;
    */Codex.app/Contents/Resources/*)    return 0 ;;
    *"@openai/codex"*)                   return 0 ;;
    */.codex/*)                          return 0 ;;
  esac
  return 1
}

# claude daemon main process — only normal PPID=1 exception (excluded from orphan detection)
# Match both with and without a path: "claude daemon run ..." / "/path/to/claude daemon run ..."
is_claude_daemon() {
  local cmd="$1"
  case "$cmd" in
    *claude\ daemon\ *|*claude\ daemon) return 0 ;;
  esac
  return 1
}

# Protection list (protected array in tracker-settings.json) — partial command line match
is_protected() {
  local cmd="$1" pat
  for pat in $SET_PROTECTED; do
    [[ -n "$pat" && "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

# claude daemon is currently running — scan only 1 time per snapshot (result cache)
typeset -g _DAEMON_ALIVE=""
claude_daemon_running() {
  if [[ -z "$_DAEMON_ALIVE" ]]; then
    _DAEMON_ALIVE=0
    local q
    for q in $PROC_PIDS; do
      is_claude_daemon "${PROC_CMD[$q]:-}" && { _DAEMON_ALIVE=1; break }
    done
  fi
  (( _DAEMON_ALIVE ))
}

# Process elapsed time(seconds) — parse ps etime ([[dd-]hh:]mm:ss). Return non-0 on failure.
proc_age_sec() {
  local e d=0 hms h=0 m s
  e=$(ps -o etime= -p "$1" 2>/dev/null); e="${e//[[:space:]]/}"
  [[ -n "$e" ]] || return 1
  hms="$e"
  [[ "$e" == *-* ]] && { d="${e%%-*}"; hms="${e#*-}" }
  local -a parts=("${(@s/:/)hms}")
  case ${#parts} in
    3) h=${parts[1]}; m=${parts[2]}; s=${parts[3]} ;;
    2) m=${parts[1]}; s=${parts[2]} ;;
    *) return 1 ;;
  esac
  [[ "$d" == <-> && "$h" == <-> && "$m" == <-> && "$s" == <-> ]] || return 1
  # 10# — prevent etime values such as "08" from being interpreted as base 8
  print -- $(( ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 + 10#$s ))
}

categorize() {
  local cmd="$1"
  # Order matters: check daemon/helper signatures before path patterns.
  # Actual daemon command line is like "/Users/x/.local/bin/claude daemon run ..."
  # A path prefix means "claude daemon *" does not match when anchored → *claude daemon *.
  case "$cmd" in
    "$HOME"/.antigravity/extensions/*)  print -- "Claude(Antigravity ext)" ;;
    "$HOME"/.cursor/extensions/*)       print -- "Claude(Cursor ext)" ;;
    "$HOME"/.vscode/extensions/*)       print -- "Claude(VS Code ext)" ;;
    "$HOME"/.windsurf/extensions/*)     print -- "Claude(Windsurf ext)" ;;
    *"/node_modules/@anthropic-ai/claude-code/"*|*"@anthropic-ai/claude-code"*) print -- "Claude(npm)" ;;
    *claude\ daemon\ *|*claude\ daemon)  print -- "Claude(daemon)" ;;
    # Check pty-host before bg-spare — the pty-host command-line tail
    # "-- <version-bin> --bg-spare <sock>" follows it, so checking bg-spare first
    # pty-host is misclassified as bg-spare. Reverse confusion does not occur.
    *claude\ bg-pty-host*|*claude\ pty-*|*--bg-pty-host*) print -- "Claude(pty-host)" ;;
    *claude\ bg-spare*|*--bg-spare*)     print -- "Claude(bg-spare)" ;;
    "$HOME"/.local/share/claude/*|"$HOME"/.local/bin/claude*) print -- "Claude(native)" ;;
    codex|codex\ *)                     print -- "Codex(CLI)" ;;
    */Codex.app/Contents/Resources/*)   print -- "Codex(runtime)" ;;
    *"@openai/codex"*|*/.codex/*)       print -- "Codex" ;;
    *)                                  print -- "Other(unknown)" ;;
  esac
}

# ── Self + all ancestors (macOS required safeguard) ──────────────────────
# The Windows version excludes only $PID itself. On macOS this script usually
# claude session(terminal) runs this, so the ancestor chain contains a claude process.
# Without excluding ancestors, it kills "the session that runs it".
typeset -gA SELF_CHAIN
build_self_chain() {
  SELF_CHAIN=()
  local cur=$$ guard=0
  while [[ -n "$cur" && "$cur" != "0" && "$cur" != "1" ]]; do
    SELF_CHAIN[$cur]=1
    cur="${PROC_PPID[$cur]:-}"
    (( ++guard > 64 )) && break
  done
  [[ -n "${PPID:-}" ]] && SELF_CHAIN[$PPID]=1
}

# ── Orphan detection (macOS-only redesign) ────────────────────────────────────
# macOS reparents children to launchd(PID 1) immediately when the parent dies.
# Therefore the Windows version "parent PID disappeared / PID reused" test does not apply,
# instead, a much more precise signal exists: PPID == 1.
#
#   · claude/codex process with PPID=1  → orphan (parent terminal·daemon died)
#   · claude daemon with PPID=1         → normal (daemon normally detaches)
#   · parent alive                      → not orphan (conservative — prevent active session false positives)
#
# Caution: the Windows version has an "orphan when the parent is alive but not a normal spawner" rule,
#       direct porting to macOS falsely flags login shells(argv[0] is "-zsh")·terminal emulators
#       and others as false positives measured as not portable.
is_orphan() {
  local pid="$1"
  local cmd="${PROC_CMD[$pid]:-}"
  local ppid="${PROC_PPID[$pid]:-}"
  [[ "$ppid" == "1" ]] || return 1          # Parent alive → not orphan
  is_claude_daemon "$cmd" && return 1       # daemon with normal detach → not orphan
  # daemon-managed helper (bg-spare / pty-host / daemon socket user) is managed by daemon
  # detach spawning makes PPID=1 normal. Measured: even while daemon is alive
  # pty-host PPID for hosting an active session was 1 (2026-07-14 false positive incident).
  # → detect as orphan only when daemon has actually disappeared.
  case "$cmd" in
    *cc-daemon-*|*"/.claude/daemon"*|*claude\ bg-*|*claude\ pty-*|*--bg-pty-host*|*--bg-spare*)
      claude_daemon_running && return 1 ;;
  esac
  return 0
}

# ── Descendant tree BFS ────────────────────────────────────────────────────
descendants_of() {
  # Arguments: root pid values → output descendant PID values one per line
  local -a queue=("$@")
  local -A seen
  local cur child
  typeset -A children
  for child in $PROC_PIDS; do
    local pp="${PROC_PPID[$child]:-}"
    [[ -n "$pp" ]] && children[$pp]="${children[$pp]:-} $child"
  done
  while (( ${#queue} > 0 )); do
    cur="${queue[1]}"; shift queue
    for child in ${=children[$cur]:-}; do
      if [[ -z "${seen[$child]:-}" ]]; then
        seen[$child]=1
        print -- "$child"
        queue+=("$child")
      fi
    done
  done
}

# ── Generate target list ───────────────────────────────────────────────────
typeset -ga TARGET_PIDS
get_targets() {
  TARGET_PIDS=()
  local -A exclude
  local p

  # --keep-pids
  local pid_csv="${KEEP_PIDS//,/ }"
  for p in ${=pid_csv}; do
    [[ "$p" =~ '^[0-9]+$' ]] && exclude[$p]=1
  done
  # Self + all ancestors
  for p in ${(k)SELF_CHAIN}; do exclude[$p]=1; done

  local -a matched=()
  for p in $PROC_PIDS; do
    local cmd="${PROC_CMD[$p]:-}"
    [[ -n "${exclude[$p]:-}" ]] && continue
    if is_claude_cli "$cmd" || is_codex_cli "$cmd"; then
      matched+=("$p")
    fi
  done

  # --orphans-only
  if (( ORPHANS_ONLY )); then
    local -a only=()
    for p in $matched; do
      is_orphan "$p" && only+=("$p")
    done
    matched=($only)
  fi

  # --include-descendants (--orphans-only is included automatically — orphan descendants are also abandoned)
  if (( INCLUDE_DESCENDANTS || ORPHANS_ONLY )) && (( ${#matched} > 0 )); then
    local -A have
    for p in $matched; do have[$p]=1; done
    local d=""
    for d in $(descendants_of $matched); do
      [[ -n "${exclude[$d]:-}" ]] && continue
      [[ -n "${have[$d]:-}" ]] && continue
      have[$d]=1
      matched+=("$d")
    done
  fi

  TARGET_PIDS=(${(on)matched})
}

# ════════════════════════════════════════════════════════════════════
# 5. Settings (tracker-settings.json) — read with plutil (built into macOS, jq unnecessary)
# ════════════════════════════════════════════════════════════════════
typeset -g SET_IDLE_MIN=60 SET_CPU_PCT=0.5 SET_TRACK_INTERVAL=5
typeset -g SET_MIN_AGE_MIN=30 SET_MIN_FREE_PCT=25
typeset -ga SET_PROTECTED=()
typeset -g SET_ALERT_ENABLED=0 SET_TG_TOKEN="" SET_TG_CHAT=""
typeset -g SET_RAM_PCT=10 SET_IDLE_COUNT=10 SET_IDLE_MEM_MB=4096 SET_COOLDOWN_MIN=30

json_get() {
  # json_get <keypath> <default>
  local v
  v=$(plutil -extract "$1" raw -o - "$SETTINGS_FILE" 2>/dev/null) || { print -r -- "$2"; return }
  [[ -z "$v" || "$v" == "<stdin>"* ]] && { print -r -- "$2"; return }
  print -r -- "$v"
}

load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  SET_IDLE_MIN=$(json_get idleMinutes 60)
  SET_CPU_PCT=$(json_get cpuThresholdPct 0.5)
  SET_TRACK_INTERVAL=$(json_get trackIntervalMin 5)
  SET_MIN_AGE_MIN=$(json_get minAgeMinutes 30)
  SET_MIN_FREE_PCT=$(json_get minFreePct 25)
  SET_PROTECTED=()
  local i=0 pat
  # Detect array end only from plutil exit code — break on an empty string element
  # silently discards all following patterns
  while pat=$(plutil -extract "protected.$i" raw -o - "$SETTINGS_FILE" 2>/dev/null); do
    [[ -n "$pat" ]] && SET_PROTECTED+=("$pat")
    (( ++i > 64 )) && break
  done
  local ae; ae=$(json_get alert.enabled false)
  [[ "$ae" == "true" || "$ae" == "1" ]] && SET_ALERT_ENABLED=1 || SET_ALERT_ENABLED=0
  SET_TG_TOKEN=$(json_get alert.telegramBotToken "")
  SET_TG_CHAT=$(json_get alert.telegramChatId "")
  SET_RAM_PCT=$(json_get alert.ramPctThreshold 10)
  SET_IDLE_COUNT=$(json_get alert.idleCountThreshold 10)
  SET_IDLE_MEM_MB=$(json_get alert.idleMemMBThreshold 4096)
  SET_COOLDOWN_MIN=$(json_get alert.cooldownMin 30)
}

# ════════════════════════════════════════════════════════════════════
# 6. Activity tracking (CPU delta accumulation → "N minutes of continuous inactivity" detection)
#
#    Core safety principle(same as Windows): active claude sessions have CPU 0% while waiting for input.
#    "CPU low now" alone kills active sessions.
#    Accumulate activity history over time and clean up only processes with continuous inactivity for idleMinutes.
#
#    State file is TSV (instead of Windows JSON) — for atomic/safe shell handling.
#    Fields: pid  startToken  name  firstTracked  lastActive  lastCpuSec  lastSeen  lastRatePct  rssKB  cmdHash
# ════════════════════════════════════════════════════════════════════
typeset -gA ST_START ST_NAME ST_FIRST ST_ACTIVE ST_CPUSEC ST_SEEN ST_RATE ST_RSS ST_CMDHASH

read_state() {
  ST_START=(); ST_NAME=(); ST_FIRST=(); ST_ACTIVE=(); ST_CPUSEC=(); ST_SEEN=(); ST_RATE=(); ST_RSS=(); ST_CMDHASH=()
  [[ -f "$STATE_FILE" ]] || return 0
  local pid stok name first active cpusec seen rate rss chash
  while IFS=$'\t' read -r pid stok name first active cpusec seen rate rss chash; do
    [[ "$pid" =~ '^[0-9]+$' ]] || continue
    # "-" is an empty field sentinel — TAB is an IFS whitespace character, so consecutive tabs (empty fields)
    # read merges them into one and shifts columns. Fill with "-" when writing and restore here.
    [[ "$stok"  == "-" ]] && stok=""
    [[ "$rate"  == "-" ]] && rate=""
    [[ "$chash" == "-" ]] && chash=""
    ST_START[$pid]="$stok";  ST_NAME[$pid]="$name"
    ST_FIRST[$pid]="$first"; ST_ACTIVE[$pid]="$active"
    ST_CPUSEC[$pid]="$cpusec"; ST_SEEN[$pid]="$seen"
    ST_RATE[$pid]="$rate";   ST_RSS[$pid]="$rss"
    ST_CMDHASH[$pid]="$chash"
  done < "$STATE_FILE"
}

write_state() {
  local tmp="$STATE_FILE.$$.tmp"
  local p
  : > "$tmp" 2>/dev/null || { tracker_log "state save failed: cannot create $tmp"; return 1 }
  for p in ${(k)ST_START}; do
    # Use "-" as sentinel for empty values — consecutive tabs merge in read and shift columns (see read_state)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$p" "${ST_START[$p]:--}" "${ST_NAME[$p]:--}" "${ST_FIRST[$p]:--}" "${ST_ACTIVE[$p]:--}" \
      "${ST_CPUSEC[$p]:--}" "${ST_SEEN[$p]:--}" "${ST_RATE[$p]:--}" "${ST_RSS[$p]:--}" \
      "${ST_CMDHASH[$p]:--}" >> "$tmp"
  done
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; tracker_log "state atomic replacement failed"; return 1 }
}

cmd_hash() { print -r -- "$1" | md5 -q 2>/dev/null }

update_activity_state() {
  local now=$(date +%s)
  read_state
  get_targets

  local -A seen_now
  local p
  for p in $TARGET_PIDS; do
    seen_now[$p]=1
    local cmd="${PROC_CMD[$p]}"
    local stok=""; stok=$(proc_start_token "$p") || stok=""
    local chash="$(cmd_hash "$cmd")"
    local cpusec="${PROC_CPUT[$p]:-0}"

    # Determine activity from full tree CPU — Claude also does actual work in children (tool execution and more)
    # so, like Codex, descendant CPU must be summed to detect activity.
    local d=""
    for d in $(descendants_of "$p"); do
      cpusec=$(( cpusec + ${PROC_CPUT[$d]:-0} ))
    done

    if [[ -n "${ST_START[$p]:-}" && "${ST_START[$p]}" == "$stok" \
          && "${ST_CMDHASH[$p]:-}" == "$chash" ]]; then
      # Same process + same command line — determine activity from CPU delta
      local last_seen="${ST_SEEN[$p]}"
      local last_cpu="${ST_CPUSEC[$p]}"
      local dsec=$(( now - last_seen ))
      if (( dsec > 0 )); then
        # An observation gap (sleep/tracker stopped) is not idle time — shift
        # first/active clocks forward by the gap to exclude downtime from idle calculation.
        local gap_limit=$(( SET_TRACK_INTERVAL * 60 * 3 ))
        if (( dsec > gap_limit )); then
          local shift_sec=$(( dsec - SET_TRACK_INTERVAL * 60 ))
          ST_FIRST[$p]=$(( ${ST_FIRST[$p]} + shift_sec ))
          ST_ACTIVE[$p]=$(( ${ST_ACTIVE[$p]} + shift_sec ))
          (( ST_FIRST[$p]  > now )) && ST_FIRST[$p]=$now
          (( ST_ACTIVE[$p] > now )) && ST_ACTIVE[$p]=$now
          tracker_log "gap: pid=$p observation gap ${dsec}s → adjust idle clock +${shift_sec}s"
        fi
        local dcpu=$(( cpusec - last_cpu ))
        # Full tree CPU total decreased = a child using CPU just exited — that alone is
        # evidence of activity in the prior interval (if discarded as 0, a child that worked briefly then exited is missed)
        (( dcpu < 0 )) && { ST_ACTIVE[$p]=$now; dcpu=0 }
        # Single core % basis — dividing by total core count makes API wait focused sessions
        # never register as active (0.5% threshold on 10 cores = CPU 15 seconds/5 minutes).
        local -F rate=$(( dcpu * 100.0 / dsec ))
        ST_RATE[$p]=$(printf '%.3f' $rate)
        if (( rate >= SET_CPU_PCT )); then
          ST_ACTIVE[$p]=$now
        fi
      fi
      ST_CPUSEC[$p]="$cpusec"
      ST_SEEN[$p]=$now
      ST_RSS[$p]="${PROC_RSS[$p]:-0}"
    else
      # New / PID reuse (start time mismatch) / command line change → reset history.
      # Without command line change detection, bg-spare prestarted by the daemon
      # inherits hours of idle history unchanged when it becomes a session host
      # "Newly opened session" dies in the next sweep (measured incident in 2026-07).
      ST_START[$p]="$stok"
      ST_NAME[$p]="$(categorize "$cmd")"
      ST_FIRST[$p]=$now
      ST_ACTIVE[$p]=$now
      ST_CPUSEC[$p]="$cpusec"
      ST_SEEN[$p]=$now
      ST_RATE[$p]=""
      ST_RSS[$p]="${PROC_RSS[$p]:-0}"
      ST_CMDHASH[$p]="$chash"
    fi
  done

  # Remove vanished PIDs
  for p in ${(k)ST_START}; do
    [[ -z "${seen_now[$p]:-}" ]] && {
      unset "ST_START[$p]" "ST_NAME[$p]" "ST_FIRST[$p]" "ST_ACTIVE[$p]" \
            "ST_CPUSEC[$p]" "ST_SEEN[$p]" "ST_RATE[$p]" "ST_RSS[$p]" "ST_CMDHASH[$p]"
    }
  done
  write_state
}

is_process_idle() {
  # (1) idleMinutes elapsed since tracking began (enough observations) AND
  # (2) idleMinutes elapsed since last activity AND
  # (3) CPU rate in prior interval < threshold
  # Preserve if any condition fails → prevent false positives for active sessions.
  local pid="$1" now="$2"
  local first="${ST_FIRST[$pid]:-}" active="${ST_ACTIVE[$pid]:-}" rate="${ST_RATE[$pid]:-}"
  [[ -z "$first" || -z "$active" ]] && return 1
  local idle_sec=$(( SET_IDLE_MIN * 60 ))
  (( now - first  < idle_sec )) && return 1
  (( now - active < idle_sec )) && return 1
  [[ -n "$rate" ]] && (( rate >= SET_CPU_PCT )) && return 1
  return 0
}

typeset -ga CAND_PIDS
typeset -gA CAND_IDLE CAND_ORPHAN CAND_IDLEMIN
get_reclaim_candidates() {
  CAND_PIDS=(); CAND_IDLE=(); CAND_ORPHAN=(); CAND_IDLEMIN=()
  local now=$(date +%s) p
  read_state
  get_targets
  for p in $TARGET_PIDS; do
    local cmd="${PROC_CMD[$p]:-}"
    # Exclude shared daemon from candidates — killing it orphans helpers for all sessions
    is_claude_daemon "$cmd" && continue
    # Protection list (persistent listeners/services, etc.)
    is_protected "$cmd" && continue
    # Minimum age gate — prohibit just started processes as candidates through any path (idle/orphan).
    # If age cannot be determined, preserve conservatively.
    local age=""
    age=$(proc_age_sec "$p") || age=""
    [[ -z "$age" ]] && continue
    (( age < SET_MIN_AGE_MIN * 60 )) && continue
    local isidle=0 isorph=0
    is_process_idle "$p" "$now" && isidle=1
    is_orphan "$p" && isorph=1
    if (( isidle || isorph )); then
      CAND_PIDS+=("$p")
      CAND_IDLE[$p]=$isidle
      CAND_ORPHAN[$p]=$isorph
      local active="${ST_ACTIVE[$p]:-}"
      if [[ -n "$active" ]]; then
        CAND_IDLEMIN[$p]=$(printf '%.1f' $(( (now - active) / 60.0 )))
      else
        CAND_IDLEMIN[$p]="-"
      fi
    fi
  done
}

# ════════════════════════════════════════════════════════════════════
# 7. Telegram alerts
# ════════════════════════════════════════════════════════════════════
send_telegram() {
  local text="$1"
  [[ -z "$SET_TG_TOKEN" || -z "$SET_TG_CHAT" ]] && {
    tracker_log "Skip Telegram send — token or chatId not set"
    return 1
  }
  # JSON escape (control characters/quotes/backslashes)
  local esc="${text//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"
  local payload="{\"chat_id\":\"$SET_TG_CHAT\",\"text\":\"$esc\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}"
  if curl -fsS -m 12 -X POST \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$payload" \
      "https://api.telegram.org/bot${SET_TG_TOKEN}/sendMessage" >/dev/null 2>&1; then
    return 0
  fi
  tracker_log "Telegram send failed"
  return 1
}

read_last_alert() {
  [[ -f "$TRACKER_STATE_FILE" ]] || { print -- 0; return }
  local v; v=$(cat "$TRACKER_STATE_FILE" 2>/dev/null)
  [[ "$v" =~ '^[0-9]+$' ]] && print -- "$v" || print -- 0
}

invoke_activity_tracking() {
  load_settings
  update_activity_state
  get_reclaim_candidates

  local count=${#CAND_PIDS}
  local mem_mb=0 p
  for p in $CAND_PIDS; do
    mem_mb=$(( mem_mb + ${PROC_RSS[$p]:-0} / 1024.0 ))
  done
  mem_stats
  local ram_pct=0
  (( MEM_TOTAL_MB > 0 )) && ram_pct=$(( mem_mb * 100.0 / MEM_TOTAL_MB ))

  local trigger=0
  (( count  >= SET_IDLE_COUNT ))  && trigger=1
  (( mem_mb >= SET_IDLE_MEM_MB )) && trigger=1
  (( ram_pct >= SET_RAM_PCT ))    && trigger=1

  tracker_log "$(printf 'tick: candidates=%d memMB=%.1f ramPct=%.1f%% trigger=%d alertEnabled=%d' \
    $count $mem_mb $ram_pct $trigger $SET_ALERT_ENABLED)"

  if (( SET_ALERT_ENABLED && trigger )); then
    local now=$(date +%s) last=$(read_last_alert)
    if (( now - last >= SET_COOLDOWN_MIN * 60 )); then
      local idle_n=0 orph_n=0
      for p in $CAND_PIDS; do
        (( ${CAND_IDLE[$p]} ))   && (( idle_n++ ))
        (( ${CAND_ORPHAN[$p]} )) && (( orph_n++ ))
      done
      local msg
      msg="🧹 <b>MemoryReset (macOS) — Cleanup candidate accumulation alert</b>"$'\n\n'
      msg+="$(printf 'Cleanup candidates: <b>%d</b> / <b>%.0f MB</b> (%.1f%% of RAM)' $count $mem_mb $ram_pct)"$'\n'
      msg+="· idle (${SET_IDLE_MIN}min+ inactive): ${idle_n} items"$'\n'
      msg+="· orphan (parent daemon died): ${orph_n} items"$'\n'
      msg+="$(printf '· Current available RAM: %.0f MB (%.1f%%)' $MEM_AVAIL_MB $MEM_PCT_FREE)"$'\n\n'
      msg+="Preview: <code>./memoryreset.sh --idle-only --dry-run</code>"$'\n'
      msg+="Clean up now: <code>./memoryreset.sh --idle-only --skip-confirmation</code>"
      if send_telegram "$msg"; then
        print -- "$now" > "$TRACKER_STATE_FILE" 2>/dev/null
        tracker_log "Telegram alert sent (candidates=$count)"
      fi
    else
      tracker_log "Cooldown active — skip alert"
    fi
  fi
  print -- "$count"
}

# ════════════════════════════════════════════════════════════════════
# 8. Process termination (SIGTERM → wait → SIGKILL)
# ════════════════════════════════════════════════════════════════════
stop_targets() {
  local -a targets=("$@")
  if (( ${#targets} == 0 )); then
    info "[i] No target processes to terminate."
    run_log "stop: no target processes"
    return 0
  fi

  run_log "stop: start targets=${#targets} dryRun=$DRY_RUN timeoutSec=$GRACEFUL_TIMEOUT_SEC"

  # Preserve active Codex sessions (Windows equivalent to Get-ActiveCodexProtectedPids)
  local -A protect
  local p
  load_settings
  read_state
  local now=$(date +%s)
  for p in $PROC_PIDS; do
    if is_codex_cli "${PROC_CMD[$p]}" && ! is_process_idle "$p" "$now"; then
      # codex with activity history and not idle → preserve full tree
      if [[ -n "${ST_FIRST[$p]:-}" ]]; then
        protect[$p]=1
        local d=""
        for d in $(descendants_of "$p"); do protect[$d]=1; done
      fi
    fi
  done

  local -a filtered=()
  for p in $targets; do
    if [[ -n "${protect[$p]:-}" ]]; then
      ok " [SKIP] Preserve active Codex session → PID=$p"
      run_log "skip: active-codex pid=$p"
      continue
    fi
    if is_protected "${PROC_CMD[$p]:-}"; then
      ok " [SKIP] Protection list (protected) → PID=$p"
      run_log "skip: protected pid=$p"
      continue
    fi
    filtered+=("$p")
  done
  targets=($filtered)
  if (( ${#targets} == 0 )); then
    info "[i] No targets to terminate after preserving Codex."
    return 0
  fi

  say ""
  head1 "── [1/4] Graceful exit (SIGTERM) ──"
  for p in $targets; do
    local tag="$(categorize "${PROC_CMD[$p]}") (PID=$p)"
    if (( DRY_RUN )); then
      info " [DRY] SIGTERM → $tag"
      run_log "dry-term pid=$p"
      continue
    fi
    if kill -TERM "$p" 2>/dev/null; then
      ok " [OK] SIGTERM → $tag"
      run_log "sigterm pid=$p"
    else
      info "  ·   Already terminated → $tag"
      run_log "gone-before-term pid=$p"
    fi
  done

  (( DRY_RUN )) && { run_log "stop: dry-run complete"; return 0 }

  say ""
  head1 "── [2/4] ${GRACEFUL_TIMEOUT_SEC}s wait (allow save/cleanup time) ──"
  local i
  for (( i = GRACEFUL_TIMEOUT_SEC; i > 0; i-- )); do
    printf "\r Time remaining: %2d seconds " $i
    sleep 1
  done
  printf "\r Wait complete.            \n"

  say ""
  head1 "── [3/4] Force-kill remaining process tree (SIGKILL) ──"
  # Recalculate tree — children may have started or exited during graceful stage
  snapshot_processes
  local -a survivors=()
  for p in $targets; do
    kill -0 "$p" 2>/dev/null && survivors+=("$p")
  done
  run_log "stop: survivors=${#survivors}"

  if (( ${#survivors} == 0 )); then
    ok " [OK] All processes completed a graceful exit."
    run_log "stop: all closed gracefully"
    return 0
  fi

  for p in $survivors; do
    local tag="$(categorize "${PROC_CMD[$p]:-}") (PID=$p)"
    # Tree kill — descendants first, then root (Windows taskkill /T equivalent)
    local d=""
    for d in $(descendants_of "$p"); do
      [[ -n "${protect[$d]:-}" ]] && continue
      [[ -n "${SELF_CHAIN[$d]:-}" ]] && continue
      is_protected "${PROC_CMD[$d]:-}" && continue
      is_blacklisted "${PROC_CMD[$d]:-}" && continue
      kill -KILL "$d" 2>/dev/null
    done
    if kill -KILL "$p" 2>/dev/null; then
      warn " [KILL] $tag"
      run_log "sigkill pid=$p"
    else
      info " [GONE] $tag (already exited)"
      run_log "sigkill-gone pid=$p"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════
# 9. Memory recovery
#
#    macOS returns pages to the free list immediately when a process terminates.
#    (No Windows Standby List delayed recovery issue — stages 3~5 are unnecessary)
#    File cache(Cached Files) remains and purge(8) reclaims it. sudo required.
# ════════════════════════════════════════════════════════════════════
run_purge() {
  if (( NO_PURGE )); then
    info " · purge(8) skipped (--no-purge)"
    return 0
  fi
  if [[ ! -x /usr/sbin/purge ]]; then
    warn " · purge(8) missing — skipped (Xcode Command Line Tools required)"
    return 1
  fi

  printf " · File cache recovery (purge) ..."
  if [[ $EUID -eq 0 ]]; then
    if /usr/sbin/purge 2>/dev/null; then ok " [OK]"; return 0; fi
    warn " [!] failed"; return 1
  fi

  # Run without a prompt if sudo credentials are already cached
  if sudo -n true 2>/dev/null; then
    if sudo -n /usr/sbin/purge 2>/dev/null; then ok " [OK]"; return 0; fi
    warn " [!] failed"; return 1
  fi

  if (( SKIP_CONFIRMATION )); then
    # A password prompt during unattended execution(launchd) blocks forever.
    say ""
    info "   [skip] sudo credentials unavailable — prompt skipped in unattended mode."
    info "          To use without a password register sudoers: see README-macOS.md 'purge without password'"
    return 1
  fi

  say ""
  info "   purge(8) requires administrator privileges (file cache recovery). You can skip with Ctrl-C."
  if sudo /usr/sbin/purge; then ok "   [OK] File cache recovery complete"; return 0; fi
  warn "   [!] purge failed or canceled — memory from terminated processes already recovered"
  return 1
}

invoke_memory_recovery() {
  say ""
  head1 "── [4/4] Memory recovery ──"
  if (( DRY_RUN )); then
    info " [DRY] purge(8) scheduled"
    return 0
  fi
  info " · macOS immediately returns memory from terminated processes (no Windows Standby List delay)"
  run_purge
}

invoke_deep_recovery() {
  say ""
  head1 "── [Deep] Additional recovery ──"
  if (( DRY_RUN )); then
    info " [DRY] DNS cache flush scheduled"
    return 0
  fi

  printf " · DNS cache flush ..."
  local dns_ok=0
  if [[ $EUID -eq 0 ]]; then
    dscacheutil -flushcache 2>/dev/null && killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  elif sudo -n true 2>/dev/null; then
    sudo -n dscacheutil -flushcache 2>/dev/null && sudo -n killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  elif (( ! SKIP_CONFIRMATION )); then
    say ""
    sudo dscacheutil -flushcache 2>/dev/null && sudo killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  fi
  (( dns_ok )) && ok " [OK]" || warn " [skip] no sudo credentials"

  info " · Memory Compression: macOS has no public API to flush the compression store (no Windows MMAgent equivalent)"
}

invoke_shell_restart() {
  say ""
  head1 "── [Deep+Shell] Finder / Dock restart ──"
  warn "  ! Finder windows close and Dock briefly disappears (launchd restarts automatically)"
  if (( DRY_RUN )); then
    info " [DRY] killall Finder / killall Dock scheduled"
    return 0
  fi
  printf " · Finder restart ..."
  killall Finder 2>/dev/null && ok " [OK]" || info " [skip] not running"
  printf " · Dock restart ..."
  killall Dock 2>/dev/null && ok " [OK]" || info " [skip] not running"
}

# ════════════════════════════════════════════════════════════════════
# 10. CSV recovery history
# ════════════════════════════════════════════════════════════════════
write_recovery_log() {
  local mode="$1" total="$2" before_free="$3" after_free="$4"
  local before_pct="$5" after_pct="$6" killed="$7" runtime="$8"

  if [[ ! -f "$HISTORY_CSV" ]]; then
    print -r -- 'Timestamp,Mode,TotalMB,UsedBeforeMB,UsedAfterMB,FreedMB,BeforeFreeMB,AfterFreeMB,BeforePctFree,AfterPctFree,FreedPctP,ProcessesKilled,RuntimeSec' \
      > "$HISTORY_CSV" 2>/dev/null || { warn " [!] Failed to write CSV history"; return 1 }
  fi
  local used_before=$(( total - before_free ))
  local used_after=$(( total - after_free ))
  printf '%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f,%.2f,%d,%.1f\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" "$total" "$used_before" "$used_after" \
    "$(( used_before - used_after ))" "$before_free" "$after_free" \
    "$before_pct" "$after_pct" "$(( after_pct - before_pct ))" "$killed" "$runtime" \
    >> "$HISTORY_CSV" 2>/dev/null || warn " [!] Failed to write CSV history"
}

# ════════════════════════════════════════════════════════════════════
# 11. Diagnostics (--diagnose)
# ════════════════════════════════════════════════════════════════════
show_zombie_analysis() {
  say ""
  head1 "── Zombie analysis ──"
  info "   macOS reparents children to launchd(PID 1) when the parent dies."
  info "   → claude helper(bg-spare/bg-pty-host) with PPID=1 is an orphan whose daemon died."
  info "   → claude daemon itself with PPID=1 is normal (originally detached daemon)."

  local -a orphans=() alive=()
  local p
  for p in $TARGET_PIDS; do
    if is_orphan "$p"; then orphans+=("$p"); else alive+=("$p"); fi
  done

  say ""
  if (( ${#orphans} > 0 )); then
    local total=0
    for p in $orphans; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    err "$(printf ' [!] confirmed orphans: %d / %.0f MB' ${#orphans} $total)"
    for p in ${orphans[1,8]}; do
      printf "     ${C_GRAY}PID=%-7s PPID=%-6s RSS=%7.0f MB  %s${C_RESET}\n" \
        "$p" "${PROC_PPID[$p]}" "$(( ${PROC_RSS[$p]:-0} / 1024.0 ))" "$(categorize "${PROC_CMD[$p]}")"
    done
    (( ${#orphans} > 8 )) && info "     ... $(( ${#orphans} - 8 )) more"
    warn "    → Safe exit:  ./memoryreset.sh --orphans-only"
  else
    ok " [OK] no orphans with dead parents"
  fi

  if (( ${#alive} > 0 )); then
    local total=0
    for p in $alive; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    say ""
    warn "$(printf ' [i] targets with live parents: %d / %.0f MB' ${#alive} $total)"
    info "     → May be active sessions. --idle-only (idle only) or --interactive (selection) recommended"
  fi
}

show_diagnostics() {
  say ""
  print -r -- "${C_MAGENTA}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  print -r -- "${C_MAGENTA}║                    Memory Diagnostics                     ║${C_RESET}"
  print -r -- "${C_MAGENTA}╚══════════════════════════════════════════════════════════╝${C_RESET}"

  show_memory_status "Memory distribution"

  say ""
  head1 "── Memory Pressure ──"
  local mp
  mp=$(memory_pressure 2>/dev/null | grep -i 'free percentage' | head -1)
  [[ -n "$mp" ]] && info " · $mp" || info " · (memory_pressure unavailable)"
  local swap
  swap=$(sysctl -n vm.swapusage 2>/dev/null)
  [[ -n "$swap" ]] && info " · swap: $swap"

  say ""
  head1 "── Top 15 processes by memory use (RSS) ──"
  local line
  while IFS= read -r line; do
    print -r -- " · $line"
  done < <(ps -axo rss=,pid=,comm= 2>/dev/null | sort -rn | head -15 | \
           awk '{ rss=$1/1024; pid=$2; $1=""; $2=""; sub(/^  /,""); printf "%-52.52s PID=%-7s RSS=%8.0f MB\n", $0, pid, rss }')

  say ""
  head1 "── Processes targeted for termination (Claude/Codex CLI) ──"
  if (( ${#TARGET_PIDS} == 0 )); then
    info " (none)"
  else
    local total=0 p
    for p in $TARGET_PIDS; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    printf " · %d total processes / %.0f MB RSS total recoverable\n" ${#TARGET_PIDS} $total
  fi

  # Preservation check — Claude Desktop / self ancestors
  say ""
  head1 "── Preservation check (safety verification) ──"
  local -a desktop=()
  for p in $PROC_PIDS; do
    [[ "${PROC_CMD[$p]}" == /Applications/Claude.app/* ]] && desktop+=("$p")
  done
  if (( ${#desktop} > 0 )); then
    local dtotal=0
    for p in $desktop; do dtotal=$(( dtotal + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    ok "$(printf ' [Preserved] Claude Desktop app: %d / %.0f MB — not a termination target' ${#desktop} $dtotal)"
  else
    info " · Claude Desktop app not running"
  fi
  ok " [Preserved] self + ancestor chain: ${(k)SELF_CHAIN} — not a termination target"

  show_zombie_analysis

  say ""
  print -r -- "${C_MAGENTA}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  print -r -- "${C_MAGENTA}║  Done. Re-run without --diagnose to reclaim.              ║${C_RESET}"
  print -r -- "${C_MAGENTA}╚══════════════════════════════════════════════════════════╝${C_RESET}"
}

# ════════════════════════════════════════════════════════════════════
# 12. Main
#
# If MEMORYRESET_LIB_ONLY=1 is source, load functions only and exit.
# test-patterns.sh uses detection rules (is_claude_cli / is_blacklisted / is_orphan etc)
# to validate them with synthetic input.
# ════════════════════════════════════════════════════════════════════
if [[ "${MEMORYRESET_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

START_TS=$(date +%s)
load_settings
snapshot_processes
build_self_chain

# ── --track-activity: tracking 1-tick (without banner/UI, without kill) ──────────
if (( TRACK_ACTIVITY )); then
  tracker_log "=== TrackActivity tick ==="
  cnt=$(invoke_activity_tracking)
  info "[tracker] reclaim candidates = $cnt"
  exit 0
fi

run_modes=()
(( DRY_RUN ))             && run_modes+=(dry-run)
(( DIAGNOSE ))            && run_modes+=(diagnose)
(( DEEP ))                && run_modes+=(deep)
(( INCLUDE_SHELL ))       && run_modes+=(include-shell)
(( ORPHANS_ONLY ))        && run_modes+=(orphans-only)
(( INTERACTIVE ))         && run_modes+=(interactive)
(( IDLE_ONLY ))           && run_modes+=(idle-only)
(( INCLUDE_DESCENDANTS )) && run_modes+=(include-descendants)
(( ${#run_modes} == 0 ))  && run_modes=(basic)
run_log "=== run start modes=${(j:,:)run_modes} version=$VERSION"

print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
print -r -- "${C_CYAN}║   Memory Reset (macOS)  —  Claude/Codex CLI Cleanup      ║${C_RESET}"
print -r -- "${C_CYAN}║   graceful kill + descendant cleanup + file cache purge  ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

(( DRY_RUN ))       && print -r -- "${C_MAGENTA}[i] DRY-RUN mode — no actual termination/recovery${C_RESET}"
(( DIAGNOSE ))      && print -r -- "${C_MAGENTA}[i] DIAGNOSE mode — diagnostics only (read-only)${C_RESET}"
(( DEEP ))          && print -r -- "${C_MAGENTA}[i] DEEP mode — purge + DNS cache flush added${C_RESET}"
(( ORPHANS_ONLY ))  && print -r -- "${C_MAGENTA}[i] ORPHANS-ONLY mode — only helper with dead parent targeted${C_RESET}"
(( IDLE_ONLY ))     && print -r -- "${C_MAGENTA}[i] IDLE-ONLY mode — ${SET_IDLE_MIN}min+ inactivity / orphans only${C_RESET}"
(( INTERACTIVE ))   && print -r -- "${C_MAGENTA}[i] INTERACTIVE mode — choose PID to preserve before termination${C_RESET}"
(( INCLUDE_SHELL )) && print -r -- "${C_YELLOW}[!] SHELL restart mode — Finder/Dock will restart${C_RESET}"

get_targets

if (( DIAGNOSE )); then
  run_log "diagnose: start"
  show_diagnostics
  run_log "diagnose: complete"
  exit 0
fi

show_memory_status "Current memory status"
before_total=$MEM_TOTAL_MB
before_free=$MEM_AVAIL_MB
before_pct=$MEM_PCT_FREE

say ""
head1 "── Processes to terminate ──"
(( INCLUDE_DESCENDANTS )) && print -r -- "${C_MAGENTA}[i] INCLUDE-DESCENDANTS — also terminate descendant tree (byproducts)${C_RESET}"

# ── --idle-only: limit to tracking-based candidates only ─────────────────────────────
if (( IDLE_ONLY )); then
  # Boot warmup — do not sweep until idle observation accumulates for idleMinutes.
  # (reboot-only guard — sleep wake does not change kern.boottime, so
  #  update_activity_state corrects observation gaps)
  now_ts=$(date +%s)
  # sed requires a comma anchor: greedy .* lets "usec = " rematch as "sec = ",
  # a microsecond capture bug existed (silently disabling the entire guard)
  boot_sec=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*\{ *sec = ([0-9]+),.*/\1/')
  if [[ "$boot_sec" =~ '^[0-9]+$' ]] && (( now_ts - boot_sec < SET_IDLE_MIN * 60 )); then
    uptime_min=$(( (now_ts - boot_sec) / 60 ))
    info " [i] ${uptime_min}min after boot — idle cleanup skipped before warmup (${SET_IDLE_MIN}min)."
    run_log "targets: skipped boot-warmup uptimeMin=$uptime_min idleMinutes=$SET_IDLE_MIN"
    run_log "=== run complete (boot-warmup skip) ==="
    exit 0
  fi
  # Always update observations even if sweep is skipped — every 90 minutes
  # this path must build history for idle detection
  update_activity_state
  # Available memory gate — no reason to kill if available RAM is sufficient.
  if (( MEM_PCT_FREE >= SET_MIN_FREE_PCT )); then
    info "$(printf ' [i] Available RAM %.1f%% ≥ gate %s%% — skip idle cleanup.' $MEM_PCT_FREE $SET_MIN_FREE_PCT)"
    run_log "$(printf 'targets: skipped memory-ok freePct=%.1f gatePct=%s' $MEM_PCT_FREE $SET_MIN_FREE_PCT)"
    run_log "=== run complete (memory-ok skip) ==="
    exit 0
  fi
  get_reclaim_candidates
  typeset -A cand_set
  for p in $CAND_PIDS; do cand_set[$p]=1; done
  filtered=()
  for p in $TARGET_PIDS; do
    [[ -n "${cand_set[$p]:-}" ]] && filtered+=("$p")
  done
  TARGET_PIDS=($filtered)
  run_log "targets: idleCandidates=${#CAND_PIDS} filtered=${#TARGET_PIDS} idleMinutes=$SET_IDLE_MIN"
  if (( ${#CAND_PIDS} == 0 )); then
    info " [i] no idle/orphan candidates — idle detection requires ${SET_IDLE_MIN} minutes of accumulated tracking history."
    info "     (check that the launchd tracking agent is running: ./install-launchd.sh --status)"
  fi
fi

run_log "targets: finalCount=${#TARGET_PIDS}"
for p in $TARGET_PIDS; do
  run_log "target: pid=$p ppid=${PROC_PPID[$p]} cat=$(categorize "${PROC_CMD[$p]}") idleMin=${CAND_IDLEMIN[$p]:--} rssKB=${PROC_RSS[$p]} cmd=${PROC_CMD[$p]}"
done

if (( ${#TARGET_PIDS} == 0 )); then
  info " (No targets — cache recovery only)"
else
  typeset -A cat_count cat_mb
  grand_total=0
  for p in $TARGET_PIDS; do
    c="$(categorize "${PROC_CMD[$p]}")"
    mb=$(( ${PROC_RSS[$p]:-0} / 1024.0 ))
    cat_count[$c]=$(( ${cat_count[$c]:-0} + 1 ))
    cat_mb[$c]=$(( ${cat_mb[$c]:-0} + mb ))
    grand_total=$(( grand_total + mb ))
  done
  for c in ${(ok)cat_count}; do
    printf "\n${C_YELLOW}  ▶ [%s]  %d items  /  %.1f MB${C_RESET}\n" "$c" "${cat_count[$c]}" "${cat_mb[$c]}"
    shown=0
    for p in $TARGET_PIDS; do
      [[ "$(categorize "${PROC_CMD[$p]}")" == "$c" ]] || continue
      (( shown >= 3 )) && continue
      pmb=$(( ${PROC_RSS[$p]:-0} / 1024.0 ))
      cmdshort="${PROC_CMD[$p]}"
      (( ${#cmdshort} > 66 )) && cmdshort="${cmdshort[1,63]}..."
      orphan_tag=""
      is_orphan "$p" && orphan_tag=" ${C_RED}[orphan]${C_RESET}"
      printf "     ${C_GRAY}PID=%-7s RSS=%7.0f MB  %s${C_RESET}%s\n" "$p" "$pmb" "$cmdshort" "$orphan_tag"
      (( shown++ ))
    done
    (( ${cat_count[$c]} > 3 )) && info "     ... and $(( ${cat_count[$c]} - 3 )) more"
  done
  say ""
  printf "${C_CYAN} ── Total: %.1f MB  (%d processes)${C_RESET}\n" $grand_total ${#TARGET_PIDS}

  # Preservation check display (safety verification)
  desktop_n=0; desktop_mb=0
  for p in $PROC_PIDS; do
    if [[ "${PROC_CMD[$p]}" == /Applications/Claude.app/* ]]; then
      (( desktop_n++ )); desktop_mb=$(( desktop_mb + ${PROC_RSS[$p]:-0} / 1024.0 ))
    fi
  done
  (( desktop_n > 0 )) && printf "${C_GREEN} ── Preserved (not terminated): Claude Desktop app %d / %.1f MB${C_RESET}\n" $desktop_n $desktop_mb
  printf "${C_GREEN} ── Preserved (not terminated): self ancestor chain %d (session running this script)${C_RESET}\n" ${#SELF_CHAIN}
fi

# ── --interactive: select PID to preserve ─────────────────────────────────────
if (( INTERACTIVE )) && (( ! DRY_RUN )) && (( ${#TARGET_PIDS} > 0 )); then
  say ""
  head1 "── [Interactive] Select PID to preserve ──"
  info "  Enter PID to keep from list above using commas. Blank = terminate all"
  printf "  PID to preserve (example: 1234,5678): "
  read -r user_keep
  if [[ -n "$user_keep" ]]; then
    typeset -A keep_set
    for p in ${=user_keep//,/ }; do
      [[ "$p" =~ '^[0-9]+$' ]] && keep_set[$p]=1
    done
    if (( ${#keep_set} > 0 )); then
      filtered=()
      for p in $TARGET_PIDS; do
        [[ -z "${keep_set[$p]:-}" ]] && filtered+=("$p")
      done
      TARGET_PIDS=($filtered)
      ok " [i] Preserved: ${#keep_set} PID — remaining targets to terminate: ${#TARGET_PIDS}"
      run_log "interactive: preserved=${#keep_set} remaining=${#TARGET_PIDS}"
    fi
  else
    info " [i] No PID to preserve — terminate all."
  fi
fi

# ── Confirmation prompt ────────────────────────────────────────────────────
if (( ! SKIP_CONFIRMATION )) && (( ! DRY_RUN )) && (( ${#TARGET_PIDS} > 0 )); then
  say ""
  printf "Terminate the above processes and reclaim memory? [Y/n] "
  read -r confirm
  if [[ "$confirm" == [nN]* ]]; then
    info "[i] Cancelled by user."
    run_log "run cancelled by user"
    exit 0
  fi
fi

stop_targets $TARGET_PIDS
invoke_memory_recovery
(( DEEP ))          && invoke_deep_recovery
(( INCLUDE_SHELL )) && invoke_shell_restart

show_memory_status "Memory status after recovery"

if (( ! DRY_RUN )); then
  recovered=$(( MEM_AVAIL_MB - before_free ))
  pct_change=$(( MEM_PCT_FREE - before_pct ))
  sign=""; (( recovered >= 0 )) && sign="+"
  say ""
  print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  printf "${C_GREEN} Recovered RAM: %s%.0f MB   (%s%.1f%%p)${C_RESET}\n" "$sign" $recovered "$sign" $pct_change
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

  mode_tag=basic
  (( DEEP ))                       && mode_tag=deep
  (( DEEP && INCLUDE_SHELL ))      && mode_tag=deep+shell
  (( IDLE_ONLY ))                  && mode_tag=idle
  (( ORPHANS_ONLY ))               && mode_tag=orphans
  elapsed=$(( $(date +%s) - START_TS ))
  write_recovery_log "$mode_tag" "$before_total" "$before_free" "$MEM_AVAIL_MB" \
                     "$before_pct" "$MEM_PCT_FREE" "${#TARGET_PIDS}" "$elapsed"
  info " [i] Recovery history recorded: recovery-history.csv (run ${elapsed}s)"
  run_log "recovery: mode=$mode_tag targets=${#TARGET_PIDS} recoveredMB=$recovered elapsedSec=$elapsed"
fi
run_log "=== run complete ==="
