#!/bin/zsh
# Diagnose only (read-only) — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --diagnose
echo ""
echo "[i] Complete. You can close this window."
