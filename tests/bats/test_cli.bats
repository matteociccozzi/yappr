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

@test "yappr --help output contains EXAMPLES section" {
  run "$YAPPR_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXAMPLES"* ]]
}

@test "yappr --help output contains ENV VAR OVERRIDES section" {
  run "$YAPPR_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV VAR OVERRIDES"* ]]
}

@test "yappr -h output contains SUBCOMMANDS section" {
  run "$YAPPR_BIN" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUBCOMMANDS"* ]]
}

@test "yappr -h output is shorter than yappr --help output" {
  run "$YAPPR_BIN" -h
  short="${output}"
  run "$YAPPR_BIN" --help
  full="${output}"
  [ "${#short}" -lt "${#full}" ]
}
