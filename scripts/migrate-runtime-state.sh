#!/usr/bin/env bash
# migrate-runtime-state.sh — one-time migration from repo-local runtime dirs
# to XDG dirs. Run once after upgrading to the Tier 2 branch.
# Safe to run multiple times (idempotent).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # path resolved dynamically at runtime
source "$HERE/../bin/_yappr-paths.sh"

echo "=== yappr runtime state migration ==="
echo "FROM: $YAPPR_ROOT/{logs,metrics}"
echo "TO:   $YAPPR_STATE_HOME/{logs,metrics}"
echo ""

yappr_ensure_dirs

MOVED=0

# Migrate logs
if [[ -d "$YAPPR_ROOT/logs" ]]; then
  for f in "$YAPPR_ROOT/logs"/*.log; do
    [[ -f "$f" ]] || continue
    dest="$YAPPR_STATE_HOME/logs/$(basename "$f")"
    if [[ ! -f "$dest" ]]; then
      mv "$f" "$dest"
      echo "  moved logs/$(basename "$f")"
      MOVED=$((MOVED + 1))
    else
      echo "  skipped logs/$(basename "$f") (already in state dir)"
    fi
  done
fi

# Migrate metrics
if [[ -d "$YAPPR_ROOT/metrics" ]]; then
  for f in "$YAPPR_ROOT/metrics"/*.jsonl; do
    [[ -f "$f" ]] || continue
    dest="$YAPPR_STATE_HOME/metrics/$(basename "$f")"
    if [[ ! -f "$dest" ]]; then
      mv "$f" "$dest"
      echo "  moved metrics/$(basename "$f")"
      MOVED=$((MOVED + 1))
    else
      echo "  skipped metrics/$(basename "$f") (already in state dir)"
    fi
  done
fi

echo ""
if [[ $MOVED -gt 0 ]]; then
  echo "Moved $MOVED file(s). Old empty dirs (logs/, metrics/) can be deleted:"
  echo "  rmdir $YAPPR_ROOT/logs $YAPPR_ROOT/metrics 2>/dev/null || true"
else
  echo "Nothing to migrate."
fi
