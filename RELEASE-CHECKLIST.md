# Release Checklist

Run through this for every release. No skipping.

## 1. Pre-release verification

- [ ] All PRs for this release are merged to `main`
- [ ] `git checkout main && git pull` — up to date
- [ ] `bats tests/bats/` — all tests pass
- [ ] `pytest tests/python/ -v` — all tests pass
- [ ] `shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate bin/yappr-daemon bin/yappr-server bin/yappr-help scripts/install.sh scripts/uninstall.sh scripts/migrate-runtime-state.sh scripts/check-no-runtime-writes.sh diagnostics/yappr-probe-caching` — zero errors
- [ ] `ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py tests/python/` — zero errors
- [ ] `bash scripts/check-no-runtime-writes.sh` — passes
- [ ] Manual golden-path: `./scripts/install.sh --skip-optional && yappr daemon start && yappr server start && yappr doctor`

## 2. Version bump + CHANGELOG

- [ ] Edit `VERSION` — set new semver (e.g. `0.2.0`)
- [ ] Edit `CHANGELOG.md`:
  - Move all items from `## [Unreleased]` to a new section: `## [0.2.0] — YYYY-MM-DD`
  - Add comparison link at the bottom: `[0.2.0]: https://github.com/matteociccozzi/yappr/compare/v0.1.0...v0.2.0`
  - Leave `## [Unreleased]` empty (no subsections)
- [ ] Commit: `git commit -am "chore: bump version to 0.2.0, update CHANGELOG"`

## 3. Tag and push

- [ ] `git tag v0.2.0`
- [ ] `git push origin main --tags`

## 4. Verify release automation

- [ ] GitHub Actions → release workflow completes (check the Actions tab)
- [ ] GitHub Release page shows `yappr-0.2.0-macos-arm64.tar.gz` and `.sha256`
- [ ] `mislav/bump-homebrew-formula-action` creates a PR in `matteociccozzi/homebrew-yappr`
- [ ] Review and merge the Homebrew bump PR

## 5. Post-release smoke test

- [ ] `brew update && brew upgrade matteociccozzi/yappr/yappr` (or fresh install) succeeds
- [ ] `yappr version` prints `yappr 0.2.0`
- [ ] `yappr doctor` exits 0

## Semver rules

| Change type | Bump |
|-------------|------|
| Breaking CLI, config schema, socket protocol change | MAJOR (1.0.0) |
| New subcommand, new config key, new feature | MINOR (0.2.0) |
| Bug fix, performance, docs, CI | PATCH (0.1.1) |
