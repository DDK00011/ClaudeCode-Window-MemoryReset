#!/bin/zsh
# Basic recovery — Double click in Finder or run in Terminal.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh 
echo ""
echo "[i] Complete. You can close this window."
