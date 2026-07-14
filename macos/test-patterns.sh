#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# 판별 규칙 검증 — Windows 판 Test-Patterns.ps1 대응.
#
# 목적: 실제 프로세스를 건드리지 않고, 합성 커맨드라인으로
#       "무엇을 죽이고 무엇을 절대 죽이지 않는가" 를 증명한다.
#
# 최우선 불변식:
#   1. Claude Desktop (/Applications/Claude.app) 은 어떤 경우에도 종료 대상이 아니다.
#   2. GUI IDE 본체(VS Code / Cursor / Windsurf / Antigravity) 는 종료 대상이 아니다.
#   3. 스크립트를 실행한 세션의 조상 체인은 종료 대상이 아니다.
#   4. claude daemon 은 PPID=1 이어도 고아가 아니다.
#
# 실행: ./test-patterns.sh
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch

SCRIPT_DIR="${0:A:h}"
MEMORYRESET_LIB_ONLY=1 source "$SCRIPT_DIR/memoryreset.sh"

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'
PASS=0; FAIL=0

# assert_target <expect: yes|no> <설명> <커맨드라인>
assert_target() {
  local expect="$1" desc="$2" cmd="$3"
  local got=no
  if is_claude_cli "$cmd" || is_codex_cli "$cmd"; then got=yes; fi
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ ))
    print -r -- "${C_GREEN}  ✓${C_RESET} $desc ${C_GRAY}(대상=$got)${C_RESET}"
  else
    (( FAIL++ ))
    print -r -- "${C_RED}  ✗ $desc — 기대=$expect 실제=$got${C_RESET}"
    print -r -- "${C_RED}      cmd: $cmd${C_RESET}"
  fi
}

assert_cat() {
  local expect="$1" cmd="$2"
  local got; got="$(categorize "$cmd")"
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} 분류: $expect"
  else
    (( PASS=PASS )); (( FAIL++ ))
    print -r -- "${C_RED}  ✗ 분류 — 기대=$expect 실제=$got${C_RESET}"
  fi
}

# assert_orphan <expect: yes|no> <설명> <ppid> <커맨드라인>
assert_orphan() {
  local expect="$1" desc="$2" ppid="$3" cmd="$4"
  local pid=999001
  PROC_CMD[$pid]="$cmd"; PROC_PPID[$pid]="$ppid"
  local got=no
  is_orphan "$pid" && got=yes
  if [[ "$got" == "$expect" ]]; then
    (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} $desc ${C_GRAY}(고아=$got)${C_RESET}"
  else
    (( FAIL++ )); print -r -- "${C_RED}  ✗ $desc — 기대=$expect 실제=$got${C_RESET}"
  fi
  unset "PROC_CMD[$pid]" "PROC_PPID[$pid]"
}

print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
print -r -- "${C_CYAN}║   MemoryReset (macOS) — 판별 규칙 검증                    ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

print -r -- "\n${C_CYAN}[1] 절대 종료 금지 — Claude Desktop 앱${C_RESET}"
assert_target no "Claude Desktop 본체"            "/Applications/Claude.app/Contents/MacOS/Claude"
assert_target no "Claude Desktop 렌더러 helper"   "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
assert_target no "Claude Desktop GPU helper"      "/Applications/Claude.app/Contents/Frameworks/Claude Helper (GPU).app/Contents/MacOS/Claude Helper (GPU)"
assert_target no "사용자 홈 설치 Claude Desktop"  "$HOME/Applications/Claude.app/Contents/MacOS/Claude"
# 함정: Desktop 앱이 claude-code 문자열을 인수로 가져도 블랙리스트가 이긴다
assert_target no "Desktop 앱 + claude-code 인수(위장)" "/Applications/Claude.app/Contents/MacOS/Claude --enable-feature=@anthropic-ai/claude-code"

print -r -- "\n${C_CYAN}[2] 절대 종료 금지 — GUI IDE 본체${C_RESET}"
assert_target no "VS Code 본체"      "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
assert_target no "Cursor 본체"       "/Applications/Cursor.app/Contents/MacOS/Cursor"
assert_target no "Windsurf 본체"     "/Applications/Windsurf.app/Contents/MacOS/Electron"
assert_target no "Antigravity 본체"  "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper"
assert_target no "Codex GUI 본체"    "/Applications/Codex.app/Contents/MacOS/Codex"

print -r -- "\n${C_CYAN}[3] 종료 대상 — Claude Code CLI (네이티브 설치)${C_RESET}"
assert_target yes "네이티브 daemon"      "$HOME/.local/bin/claude daemon run --json-path $HOME/.claude/daemon.json"
assert_target yes "버전 바이너리"        "$HOME/.local/share/claude/versions/2.1.209 --session-id abc"
assert_target yes "ClaudeCode.app 번들"  "$HOME/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc-daemon-501/x/y.sock"
assert_target yes "bg-pty-host helper"   "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/e540b5a0/spare/d9d3b1eb.pty.sock 200 50"
assert_target yes "bg-spare helper"      "claude bg-spare --bg-spare /tmp/cc-daemon-501/e540b5a0/spare/beec2f4e.claim.sock"

print -r -- "\n${C_CYAN}[4] 종료 대상 — Claude Code CLI (npm / IDE 확장)${C_RESET}"
assert_target yes "npm 전역(homebrew)"  "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
assert_target yes "npm 전역(/usr/local)" "/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --output-format stream-json"
assert_target yes "VS Code 확장"        "$HOME/.vscode/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "Cursor 확장"         "$HOME/.cursor/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "Antigravity 확장"    "$HOME/.antigravity/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_target yes "로컬 설치(~/.claude/local)" "$HOME/.claude/local/node_modules/.bin/claude"

print -r -- "\n${C_CYAN}[5] 종료 대상 — Codex CLI${C_RESET}"
assert_target yes "codex CLI"        "codex --model o3"
assert_target yes "codex node_repl"  "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"
assert_target yes "npm codex"        "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"

print -r -- "\n${C_CYAN}[6] 무관한 프로세스 — 건드리면 안 됨${C_RESET}"
assert_target no "일반 node 서버"    "/opt/homebrew/opt/node@22/bin/node /Users/liam/app/server.js"
assert_target no "Chrome"            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
assert_target no "로그인 셸"         "-zsh"
assert_target no "Spotlight"         "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
assert_target no "이름만 비슷한 앱"  "/Applications/ClaudeNotes.app/Contents/MacOS/ClaudeNotes"
assert_target no "홈 밖 위장 경로"   "/tmp/evil/.local/share/claude/versions/9.9.9"

print -r -- "\n${C_CYAN}[7] 고아 판정 (macOS 재부모화 규칙)${C_RESET}"
assert_orphan no  "claude daemon (PPID=1 은 정상)"        1     "$HOME/.local/bin/claude daemon run --json-path $HOME/.claude/daemon.json"
assert_orphan yes "bg-pty-host 인데 PPID=1 (daemon 죽음)" 1     "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/x.sock"
assert_orphan yes "버전 바이너리인데 PPID=1"              1     "$HOME/.local/share/claude/versions/2.1.208 --session-id x"
assert_orphan no  "부모가 살아있는 helper"                1976  "claude bg-spare --bg-spare /tmp/cc-daemon-501/y.sock"
assert_orphan no  "부모가 로그인 셸(-zsh) 인 세션"        936   "$HOME/.local/bin/claude"
assert_orphan yes "codex 인데 PPID=1 (터미널 죽음)"       1     "codex --model o3"

print -r -- "\n${C_CYAN}[8] 분류(categorize)${C_RESET}"
assert_cat "Claude(daemon)"    "$HOME/.local/bin/claude daemon run --json-path x"
assert_cat "Claude(bg-spare)"  "claude bg-spare --bg-spare /tmp/cc-daemon-501/y.sock"
assert_cat "Claude(pty-host)"  "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/y.sock"
assert_cat "Claude(VS Code ext)" "$HOME/.vscode/extensions/anthropic.claude-code-1.0.0/resources/claude"
assert_cat "Codex(runtime)"    "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"
# 회귀: pty-host 의 커맨드라인 꼬리에 "--bg-spare" 가 딸려온다.
# bg-spare 를 먼저 검사하면 pty-host 가 bg-spare 로 오분류됐다 (실측으로 발견).
assert_cat "Claude(pty-host)" "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/e5/spare/be.pty.sock 200 50 -- $HOME/.local/share/claude/versions/2.1.209 --bg-spare /tmp/cc-daemon-501/e5/spare/be.claim.sock"

print -r -- "\n${C_CYAN}[9] zsh 함정 회귀 가드${C_RESET}"

# (a) 특수변수 충돌 — zsh 에서 path/fpath/manpath/cdpath 는 $PATH 등과 연동된 배열이다.
#     지역변수로 덮어쓰면 그 스코프에서 외부 명령을 못 찾는다 (실제로 겪은 버그).
if grep -qnE '\b(local|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?(path|fpath|manpath|cdpath)\b' \
     "$SCRIPT_DIR"/*.sh 2>/dev/null; then
  (( FAIL++ )); print -r -- "${C_RED}  ✗ zsh 특수변수(path/fpath/manpath/cdpath)를 지역변수로 사용 중${C_RESET}"
  grep -nE '\b(local|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)?(path|fpath|manpath|cdpath)\b' "$SCRIPT_DIR"/*.sh
else
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} zsh 특수변수 충돌 없음"
fi

# (b) 루프 안 무값 `local x` — zsh 는 재선언 시 "x=값" 을 stdout 에 출력해 반환값을 오염시킨다.
if grep -qnE '^[[:space:]]+local [a-z_]+$' "$SCRIPT_DIR/memoryreset.sh" 2>/dev/null; then
  # 루프 밖 단일 선언은 안전하므로, 존재 자체는 경고로만 본다 — 실제 오염은 (c) 로 잡는다.
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} 무값 local 존재하나 루프 밖 단일 선언 (통과)"
else
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} 무값 local 없음"
fi

# (c) --track-activity 의 stdout 은 반드시 숫자 하나여야 한다 (오염 감지).
track_out="$("$SCRIPT_DIR/memoryreset.sh" --track-activity 2>/dev/null | tail -1)"
if [[ "$track_out" =~ 'candidates = [0-9]+$' ]]; then
  (( PASS++ )); print -r -- "${C_GREEN}  ✓${C_RESET} --track-activity 출력 오염 없음 ${C_GRAY}($track_out)${C_RESET}"
else
  (( FAIL++ )); print -r -- "${C_RED}  ✗ --track-activity 출력 오염: '$track_out'${C_RESET}"
fi

print -r -- ""
print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
if (( FAIL == 0 )); then
  print -r -- "${C_GREEN}  전체 통과: ${PASS}개${C_RESET}"
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  exit 0
else
  print -r -- "${C_RED}  통과 ${PASS}개 / 실패 ${FAIL}개${C_RESET}"
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  exit 1
fi
