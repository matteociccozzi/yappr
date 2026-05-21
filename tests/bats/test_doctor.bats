#!/usr/bin/env bats
# test_doctor.bats — tests for bin/yappr-doctor.
# Doctor exit codes: 0 = all checks pass, 1 = some failed. Never 2+ (crash).
load "test_helper"

@test "yappr doctor runs without crashing" {
  run "$YAPPR_BIN" doctor
  [ "$status" -le 1 ]
}

@test "yappr doctor output contains OK or FAIL labels" {
  run "$YAPPR_BIN" doctor
  [[ "$output" == *"[OK]"* ]] || [[ "$output" == *"[FAIL]"* ]]
}

@test "yappr doctor output mentions macOS platform check" {
  run "$YAPPR_BIN" doctor
  [[ "$output" == *"macOS"* ]] || [[ "$output" == *"platform"* ]]
}

@test "yappr doctor exits 1 in isolated test environment (daemon not running)" {
  # YAPPR_RUNTIME_DIR is a fresh tmpdir with no socket — doctor must report FAIL and exit 1.
  run "$YAPPR_BIN" doctor
  [ "$status" -eq 1 ]
}
