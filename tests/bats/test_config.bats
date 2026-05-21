#!/usr/bin/env bats
# test_config.bats — tests for yappr config subcommand.
load "test_helper"

# ---------------------------------------------------------------------------
# yappr config list
# ---------------------------------------------------------------------------

@test "config list exits 0" {
  run "$YAPPR_BIN" config list
  [ "$status" -eq 0 ]
}

@test "config list shows 'default'" {
  run "$YAPPR_BIN" config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "config list shows Active line" {
  run "$YAPPR_BIN" config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"Active:"* ]]
}

# ---------------------------------------------------------------------------
# yappr config active
# ---------------------------------------------------------------------------

@test "config active exits 0" {
  run "$YAPPR_BIN" config active
  [ "$status" -eq 0 ]
}

@test "config active prints 'default'" {
  run "$YAPPR_BIN" config active
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
}

# ---------------------------------------------------------------------------
# yappr config show
# ---------------------------------------------------------------------------

@test "config show exits 0" {
  run "$YAPPR_BIN" config show
  [ "$status" -eq 0 ]
}

@test "config show outputs valid JSON" {
  run "$YAPPR_BIN" config show
  [ "$status" -eq 0 ]
  echo "$output" | jq . >/dev/null
}

@test "config show output contains llm key" {
  run "$YAPPR_BIN" config show
  [ "$status" -eq 0 ]
  [[ "$output" == *'"llm"'* ]]
}

# ---------------------------------------------------------------------------
# yappr config path
# ---------------------------------------------------------------------------

@test "config path exits 0" {
  run "$YAPPR_BIN" config path
  [ "$status" -eq 0 ]
}

@test "config path prints a non-empty string" {
  run "$YAPPR_BIN" config path
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "config path output contains the YAPPR_CONFIG_HOME prefix" {
  run "$YAPPR_BIN" config path
  [ "$status" -eq 0 ]
  [[ "$output" == *"$YAPPR_CONFIG_HOME"* ]]
}

# ---------------------------------------------------------------------------
# yappr config use — error cases
# ---------------------------------------------------------------------------

@test "config use nonexistent exits nonzero" {
  run "$YAPPR_BIN" config use nonexistent
  [ "$status" -ne 0 ]
}

@test "config use nonexistent output mentions the missing config name" {
  run "$YAPPR_BIN" config use nonexistent
  [[ "$output" == *"nonexistent"* ]]
}

@test "config use with no args exits nonzero" {
  run "$YAPPR_BIN" config use
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# yappr config use — success
# ---------------------------------------------------------------------------

@test "config use existing config exits 0" {
  run "$YAPPR_BIN" config use default
  [ "$status" -eq 0 ]
}

@test "config use existing config updates active symlink" {
  # Seed a second config so we can round-trip the symlink.
  cp "$YAPPR_CONFIG_HOME/configs/default.json" "$YAPPR_CONFIG_HOME/configs/alt.json"

  # Switch to alt.
  run "$YAPPR_BIN" config use alt
  [ "$status" -eq 0 ]

  # active should now be alt.
  run "$YAPPR_BIN" config active
  [ "$status" -eq 0 ]
  [ "$output" = "alt" ]
}
