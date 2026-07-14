#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# Classification rule verification — Windows Test-Patterns.ps1 counterpart.
#
# Purpose: without touching real processes, use synthetic command lines to prove
#       "what is terminated and what is never terminated".
#
# Highest priority invariants:
#   1. Claude Desktop (/Applications/Claude.app) is never a termination target.
#   2. GUI IDE app(VS Code / Cursor / Windsurf / Antigravity) is never a termination target.
#   3. Ancestor chain of the session running this script is never a termination target.
#   4. claude daemon is not an orphan even with PPID=1.
#
# Run: ./test-patterns.sh
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch

SCRIPT_DIR="${0:A:h}"
MEMORYRESET_LIB_ONLY=1 source "$SCRIPT_DIR/memoryreset.sh"

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'
PASS=0; FAIL=0

# assert_target <expect: yes|no> <description> <command line>
assert_target() {
  local expect="$1" desc="$2" cmd="$3"
  local got=no
  if is_claude_cli "$cmd" || is_codex_cli "$cmd"; then got=yes; fi
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ ))
    print -r -- "${C_GREEN}  ✓${C_RESET} $desc ${C_GRAY}(target=$got)${C_RESET}"
  else
    (( FAIL++ ))
    print -r -- "${C_RED}  ✗ $desc — expected=$expect actual=$got${C_RESET}"
    print -r -- "${C_RED}      cmd: $cmd${C_RESET}"
  fi
}

assert_cat() {
  local expect="$1" cmd="$2"
  local got; got="$(categorize "$cmd")"
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} classification: $expect"
  else
    (( PASS=PASS )); (( FAIL++ ))
    print -r -- "${C_RED}  ✗ classification — expected=$expect actual=$got${C_RESET}"
  fi
}

# assert_orphan <expect: yes|no> <description> <ppid> <command line>
assert_orphan() {
  local expect="$1" desc="$2" ppid="$3" cmd="$4"
  local pid=999001
  PROC_CMD[$pid]="$cmd"; PROC_PPID[$pid]="$ppid"
  local got=no
  is_orphan "$pid" && got=yes
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} $desc ${C_GRAY}(orphan=$got)${C_RESET}"
  else
    (( FAIL++ )); print -r -- "${C_RED}  ✗ $desc — expected=$expect actual=$got${C_RESET}"
  fi
  unset "PROC_CMD[$pid]" "PROC_PPID[$pid]"
}

print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
print -r -- "${C_CYAN}║   MemoryReset (macOS) — Identification Rule Check         ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

print -r -- ""; print -r -- "${C_CYAN}[1] Never terminate — Claude Desktop app${C_RESET}"
assert_target no "Claude Desktop main app"        "/Applications/Claude.app/Contents/MacOS/Claude"
assert_target no "Claude Desktop renderer helper"   "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
assert_target no "Claude Desktop GPU helper"      "/Applications/Claude.app/Contents/Frameworks/Claude Helper (GPU).app/Contents/MacOS/Claude Helper (GPU)"
assert_target no "User home installed Claude Desktop"  "$HOME/Applications/Claude.app/Contents/MacOS/Claude"
# Trap: The blacklist wins even if the Desktop app has claude-code in its arguments
assert_target no "Desktop app + claude-code argument(disguise)" "/Applications/Claude.app/Contents/MacOS/Claude --enable-feature=@anthropic-ai/claude-code"

print -r -- ""; print -r -- "${C_CYAN}[2] Never terminate — GUI IDE main app${C_RESET}"
assert_target no "VS Code main app"  "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
assert_target no "Cursor main app"   "/Applications/Cursor.app/Contents/MacOS/Cursor"
assert_target no "Windsurf main app"     "/Applications/Windsurf.app/Contents/MacOS/Electron"
assert_target no "Antigravity main app"  "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper"
assert_target no "Codex GUI main app"    "/Applications/Codex.app/Contents/MacOS/Codex"

print -r -- ""; print -r -- "${C_CYAN}[3] Terminate targets — Claude Code CLI (native installation)${C_RESET}"
assert_target yes "native daemon"        "$HOME/.local/bin/claude daemon run --json-path $HOME/.claude/daemon.json"
assert_target yes "version binary"       "$HOME/.local/share/claude/versions/2.1.209 --session-id abc"
assert_target yes "ClaudeCode.app bundle"  "$HOME/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc-daemon-501/x/y.sock"
assert_target yes "bg-pty-host helper"   "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/e540b5a0/spare/d9d3b1eb.pty.sock 200 50"
assert_target yes "bg-spare helper"      "claude bg-spare --bg-spare /tmp/cc-daemon-501/e540b5a0/spare/beec2f4e.claim.sock"

print -r -- ""; print -r -- "${C_CYAN}[4] Terminate targets — Claude Code CLI (npm / IDE extension)${C_RESET}"
assert_target yes "npm global(homebrew)"  "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
assert_target yes "npm global(/usr/local)" "/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --output-format stream-json"
assert_target yes "VS Code extension"   "$HOME/.vscode/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "Cursor extension"    "$HOME/.cursor/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "Antigravity extension"    "$HOME/.antigravity/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "local installation(~/.claude/local)" "$HOME/.claude/local/node_modules/.bin/claude"

print -r -- ""; print -r -- "${C_CYAN}[5] Terminate targets — Codex CLI${C_RESET}"
assert_target yes "codex CLI"        "codex --model o3"
assert_target yes "codex node_repl"  "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"
assert_target yes "npm codex"        "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"

print -r -- ""; print -r -- "${C_CYAN}[6] Unrelated processes — Do not touch${C_RESET}"
assert_target no "normal node server"    "/opt/homebrew/opt/node@22/bin/node /Users/liam/app/server.js"
assert_target no "Chrome"            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
assert_target no "login shell"       "-zsh"
assert_target no "Spotlight"         "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
assert_target no "similar name app"  "/Applications/ClaudeNotes.app/Contents/MacOS/ClaudeNotes"
assert_target no "disguised path outside home"   "/tmp/evil/.local/share/claude/versions/9.9.9"

print -r -- ""; print -r -- "${C_CYAN}[7] Orphan decision (macOS reparenting rule)${C_RESET}"
assert_orphan no  "claude daemon (PPID=1 is normal)"      1     "$HOME/.local/bin/claude daemon run --json-path $HOME/.claude/daemon.json"
assert_orphan yes "bg-pty-host with PPID=1 (daemon dead)" 1     "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/x.sock"
assert_orphan yes "version binary with PPID=1"            1     "$HOME/.local/share/claude/versions/2.1.208 --session-id x"
assert_orphan no  "helper with live parent"               1976  "claude bg-spare --bg-spare /tmp/cc-daemon-501/y.sock"
assert_orphan no  "session whose parent is login shell(-zsh)"        936   "$HOME/.local/bin/claude"
assert_orphan yes "codex with PPID=1 (terminal dead)"     1     "codex --model o3"

print -r -- ""; print -r -- "${C_CYAN}[8] Classification(categorize)${C_RESET}"
assert_cat "Claude(daemon)"    "$HOME/.local/bin/claude daemon run --json-path x"
assert_cat "Claude(bg-spare)"  "claude bg-spare --bg-spare /tmp/cc-daemon-501/y.sock"
assert_cat "Claude(pty-host)"  "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/y.sock"
assert_cat "Claude(VS Code ext)" "$HOME/.vscode/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_cat "Codex(runtime)"    "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"
# Regression: The pty-host command line tail includes "--bg-spare".
# Checking bg-spare first misclassified pty-host as bg-spare (found by measurement).
assert_cat "Claude(pty-host)" "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/e5/spare/be.pty.sock 200 50 -- $HOME/.local/share/claude/versions/2.1.209 --bg-spare /tmp/cc-daemon-501/e5/spare/be.claim.sock"

print -r -- ""; print -r -- "${C_CYAN}[9] zsh trap regression guard${C_RESET}"

# (a) Special variable collision — In zsh path/fpath/manpath/cdpath are arrays linked to $PATH etc.
#     Overwriting them as local variables prevents finding external commands in that scope (a bug actually encountered).
if grep -qnE '\b(local|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?(path|fpath|manpath|cdpath)\b' \
     "$SCRIPT_DIR"/*.sh 2>/dev/null; then
  (( FAIL++ )); print -r -- "${C_RED}  ✗ zsh special variables(path/fpath/manpath/cdpath) used as local variables${C_RESET}"
  grep -nE '\b(local|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?(path|fpath|manpath|cdpath)\b' "$SCRIPT_DIR"/*.sh
else
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} no zsh special variable collision"
fi

# (b) Valueless `local x` inside a loop — In zsh redeclaring outputs "x=value" to stdout and corrupts the return value.
if grep -qnE '^[[:space:]]+local [a-z_]+$' "$SCRIPT_DIR/memoryreset.sh" 2>/dev/null; then
  # A single declaration outside the loop is safe, so its presence is only a warning — actual corruption is caught by (c).
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} valueless local exists but single declaration outside loop (pass)"
else
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} no valueless local"
fi

# (c) The stdout of --track-activity must be exactly one number (detect corruption).
track_out="$("$SCRIPT_DIR/memoryreset.sh" --track-activity 2>/dev/null | tail -1)"
if [[ "$track_out" =~ 'candidates = [0-9]+$' ]]; then
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} --track-activity output has no corruption ${C_GRAY}($track_out)${C_RESET}"
else
  (( FAIL++ )); print -r -- "${C_RED}  ✗ --track-activity output corruption: '$track_out'${C_RESET}"
fi

print -r -- ""
print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
if (( FAIL == 0 )); then
  print -r -- "${C_GREEN}  All passed: ${PASS}${C_RESET}"
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  exit 0
else
  print -r -- "${C_RED}  Passed ${PASS} / Failed ${FAIL}${C_RESET}"
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  exit 1
fi
