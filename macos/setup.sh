#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# Install on another Mac — one-point bootstrap.
#
#   ./setup.sh                  environment check + executable permission + tests + diagnostics
#   ./setup.sh --with-menubar   above + build/run menu bar app
#   ./setup.sh --with-launchd   above + register background tracking agent (read-only)
#   ./setup.sh --all            all
#
# This script does not terminate any processes. Cleanup follows diagnostics
# and is run directly by the user.
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" || exit 1

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
C_GRAY=$'\e[90m'; C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'
say()  { print -r -- "$@" }
ok()   { print -r -- "${C_GREEN}  ✓${C_RESET} $*" }
warn() { print -r -- "${C_YELLOW}  !${C_RESET} $*" }
bad()  { print -r -- "${C_RED}  ✗${C_RESET} $*" }
info() { print -r -- "${C_GRAY}    $*${C_RESET}" }
head1(){ print -r -- ""; print -r -- "${C_CYAN}${C_BOLD}$*${C_RESET}" }

WITH_MENUBAR=0; WITH_LAUNCHD=0
while (( $# > 0 )); do
  case "$1" in
    --with-menubar) WITH_MENUBAR=1 ;;
    --with-launchd) WITH_LAUNCHD=1 ;;
    --all)          WITH_MENUBAR=1; WITH_LAUNCHD=1 ;;
    -h|--help)      sed -n '3,11p' "$0"; exit 0 ;;
    *) bad "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
print -r -- "${C_CYAN}║   MemoryReset (macOS) — Installation Check                ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

FATAL=0

# ── 1. Environment ─────────────────────────────────────────────────────────
head1 "[1/5] Environment check"
os_ver=$(sw_vers -productVersion 2>/dev/null)
if [[ -z "$os_ver" ]]; then
  bad "This is not macOS. This port is for macOS only."
  info "On Windows use MemoryReset.ps1 in the repository root"
  exit 1
fi
ok "macOS $os_ver ($(uname -m))"

if [[ "${os_ver%%.*}" -lt 12 ]]; then
  warn "macOS below 12 — menu bar app may not work (CLI works)"
fi

[[ -x /bin/zsh ]] && ok "zsh $(/bin/zsh --version | awk '{print $2}')" || { bad "/bin/zsh not found"; FATAL=1 }

for t in /usr/bin/vm_stat /usr/sbin/sysctl /usr/bin/plutil; do
  [[ -x "$t" ]] || { bad "Required tool missing: $t"; FATAL=1 }
done
(( FATAL == 0 )) && ok "Required tools (vm_stat / sysctl / plutil)"

if [[ -x /usr/sbin/purge ]]; then
  ok "purge(8) available ${C_GRAY}(--deep file cache recovery. sudo required, can skip with --no-purge)${C_RESET}"
else
  warn "purge(8) not found — skipping only --deep cache recovery. Process cleanup works"
fi

if command -v swiftc >/dev/null 2>&1; then
  ok "swiftc available (can build menu bar app)"
else
  warn "swiftc not found — cannot build menu bar app (optional). Install if needed: xcode-select --install"
  info "All CLI functions work."
fi

(( FATAL )) && { bad "Requirements not met — stopping."; exit 1 }

# ── 2. File permissions / quarantine attributes ────────────────────────────────────────
head1 "[2/5] File permissions / quarantine attributes"
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.command 2>/dev/null
ok "Execution permissions set"

# GitHub zip downloads add com.apple.quarantine and block .command double click.
# git clone does not add it.
if xattr -p com.apple.quarantine "$SCRIPT_DIR/memoryreset.sh" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null
  ok "Quarantine attribute removed — zip download"
else
  ok "No quarantine attribute (git clone copy)"
fi

# ── 3. Safety rule verification ───────────────────────────────────────────────
head1 "[3/5] Safety rule verification (does not touch processes)"
if ./test-patterns.sh >/tmp/memoryreset-setup-test.log 2>&1; then
  ok "$(grep -o 'All passed: [0-9]* items' /tmp/memoryreset-setup-test.log)"
  info "Claude Desktop preserved / IDE host process preserved / orphan classification / classification rules verified"
else
  bad "Test failed — safety rules have an issue. Do not run cleanup."
  tail -20 /tmp/memoryreset-setup-test.log
  exit 1
fi

# ── 4. Diagnose this Mac ───────────────────────────────────────
head1 "[4/5] Claude/Codex CLI status on this Mac"
target_line=$(./memoryreset.sh --diagnose 2>/dev/null | grep -A1 'Target processes to terminate' | tail -1)
print -r -- "  ${target_line#* }"

n_targets=$(./memoryreset.sh --dry-run 2>/dev/null | grep -oE '\(([0-9]+) processes\)' | grep -oE '[0-9]+' | head -1)
: ${n_targets:=0}

if (( n_targets == 0 )); then
  warn "0 processes to terminate."
  info "This can be normal (no accumulated remaining processes)."
  info "But if it is 0 while using claude, installation on this Mac may differ."
  info "Check:  ps -axo pid,ppid,rss,command | grep -i claude | grep -v grep"
  info "Please report if the installation path differs from 'target process identification rules' in README-macOS.md."
else
  ok "${n_targets} targets identified — proceed in order below"
fi

# ── 5. Optional components ────────────────────────────────────────────────
if (( WITH_MENUBAR )); then
  head1 "[5/5] Menu bar app"
  if command -v swiftc >/dev/null 2>&1; then
    ./build-menubar.sh --run >/dev/null 2>&1 && ok "Build + run complete — check upper right of screen" \
      || bad "Build failed — run ./build-menubar.sh directly to check errors"
  else
    warn "Skipping because swiftc not found"
  fi
fi

if (( WITH_LAUNCHD )); then
  head1 "[5/5] Background tracking agent"
  ./install-launchd.sh >/dev/null 2>&1 && {
    ok "tracker registered (5 minute interval, read only — never terminates)"
    warn "cleanup agent(every 3 hours unattended termination) also registered."
    info "To disable unattended termination:  launchctl bootout gui/\$UID/com.claudecode.memoryreset.cleanup"
    info "                          rm ~/Library/LaunchAgents/com.claudecode.memoryreset.cleanup.plist"
  } || bad "Registration failed — run ./install-launchd.sh directly to check errors"
fi

# ── Next steps ───────────────────────────────────────────────────────
head1 "Next steps (follow this order)"
say "  1) See what will terminate      ${C_GRAY}./memoryreset.sh --dry-run${C_RESET}"
say "  2) Safest cleanup (orphans)     ${C_GRAY}./memoryreset.sh --orphans-only${C_RESET}"
say "  3) Deep recovery (includes cache purge)  ${C_GRAY}./memoryreset.sh --deep${C_RESET}"
say ""
say "  ${C_YELLOW}Warning${C_RESET}: ${C_GRAY}./memoryreset.sh${C_RESET} without options terminates ${C_BOLD}all${C_RESET} CLI including active sessions"
say "        (Y/n prompt will appear). To preserve active sessions use --orphans-only / --idle-only / --interactive."
say ""
say "  Details: ${C_GRAY}README-macOS.md${C_RESET}"
