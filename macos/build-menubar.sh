#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# 메뉴바 앱 빌드 — MenuBar.swift → MemoryResetMenuBar.app
#
# Windows 판의 Tray.bat / Tray-AutoStart-Register.bat 대응.
# swiftc (Xcode Command Line Tools) 가 필요하다. 없으면 설치 방법을 안내하고
# 메뉴바 없이도 CLI 로 모든 기능을 쓸 수 있음을 알린다.
#
#   ./build-menubar.sh              빌드
#   ./build-menubar.sh --run        빌드 후 즉시 실행
#   ./build-menubar.sh --autostart  빌드 + 로그인 시 자동 시작 등록
#   ./build-menubar.sh --unregister 자동 시작 해제
# ════════════════════════════════════════════════════════════════════

emulate -L zsh
setopt no_nomatch

SCRIPT_DIR="${0:A:h}"
APP_NAME="MemoryResetMenuBar"
APP="$SCRIPT_DIR/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
SRC="$SCRIPT_DIR/MenuBar.swift"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.claudecode.memoryreset.menubar"
PLIST="$AGENT_DIR/$LABEL.plist"

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'; C_CYAN=$'\e[36m'
ok()   { print -r -- "${C_GREEN}$*${C_RESET}" }
warn() { print -r -- "${C_YELLOW}$*${C_RESET}" }
err()  { print -r -- "${C_RED}$*${C_RESET}" }
info() { print -r -- "${C_GRAY}$*${C_RESET}" }
head1(){ print -r -- "${C_CYAN}$*${C_RESET}" }

DO_RUN=0; DO_AUTOSTART=0; DO_UNREGISTER=0
while (( $# > 0 )); do
  case "$1" in
    --run)        DO_RUN=1 ;;
    --autostart)  DO_AUTOSTART=1 ;;
    --unregister) DO_UNREGISTER=1 ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) err "[X] 알 수 없는 옵션: $1"; exit 1 ;;
  esac
  shift
done

# ── 자동 시작 해제 ───────────────────────────────────────────────────
if (( DO_UNREGISTER )); then
  if [[ -f "$PLIST" ]]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
    rm -f "$PLIST"
    ok "[OK] 자동 시작 해제됨: $LABEL"
  else
    info "[i] 등록되어 있지 않음"
  fi
  pkill -f "$APP_NAME" 2>/dev/null && info "[i] 실행 중이던 메뉴바 앱 종료됨"
  exit 0
fi

# ── swiftc 확인 ──────────────────────────────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
  err "[X] swiftc 를 찾을 수 없습니다 — Xcode Command Line Tools 가 필요합니다."
  warn "    설치:  xcode-select --install"
  print -r -- ""
  info "    메뉴바 앱은 선택 사항입니다. 없어도 모든 기능을 CLI 로 쓸 수 있습니다:"
  info "      ./memoryreset.sh --diagnose"
  info "      ./memoryreset.sh --orphans-only"
  info "      ./install-launchd.sh          (백그라운드 추적 + 자동 정리)"
  exit 1
fi

[[ -f "$SRC" ]] || { err "[X] MenuBar.swift 를 찾을 수 없습니다: $SRC"; exit 1 }

# ── 빌드 ─────────────────────────────────────────────────────────────
head1 "── 메뉴바 앱 빌드 ──"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

printf " · swiftc 컴파일 ..."
if ! swiftc -O -o "$BIN" "$SRC" 2>/tmp/memoryreset-swiftc.err; then
  print -r -- ""
  err "[X] 컴파일 실패:"
  cat /tmp/memoryreset-swiftc.err
  exit 1
fi
ok " [OK]"

# ── Info.plist (LSUIElement=1 → Dock 아이콘 없이 메뉴 막대에만 상주) ──
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MemoryReset</string>
    <key>CFBundleDisplayName</key>       <string>MemoryReset</string>
    <key>CFBundleIdentifier</key>        <string>com.claudecode.memoryreset.menubar</string>
    <key>CFBundleVersion</key>           <string>1.4.1</string>
    <key>CFBundleShortVersionString</key><string>1.4.1</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1 || { err "[X] Info.plist 생성 실패"; exit 1 }

# ── ad-hoc 코드 서명 (Gatekeeper 경고 완화, 배포용 서명 아님) ─────────
printf " · ad-hoc 코드 서명 ..."
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  ok " [OK]"
else
  warn " [skip] 서명 실패 — 실행에는 지장 없습니다"
fi

ok "[OK] 빌드 완료: $APP"

# ── 로그인 시 자동 시작 등록 ─────────────────────────────────────────
if (( DO_AUTOSTART )); then
  mkdir -p "$AGENT_DIR"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>ProcessType</key>        <string>Interactive</string>
    <key>StandardErrorPath</key>  <string>$SCRIPT_DIR/menubar.err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null 2>&1 || { err "[X] LaunchAgent plist 생성 실패"; exit 1 }
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null
  ok "[OK] 로그인 시 자동 시작 등록됨: $LABEL"
  info "     해제: ./build-menubar.sh --unregister"
  exit 0
fi

if (( DO_RUN )); then
  pkill -f "$APP_NAME" 2>/dev/null
  open "$APP"
  ok "[OK] 메뉴바 앱 실행됨 — 화면 우측 상단 메뉴 막대를 확인하세요"
  exit 0
fi

print -r -- ""
head1 "── 다음 단계 ──"
info " 실행:        open $APP_NAME.app     (또는 ./build-menubar.sh --run)"
info " 자동 시작:   ./build-menubar.sh --autostart"
info " 해제:        ./build-menubar.sh --unregister"
