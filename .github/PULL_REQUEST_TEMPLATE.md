## What does this PR do?

<!-- One clear sentence. -->

## Why?

<!-- Motivation, linked issue number, or context. -->

## Changes

<!-- Bullet list of concrete changes (files, behaviors, APIs). -->

## Test plan

- [ ] `shellcheck bin/... scripts/...` passes
- [ ] `ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py tests/python/` passes
- [ ] `bats tests/bats/` passes (all 24+ tests)
- [ ] `pytest tests/python/ -v` passes (all 14+ tests)
- [ ] `bash scripts/check-no-runtime-writes.sh` passes
- [ ] Manual golden-path test: `yappr daemon start && yappr server start && yappr doctor`

## Boy Scout

<!-- What did you clean up that you found nearby? ("Nothing" is a valid answer.) -->
