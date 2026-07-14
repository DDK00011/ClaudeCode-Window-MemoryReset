#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# 다른 맥에 설치 — 원포인트 부트스트랩.
#
#   ./setup.sh                  환경 점검 + 실행권한 + 테스트 + 진단
#   ./setup.sh --with-menubar   위 + 메뉴 막대 앱 빌드/실행
#   ./setup.sh --with-launchd   위 + 백그라운드 추적 에이전트 등록 (읽기 전용)
#   ./setup.sh --all            전부
#
# 이 스크립트는 아무 프로세스도 종료하지 않는다. 정리는 진단 결과를 보고
# 사용자가 직접 실행한다.
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
    *) bad "알 수 없는 옵션: $1"; exit 1 ;;
  esac
  shift
done

print -r -- "${C_CYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
print -r -- "${C_CYAN}║   MemoryReset (macOS) — 설치 점검                         ║${C_RESET}"
print -r -- "${C_CYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"

FATAL=0

# ── 1. 환경 ─────────────────────────────────────────────────────────
head1 "[1/5] 환경 점검"
os_ver=$(sw_vers -productVersion 2>/dev/null)
if [[ -z "$os_ver" ]]; then
  bad "macOS 가 아닙니다. 이 포팅은 macOS 전용입니다."
  info "Windows 는 저장소 루트의 MemoryReset.ps1 을 쓰세요."
  exit 1
fi
ok "macOS $os_ver ($(uname -m))"

if [[ "${os_ver%%.*}" -lt 12 ]]; then
  warn "macOS 12 미만 — 메뉴 막대 앱이 동작하지 않을 수 있습니다 (CLI 는 정상)"
fi

[[ -x /bin/zsh ]] && ok "zsh $(/bin/zsh --version | awk '{print $2}')" || { bad "/bin/zsh 없음"; FATAL=1 }

for t in /usr/bin/vm_stat /usr/sbin/sysctl /usr/bin/plutil; do
  [[ -x "$t" ]] || { bad "필수 도구 없음: $t"; FATAL=1 }
done
(( FATAL == 0 )) && ok "필수 도구 (vm_stat / sysctl / plutil)"

if [[ -x /usr/sbin/purge ]]; then
  ok "purge(8) 사용 가능 ${C_GRAY}(--deep 의 파일 캐시 회수. sudo 필요, --no-purge 로 생략 가능)${C_RESET}"
else
  warn "purge(8) 없음 — --deep 의 캐시 회수만 건너뜁니다. 프로세스 정리는 정상 동작"
fi

if command -v swiftc >/dev/null 2>&1; then
  ok "swiftc 사용 가능 (메뉴 막대 앱 빌드 가능)"
else
  warn "swiftc 없음 — 메뉴 막대 앱은 빌드 불가 (선택 사항). 필요하면: xcode-select --install"
  info "CLI 기능은 전부 정상 동작합니다."
fi

(( FATAL )) && { bad "필수 요건 미충족 — 중단합니다."; exit 1 }

# ── 2. 파일 권한 / 격리 속성 ────────────────────────────────────────
head1 "[2/5] 파일 권한 / 격리 속성"
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.command 2>/dev/null
ok "실행 권한 설정 완료"

# GitHub 에서 zip 으로 받으면 com.apple.quarantine 이 붙어 .command 더블클릭이 막힌다.
# git clone 으로 받았으면 붙지 않는다.
if xattr -p com.apple.quarantine "$SCRIPT_DIR/memoryreset.sh" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null
  ok "격리 속성(quarantine) 제거 — zip 다운로드본이었습니다"
else
  ok "격리 속성 없음 (git clone 본)"
fi

# ── 3. 안전 규칙 검증 ───────────────────────────────────────────────
head1 "[3/5] 안전 규칙 검증 (프로세스를 건드리지 않음)"
if ./test-patterns.sh >/tmp/memoryreset-setup-test.log 2>&1; then
  ok "$(grep -o '전체 통과: [0-9]*개' /tmp/memoryreset-setup-test.log)"
  info "Claude Desktop 보존 / IDE 본체 보존 / 고아 판정 / 분류 규칙 검증됨"
else
  bad "테스트 실패 — 안전 규칙에 문제가 있습니다. 정리를 실행하지 마세요."
  tail -20 /tmp/memoryreset-setup-test.log
  exit 1
fi

# ── 4. 이 맥의 실제 상황 진단 ───────────────────────────────────────
head1 "[4/5] 이 맥의 Claude/Codex CLI 현황"
target_line=$(./memoryreset.sh --diagnose 2>/dev/null | grep -A1 '종료 대상 프로세스' | tail -1)
print -r -- "  ${target_line#* }"

n_targets=$(./memoryreset.sh --dry-run 2>/dev/null | grep -oE '\(([0-9]+) 개 프로세스\)' | grep -oE '[0-9]+' | head -1)
: ${n_targets:=0}

if (( n_targets == 0 )); then
  warn "종료 대상이 0개입니다."
  info "정상일 수 있습니다 (누적된 잔존 프로세스가 없음)."
  info "하지만 claude 를 쓰고 있는데도 0개라면, 이 맥의 설치 형태가 다를 수 있습니다."
  info "확인:  ps -axo pid,ppid,rss,command | grep -i claude | grep -v grep"
  info "설치 경로가 README-macOS.md 의 '종료 대상 식별 규칙' 과 다르면 알려주세요."
else
  ok "${n_targets}개 대상 식별됨 — 아래 순서로 진행하세요"
fi

# ── 5. 선택 구성요소 ────────────────────────────────────────────────
if (( WITH_MENUBAR )); then
  head1 "[5/5] 메뉴 막대 앱"
  if command -v swiftc >/dev/null 2>&1; then
    ./build-menubar.sh --run >/dev/null 2>&1 && ok "빌드 + 실행 완료 — 화면 우측 상단 확인" \
      || bad "빌드 실패 — ./build-menubar.sh 를 직접 실행해 오류를 확인하세요"
  else
    warn "swiftc 가 없어 건너뜁니다"
  fi
fi

if (( WITH_LAUNCHD )); then
  head1 "[5/5] 백그라운드 추적 에이전트"
  ./install-launchd.sh >/dev/null 2>&1 && {
    ok "tracker 등록 (5분 주기, 읽기 전용 — 절대 종료 안 함)"
    warn "cleanup 에이전트(3시간마다 무인 종료)도 함께 등록되었습니다."
    info "무인 종료를 원치 않으면:  launchctl bootout gui/\$UID/com.claudecode.memoryreset.cleanup"
    info "                          rm ~/Library/LaunchAgents/com.claudecode.memoryreset.cleanup.plist"
  } || bad "등록 실패 — ./install-launchd.sh 를 직접 실행해 오류를 확인하세요"
fi

# ── 다음 단계 ───────────────────────────────────────────────────────
head1 "다음 단계 (이 순서를 지키세요)"
say "  1) 무엇이 죽는지 먼저 본다      ${C_GRAY}./memoryreset.sh --dry-run${C_RESET}"
say "  2) 가장 안전한 정리 (고아만)    ${C_GRAY}./memoryreset.sh --orphans-only${C_RESET}"
say "  3) 깊은 회수 (캐시 purge 포함)  ${C_GRAY}./memoryreset.sh --deep${C_RESET}"
say ""
say "  ${C_YELLOW}주의${C_RESET}: 옵션 없는 ${C_GRAY}./memoryreset.sh${C_RESET} 는 활성 세션을 포함해 ${C_BOLD}모든${C_RESET} CLI 를 종료합니다"
say "        (Y/n 확인은 표시됩니다). 활성 세션을 살리려면 --orphans-only / --idle-only / --interactive."
say ""
say "  자세한 내용: ${C_GRAY}README-macOS.md${C_RESET}"
