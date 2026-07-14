#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
# Menu bar app build — MenuBar.swift → MemoryResetMenuBar.app
#
# Equivalent to Windows Tray.bat / Tray-AutoStart-Register.bat.
# swiftc (Xcode Command Line Tools) is required. If unavailable, show installation instructions and
# explain that all features can be used from the CLI without the menu bar.
#
#   ./build-menubar.sh              build
#   ./build-menubar.sh --run        build and run immediately
#   ./build-menubar.sh --autostart  build + register auto start at login
#   ./build-menubar.sh --unregister unregister auto start
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
    *) err "[X] Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Unregister Auto Start ───────────────────────────────────────────────────
if (( DO_UNREGISTER )); then
  if [[ -f "$PLIST" ]]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
    rm -f "$PLIST"
    ok "[OK] Auto start unregistered: $LABEL"
  else
    info "[i] Not registered"
  fi
  pkill -f "$APP_NAME" 2>/dev/null && info "[i] Running menu bar app terminated"
  exit 0
fi

# ── Check swiftc ──────────────────────────────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
  err "[X] Cannot find swiftc — Xcode Command Line Tools is required."
  warn "    Install:  xcode-select --install"
  print -r -- ""
  info "    The menu bar app is optional. All features can be used from the CLI without it:"
  info "      ./memoryreset.sh --diagnose"
  info "      ./memoryreset.sh --orphans-only"
  info "      ./install-launchd.sh          (background tracking + auto cleanup)"
  exit 1
fi

[[ -f "$SRC" ]] || { err "[X] Cannot find MenuBar.swift: $SRC"; exit 1 }

# ── Build ─────────────────────────────────────────────────────────────
head1 "── Build Menu Bar App ──"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

printf " · Compiling swiftc ..."
if ! swiftc -O -o "$BIN" "$SRC" 2>/tmp/memoryreset-swiftc.err; then
  print -r -- ""
  err "[X] Compilation failed:"
  cat /tmp/memoryreset-swiftc.err
  exit 1
fi
ok " [OK]"

# ── Info.plist (LSUIElement=1 → Dock icon absent, menu bar only) ──
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
plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1 || { err "[X] Info.plist creation failed"; exit 1 }

# ── ad-hoc code signing (Gatekeeper warning mitigation, not distribution signing) ─────────
printf " · ad-hoc code signing ..."
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  ok " [OK]"
else
  warn " [skip] Signing failed — Execution is unaffected"
fi

ok "[OK] Build complete: $APP"

# ── Register Auto Start at Login ─────────────────────────────────────────
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
  plutil -lint "$PLIST" >/dev/null 2>&1 || { err "[X] LaunchAgent plist creation failed"; exit 1 }
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null
  ok "[OK] Auto start registered at login: $LABEL"
  info "     Unregister: ./build-menubar.sh --unregister"
  exit 0
fi

if (( DO_RUN )); then
  pkill -f "$APP_NAME" 2>/dev/null
  open "$APP"
  ok "[OK] Menu bar app launched — Check the menu bar at the top right of the screen"
  exit 0
fi

print -r -- ""
head1 "── Next Steps ──"
info " Run:         open $APP_NAME.app     (or ./build-menubar.sh --run)"
info " Auto start:  ./build-menubar.sh --autostart"
info " unregister:  ./build-menubar.sh --unregister"
