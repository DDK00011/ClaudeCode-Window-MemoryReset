#!/bin/zsh
# Deep recovery (purge + DNS flush) — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --deep
echo ""
echo "[i] Complete. You can close this window."
