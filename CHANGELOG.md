# Changelog

All notable changes to yappr are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.1.3] - 2026-05-21

### Added
- `yappr setup` now installs `mlx-lm` via `uv tool install` in addition to downloading the Nemotron model
- `uv` added as a Homebrew dependency so it is present after `brew install yappr`

## [0.1.2] - 2026-05-21

### Added
- `yappr setup` subcommand — downloads Nemotron STT model (~200 MB, one-time); works for both Homebrew and source installs
- `fluidaudiocli` included in release tarball so `yappr setup` works without the git repo

### Fixed
- `yappr doctor` now points to `yappr setup` instead of `scripts/install.sh`

## [0.1.1] - 2026-05-21

### Fixed
- Homebrew install: resolve `YapprSttDaemon`/`YapprSttConnect` from Homebrew bin dir instead of source build path

### Added
- Homebrew tap: `brew install matteociccozzi/yappr/yappr`
- Shell completions auto-installed by `scripts/install.sh` (bash/zsh/fish)
- `scripts/uninstall.sh` — clean removal of launchd, binaries, completions, user dirs
- BATS test suite (`tests/bats/`) — tests for CLI, config, doctor
- pytest suite (`tests/python/`) — tests for path helpers and LLM call error paths
- CI `test.yml` workflow — BATS + pytest on every PR
- `<think>` token suppressor in `bin/yappr-llm-call` — Qwen3 thinking mode bleedthrough fix
- Softer cleanup prompt — preserves speaker vocabulary, only strips disfluencies
- Issue templates (bug, feature), PR template, CODE_OF_CONDUCT, SECURITY policy
- `RELEASE-CHECKLIST.md`
- Tiered `--help` (`-h` compact, `--help` full with examples)
- Man page: `docs/man/yappr.1`
- Release tarball: SHA256 sidecar, explicit file list, completions, man page

---

## [0.1.0] — 2026-05-19

Initial public release.

### Added
- `bin/yappr` — subcommand dispatcher (`dictate`, `daemon`, `config`, `stats`, `trace`, `doctor`, `server`, `help`, `version`)
- `bin/yappr-dictate` — dictation pipeline: socket → Nemotron STT → Qwen3 cleanup → Hammerspoon keystroke
- `YapprSttDaemon` (Swift) — long-running mic owner, streaming Nemotron 0.6B via FluidAudio; warm-up on launch
- `YapprSttConnect` (Swift) — lightweight socket client (~5 ms startup) spawned per dictation session
- `bin/yappr-mlx-server.py` — custom MLX inference server with explicit prefix caching (~32% TTFT reduction vs stock mlx_lm.server)
- `bin/yappr-daemon` / `bin/yappr-server` — lifecycle management (start/stop/restart/status/logs/tail)
- `bin/yappr-config` — config switching (list/active/use/show/diff/delete/path)
- `bin/yappr-stats` — dictation metrics viewer (words, latency, daily usage)
- `bin/yappr-doctor` — 11-point post-install health check
- `bin/yappr-trace` — timing trace renderer
- `bin/_yappr-paths.sh` / `bin/_yappr_paths.py` — single source of truth for XDG paths (bash + Python)
- `scripts/install.sh` — idempotent installer: Xcode, Homebrew, Swift build, codesign, launchd, PATH
- `scripts/migrate-runtime-state.sh` — one-time migration helper for pre-XDG installs
- Shell completions: bash, zsh, fish
- XDG Base Directory compliance for all runtime state
- Voice commands: "scratch that", "new paragraph", "new line", "bullet list", "all caps X"
- CI: GitHub Actions (macos-15) — shellcheck, ruff, Swift build, codesign
- Release: GitHub Actions — tarball, GitHub Release

[Unreleased]: https://github.com/matteociccozzi/yappr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/matteociccozzi/yappr/releases/tag/v0.1.0
