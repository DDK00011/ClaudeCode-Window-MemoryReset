#!/bin/zsh
# idle/orphan cleanup — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --idle-only
echo ""
echo "[i] Complete. You can close this window."
