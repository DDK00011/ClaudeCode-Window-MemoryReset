#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# launchd LaunchAgent 등록/해제 — Windows 작업 스케줄러(Track-Schedule.ps1 /
# Cleanup-Schedule.ps1) 대응.
#
#   1) tracker  : trackIntervalMin 간격으로 --track-activity 실행
#                 (CPU 스냅샷 기록 + 임계 초과 시 텔레그램 알림. 절대 종료 안 함)
#   2) cleanup  : IntervalHours(기본 3) 간격으로 --idle-only 실행
#                 (idle/고아만 종료. 활성 세션 보존)
#
# Windows 와의 결정적 차이: 프로세스 종료에 관리자 권한이 필요 없다 (같은 사용자 소유).
# 따라서 UAC 승격에 해당하는 절차가 없고, LaunchAgent 는 평범한 사용자 권한으로 돈다.
# cleanup 은 무인 실행이라 sudo 프롬프트가 뜨면 영원히 멈추므로 --no-purge 로 등록한다.
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
# cleanup 실행 간격은 분 단위로 보관한다 — 시간 단위(정수)만 받으면 90분 같은 값을
# 표현할 수 없다. --interval-hours 는 하위호환으로 남겨두고 내부에서 분으로 환산한다.
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
사용법: ./install-launchd.sh [옵션]

  (옵션 없음)             tracker + cleanup LaunchAgent 등록
  --remove                둘 다 해제
  --status                등록/실행 상태 확인
  --interval-min N        cleanup 실행 간격 (분). 기본 180 (=3시간). 예: 90 → 1시간 30분
  --interval-hours N      같은 뜻의 시간 단위 (정수만). --interval-min 이 더 정밀

등록되는 것:
  com.claudecode.memoryreset.tracker  — trackIntervalMin(기본 5분) 간격, CPU 스냅샷 + 알림
  com.claudecode.memoryreset.cleanup  — N시간(기본 3) 간격, idle/고아만 종료

sudo 불필요 — LaunchAgent 는 사용자 권한으로 실행됩니다.
EOF
      exit 0 ;;
    *) err "[X] 알 수 없는 옵션: $1"; exit 1 ;;
  esac
  shift
done

[[ "$CLEANUP_INTERVAL_MIN" =~ '^[0-9]+$' ]] || { err "[X] 간격은 정수(분)여야 합니다"; exit 1 }
(( CLEANUP_INTERVAL_MIN < 5 )) && {
  warn "[!] 간격이 너무 짧습니다 (${CLEANUP_INTERVAL_MIN}분) — 최소 5분으로 올립니다"
  CLEANUP_INTERVAL_MIN=5
}

# launchctl bootstrap/bootout (최신) → load/unload (구버전) 폴백
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

# ── 해제 ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == remove ]]; then
  for pair in "$TRACKER_PLIST:$TRACKER_LABEL" "$CLEANUP_PLIST:$CLEANUP_LABEL"; do
    plist="${pair%:*}"; label="${pair##*:}"
    if [[ -f "$plist" ]]; then
      lc_unload "$plist" "$label"
      rm -f "$plist"
      ok "[OK] 해제됨: $label"
    else
      info "[i] 등록되어 있지 않음: $label"
    fi
  done
  exit 0
fi

# ── 상태 ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == status ]]; then
  head1 "── LaunchAgent 상태 ──"
  for pair in "$TRACKER_PLIST:$TRACKER_LABEL" "$CLEANUP_PLIST:$CLEANUP_LABEL"; do
    plist="${pair%:*}"; label="${pair##*:}"
    if [[ -f "$plist" ]]; then
      if launchctl list 2>/dev/null | grep -q "$label"; then
        ok "[실행중] $label"
      else
        warn "[등록됨/미실행] $label"
      fi
      info "         plist: $plist"
    else
      info "[미등록] $label"
    fi
  done
  state_file="$SCRIPT_DIR/activity-state.tsv"
  say ""
  head1 "── 추적 상태 ──"
  if [[ -f "$state_file" ]]; then
    n=$(wc -l < "$state_file" | tr -d ' ')
    ok "[OK] activity-state.tsv — 추적 중인 프로세스 ${n}개"
    info "     최종 갱신: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$state_file" 2>/dev/null)"
  else
    warn "[!] activity-state.tsv 없음 — 아직 추적 tick 이 돌지 않았습니다"
  fi
  [[ -f "$SCRIPT_DIR/tracker.log" ]] && { say ""; head1 "── tracker.log (마지막 5줄) ──"; tail -5 "$SCRIPT_DIR/tracker.log" }
  exit 0
fi

# ── 등록 ─────────────────────────────────────────────────────────────
[[ -x "$MAIN" ]] || { err "[X] memoryreset.sh 를 찾을 수 없거나 실행 권한이 없습니다: $MAIN"; exit 1 }
mkdir -p "$AGENT_DIR" || { err "[X] $AGENT_DIR 생성 실패"; exit 1 }

# trackIntervalMin 을 설정에서 읽음 (기본 5)
INTERVAL_MIN=5
CFG="$SCRIPT_DIR/tracker-settings.json"
if [[ -f "$CFG" ]]; then
  v=$(plutil -extract trackIntervalMin raw -o - "$CFG" 2>/dev/null)
  [[ "$v" =~ '^[0-9]+$' ]] && (( v >= 1 )) && INTERVAL_MIN=$v
fi

write_plist() {
  # write_plist <out_path> <label> <interval-seconds> <args...>
  # 주의: 지역변수 이름으로 `path` 를 쓰면 안 된다 — zsh 에서 `path` 는 $PATH 와
  # 연동된 특수 배열이라, 덮어쓰는 순간 이 함수 안에서 cat/plutil 등을 못 찾는다.
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

# 1) tracker — read-only, 종료 안 함
write_plist "$TRACKER_PLIST" "$TRACKER_LABEL" $(( INTERVAL_MIN * 60 )) "--track-activity"
plutil -lint "$TRACKER_PLIST" >/dev/null 2>&1 || { err "[X] tracker plist 생성 실패"; exit 1 }
lc_load "$TRACKER_PLIST" "$TRACKER_LABEL"
ok "[OK] 추적 등록: $TRACKER_LABEL"
info "     → ${INTERVAL_MIN}분 간격 --track-activity (CPU 스냅샷 + 임계 시 텔레그램 알림)"
info "     → 절대 프로세스를 종료하지 않습니다 (read-only)"

# 2) cleanup — idle/고아만 종료. 무인이므로 --no-purge (sudo 프롬프트 방지)
write_plist "$CLEANUP_PLIST" "$CLEANUP_LABEL" $(( CLEANUP_INTERVAL_MIN * 60 )) \
  "--idle-only" "--skip-confirmation" "--no-purge"
plutil -lint "$CLEANUP_PLIST" >/dev/null 2>&1 || { err "[X] cleanup plist 생성 실패"; exit 1 }
lc_load "$CLEANUP_PLIST" "$CLEANUP_LABEL"
ok "[OK] 자동 정리 등록: $CLEANUP_LABEL"
if (( CLEANUP_INTERVAL_MIN % 60 == 0 )); then
  info "     → $(( CLEANUP_INTERVAL_MIN / 60 ))시간 간격 --idle-only (idle/고아만 종료, 활성 세션 보존)"
else
  info "     → ${CLEANUP_INTERVAL_MIN}분 간격 ($(( CLEANUP_INTERVAL_MIN / 60 ))시간 $(( CLEANUP_INTERVAL_MIN % 60 ))분) --idle-only (idle/고아만 종료, 활성 세션 보존)"
fi
info "     → --no-purge: 무인 실행 중 sudo 프롬프트로 멈추는 것을 방지"
info "        (프로세스 종료 자체는 sudo 가 필요 없어 정상 동작합니다)"

say ""
head1 "── 다음 단계 ──"
info " 상태 확인:   ./install-launchd.sh --status"
info " 해제:        ./install-launchd.sh --remove"
info " 미리보기:    ./memoryreset.sh --idle-only --dry-run"
info ""
info " idle 판정에는 추적 이력이 idleMinutes(기본 60분) 이상 누적돼야 합니다."
info " 그 전까지는 고아(부모 죽은 프로세스)만 정리됩니다."
