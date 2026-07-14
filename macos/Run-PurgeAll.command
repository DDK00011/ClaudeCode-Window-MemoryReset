#!/bin/zsh
# Full cleanup (including descendants + deep recovery) — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --deep --include-descendants
echo ""
echo "[i] Complete. You can close this window."
