#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# launchd LaunchAgent register/unregister — Windows Task Scheduler(Track-Schedule.ps1 /
# Cleanup-Schedule.ps1) equivalent.
#
#   1) tracker  : trackIntervalMin interval --track-activity run
#                 (CPU snapshot logging + Telegram alert on threshold exceeded. never terminates)
#   2) cleanup  : IntervalHours(default 3) interval --idle-only run
#                 (terminate idle/orphans only. preserve active sessions)
#
# Key difference from Windows: process termination needs no administrator privileges (owned by same user).
# Therefore no UAC elevation procedure is needed, LaunchAgent runs with regular user permissions.
# cleanup runs unattended so sudo prompts block forever so register with --no-purge.
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch

SCRIPT_DIR="${0:A:h}"
MAIN="$SCRIPT_DIR/memoryreset.sh"
AGENT_DIR="$HOME/Library/LaunchAgents"
TRACKER_LABEL="com.claudecode.memoryreset.tracker"
CLEANUP_LABEL="com.claudecode.memoryreset.cleanup"
TRACKER_PLIST="$AGENT_DIR/$TRACKER_LABEL.plist"
CLEANUP_PLIST="$AGENT_DIR/$CLEANUP_LABEL.plist"

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'; C_CYAN=$'\e[36m'
say()  { print -r -- "$@" }
ok()   { print -r -- "${C_GREEN}$*${C_RESET}" }
warn() { print -r -- "${C_YELLOW}$*${C_RESET}" }
err()  { print -r -- "${C_RED}$*${C_RESET}" }
info() { print -r -- "${C_GRAY}$*${C_RESET}" }
head1(){ print -r -- "${C_CYAN}$*${C_RESET}" }

ACTION=install
# cleanup intervals are stored in minutes — accepting only hour units(integers) cannot express values like 90 minutes
# be expressed. --interval-hours remains for compatibility and converts internally to minutes.
CLEANUP_INTERVAL_MIN=180

while (( $# > 0 )); do
  case "$1" in
    --remove|--uninstall) ACTION=remove ;;
    --status)             ACTION=status ;;
    --interval-min)       CLEANUP_INTERVAL_MIN="${2:-180}"; shift ;;
    --interval-min=*)     CLEANUP_INTERVAL_MIN="${1#*=}" ;;
    --interval-hours)     CLEANUP_INTERVAL_MIN=$(( ${2:-3} * 60 )); shift ;;
    --interval-hours=*)   CLEANUP_INTERVAL_MIN=$(( ${1#*=} * 60 )) ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install-launchd.sh [options]

  (no options)            tracker + cleanup LaunchAgent registration
  --remove                unregister both
  --status                check registration/run status
  --interval-min N        cleanup interval (minutes). Default 180 (=3 hours). Example: 90 → 1 hour 30 minutes
  --interval-hours N      hour units with same meaning (integers only). --interval-min is more precise

Registered items:
  com.claudecode.memoryreset.tracker  — trackIntervalMin(default 5 minutes) interval, CPU snapshot + alert
  com.claudecode.memoryreset.cleanup  — N hours(default 3) interval, terminate idle/orphans only

sudo not needed — LaunchAgent runs with user permissions.
EOF
      exit 0 ;;
    *) err "[X] Unknown option: $1"; exit 1 ;;
  esac
  shift
done

[[ "$CLEANUP_INTERVAL_MIN" =~ '^[0-9]+$' ]] || { err "[X] interval must be an integer(minutes)"; exit 1 }
(( CLEANUP_INTERVAL_MIN < 5 )) && {
  warn "[!] interval is too short (${CLEANUP_INTERVAL_MIN} minutes) — raise to minimum 5 minutes"
  CLEANUP_INTERVAL_MIN=5
}

# launchctl bootstrap/bootout (newer) → load/unload (older) fallback
lc_load() {
  local plist="$1" label="$2"
  launchctl bootout "gui/$UID/$label" 2>/dev/null
  if launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null; then return 0; fi
  launchctl unload "$plist" 2>/dev/null
  launchctl load -w "$plist" 2>/dev/null
}
lc_unload() {
  local plist="$1" label="$2"
  launchctl bootout "gui/$UID/$label" 2>/dev/null || launchctl unload -w "$plist" 2>/dev/null
}

# ── unregister ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == remove ]]; then
  for pair in "$TRACKER_PLIST:$TRACKER_LABEL" "$CLEANUP_PLIST:$CLEANUP_LABEL"; do
    plist="${pair%:*}"; label="${pair##*:}"
    if [[ -f "$plist" ]]; then
      lc_unload "$plist" "$label"
      rm -f "$plist"
      ok "[OK] unregistered: $label"
    else
      info "[i] not registered: $label"
    fi
  done
  exit 0
fi

# ── status ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == status ]]; then
  head1 "── LaunchAgent status ──"
  for pair in "$TRACKER_PLIST:$TRACKER_LABEL" "$CLEANUP_PLIST:$CLEANUP_LABEL"; do
    plist="${pair%:*}"; label="${pair##*:}"
    if [[ -f "$plist" ]]; then
      if launchctl list 2>/dev/null | grep -q "$label"; then
        ok "[running] $label"
      else
        warn "[registered/not running] $label"
      fi
      info "         plist: $plist"
    else
      info "[not registered] $label"
    fi
  done
  state_file="$SCRIPT_DIR/activity-state.tsv"
  say ""
  head1 "── tracking status ──"
  if [[ -f "$state_file" ]]; then
    n=$(wc -l < "$state_file" | tr -d ' ')
    ok "[OK] activity-state.tsv — tracked processes ${n}"
    info "     last update: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$state_file" 2>/dev/null)"
  else
    warn "[!] activity-state.tsv missing — no tracking tick has run yet"
  fi
  [[ -f "$SCRIPT_DIR/tracker.log" ]] && { say ""; head1 "── tracker.log (last 5 lines) ──"; tail -5 "$SCRIPT_DIR/tracker.log" }
  exit 0
fi

# ── register ─────────────────────────────────────────────────────────────
[[ -x "$MAIN" ]] || { err "[X] memoryreset.sh cannot be found or is not executable: $MAIN"; exit 1 }
mkdir -p "$AGENT_DIR" || { err "[X] $AGENT_DIR creation failed"; exit 1 }

# Read trackIntervalMin from settings (default 5)
INTERVAL_MIN=5
CFG="$SCRIPT_DIR/tracker-settings.json"
if [[ -f "$CFG" ]]; then
  v=$(plutil -extract trackIntervalMin raw -o - "$CFG" 2>/dev/null)
  [[ "$v" =~ '^[0-9]+$' ]] && (( v >= 1 )) && INTERVAL_MIN=$v
fi

write_plist() {
  # write_plist <out_path> <label> <interval-seconds> <args...>
  # Warning: do not use `path` as a local variable name — in zsh `path` is linked to $PATH
  # a linked special array, and overwriting it prevents finding cat/plutil in this function.
  local out_path="$1" label="$2" interval="$3"; shift 3
  local args_xml=""
  local a
  for a in "$@"; do
    args_xml+="        <string>${a}</string>"$'\n'
  done
  cat > "$out_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>${MAIN}</string>
${args_xml}    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/launchd-${label##*.}.out.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/launchd-${label##*.}.err.log</string>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
</dict>
</plist>
EOF
}

# 1) tracker — read-only, never terminates
write_plist "$TRACKER_PLIST" "$TRACKER_LABEL" $(( INTERVAL_MIN * 60 )) "--track-activity"
plutil -lint "$TRACKER_PLIST" >/dev/null 2>&1 || { err "[X] tracker plist creation failed"; exit 1 }
lc_load "$TRACKER_PLIST" "$TRACKER_LABEL"
ok "[OK] tracking registered: $TRACKER_LABEL"
info "     → ${INTERVAL_MIN} minute interval --track-activity (CPU snapshot + Telegram alert at threshold)"
info "     → never terminates processes (read-only)"

# 2) cleanup — idle/orphans only terminate. unattended so --no-purge (prevent sudo prompts)
write_plist "$CLEANUP_PLIST" "$CLEANUP_LABEL" $(( CLEANUP_INTERVAL_MIN * 60 )) \
  "--idle-only" "--skip-confirmation" "--no-purge"
plutil -lint "$CLEANUP_PLIST" >/dev/null 2>&1 || { err "[X] cleanup plist creation failed"; exit 1 }
lc_load "$CLEANUP_PLIST" "$CLEANUP_LABEL"
ok "[OK] auto cleanup registered: $CLEANUP_LABEL"
if (( CLEANUP_INTERVAL_MIN % 60 == 0 )); then
  info "     → $(( CLEANUP_INTERVAL_MIN / 60 )) hour interval --idle-only (idle/orphans only terminate, preserve active sessions)"
else
  info "     → ${CLEANUP_INTERVAL_MIN} minute interval ($(( CLEANUP_INTERVAL_MIN / 60 )) hours $(( CLEANUP_INTERVAL_MIN % 60 )) minutes) --idle-only (idle/orphans only terminate, preserve active sessions)"
fi
info "     → --no-purge: prevent blocking on sudo prompts during unattended execution"
info "        (process termination itself needs no sudo and works normally)"

say ""
head1 "── Next Steps ──"
info " check status:   ./install-launchd.sh --status"
info " unregister:  ./install-launchd.sh --remove"
info " preview:     ./memoryreset.sh --idle-only --dry-run"
info ""
info " idle determination requires tracking history to accumulate for at least idleMinutes(default 60 minutes)."
info " Until then, cleanup targets only orphans(processes with dead parents)."
