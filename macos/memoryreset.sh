#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# MemoryReset for macOS — Claude Code / Codex CLI 정리 + RAM 회수
#
# Windows 판(MemoryReset.ps1)의 macOS 포팅.
# 커널 API 계층은 macOS 에 대응물이 없거나 불필요하므로 아래와 같이 번역했다.
#
#   Windows                          macOS
#   ─────────────────────────────    ────────────────────────────────────
#   CloseMainWindow()                SIGTERM
#   taskkill /F /T                   SIGKILL + 자손 트리 walk
#   EmptyWorkingSet (psapi)          (대응물 없음 — macOS 는 자동 회수)
#   SetSystemFileCacheSize           purge(8)          [sudo 필요]
#   NtSetSystemInformation
#     MemoryPurgeStandbyList         purge(8)          [sudo 필요]
#     MemoryFlushModifiedList        (대응물 없음)
#   Memory Compression flush         (대응물 없음 — macOS 압축은 flush 불가)
#   Clear-DnsClientCache             dscacheutil -flushcache + killall -HUP mDNSResponder
#   Explorer.exe 재시작              killall Finder + killall Dock
#   작업 스케줄러                    launchd (LaunchAgent)
#
# 자세한 대응표는 README-macOS.md 참고.
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch pipe_fail

SCRIPT_DIR="${0:A:h}"
VERSION="1.5.0-macos"

# ── 기본값 ───────────────────────────────────────────────────────────
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

# ── 파일 경로 ────────────────────────────────────────────────────────
SETTINGS_FILE="$SCRIPT_DIR/tracker-settings.json"
STATE_FILE="$SCRIPT_DIR/activity-state.tsv"
TRACKER_STATE_FILE="$SCRIPT_DIR/tracker-state.tsv"
HISTORY_CSV="$SCRIPT_DIR/recovery-history.csv"
RUN_LOG="$SCRIPT_DIR/memoryreset.log"
TRACKER_LOG="$SCRIPT_DIR/tracker.log"

# ── 색상 ─────────────────────────────────────────────────────────────
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
# 0. 인자 파싱
# ════════════════════════════════════════════════════════════════════
usage() {
  cat <<'EOF'
MemoryReset for macOS — Claude Code / Codex CLI 정리 + RAM 회수

사용법: ./memoryreset.sh [옵션]

  --dry-run              종료/회수 없이 대상만 표시 (sudo 불필요)
  --diagnose             메모리 분포 + 좀비 분석만 (sudo 불필요)
  --deep                 추가 회수 — purge + DNS 캐시 flush
  --include-shell        Finder + Dock 재시작 (--deep 자동 활성)
  --orphans-only         고아(부모 죽은 helper)만 대상 — 안전 모드
  --idle-only            idle(무활동 누적) / 고아만 대상 — 활성 세션 보존
  --interactive          종료 전 PID 별 보존 선택
  --keep-pids "1,2,3"    지정 PID 보존
  --include-descendants  대상의 자손 트리(부산물)까지 종료
  --track-activity       추적 1-tick (CPU 스냅샷 + 임계 시 텔레그램 알림, 종료 안 함)
  --graceful-timeout N   SIGTERM 후 대기 초 (기본 8)
  --skip-confirmation    Y/n 프롬프트 생략
  --no-purge             purge(8) 생략 — sudo 를 전혀 쓰지 않음
  -h, --help             이 도움말

예시:
  ./memoryreset.sh --dry-run                 # 사전 확인
  ./memoryreset.sh --diagnose                # 메모리 분석 + 좀비 분석
  ./memoryreset.sh --orphans-only            # 고아만 안전 정리
  ./memoryreset.sh --idle-only               # 무활동 세션만 정리
  ./memoryreset.sh --deep                    # 종료 + purge + DNS flush
  ./memoryreset.sh --deep --include-descendants --skip-confirmation   # 전체 청소

주의: 프로세스 종료는 sudo 가 필요 없다 (같은 사용자 소유).
      sudo 는 purge(8) 단계에서만 요구되며, --no-purge 로 완전히 생략 가능.
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
    *) err "[X] 알 수 없는 옵션: $1"; say ""; usage; exit 1 ;;
  esac
  shift
done

# 입력 검증 — Windows 판과 동일한 방어 (숫자/콤마/공백만 허용)
if [[ -n "$KEEP_PIDS" && ! "$KEEP_PIDS" =~ '^[0-9,[:space:]]*$' ]]; then
  err "[X] --keep-pids 값에 허용되지 않는 문자 포함."
  warn "    허용: 숫자 / 콤마 / 공백. 예: --keep-pids \"1234,5678\""
  exit 1
fi
if [[ ! "$GRACEFUL_TIMEOUT_SEC" =~ '^[0-9]+$' ]]; then
  err "[X] --graceful-timeout 은 정수여야 합니다: '$GRACEFUL_TIMEOUT_SEC'"
  exit 1
fi
(( INCLUDE_SHELL )) && (( ! DEEP )) && { info "[i] --include-shell 단독 사용 — --deep 도 자동 활성화"; DEEP=1 }

# ════════════════════════════════════════════════════════════════════
# 1. 로깅
# ════════════════════════════════════════════════════════════════════
run_log() {
  # 로그 실패가 정리/회수 자체를 막아서는 안 됨.
  print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] PID=$$ $*" >> "$RUN_LOG" 2>/dev/null || true
}
tracker_log() {
  print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$TRACKER_LOG" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════
# 2. 메모리 상태 (vm_stat 기반 — Activity Monitor 와 같은 회계)
#
#    macOS 의 "사용 중" = App Memory + Wired + Compressed
#    (Windows 의 FreePhysicalMemory 와 직접 대응하는 값이 없어 재구성한다)
#      App Memory = Anonymous pages − Purgeable
#      Cached Files = File-backed + Purgeable  → 회수 가능
#      가용(Available) = 전체 − 사용 중        → 캐시는 회수 가능하므로 가용에 포함
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
  printf " 전체:        %8.0f MB\n" $MEM_TOTAL_MB
  printf " 앱(App):     %8.0f MB\n" $MEM_APP_MB
  printf " Wired:       %8.0f MB\n" $MEM_WIRED_MB
  printf " 압축(Comp):  %8.0f MB\n" $MEM_COMP_MB
  printf " 캐시(회수가능): %5.0f MB\n" $MEM_CACHED_MB
  printf " 사용중:      %8.0f MB (%.1f%%)\n" $MEM_USED_MB $MEM_PCT_USED
  printf "${color} 가용:        %8.0f MB (%.1f%%)${C_RESET}\n" $MEM_AVAIL_MB $MEM_PCT_FREE
}

# ════════════════════════════════════════════════════════════════════
# 3. 프로세스 스냅샷
#    PROC_CMD[pid] / PROC_PPID[pid] / PROC_RSS[pid](KB) / PROC_CPUT[pid](누적 CPU 초)
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
  _DAEMON_ALIVE=""   # daemon 생존 캐시는 스냅샷 수명과 일치해야 함
  local pid ppid rss cput cmd
  # command= 는 반드시 마지막 — read 의 마지막 변수가 나머지 전부(공백 포함 argv)를 받는다.
  while read -r pid ppid rss cput cmd; do
    [[ "$pid" =~ '^[0-9]+$' ]] || continue
    PROC_PIDS+=("$pid")
    PROC_PPID[$pid]="$ppid"
    PROC_RSS[$pid]="$rss"
    PROC_CPUT[$pid]="$(cputime_to_sec "$cput")"
    PROC_CMD[$pid]="$cmd"
  done < <(ps -axo pid=,ppid=,rss=,cputime=,command= 2>/dev/null)
}

# 프로세스 시작 시각 — PID 재사용 판별용 (Windows 의 CreationDate 대응)
proc_start_token() {
  local s
  s=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  print -r -- "${s//[[:space:]]/}"
}

# ════════════════════════════════════════════════════════════════════
# 4. 대상 식별 — 화이트리스트 / 블랙리스트
#
#    핵심 안전장치: Claude Desktop 앱(/Applications/Claude.app)은 절대 매칭 금지.
#    Claude Code 의 네이티브 설치판은 ~/.local/share/claude/ 아래에 있고,
#    helper 는 argv[0] 을 "claude bg-spare" 등으로 바꾸므로 소켓 경로
#    (/tmp/cc-daemon-<uid>/) 시그니처로 식별한다. 두 경로는 절대 겹치지 않는다.
# ════════════════════════════════════════════════════════════════════

# 종료 절대 금지 → 0(성공) 반환 시 블랙리스트
is_blacklisted() {
  local cmd="$1"
  case "$cmd" in
    # Claude Desktop (GUI 앱) — 모든 설치 위치
    /Applications/Claude.app/*)         return 0 ;;
    "$HOME"/Applications/Claude.app/*)  return 0 ;;
    # GUI IDE 본체 (확장이 띄운 claude-code 는 아래 화이트리스트에서 별도로 잡힘)
    /Applications/Visual\ Studio\ Code.app/*) return 0 ;;
    /Applications/Cursor.app/*)               return 0 ;;
    /Applications/Windsurf.app/*)             return 0 ;;
    /Applications/Antigravity.app/*)          return 0 ;;
    # Codex GUI 본체 (CLI 인 codex / node_repl 은 대상, GUI 본체는 보존)
    /Applications/Codex.app/Contents/MacOS/*) return 0 ;;
  esac
  return 1
}

is_claude_cli() {
  local cmd="$1"
  is_blacklisted "$cmd" && return 1

  # (a) 네이티브 설치 경로 (~/.local/share/claude/versions/*, ClaudeCode.app, ~/.local/bin/claude)
  case "$cmd" in
    "$HOME"/.local/share/claude/*) return 0 ;;
    "$HOME"/.local/bin/claude|"$HOME"/.local/bin/claude\ *) return 0 ;;
  esac

  # (b) daemon helper — argv[0] 이 "claude bg-*"/"claude pty-*" 이고 daemon 소켓 경로를 가짐
  case "$cmd" in
    claude\ bg-*|claude\ pty-*|claude\ daemon\ *)
      [[ "$cmd" == */tmp/cc-daemon-* || "$cmd" == *"/.claude/daemon"* ]] && return 0
      ;;
  esac

  # (c) npm / IDE 확장 설치 경로
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

# claude daemon 본체인가 — PPID=1 이 정상인 유일한 예외 (고아 판정 제외)
# 경로 유무 양쪽 매칭: "claude daemon run ..." / "/path/to/claude daemon run ..."
is_claude_daemon() {
  local cmd="$1"
  case "$cmd" in
    *claude\ daemon\ *|*claude\ daemon) return 0 ;;
  esac
  return 1
}

# 보호 목록 (tracker-settings.json 의 protected 배열) — 커맨드라인 부분 일치
is_protected() {
  local cmd="$1" pat
  for pat in $SET_PROTECTED; do
    [[ -n "$pat" && "$cmd" == *"$pat"* ]] && return 0
  done
  return 1
}

# claude daemon 이 현재 떠 있는가 — 스냅샷 당 1회만 스캔 (결과 캐시)
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

# 프로세스 경과 시간(초) — ps etime ([[dd-]hh:]mm:ss) 파싱. 실패 시 비-0 반환.
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
  # 10# — etime 의 "08" 같은 값이 8진수로 해석되는 것 방지
  print -- $(( ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 + 10#$s ))
}

categorize() {
  local cmd="$1"
  # 순서 주의: daemon/helper 시그니처를 경로 패턴보다 먼저 본다.
  # 실제 daemon 커맨드라인은 "/Users/x/.local/bin/claude daemon run ..." 처럼
  # 경로 접두사가 붙으므로 "claude daemon *" 로 앵커하면 잡히지 않는다 → *claude daemon *.
  case "$cmd" in
    "$HOME"/.antigravity/extensions/*)  print -- "Claude(Antigravity ext)" ;;
    "$HOME"/.cursor/extensions/*)       print -- "Claude(Cursor ext)" ;;
    "$HOME"/.vscode/extensions/*)       print -- "Claude(VS Code ext)" ;;
    "$HOME"/.windsurf/extensions/*)     print -- "Claude(Windsurf ext)" ;;
    *"/node_modules/@anthropic-ai/claude-code/"*|*"@anthropic-ai/claude-code"*) print -- "Claude(npm)" ;;
    *claude\ daemon\ *|*claude\ daemon)  print -- "Claude(daemon)" ;;
    # pty-host 를 bg-spare 보다 먼저 본다 — pty-host 의 커맨드라인 꼬리에는
    # "-- <version-bin> --bg-spare <sock>" 이 딸려오므로, bg-spare 를 먼저 검사하면
    # pty-host 가 bg-spare 로 오분류된다. 반대 방향의 혼동은 일어나지 않는다.
    *claude\ bg-pty-host*|*claude\ pty-*|*--bg-pty-host*) print -- "Claude(pty-host)" ;;
    *claude\ bg-spare*|*--bg-spare*)     print -- "Claude(bg-spare)" ;;
    "$HOME"/.local/share/claude/*|"$HOME"/.local/bin/claude*) print -- "Claude(native)" ;;
    codex|codex\ *)                     print -- "Codex(CLI)" ;;
    */Codex.app/Contents/Resources/*)   print -- "Codex(runtime)" ;;
    *"@openai/codex"*|*/.codex/*)       print -- "Codex" ;;
    *)                                  print -- "기타(unknown)" ;;
  esac
}

# ── 자기 자신 + 조상 전체 (macOS 필수 안전장치) ──────────────────────
# Windows 판은 자기 $PID 하나만 제외한다. macOS 에서 이 스크립트는 보통
# claude 세션(터미널) 안에서 실행되므로, 조상 체인에 claude 프로세스가 있다.
# 조상을 제외하지 않으면 "자기를 실행한 세션"을 죽인다.
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

# ── 고아 판정 (macOS 전용 재설계) ────────────────────────────────────
# macOS 는 부모가 죽으면 자식이 즉시 launchd(PID 1)로 재부모화된다.
# 따라서 Windows 판의 "부모 PID 가 사라졌는가 / PID 재사용인가" 판정은 성립하지 않고,
# 대신 훨씬 정확한 신호가 생긴다: PPID == 1.
#
#   · claude/codex 프로세스인데 PPID=1  → 고아 (부모 터미널·daemon 이 죽음)
#   · claude daemon 인데 PPID=1         → 정상 (원래 detach 되는 데몬)
#   · 부모가 살아있음                   → 고아 아님 (보수적 — 활성 세션 오탐 방지)
#
# 주의: Windows 판에는 "부모가 살아있어도 정상 spawner 가 아니면 고아" 규칙이 있으나,
#       macOS 에 그대로 옮기면 로그인 셸(argv[0] 이 "-zsh")·터미널 에뮬레이터 등을
#       전부 오탐한다. 실측으로 확인된 오탐이라 이식하지 않는다.
is_orphan() {
  local pid="$1"
  local cmd="${PROC_CMD[$pid]:-}"
  local ppid="${PROC_PPID[$pid]:-}"
  [[ "$ppid" == "1" ]] || return 1          # 부모 생존 → 고아 아님
  is_claude_daemon "$cmd" && return 1       # detach 가 정상인 데몬 → 고아 아님
  # daemon 관리 helper (bg-spare / pty-host / daemon 소켓 사용자)는 daemon 이
  # detach 스폰하므로 PPID=1 이 정상 상태다. 실측: daemon 이 살아있는 동안에도
  # 활성 세션을 호스팅하는 pty-host 의 PPID 는 1 이었다 (2026-07-14 오탐 사고).
  # → daemon 이 실제로 사라졌을 때만 고아로 판정한다.
  case "$cmd" in
    *cc-daemon-*|*"/.claude/daemon"*|*claude\ bg-*|*claude\ pty-*|*--bg-pty-host*|*--bg-spare*)
      claude_daemon_running && return 1 ;;
  esac
  return 0
}

# ── 자손 트리 BFS ────────────────────────────────────────────────────
descendants_of() {
  # 인자: root pid 들 → 자손 PID 를 줄 단위로 출력
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

# ── 대상 목록 산출 ───────────────────────────────────────────────────
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
  # 자기 자신 + 조상 전체
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

  # --include-descendants (--orphans-only 는 자동 포함 — 고아의 자손도 함께 버려진 것이므로)
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
# 5. 설정 (tracker-settings.json) — plutil 로 읽음 (macOS 내장, jq 불필요)
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
  # 배열 끝은 plutil 의 종료 코드로만 판정 — 빈 문자열 요소에서 break 하면
  # 그 뒤의 패턴이 전부 조용히 버려진다
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
# 6. 활동 추적 (CPU delta 누적 → "N분 연속 무활동" 판정)
#
#    핵심 안전 원리(Windows 판과 동일): 활성 claude 세션도 입력 대기 중엔 CPU 0%.
#    "지금 CPU 낮음"만으로 죽이면 활성 세션을 죽인다. 활동 이력을 시간에 걸쳐
#    누적해서 idleMinutes 연속 무활동인 것만 정리한다.
#
#    상태 파일은 TSV (Windows 판의 JSON 대신) — 셸에서 원자적/안전하게 다루기 위함.
#    필드: pid  startToken  name  firstTracked  lastActive  lastCpuSec  lastSeen  lastRatePct  rssKB  cmdHash
# ════════════════════════════════════════════════════════════════════
typeset -gA ST_START ST_NAME ST_FIRST ST_ACTIVE ST_CPUSEC ST_SEEN ST_RATE ST_RSS ST_CMDHASH

read_state() {
  ST_START=(); ST_NAME=(); ST_FIRST=(); ST_ACTIVE=(); ST_CPUSEC=(); ST_SEEN=(); ST_RATE=(); ST_RSS=(); ST_CMDHASH=()
  [[ -f "$STATE_FILE" ]] || return 0
  local pid stok name first active cpusec seen rate rss chash
  while IFS=$'\t' read -r pid stok name first active cpusec seen rate rss chash; do
    [[ "$pid" =~ '^[0-9]+$' ]] || continue
    # "-" 는 빈 필드 센티널 — TAB 은 IFS 공백문자라 연속 탭(빈 필드)이
    # read 에서 하나로 접혀 컬럼이 밀린다. 쓰기 쪽에서 "-" 로 채우고 여기서 복원.
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
  : > "$tmp" 2>/dev/null || { tracker_log "state 저장 실패: $tmp 생성 불가"; return 1 }
  for p in ${(k)ST_START}; do
    # 빈 값은 "-" 센티널로 — 연속 탭은 read 에서 접혀 컬럼이 밀린다 (read_state 참고)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$p" "${ST_START[$p]:--}" "${ST_NAME[$p]:--}" "${ST_FIRST[$p]:--}" "${ST_ACTIVE[$p]:--}" \
      "${ST_CPUSEC[$p]:--}" "${ST_SEEN[$p]:--}" "${ST_RATE[$p]:--}" "${ST_RSS[$p]:--}" \
      "${ST_CMDHASH[$p]:--}" >> "$tmp"
  done
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; tracker_log "state 원자적 교체 실패"; return 1 }
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

    # 트리 전체 CPU 로 활동 판정 — Claude 도 실제 작업은 자식(tool 실행 등)에서
    # 돌기 때문에 Codex 처럼 자손 CPU 를 합산해야 활동이 잡힌다.
    local d=""
    for d in $(descendants_of "$p"); do
      cpusec=$(( cpusec + ${PROC_CPUT[$d]:-0} ))
    done

    if [[ -n "${ST_START[$p]:-}" && "${ST_START[$p]}" == "$stok" \
          && "${ST_CMDHASH[$p]:-}" == "$chash" ]]; then
      # 동일 프로세스 + 동일 커맨드라인 — CPU delta 로 활동 여부 판정
      local last_seen="${ST_SEEN[$p]}"
      local last_cpu="${ST_CPUSEC[$p]}"
      local dsec=$(( now - last_seen ))
      if (( dsec > 0 )); then
        # 관측 공백(잠자기/트래커 중단)은 유휴 시간이 아니다 — 공백만큼
        # first/active 시계를 앞으로 밀어 downtime 을 유휴 계산에서 제외한다.
        local gap_limit=$(( SET_TRACK_INTERVAL * 60 * 3 ))
        if (( dsec > gap_limit )); then
          local shift_sec=$(( dsec - SET_TRACK_INTERVAL * 60 ))
          ST_FIRST[$p]=$(( ${ST_FIRST[$p]} + shift_sec ))
          ST_ACTIVE[$p]=$(( ${ST_ACTIVE[$p]} + shift_sec ))
          (( ST_FIRST[$p]  > now )) && ST_FIRST[$p]=$now
          (( ST_ACTIVE[$p] > now )) && ST_ACTIVE[$p]=$now
          tracker_log "gap: pid=$p 관측 공백 ${dsec}s → 유휴 시계 +${shift_sec}s 보정"
        fi
        local dcpu=$(( cpusec - last_cpu ))
        # 트리 CPU 합이 감소했다 = CPU 를 쓰던 자식이 방금 종료했다 — 그 자체가
        # 직전 간격의 활동 증거다 (0 으로 버리면 짧게 일하고 사라진 자식이 안 보임)
        (( dcpu < 0 )) && { ST_ACTIVE[$p]=$now; dcpu=0 }
        # 단일 코어 기준 % — 전체 코어 수로 나누면 API 대기 위주 세션은
        # 영원히 활동으로 안 잡힌다 (10코어에서 임계 0.5% = CPU 15초/5분).
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
      # 신규 / PID 재사용(시작 시각 불일치) / 커맨드라인 변경 → 이력 리셋.
      # 커맨드라인 변경 감지가 없으면 daemon 이 미리 띄워둔 bg-spare 가
      # 세션 호스트로 전환될 때 몇 시간짜리 유휴 이력을 그대로 상속받아
      # "방금 연 세션"이 다음 스윕에서 죽는다 (2026-07 실측 사고).
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

  # 소멸한 PID 제거
  for p in ${(k)ST_START}; do
    [[ -z "${seen_now[$p]:-}" ]] && {
      unset "ST_START[$p]" "ST_NAME[$p]" "ST_FIRST[$p]" "ST_ACTIVE[$p]" \
            "ST_CPUSEC[$p]" "ST_SEEN[$p]" "ST_RATE[$p]" "ST_RSS[$p]" "ST_CMDHASH[$p]"
    }
  done
  write_state
}

is_process_idle() {
  # (1) 추적 시작 후 idleMinutes 경과(관측 충분) AND
  # (2) 마지막 활동 후 idleMinutes 경과 AND
  # (3) 직전 간격 CPU 율 < 임계
  # 하나라도 불충족 → 보존. 활성 세션 오탐 방지.
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
    # 공유 daemon 은 후보 제외 — 죽이면 전 세션 helper 가 고아화되는 연쇄 사고
    is_claude_daemon "$cmd" && continue
    # 보호 목록 (상시 리스너/서비스 등)
    is_protected "$cmd" && continue
    # 최소 나이 게이트 — 방금 시작한 프로세스는 어떤 경로(idle/고아)로도 후보 금지.
    # 나이를 알 수 없으면 보수적으로 보존한다.
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
# 7. 텔레그램 알림
# ════════════════════════════════════════════════════════════════════
send_telegram() {
  local text="$1"
  [[ -z "$SET_TG_TOKEN" || -z "$SET_TG_CHAT" ]] && {
    tracker_log "텔레그램 발송 생략 — token 또는 chatId 미설정"
    return 1
  }
  # JSON escape (제어문자/따옴표/역슬래시)
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
  tracker_log "텔레그램 발송 실패"
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
      msg="🧹 <b>MemoryReset (macOS) — 정리 후보 누적 알림</b>"$'\n\n'
      msg+="$(printf '정리 후보: <b>%d개</b> / <b>%.0f MB</b> (RAM 의 %.1f%%)' $count $mem_mb $ram_pct)"$'\n'
      msg+="· idle (${SET_IDLE_MIN}분+ 무활동): ${idle_n} 개"$'\n'
      msg+="· 고아 (부모 daemon 죽음): ${orph_n} 개"$'\n'
      msg+="$(printf '· 현재 가용 RAM: %.0f MB (%.1f%%)' $MEM_AVAIL_MB $MEM_PCT_FREE)"$'\n\n'
      msg+="미리보기: <code>./memoryreset.sh --idle-only --dry-run</code>"$'\n'
      msg+="즉시 정리: <code>./memoryreset.sh --idle-only --skip-confirmation</code>"
      if send_telegram "$msg"; then
        print -- "$now" > "$TRACKER_STATE_FILE" 2>/dev/null
        tracker_log "텔레그램 알림 발송됨 (candidates=$count)"
      fi
    else
      tracker_log "쿨다운 활성 — 알림 생략"
    fi
  fi
  print -- "$count"
}

# ════════════════════════════════════════════════════════════════════
# 8. 프로세스 종료 (SIGTERM → 대기 → SIGKILL)
# ════════════════════════════════════════════════════════════════════
stop_targets() {
  local -a targets=("$@")
  if (( ${#targets} == 0 )); then
    info "[i] 종료할 대상 프로세스가 없습니다."
    run_log "stop: no target processes"
    return 0
  fi

  run_log "stop: start targets=${#targets} dryRun=$DRY_RUN timeoutSec=$GRACEFUL_TIMEOUT_SEC"

  # 진행 중인 Codex 세션 보존 (Windows 판의 Get-ActiveCodexProtectedPids 대응)
  local -A protect
  local p
  load_settings
  read_state
  local now=$(date +%s)
  for p in $PROC_PIDS; do
    if is_codex_cli "${PROC_CMD[$p]}" && ! is_process_idle "$p" "$now"; then
      # 활동 이력이 있고 idle 이 아닌 codex → 트리 전체 보존
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
      ok " [SKIP] 진행 중인 Codex 세션 보존 → PID=$p"
      run_log "skip: active-codex pid=$p"
      continue
    fi
    if is_protected "${PROC_CMD[$p]:-}"; then
      ok " [SKIP] 보호 목록(protected) → PID=$p"
      run_log "skip: protected pid=$p"
      continue
    fi
    filtered+=("$p")
  done
  targets=($filtered)
  if (( ${#targets} == 0 )); then
    info "[i] Codex 보존 후 종료할 대상이 없습니다."
    return 0
  fi

  say ""
  head1 "── [1/4] Graceful 종료 (SIGTERM) ──"
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
      info "  ·   이미 종료됨 → $tag"
      run_log "gone-before-term pid=$p"
    fi
  done

  (( DRY_RUN )) && { run_log "stop: dry-run complete"; return 0 }

  say ""
  head1 "── [2/4] ${GRACEFUL_TIMEOUT_SEC}초 대기 (저장/정리 시간 확보) ──"
  local i
  for (( i = GRACEFUL_TIMEOUT_SEC; i > 0; i-- )); do
    printf "\r 남은 시간: %2d 초 " $i
    sleep 1
  done
  printf "\r 대기 완료.            \n"

  say ""
  head1 "── [3/4] 잔존 프로세스 트리 강제 종료 (SIGKILL) ──"
  # 트리 재계산 — graceful 단계에서 자식이 새로 생겼거나 죽었을 수 있음
  snapshot_processes
  local -a survivors=()
  for p in $targets; do
    kill -0 "$p" 2>/dev/null && survivors+=("$p")
  done
  run_log "stop: survivors=${#survivors}"

  if (( ${#survivors} == 0 )); then
    ok " [OK] 모든 프로세스가 graceful 종료됨."
    run_log "stop: all closed gracefully"
    return 0
  fi

  for p in $survivors; do
    local tag="$(categorize "${PROC_CMD[$p]:-}") (PID=$p)"
    # 트리 kill — 자손 먼저, 그다음 root (Windows 의 taskkill /T 대응)
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
      info " [GONE] $tag (이미 종료됨)"
      run_log "sigkill-gone pid=$p"
    fi
  done
}

# ════════════════════════════════════════════════════════════════════
# 9. 메모리 회수
#
#    macOS 는 프로세스 종료 시 그 페이지를 즉시 free list 로 반환한다.
#    (Windows 의 Standby List 지연 회수 문제가 없음 — 3~5단계가 불필요)
#    남는 것은 파일 캐시(Cached Files) 이며 purge(8) 로 회수한다. sudo 필요.
# ════════════════════════════════════════════════════════════════════
run_purge() {
  if (( NO_PURGE )); then
    info " · purge(8) 생략 (--no-purge)"
    return 0
  fi
  if [[ ! -x /usr/sbin/purge ]]; then
    warn " · purge(8) 없음 — 건너뜀 (Xcode Command Line Tools 필요)"
    return 1
  fi

  printf " · 파일 캐시 회수 (purge) ..."
  if [[ $EUID -eq 0 ]]; then
    if /usr/sbin/purge 2>/dev/null; then ok " [OK]"; return 0; fi
    warn " [!] 실패"; return 1
  fi

  # sudo 자격이 이미 캐시돼 있으면 프롬프트 없이 실행
  if sudo -n true 2>/dev/null; then
    if sudo -n /usr/sbin/purge 2>/dev/null; then ok " [OK]"; return 0; fi
    warn " [!] 실패"; return 1
  fi

  if (( SKIP_CONFIRMATION )); then
    # 무인 실행(launchd) 중 비밀번호 프롬프트를 띄우면 영원히 멈춘다.
    say ""
    info "   [skip] sudo 자격 없음 — 무인 모드라 프롬프트 생략."
    info "          암호 없이 쓰려면 sudoers 등록: README-macOS.md 의 'purge 를 암호 없이' 참고"
    return 1
  fi

  say ""
  info "   purge(8) 는 관리자 권한이 필요합니다 (파일 캐시 회수). Ctrl-C 로 건너뛸 수 있습니다."
  if sudo /usr/sbin/purge; then ok "   [OK] 파일 캐시 회수 완료"; return 0; fi
  warn "   [!] purge 실패 또는 취소 — 프로세스 종료분은 이미 회수됨"
  return 1
}

invoke_memory_recovery() {
  say ""
  head1 "── [4/4] 메모리 회수 ──"
  if (( DRY_RUN )); then
    info " [DRY] purge(8) 호출 예정"
    return 0
  fi
  info " · macOS 는 종료된 프로세스의 메모리를 즉시 반환합니다 (Windows 의 Standby List 지연 없음)"
  run_purge
}

invoke_deep_recovery() {
  say ""
  head1 "── [Deep] 추가 회수 ──"
  if (( DRY_RUN )); then
    info " [DRY] DNS 캐시 flush 호출 예정"
    return 0
  fi

  printf " · DNS 캐시 flush ..."
  local dns_ok=0
  if [[ $EUID -eq 0 ]]; then
    dscacheutil -flushcache 2>/dev/null && killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  elif sudo -n true 2>/dev/null; then
    sudo -n dscacheutil -flushcache 2>/dev/null && sudo -n killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  elif (( ! SKIP_CONFIRMATION )); then
    say ""
    sudo dscacheutil -flushcache 2>/dev/null && sudo killall -HUP mDNSResponder 2>/dev/null && dns_ok=1
  fi
  (( dns_ok )) && ok " [OK]" || warn " [skip] sudo 자격 없음"

  info " · Memory Compression: macOS 는 압축 store 를 flush 하는 공개 API 가 없습니다 (Windows 의 MMAgent 대응물 없음)"
}

invoke_shell_restart() {
  say ""
  head1 "── [Deep+Shell] Finder / Dock 재시작 ──"
  warn "  ! Finder 창이 닫히고 Dock 이 잠시 사라집니다 (launchd 가 자동 재시작)"
  if (( DRY_RUN )); then
    info " [DRY] killall Finder / killall Dock 예정"
    return 0
  fi
  printf " · Finder 재시작 ..."
  killall Finder 2>/dev/null && ok " [OK]" || info " [skip] 실행 중 아님"
  printf " · Dock 재시작 ..."
  killall Dock 2>/dev/null && ok " [OK]" || info " [skip] 실행 중 아님"
}

# ════════════════════════════════════════════════════════════════════
# 10. CSV 회수 이력
# ════════════════════════════════════════════════════════════════════
write_recovery_log() {
  local mode="$1" total="$2" before_free="$3" after_free="$4"
  local before_pct="$5" after_pct="$6" killed="$7" runtime="$8"

  if [[ ! -f "$HISTORY_CSV" ]]; then
    print -r -- 'Timestamp,Mode,TotalMB,UsedBeforeMB,UsedAfterMB,FreedMB,BeforeFreeMB,AfterFreeMB,BeforePctFree,AfterPctFree,FreedPctP,ProcessesKilled,RuntimeSec' \
      > "$HISTORY_CSV" 2>/dev/null || { warn " [!] CSV 이력 기록 실패"; return 1 }
  fi
  local used_before=$(( total - before_free ))
  local used_after=$(( total - after_free ))
  printf '%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f,%.2f,%d,%.1f\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" "$total" "$used_before" "$used_after" \
    "$(( used_before - used_after ))" "$before_free" "$after_free" \
    "$before_pct" "$after_pct" "$(( after_pct - before_pct ))" "$killed" "$runtime" \
    >> "$HISTORY_CSV" 2>/dev/null || warn " [!] CSV 이력 기록 실패"
}

# ════════════════════════════════════════════════════════════════════
# 11. 진단 (--diagnose)
# ════════════════════════════════════════════════════════════════════
show_zombie_analysis() {
  say ""
  head1 "── 좀비 분석 (Zombie Analysis) ──"
  info "   macOS 는 부모가 죽으면 자식이 launchd(PID 1) 로 재부모화됩니다."
  info "   → claude helper(bg-spare/bg-pty-host)가 PPID=1 이면 daemon 이 죽은 고아입니다."
  info "   → claude daemon 자신이 PPID=1 인 것은 정상입니다 (원래 detach 된 데몬)."

  local -a orphans=() alive=()
  local p
  for p in $TARGET_PIDS; do
    if is_orphan "$p"; then orphans+=("$p"); else alive+=("$p"); fi
  done

  say ""
  if (( ${#orphans} > 0 )); then
    local total=0
    for p in $orphans; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    err "$(printf ' [!] 확실한 고아: %d개 / %.0f MB' ${#orphans} $total)"
    for p in ${orphans[1,8]}; do
      printf "     ${C_GRAY}PID=%-7s PPID=%-6s RSS=%7.0f MB  %s${C_RESET}\n" \
        "$p" "${PROC_PPID[$p]}" "$(( ${PROC_RSS[$p]:-0} / 1024.0 ))" "$(categorize "${PROC_CMD[$p]}")"
    done
    (( ${#orphans} > 8 )) && info "     ... 외 $(( ${#orphans} - 8 ))개"
    warn "    → 안전 종료:  ./memoryreset.sh --orphans-only"
  else
    ok " [OK] 부모 죽은 고아 없음"
  fi

  if (( ${#alive} > 0 )); then
    local total=0
    for p in $alive; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    say ""
    warn "$(printf ' [i] 부모 살아있는 대상: %d개 / %.0f MB' ${#alive} $total)"
    info "     → 활성 세션일 수 있음. --idle-only (무활동만) 또는 --interactive (선택) 권장"
  fi
}

show_diagnostics() {
  say ""
  print -r -- "${C_MAGENTA}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  print -r -- "${C_MAGENTA}║                메모리 진단 (Diagnostics)                  ║${C_RESET}"
  print -r -- "${C_MAGENTA}╚══════════════════════════════════════════════════════════╝${C_RESET}"

  show_memory_status "메모리 분포"

  say ""
  head1 "── 메모리 압박 (Memory Pressure) ──"
  local mp
  mp=$(memory_pressure 2>/dev/null | grep -i 'free percentage' | head -1)
  [[ -n "$mp" ]] && info " · $mp" || info " · (memory_pressure 조회 불가)"
  local swap
  swap=$(sysctl -n vm.swapusage 2>/dev/null)
  [[ -n "$swap" ]] && info " · swap: $swap"

  say ""
  head1 "── 점유 상위 프로세스 Top 15 (RSS 기준) ──"
  local line
  while IFS= read -r line; do
    print -r -- " · $line"
  done < <(ps -axo rss=,pid=,comm= 2>/dev/null | sort -rn | head -15 | \
           awk '{ rss=$1/1024; pid=$2; $1=""; $2=""; sub(/^  /,""); printf "%-52.52s PID=%-7s RSS=%8.0f MB\n", $0, pid, rss }')

  say ""
  head1 "── 종료 대상 프로세스 (Claude/Codex CLI) ──"
  if (( ${#TARGET_PIDS} == 0 )); then
    info " (없음)"
  else
    local total=0 p
    for p in $TARGET_PIDS; do total=$(( total + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    printf " · 총 %d 개 프로세스 / RSS 합계 %.0f MB 회수 가능\n" ${#TARGET_PIDS} $total
  fi

  # 보존 확인 — Claude Desktop / 자기 조상
  say ""
  head1 "── 보존 확인 (안전성 검증) ──"
  local -a desktop=()
  for p in $PROC_PIDS; do
    [[ "${PROC_CMD[$p]}" == /Applications/Claude.app/* ]] && desktop+=("$p")
  done
  if (( ${#desktop} > 0 )); then
    local dtotal=0
    for p in $desktop; do dtotal=$(( dtotal + ${PROC_RSS[$p]:-0} / 1024.0 )); done
    ok "$(printf ' [보존] Claude Desktop 앱: %d개 / %.0f MB — 종료 대상 아님' ${#desktop} $dtotal)"
  else
    info " · Claude Desktop 앱 미실행"
  fi
  ok " [보존] 자기 자신 + 조상 체인: ${(k)SELF_CHAIN} — 종료 대상 아님"

  show_zombie_analysis

  say ""
  print -r -- "${C_MAGENTA}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  print -r -- "${C_MAGENTA}║  진단 완료. 회수하려면 --diagnose 없이 재실행.            ║${C_RESET}"
  print -r -- "${C_MAGENTA}╚══════════════════════════════════════════════════════════╝${C_RESET}"
}

# ════════════════════════════════════════════════════════════════════
# 12. Main
#
# MEMORYRESET_LIB_ONLY=1 로 source 하면 함수만 로드하고 종료한다.
# test-patterns.sh 가 판별 규칙(is_claude_cli / is_blacklisted / is_orphan 등)을
# 합성 입력으로 검증하기 위해 사용한다.
# ════════════════════════════════════════════════════════════════════
if [[ "${MEMORYRESET_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

START_TS=$(date +%s)
load_settings
snapshot_processes
build_self_chain

# ── --track-activity: 추적 1-tick (배너/UI 없이, kill 없이) ──────────
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
print -r -- "${C_CYAN}║   graceful kill + 자손 트리 정리 + 파일 캐시 purge       ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

(( DRY_RUN ))       && print -r -- "${C_MAGENTA}[i] DRY-RUN 모드 — 실제 종료/회수 없음${C_RESET}"
(( DIAGNOSE ))      && print -r -- "${C_MAGENTA}[i] DIAGNOSE 모드 — 진단만 (read-only)${C_RESET}"
(( DEEP ))          && print -r -- "${C_MAGENTA}[i] DEEP 모드 — purge + DNS 캐시 flush 추가${C_RESET}"
(( ORPHANS_ONLY ))  && print -r -- "${C_MAGENTA}[i] ORPHANS-ONLY 모드 — 부모 죽은 helper 만 대상${C_RESET}"
(( IDLE_ONLY ))     && print -r -- "${C_MAGENTA}[i] IDLE-ONLY 모드 — ${SET_IDLE_MIN}분+ 무활동 / 고아만 대상${C_RESET}"
(( INTERACTIVE ))   && print -r -- "${C_MAGENTA}[i] INTERACTIVE 모드 — 종료 전 PID 별 보존 선택${C_RESET}"
(( INCLUDE_SHELL )) && print -r -- "${C_YELLOW}[!] SHELL 재시작 모드 — Finder/Dock 이 재시작됩니다${C_RESET}"

get_targets

if (( DIAGNOSE )); then
  run_log "diagnose: start"
  show_diagnostics
  run_log "diagnose: complete"
  exit 0
fi

show_memory_status "현재 메모리 상태"
before_total=$MEM_TOTAL_MB
before_free=$MEM_AVAIL_MB
before_pct=$MEM_PCT_FREE

say ""
head1 "── 종료 대상 프로세스 ──"
(( INCLUDE_DESCENDANTS )) && print -r -- "${C_MAGENTA}[i] INCLUDE-DESCENDANTS — 자손 트리(부산물)도 함께 종료${C_RESET}"

# ── --idle-only: 추적 기반 후보로만 한정 ─────────────────────────────
if (( IDLE_ONLY )); then
  # 부팅 후 워밍업 — 유휴 관측이 idleMinutes 만큼 쌓이기 전에는 스윕하지 않는다.
  # (재부팅 직후 방어 전용 — 잠자기 기상은 kern.boottime 이 안 바뀌므로
  #  update_activity_state 의 관측 공백 보정이 담당한다)
  now_ts=$(date +%s)
  # sed 는 콤마 앵커 필수: greedy .* 가 "usec = " 안의 "sec = " 에 재매칭돼
  # 마이크로초를 캡처하는 버그가 있었다 (가드 전체가 조용히 무력화됨)
  boot_sec=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*\{ *sec = ([0-9]+),.*/\1/')
  if [[ "$boot_sec" =~ '^[0-9]+$' ]] && (( now_ts - boot_sec < SET_IDLE_MIN * 60 )); then
    uptime_min=$(( (now_ts - boot_sec) / 60 ))
    info " [i] 부팅 후 ${uptime_min}분 — 워밍업(${SET_IDLE_MIN}분) 전이므로 idle 정리를 건너뜁니다."
    run_log "targets: skipped boot-warmup uptimeMin=$uptime_min idleMinutes=$SET_IDLE_MIN"
    run_log "=== run complete (boot-warmup skip) ==="
    exit 0
  fi
  # 관측은 스윕을 건너뛰더라도 항상 갱신 — 트래커가 죽어있어도 90분마다
  # 이 경로가 이력을 쌓아줘야 idle 판정이 성립한다
  update_activity_state
  # 메모리 여유 게이트 — 가용 RAM 이 충분하면 죽일 이유가 없다.
  if (( MEM_PCT_FREE >= SET_MIN_FREE_PCT )); then
    info "$(printf ' [i] 가용 RAM %.1f%% ≥ 게이트 %s%% — idle 정리를 건너뜁니다.' $MEM_PCT_FREE $SET_MIN_FREE_PCT)"
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
    info " [i] idle/고아 후보 없음 — 추적 이력이 ${SET_IDLE_MIN}분 이상 누적돼야 idle 판정됩니다."
    info "     (launchd 추적 에이전트가 돌고 있는지 확인: ./install-launchd.sh --status)"
  fi
fi

run_log "targets: finalCount=${#TARGET_PIDS}"
for p in $TARGET_PIDS; do
  run_log "target: pid=$p ppid=${PROC_PPID[$p]} cat=$(categorize "${PROC_CMD[$p]}") idleMin=${CAND_IDLEMIN[$p]:--} rssKB=${PROC_RSS[$p]} cmd=${PROC_CMD[$p]}"
done

if (( ${#TARGET_PIDS} == 0 )); then
  info " (대상 없음 — 캐시 회수만 수행됩니다)"
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
    printf "\n${C_YELLOW}  ▶ [%s]  %d개  /  %.1f MB${C_RESET}\n" "$c" "${cat_count[$c]}" "${cat_mb[$c]}"
    shown=0
    for p in $TARGET_PIDS; do
      [[ "$(categorize "${PROC_CMD[$p]}")" == "$c" ]] || continue
      (( shown >= 3 )) && continue
      pmb=$(( ${PROC_RSS[$p]:-0} / 1024.0 ))
      cmdshort="${PROC_CMD[$p]}"
      (( ${#cmdshort} > 66 )) && cmdshort="${cmdshort[1,63]}..."
      orphan_tag=""
      is_orphan "$p" && orphan_tag=" ${C_RED}[고아]${C_RESET}"
      printf "     ${C_GRAY}PID=%-7s RSS=%7.0f MB  %s${C_RESET}%s\n" "$p" "$pmb" "$cmdshort" "$orphan_tag"
      (( shown++ ))
    done
    (( ${cat_count[$c]} > 3 )) && info "     ... 외 $(( ${cat_count[$c]} - 3 ))개"
  done
  say ""
  printf "${C_CYAN} ── 총 합계: %.1f MB  (%d 개 프로세스)${C_RESET}\n" $grand_total ${#TARGET_PIDS}

  # 보존 확인 표시 (안전성 검증)
  desktop_n=0; desktop_mb=0
  for p in $PROC_PIDS; do
    if [[ "${PROC_CMD[$p]}" == /Applications/Claude.app/* ]]; then
      (( desktop_n++ )); desktop_mb=$(( desktop_mb + ${PROC_RSS[$p]:-0} / 1024.0 ))
    fi
  done
  (( desktop_n > 0 )) && printf "${C_GREEN} ── 보존 (종료 안 함): Claude Desktop 앱 %d개 / %.1f MB${C_RESET}\n" $desktop_n $desktop_mb
  printf "${C_GREEN} ── 보존 (종료 안 함): 자기 조상 체인 %d개 (이 스크립트를 실행한 세션)${C_RESET}\n" ${#SELF_CHAIN}
fi

# ── --interactive: 보존 PID 선택 ─────────────────────────────────────
if (( INTERACTIVE )) && (( ! DRY_RUN )) && (( ${#TARGET_PIDS} > 0 )); then
  say ""
  head1 "── [Interactive] 보존할 PID 선택 ──"
  info "  위 목록에서 살릴 PID 를 콤마로 입력. 빈 입력 = 전부 종료"
  printf "  보존할 PID (예: 1234,5678): "
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
      ok " [i] 보존: ${#keep_set}개 PID — 남은 종료 대상: ${#TARGET_PIDS}개"
      run_log "interactive: preserved=${#keep_set} remaining=${#TARGET_PIDS}"
    fi
  else
    info " [i] 보존 PID 없음 — 전부 종료 진행."
  fi
fi

# ── 확인 프롬프트 ────────────────────────────────────────────────────
if (( ! SKIP_CONFIRMATION )) && (( ! DRY_RUN )) && (( ${#TARGET_PIDS} > 0 )); then
  say ""
  printf "위 프로세스를 종료하고 메모리를 회수할까요? [Y/n] "
  read -r confirm
  if [[ "$confirm" == [nN]* ]]; then
    info "[i] 사용자 취소."
    run_log "run cancelled by user"
    exit 0
  fi
fi

stop_targets $TARGET_PIDS
invoke_memory_recovery
(( DEEP ))          && invoke_deep_recovery
(( INCLUDE_SHELL )) && invoke_shell_restart

show_memory_status "회수 후 메모리 상태"

if (( ! DRY_RUN )); then
  recovered=$(( MEM_AVAIL_MB - before_free ))
  pct_change=$(( MEM_PCT_FREE - before_pct ))
  sign=""; (( recovered >= 0 )) && sign="+"
  say ""
  print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  printf "${C_GREEN} 회수된 RAM: %s%.0f MB   (%s%.1f%%p)${C_RESET}\n" "$sign" $recovered "$sign" $pct_change
  print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

  mode_tag=basic
  (( DEEP ))                       && mode_tag=deep
  (( DEEP && INCLUDE_SHELL ))      && mode_tag=deep+shell
  (( IDLE_ONLY ))                  && mode_tag=idle
  (( ORPHANS_ONLY ))               && mode_tag=orphans
  elapsed=$(( $(date +%s) - START_TS ))
  write_recovery_log "$mode_tag" "$before_total" "$before_free" "$MEM_AVAIL_MB" \
                     "$before_pct" "$MEM_PCT_FREE" "${#TARGET_PIDS}" "$elapsed"
  info " [i] 회수 이력 기록: recovery-history.csv (실행 ${elapsed}초)"
  run_log "recovery: mode=$mode_tag targets=${#TARGET_PIDS} recoveredMB=$recovered elapsedSec=$elapsed"
fi
run_log "=== run complete ==="
