# Contributing to yappr

## Dev setup

```bash
git clone --recurse-submodules https://github.com/matteociccozzi/yappr.git
cd yappr
./scripts/install.sh
```

If you already cloned without `--recurse-submodules`:
```bash
git submodule update --init --recursive
```

## Repo layout

```
yappr/
├── bin/                   Scripts on PATH (the CLI)
│   ├── _yappr-paths.sh    Bash path helper — source in bash scripts
│   ├── _yappr_paths.py    Python path helper — import in Python scripts
│   ├── yappr              Subcommand dispatcher
│   ├── yappr-dictate      Dictation orchestrator (the core pipeline)
│   ├── yappr-daemon       Daemon lifecycle management
│   ├── yappr-server       MLX server lifecycle management
│   ├── yappr-config       Config management
│   ├── yappr-stats        Metrics viewer
│   ├── yappr-trace        Timing trace viewer
│   ├── yappr-doctor       Post-install health check
│   ├── yappr-help         Help text
│   ├── yappr-mlx-server   Bash launcher for the Python MLX server
│   └── yappr-mlx-server.py  Python MLX inference server
├── swift/
│   └── yappr-stt-daemon/  Swift Package — STT daemon and connect binary
├── configs/               Shipped config presets (JSON)
├── prompts/               Shipped prompt files
├── scripts/
│   ├── install.sh         One-shot installer
│   ├── templates/         File templates rendered by install.sh
│   ├── migrate-runtime-state.sh  One-time migration helper
│   └── check-no-runtime-writes.sh  CI audit script
├── completions/           Shell completions (bash, zsh, fish)
├── diagnostics/           Debug scripts
├── docs/                  User documentation
└── vendor/FluidAudio/     Git submodule — FluidAudio Swift package
```

## The cardinal rule: no runtime state in the repo

The source tree must stay clean after install and after daily use. All writes go to XDG dirs:

| What | Where |
|---|---|
| Logs, metrics | `~/.local/state/yappr/` |
| Socket, PID, trace | `/tmp/yappr-$(id -u)/` |
| User configs | `~/.config/yappr/` |
| Build artifacts | `~/.local/share/yappr/build/` |

The CI script enforces this: `scripts/check-no-runtime-writes.sh` fails if any script writes inside `$YAPPR_ROOT`. Run it locally before pushing:

```bash
bash scripts/check-no-runtime-writes.sh
```

## How to add a subcommand

1. Create `bin/yappr-foo` (executable bash or Python).
2. Source `bin/_yappr-paths.sh` (bash) or import `_yappr_paths` (Python) for path resolution.
3. Add a `case` entry in `bin/yappr`:
   ```bash
   foo) exec "$HERE/yappr-foo" "$@" ;;
   ```
4. Add completions in `completions/yappr.{bash,zsh,fish}`.
5. Add a row in `docs/cli-reference.md`.
6. Update `bin/yappr-help`.

## How to add a config preset

```bash
cp ~/.config/yappr/configs/default.json ~/.config/yappr/configs/fast.json
# edit fast.json
yappr config use fast
```

To ship a preset, also add it to `configs/` in the repo (it becomes the seed default for new installs).

## Running lint locally

```bash
# Shellcheck all bash scripts
shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate \
  bin/yappr-daemon bin/yappr-server bin/yappr-help \
  scripts/install.sh scripts/migrate-runtime-state.sh \
  scripts/check-no-runtime-writes.sh

# Ruff for Python
pip install ruff
ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py

# No-runtime-writes audit
bash scripts/check-no-runtime-writes.sh
```

## Commit conventions

- `feat:` — new functionality
- `fix:` — bug fix
- `refactor:` — refactor with no behavior change
- `docs:` — documentation only
- `chore:` — build, CI, tooling

Keep commits small and self-contained. One logical change per commit.

## PR conventions

- Branch from the relevant base (`main` or the current tier branch).
- Title: `<type>: <short description>` (under 70 chars).
- PR description: what changed and why, plus a test plan.
- All lint checks must pass (CI enforces this).

## Release process

Tag a semver version:
```bash
echo "0.2.0" > VERSION
git add VERSION
git commit -m "chore: bump version to 0.2.0"
git tag v0.2.0
git push origin v0.2.0
```

The `release.yml` GitHub Actions workflow builds a binary tarball and creates a GitHub Release automatically.
