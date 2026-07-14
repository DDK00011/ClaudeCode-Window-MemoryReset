#!/bin/zsh
# 깊은 회수 (purge + DNS flush) — Finder 에서 더블클릭하거나 터미널에서 실행하세요.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --deep
echo ""
echo "[i] 완료. 이 창은 닫아도 됩니다."
