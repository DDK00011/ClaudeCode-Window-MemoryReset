#!/bin/zsh
# Dry run (preview, no termination) — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --dry-run
echo ""
echo "[i] Complete. You can close this window."
