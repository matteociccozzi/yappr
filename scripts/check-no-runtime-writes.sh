#!/usr/bin/env bash
# check-no-runtime-writes.sh — fails if any script writes to $YAPPR_ROOT.
# Run in CI to catch regressions where scripts write logs/metrics/sockets
# back into the source tree.
set -euo pipefail
YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

FAIL=0
PATTERNS=(
  '\$YAPPR_ROOT/logs'
  '\$YAPPR_ROOT/metrics'
  '\$YAPPR_ROOT/recordings'
  'YAPPR_ROOT.*\.log'
  'YAPPR_ROOT.*\.jsonl'
  'YAPPR_ROOT.*\.sock'
  'YAPPR_ROOT.*\.pid'
  '/tmp/yappr-stt\.sock'
  '/tmp/yappr-trace\.log'
)

FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "$YAPPR_ROOT/bin" "$YAPPR_ROOT/scripts" "$YAPPR_ROOT/diagnostics" \
  -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -perm /111 \) \
  ! -name "_*" \
  -print0 2>/dev/null)

for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ "$f" == *"check-no-runtime-writes"* ]] && continue
  [[ "$f" == *"migrate-runtime-state"* ]] && continue
  for pat in "${PATTERNS[@]}"; do
    if grep -qE "$pat" "$f" 2>/dev/null; then
      echo "FAIL: $f contains forbidden write pattern: $pat"
      FAIL=1
    fi
  done
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: no runtime writes into source tree found in bin/, scripts/, diagnostics/"
fi
exit $FAIL
