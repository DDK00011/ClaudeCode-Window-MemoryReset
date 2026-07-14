#!/bin/zsh
# Safely clean up orphans only — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --orphans-only
echo ""
echo "[i] Complete. You can close this window."
