# test_helper.bash — shared setup for all yappr BATS test files.
#
# Provides:
#   YAPPR_ROOT      absolute path to repo root
#   YAPPR_BIN       absolute path to bin/yappr
#
# Each test gets an isolated XDG environment in a tmpdir (setup/teardown).
# Load with:  load "test_helper"

YAPPR_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/.." && pwd)"
export YAPPR_ROOT
YAPPR_BIN="$YAPPR_ROOT/bin/yappr"
export YAPPR_BIN

setup() {
  TEST_DIR="$(mktemp -d)"
  export YAPPR_CONFIG_HOME="$TEST_DIR/config"
  export YAPPR_STATE_HOME="$TEST_DIR/state"
  export YAPPR_RUNTIME_DIR="$TEST_DIR/runtime"
  mkdir -p "$YAPPR_CONFIG_HOME/configs" "$YAPPR_STATE_HOME" "$YAPPR_RUNTIME_DIR"
  # Seed a minimal config so config subcommands don't fail on missing file
  cp "$YAPPR_ROOT/configs/default.json" "$YAPPR_CONFIG_HOME/configs/default.json"
  ln -sf default.json "$YAPPR_CONFIG_HOME/configs/active.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}
