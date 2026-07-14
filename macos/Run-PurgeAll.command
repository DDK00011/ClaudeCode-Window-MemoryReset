#!/bin/zsh
# 전체 청소 (자손 포함 + 깊은 회수) — Finder 에서 더블클릭하거나 터미널에서 실행하세요.
cd "$(dirname "$0")" || exit 1
./memoryreset.sh --deep --include-descendants
echo ""
echo "[i] 완료. 이 창은 닫아도 됩니다."
