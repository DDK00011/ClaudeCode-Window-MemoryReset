#!/bin/zsh
# idle/orphan cleanup preview — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --idle-only --dry-run
echo ""
echo "[i] Complete. You can close this window."
