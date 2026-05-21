#!/usr/bin/env bats
# test_cli.bats — tests for bin/yappr subcommand dispatcher.
load "test_helper"

@test "yappr help exits 0" {
  run "$YAPPR_BIN" help
  [ "$status" -eq 0 ]
}

@test "yappr help output contains USAGE" {
  run "$YAPPR_BIN" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "yappr --help exits 0 and contains USAGE" {
  run "$YAPPR_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "yappr -h exits 0 and contains USAGE" {
  run "$YAPPR_BIN" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "yappr version exits 0" {
  run "$YAPPR_BIN" version
  [ "$status" -eq 0 ]
}

@test "yappr version output matches semver pattern" {
  run "$YAPPR_BIN" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ yappr\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "yappr --version exits 0 and prints semver" {
  run "$YAPPR_BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ yappr\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "yappr -V exits 0 and prints semver" {
  run "$YAPPR_BIN" -V
  [ "$status" -eq 0 ]
  [[ "$output" =~ yappr\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "unknown subcommand exits 2" {
  run "$YAPPR_BIN" notacommand
  [ "$status" -eq 2 ]
}

@test "unknown subcommand output names the bad subcommand" {
  run "$YAPPR_BIN" notacommand
  [[ "$output" == *"notacommand"* ]]
}

@test "unknown subcommand output mentions 'yappr help'" {
  run "$YAPPR_BIN" notacommand
  [[ "$output" == *"yappr help"* ]]
}
