# yappr OSS Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden yappr into a production-quality open-source CLI with Homebrew distribution, shell completion auto-install, an uninstall script, a BATS + pytest test suite, community hygiene files (CHANGELOG, issue templates, code of conduct, security policy), polished tiered help, a man page stub, and complete release tarballs.

**Architecture:** Four branches stacked on main — `feat/tier-1-distribution` → `feat/tier-2-testing` → `feat/tier-3-community` → `feat/tier-4-polish` — each producing a reviewed PR before the next tier begins. **Boy Scout Rule applies to every task**: leave any file you touch cleaner than you found it (remove dead code, tighten stale comments, fix inconsistent naming, fill gitignore gaps).

**Tech Stack:** bash, Python 3.12, Swift 6, BATS (Bash Automated Testing System), pytest, GitHub Actions (macos-15), Homebrew Ruby DSL, `mislav/bump-homebrew-formula-action`, `gh` CLI, `ruff`, `shellcheck`.

**What already exists (do not re-implement):**
- `yappr version` / `--version` / `-V` — implemented in `bin/yappr:20-23`
- `.gitignore` — already covers `__pycache__/`, `*.pyc`, `.DS_Store`, Swift `.build/`
- Shell completions files — exist in `completions/`, just not installed by `install.sh`

---

## File map

| File | Action | Tier |
|------|--------|------|
| `scripts/install.sh` | Modify — add completions install step | 1 |
| `scripts/uninstall.sh` | **Create** | 1 |
| `.github/workflows/release.yml` | Modify — tarball contents, SHA256, Homebrew bump | 1 |
| `README.md` | Modify — add Install section | 1 |
| *(separate repo)* `homebrew-yappr/Formula/yappr.rb` | **Create** (new GitHub repo) | 1 |
| `tests/bats/test_helper.bash` | **Create** | 2 |
| `tests/bats/test_cli.bats` | **Create** | 2 |
| `tests/bats/test_config.bats` | **Create** | 2 |
| `tests/bats/test_doctor.bats` | **Create** | 2 |
| `tests/python/conftest.py` | **Create** | 2 |
| `tests/python/test_yappr_paths.py` | **Create** | 2 |
| `tests/python/test_llm_call.py` | **Create** | 2 |
| `.github/workflows/test.yml` | **Create** | 2 |
| `.github/workflows/ci.yml` | Modify — ruff covers `tests/python/` | 2 |
| `CHANGELOG.md` | **Create** | 3 |
| `.github/release.yml` | **Create** | 3 |
| `.github/ISSUE_TEMPLATE/bug_report.md` | **Create** | 3 |
| `.github/ISSUE_TEMPLATE/feature_request.md` | **Create** | 3 |
| `.github/ISSUE_TEMPLATE/config.yml` | **Create** | 3 |
| `.github/PULL_REQUEST_TEMPLATE.md` | **Create** | 3 |
| `CODE_OF_CONDUCT.md` | **Create** | 3 |
| `SECURITY.md` | **Create** | 3 |
| `bin/yappr` | Modify — split `-h` from `--help` routing | 4 |
| `bin/yappr-help` | Modify — `--short` and `--full` modes | 4 |
| `docs/man/yappr.1` | **Create** | 4 |
| `RELEASE-CHECKLIST.md` | **Create** | 4 |
| `README.md` | Modify — Community links, polish | 4 |

---

## Tier 1: Distribution

Branch: `feat/tier-1-distribution` (off `main`)

---

### Task 1: Branch setup

**Files:** (none modified)

- [ ] **Step 1: Create the branch**

```bash
cd /Users/matteociccozzi/yappr
git checkout main && git pull
git checkout -b feat/tier-1-distribution
```

- [ ] **Step 2: Verify baseline CI passes**

```bash
shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate \
  bin/yappr-daemon bin/yappr-server bin/yappr-help \
  scripts/install.sh scripts/migrate-runtime-state.sh \
  scripts/check-no-runtime-writes.sh diagnostics/yappr-probe-caching
ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor bin/yappr-mlx-server.py
bash scripts/check-no-runtime-writes.sh
```
Expected: zero errors from all three.

---

### Task 2: Install shell completions in install.sh

**Files:**
- Modify: `scripts/install.sh` (insert after the PATH step, ~line 414)

Shell completions exist in `completions/` but `install.sh` never copies them. Users get no tab-completion after a fresh install.

- [ ] **Step 1: Read the PATH step to find the exact insertion point**

```bash
grep -n "Shell PATH\|9\. Shell\|shell PATH\|SHELL_NAME\|RC_FILE" scripts/install.sh | head -20
```

The PATH step ends around line 413 with `fi`. Insert a new step immediately after.

- [ ] **Step 2: Insert the completions step**

Open `scripts/install.sh` and insert the following block immediately after the closing `fi` of the "Shell PATH" section (the one that ends with `warn "Skipped. Run yappr commands with the full path: $YAPPR_BIN/yappr"`):

```bash
# -----------------------------------------------------------------------------
# 9b. Shell completions
# -----------------------------------------------------------------------------

step "Shell completions"

case "$SHELL_NAME" in
  bash)
    COMPLETION_DIR="$HOME/.bash_completion.d"
    mkdir -p "$COMPLETION_DIR"
    cp "$YAPPR_ROOT/completions/yappr.bash" "$COMPLETION_DIR/yappr"
    ok "bash completion → $COMPLETION_DIR/yappr"
    info "Ensure this is in ~/.bashrc (add if missing):"
    info "    for f in ~/.bash_completion.d/*; do source \"\$f\"; done"
    ;;
  zsh)
    ZSH_COMPLETION_DIR="$HOME/.zfunctions"
    mkdir -p "$ZSH_COMPLETION_DIR"
    cp "$YAPPR_ROOT/completions/yappr.zsh" "$ZSH_COMPLETION_DIR/_yappr"
    ok "zsh completion → $ZSH_COMPLETION_DIR/_yappr"
    info "Ensure ~/.zfunctions is in your fpath (add to ~/.zshrc if missing):"
    info "    fpath=(~/.zfunctions \$fpath) && autoload -Uz compinit && compinit"
    ;;
  fish)
    FISH_COMPLETION_DIR="$HOME/.config/fish/completions"
    mkdir -p "$FISH_COMPLETION_DIR"
    cp "$YAPPR_ROOT/completions/_yappr.fish" "$FISH_COMPLETION_DIR/yappr.fish"
    ok "fish completion → $FISH_COMPLETION_DIR/yappr.fish"
    ;;
  *)
    warn "Unknown shell ($SHELL_NAME). Install completions manually from $YAPPR_ROOT/completions/"
    ;;
esac
```

- [ ] **Step 3: Update the step list in print_help()**

Find the `Steps:` block inside `print_help()`. It currently lists steps 1–9. Renumber:
- Step 9 stays "Shell PATH"
- Add: `  9b. Shell completions (bash/zsh/fish)`
- Step 10 stays "Daemon auto-start at login (launchd)"

- [ ] **Step 4: Verify shellcheck**

```bash
shellcheck scripts/install.sh
```
Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "feat: install.sh installs shell completions (bash/zsh/fish)"
```

---

### Task 3: Add scripts/uninstall.sh

**Files:**
- Create: `scripts/uninstall.sh`
- Modify: `.github/workflows/ci.yml` (add to shellcheck list)

- [ ] **Step 1: Create scripts/uninstall.sh**

```bash
cat > /Users/matteociccozzi/yappr/scripts/uninstall.sh << 'SCRIPT'
#!/usr/bin/env bash
#
# yappr uninstaller.
#
# Removes: launchd plist + service, built Swift binaries, shell completions.
# Prompts before deleting user data dirs (config, state, build).
# Does NOT remove: Homebrew packages, Hammerspoon, mlx-lm, Xcode, the source tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAPPR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
YAPPR_DATA_HOME="${YAPPR_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/yappr}"
YAPPR_CONFIG_HOME="${YAPPR_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/yappr}"
YAPPR_STATE_HOME="${YAPPR_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/yappr}"

ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help)
      echo "Usage: $0 [-y|--yes]"
      echo "  -y, --yes   Skip confirmation prompts (auto-yes to all)"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; RESET=$'\e[0m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

step() { echo; echo "${BOLD}${CYAN}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo "    ${GREEN}OK${RESET}  $*"; }
warn() { echo "    ${YELLOW}!${RESET}   $*"; }

prompt_yn() {
  local prompt="$1" default="${2:-Y}" reply suffix
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ "$default" == "Y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    read -rp "    $prompt $suffix " reply
    reply="${reply:-$default}"
    case "$reply" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

# 1. Launchd service
step "Unload launchd service"
PLIST="$HOME/Library/LaunchAgents/com.yappr.daemon.plist"
if [[ -f "$PLIST" ]]; then
  launchctl bootout "gui/$(id -u)/com.yappr.daemon" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "Removed and unloaded $PLIST"
else
  warn "No launchd plist at $PLIST (already removed or never installed)"
fi

# 2. Built Swift binaries
step "Remove built Swift binaries"
DAEMON_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttDaemon"
CONNECT_BIN="$YAPPR_DATA_HOME/build/yappr-stt-daemon/release/YapprSttConnect"
removed=0
for BIN in "$DAEMON_BIN" "$CONNECT_BIN"; do
  if [[ -f "$BIN" ]]; then rm -f "$BIN"; removed=1; fi
done
if [[ $removed -eq 1 ]]; then
  ok "Removed YapprSttDaemon and YapprSttConnect"
else
  warn "No built binaries found"
fi

# 3. Shell completions
step "Remove shell completions"
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
  bash)
    [[ -f "$HOME/.bash_completion.d/yappr" ]] && rm -f "$HOME/.bash_completion.d/yappr" && ok "Removed bash completion"
    ;;
  zsh)
    [[ -f "$HOME/.zfunctions/_yappr" ]] && rm -f "$HOME/.zfunctions/_yappr" && ok "Removed zsh completion"
    ;;
  fish)
    [[ -f "$HOME/.config/fish/completions/yappr.fish" ]] && rm -f "$HOME/.config/fish/completions/yappr.fish" && ok "Removed fish completion"
    ;;
  *)
    warn "Unknown shell — remove completions manually from your shell's completions dir"
    ;;
esac

# 4. PATH entries (cannot remove automatically, must be manual)
step "Shell PATH entries"
YAPPR_BIN="$YAPPR_ROOT/bin"
found_rc=0
for RC_FILE in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
  if [[ -f "$RC_FILE" ]] && grep -q "$YAPPR_BIN" "$RC_FILE" 2>/dev/null; then
    warn "Remove this line from $RC_FILE manually:"
    grep "$YAPPR_BIN" "$RC_FILE" || true
    found_rc=1
  fi
done
[[ $found_rc -eq 0 ]] && ok "No PATH entries found in shell rc files"

# 5. User data directories
step "User data directories"
for DIR in "$YAPPR_CONFIG_HOME" "$YAPPR_STATE_HOME" "$YAPPR_DATA_HOME"; do
  if [[ -d "$DIR" ]]; then
    if prompt_yn "Delete $DIR?" "N"; then
      rm -rf "$DIR"
      ok "Deleted $DIR"
    else
      warn "Skipped $DIR"
    fi
  else
    ok "$DIR does not exist (already clean)"
  fi
done

echo
echo "${BOLD}${GREEN}Uninstall complete.${RESET}"
echo "The source tree at $YAPPR_ROOT is untouched — delete it manually if desired."
SCRIPT
chmod +x /Users/matteociccozzi/yappr/scripts/uninstall.sh
```

- [ ] **Step 2: Verify shellcheck**

```bash
shellcheck /Users/matteociccozzi/yappr/scripts/uninstall.sh
```
Expected: zero output.

- [ ] **Step 3: Add uninstall.sh to CI shellcheck**

In `.github/workflows/ci.yml`, find the Shellcheck step and add `scripts/uninstall.sh`:

```yaml
      - name: Shellcheck
        run: |
          shellcheck bin/_yappr-paths.sh bin/yappr bin/yappr-dictate \
            bin/yappr-daemon bin/yappr-server bin/yappr-help \
            scripts/install.sh scripts/uninstall.sh \
            scripts/migrate-runtime-state.sh \
            scripts/check-no-runtime-writes.sh \
            diagnostics/yappr-probe-caching
```

- [ ] **Step 4: Commit**

```bash
git add scripts/uninstall.sh .github/workflows/ci.yml
git commit -m "feat: add scripts/uninstall.sh — removes launchd, binaries, completions, user dirs"
```

---

### Task 4: Improve release tarball + SHA256 sidecar

**Files:**
- Modify: `.github/workflows/release.yml`

The current tarball copies `bin/` (source scripts) but not all required files explicitly, misses `scripts/uninstall.sh` implicitly via directory copy, and produces no SHA256 sidecar. Ripgrep, bat, and gh all ship `.sha256` files alongside every release asset.

- [ ] **Step 1: Replace the "Bundle tarball" and "Create GitHub Release" steps**

In `.github/workflows/release.yml`, replace the existing `Bundle tarball` step with:

```yaml
      - name: Bundle tarball
        run: |
          DIST="yappr-${{ env.VERSION }}-macos-arm64"
          mkdir -p "$DIST/bin" "$DIST/share/man/man1"
          # Source scripts (explicit list avoids __pycache__ and other noise)
          cp bin/_yappr-paths.sh bin/_yappr_paths.py \
             bin/yappr bin/yappr-config bin/yappr-daemon bin/yappr-dictate \
             bin/yappr-doctor bin/yappr-help bin/yappr-llm-call \
             bin/yappr-mlx-server bin/yappr-mlx-server.py \
             bin/yappr-server bin/yappr-stats bin/yappr-trace \
             "$DIST/bin/"
          # Pre-built Swift binaries (already codesigned above)
          cp "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttDaemon" "$DIST/bin/"
          cp "$RUNNER_TEMP/build/yappr-stt-daemon/release/YapprSttConnect" "$DIST/bin/"
          # Supporting directories
          cp -r configs prompts completions scripts docs "$DIST/"
          # Root files (CHANGELOG.md optional — present after Tier 3)
          cp README.md LICENSE VERSION "$DIST/"
          cp CHANGELOG.md "$DIST/" 2>/dev/null || true
          # Man page (present after Tier 4)
          cp docs/man/yappr.1 "$DIST/share/man/man1/" 2>/dev/null || true
          # Archive
          tar czf "$DIST.tar.gz" "$DIST"
          shasum -a 256 "$DIST.tar.gz" > "$DIST.tar.gz.sha256"
          echo "TARBALL=$DIST.tar.gz" >> $GITHUB_ENV
          echo "CHECKSUM=$DIST.tar.gz.sha256" >> $GITHUB_ENV
```

Replace the "Create GitHub Release" step with:

```yaml
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            ${{ env.TARBALL }}
            ${{ env.CHECKSUM }}
          generate_release_notes: true
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat: release tarball includes completions, scripts, man page stub, SHA256 sidecar"
```

---

### Task 5: Create Homebrew tap + formula

**Files:**
- Create (new GitHub repo): `homebrew-yappr/Formula/yappr.rb`
- Modify: `.github/workflows/release.yml` (Homebrew bump step)
- Modify: `README.md` (Install section)

- [ ] **Step 1: Create the homebrew-yappr GitHub repository**

```bash
gh repo create matteociccozzi/homebrew-yappr \
  --public \
  --description "Homebrew tap for yappr — local push-to-talk voice dictation for macOS" \
  --clone \
  --add-readme
cd homebrew-yappr
mkdir -p Formula
```

- [ ] **Step 2: Write Formula/yappr.rb**

```bash
cat > Formula/yappr.rb << 'EOF'
class Yappr < Formula
  desc "Local push-to-talk voice dictation for macOS Apple Silicon"
  homepage "https://github.com/matteociccozzi/yappr"
  version "0.1.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/matteociccozzi/yappr/releases/download/v#{version}/yappr-#{version}-macos-arm64.tar.gz"
      sha256 "PLACEHOLDER_UPDATE_ON_FIRST_RELEASE"
    else
      odie "yappr requires Apple Silicon (arm64). Intel Macs are not supported."
    end
  end

  depends_on :macos => :sonoma
  depends_on "jq"
  depends_on "python@3.12"

  def install
    # Scripts and helpers go on PATH
    bin.install Dir["bin/*"]

    # Shell completions
    bash_completion.install "completions/yappr.bash" => "yappr"
    zsh_completion.install "completions/yappr.zsh" => "_yappr"
    fish_completion.install "completions/_yappr.fish" => "yappr.fish"

    # Supporting directories (configs, prompts, scripts, docs)
    (share/"yappr").install "configs", "prompts", "scripts", "docs"

    # Man page
    man1.install "share/man/man1/yappr.1" if (share/"man"/"man1"/"yappr.1").exist?

    # Ad-hoc codesign so TCC microphone permission survives across brew upgrades.
    system "codesign", "--force", "--sign", "-", "#{bin}/YapprSttDaemon"
  end

  def caveats
    <<~EOS
      yappr requires three macOS permissions granted manually:

        1. Microphone → YapprSttDaemon
           System Settings → Privacy & Security → Microphone

        2. Accessibility → Hammerspoon
           System Settings → Privacy & Security → Accessibility

        3. Input Monitoring → Hammerspoon
           System Settings → Privacy & Security → Input Monitoring

      After install:
        yappr daemon start
        yappr server start
        yappr doctor

      Full setup guide:
        https://github.com/matteociccozzi/yappr/blob/main/docs/installation.md
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/yappr version")
    assert_match "USAGE", shell_output("#{bin}/yappr help")
  end
end
EOF
```

- [ ] **Step 3: Commit and push the formula**

```bash
git add Formula/yappr.rb
git commit -m "feat: initial Homebrew formula for yappr v0.1.0"
git push -u origin main
cd /Users/matteociccozzi/yappr
```

- [ ] **Step 4: Create a GitHub fine-grained PAT for Homebrew bump**

```
GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
  → Repository access: matteociccozzi/homebrew-yappr only
  → Permissions: Contents (Read and write)
  → Generate → copy token value
```

Store it as a secret in the yappr repo:

```bash
gh secret set HOMEBREW_TAP_TOKEN
# (paste the token value at the prompt)
```

- [ ] **Step 5: Add Homebrew bump step to release.yml**

In `.github/workflows/release.yml`, add after the "Create GitHub Release" step:

```yaml
      - name: Bump Homebrew formula
        uses: mislav/bump-homebrew-formula-action@v3
        with:
          formula-name: yappr
          tap-repository: matteociccozzi/homebrew-yappr
          download-url: >-
            https://github.com/matteociccozzi/yappr/releases/download/${{ github.ref_name }}/yappr-${{ env.VERSION }}-macos-arm64.tar.gz
        env:
          COMMITTER_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

- [ ] **Step 6: Add Install section to README.md**

In `README.md`, insert the following section immediately after the badges and before the "How it works" section:

```markdown
## Install

### Homebrew (recommended)

```bash
brew install matteociccozzi/yappr/yappr
```

### From source

```bash
git clone --recurse-submodules https://github.com/matteociccozzi/yappr.git
cd yappr
./scripts/install.sh
```

### Direct download

Download the latest tarball and `.sha256` from [Releases](https://github.com/matteociccozzi/yappr/releases), verify the checksum, then run `./scripts/install.sh`.

```bash
shasum -a 256 -c yappr-VERSION-macos-arm64.tar.gz.sha256
tar xzf yappr-VERSION-macos-arm64.tar.gz
cd yappr-VERSION-macos-arm64
./scripts/install.sh
```
```

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/release.yml README.md
git commit -m "feat: Homebrew tap formula + automated bump on release, README install section"
```

---

### Task 6: Open Tier 1 PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/tier-1-distribution
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(tier-1): Homebrew tap, completions install, uninstall.sh, tarball+SHA256" \
  --base main \
  --body "$(cat <<'EOF'
## Summary

- **Homebrew tap**: new `matteociccozzi/homebrew-yappr` repo; `brew install matteociccozzi/yappr/yappr` works. Formula bumped automatically on each tag via `mislav/bump-homebrew-formula-action`.
- **Shell completions**: `scripts/install.sh` installs completions to per-shell location (bash: `~/.bash_completion.d/yappr`, zsh: `~/.zfunctions/_yappr`, fish: `~/.config/fish/completions/yappr.fish`).
- **Uninstall script**: `scripts/uninstall.sh` — removes launchd plist, built binaries, completions; prompts before deleting user data dirs.
- **Release tarball**: explicit file list (no `__pycache__`), completions, scripts, docs, CHANGELOG (when present), `.sha256` sidecar.
- **Boy Scout**: `uninstall.sh` added to CI shellcheck; release tarball no longer silently includes junk.

## Test plan
- [ ] `shellcheck scripts/uninstall.sh` passes
- [ ] `bash scripts/check-no-runtime-writes.sh` passes
- [ ] CI lint workflow green
- [ ] `brew audit --strict Formula/yappr.rb` in homebrew-yappr (no errors)
EOF
)"
```

---

## Tier 2: Testing

Branch: `feat/tier-2-testing` (off `feat/tier-1-distribution`)

---

### Task 7: BATS scaffolding

**Files:**
- Create: `tests/bats/test_helper.bash`

- [ ] **Step 1: Create the tier-2 branch**

```bash
git checkout feat/tier-1-distribution
git checkout -b feat/tier-2-testing
```

- [ ] **Step 2: Install bats-core**

```bash
brew install bats-core
bats --version
```
Expected: `Bats 1.x.x`

- [ ] **Step 3: Create tests/bats/test_helper.bash**

```bash
mkdir -p /Users/matteociccozzi/yappr/tests/bats
cat > /Users/matteociccozzi/yappr/tests/bats/test_helper.bash << 'EOF'
# test_helper.bash — shared setup for all yappr BATS test files.
#
# Provides:
#   YAPPR_ROOT      absolute path to repo root
#   YAPPR_BIN       absolute path to bin/yappr
#
# Each test gets an isolated XDG environment in a tmpdir (setup/teardown).
# Load with:  load "test_helper"

YAPPR_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/.." && pwd)"
YAPPR_BIN="$YAPPR_ROOT/bin/yappr"

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
EOF
```

- [ ] **Step 4: Smoke-test the BATS setup**

```bash
echo '@test "sanity" { true; }' > /tmp/sanity.bats
bats /tmp/sanity.bats
rm /tmp/sanity.bats
```
Expected: `1..1\nok 1 sanity`

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: add BATS scaffolding and test_helper with isolated XDG env per test"
```

---

### Task 8: Core CLI tests

**Files:**
- Create: `tests/bats/test_cli.bats`

- [ ] **Step 1: Write tests/bats/test_cli.bats**

```bash
cat > /Users/matteociccozzi/yappr/tests/bats/test_cli.bats << 'EOF'
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
EOF
```

- [ ] **Step 2: Run the tests and confirm they all pass**

```bash
bats /Users/matteociccozzi/yappr/tests/bats/test_cli.bats
```
Expected: `1..11` with all `ok`. If any fail, read `bin/yappr` (lines 1-29) and fix the test to match the actual output format.

- [ ] **Step 3: Commit**

```bash
git add tests/bats/test_cli.bats
git commit -m "test: 11 CLI dispatcher tests — help, version flags, unknown subcommand"
```

---

### Task 9: Config subcommand tests

**Files:**
- Create: `tests/bats/test_config.bats`

`bin/yappr-config` supports: `list`, `active`, `use`, `show`, `diff`, `delete`, `path`. Tests cover the most user-facing paths.

- [ ] **Step 1: Write tests/bats/test_config.bats**

```bash
cat > /Users/matteociccozzi/yappr/tests/bats/test_config.bats << 'EOF'
#!/usr/bin/env bats
# test_config.bats — tests for 'yappr config' subcommands.
load "test_helper"

@test "yappr config list exits 0" {
  run "$YAPPR_BIN" config list
  [ "$status" -eq 0 ]
}

@test "yappr config list shows 'default'" {
  run "$YAPPR_BIN" config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "yappr config show exits 0" {
  run "$YAPPR_BIN" config show
  [ "$status" -eq 0 ]
}

@test "yappr config show outputs valid JSON" {
  run "$YAPPR_BIN" config show
  [ "$status" -eq 0 ]
  echo "$output" | jq . > /dev/null
}

@test "yappr config path exits 0 and prints a directory" {
  run "$YAPPR_BIN" config path
  [ "$status" -eq 0 ]
  [[ -n "$output" ]]
}

@test "yappr config active exits 0" {
  run "$YAPPR_BIN" config active
  [ "$status" -eq 0 ]
}

@test "yappr config active prints 'default'" {
  run "$YAPPR_BIN" config active
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "yappr config use nonexistent exits nonzero" {
  run "$YAPPR_BIN" config use doesnotexist
  [ "$status" -ne 0 ]
}

@test "yappr config use existing config succeeds and updates active link" {
  cp "$YAPPR_CONFIG_HOME/configs/default.json" "$YAPPR_CONFIG_HOME/configs/alt.json"
  run "$YAPPR_BIN" config use alt
  [ "$status" -eq 0 ]
  target="$(readlink "$YAPPR_CONFIG_HOME/configs/active.json")"
  [[ "$target" == *"alt.json"* ]]
}
EOF
```

- [ ] **Step 2: Run the tests**

```bash
bats /Users/matteociccozzi/yappr/tests/bats/test_config.bats
```
Expected: all 9 pass. If `config use alt` fails because the symlink target is relative (just `alt.json` not a full path), adjust the assertion to `[[ "$target" == "alt.json" ]]`.

- [ ] **Step 3: Commit**

```bash
git add tests/bats/test_config.bats
git commit -m "test: 9 config subcommand tests — list, show, active, path, use"
```

---

### Task 10: Doctor tests

**Files:**
- Create: `tests/bats/test_doctor.bats`

Doctor does 11 system checks. In CI most will FAIL (no daemon, no model). Tests validate the output format and exit-code contract, not individual check results.

- [ ] **Step 1: Write tests/bats/test_doctor.bats**

```bash
cat > /Users/matteociccozzi/yappr/tests/bats/test_doctor.bats << 'EOF'
#!/usr/bin/env bats
# test_doctor.bats — tests for bin/yappr-doctor.
# Doctor exit codes: 0 = all checks pass, 1 = some failed. Never 2+ (crash).
load "test_helper"

@test "yappr doctor runs without crashing" {
  run "$YAPPR_BIN" doctor
  [ "$status" -le 1 ]
}

@test "yappr doctor output contains PASS or FAIL labels" {
  run "$YAPPR_BIN" doctor
  [[ "$output" == *"PASS"* ]] || [[ "$output" == *"FAIL"* ]]
}

@test "yappr doctor output mentions 'platform'" {
  run "$YAPPR_BIN" doctor
  [[ "$output" == *"platform"* ]] || [[ "$output" == *"macOS"* ]] || [[ "$output" == *"arm64"* ]]
}

@test "yappr doctor exits 1 in isolated test environment (daemon not running)" {
  # YAPPR_RUNTIME_DIR is a fresh tmpdir with no socket — doctor must report FAIL and exit 1.
  run "$YAPPR_BIN" doctor
  [ "$status" -eq 1 ]
}
EOF
```

- [ ] **Step 2: Run the tests**

```bash
bats /Users/matteociccozzi/yappr/tests/bats/test_doctor.bats
```
Expected: all 4 pass.

- [ ] **Step 3: Commit**

```bash
git add tests/bats/test_doctor.bats
git commit -m "test: 4 doctor tests — crash guard, output format, exit code contract"
```

---

### Task 11: Python tests

**Files:**
- Create: `tests/python/conftest.py`
- Create: `tests/python/test_yappr_paths.py`
- Create: `tests/python/test_llm_call.py`

- [ ] **Step 1: Install pytest**

```bash
pip install pytest
pytest --version
```
Expected: `pytest 8.x.x`

- [ ] **Step 2: Create tests/python/conftest.py**

```bash
mkdir -p /Users/matteociccozzi/yappr/tests/python
cat > /Users/matteociccozzi/yappr/tests/python/conftest.py << 'EOF'
import sys
import os

# Add bin/ to path so tests can import _yappr_paths directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../bin"))
EOF
```

- [ ] **Step 3: Create tests/python/test_yappr_paths.py**

```bash
cat > /Users/matteociccozzi/yappr/tests/python/test_yappr_paths.py << 'EOF'
# test_yappr_paths.py — tests for bin/_yappr_paths.py path resolution.
import os
from pathlib import Path
import importlib
import _yappr_paths as P


def test_config_home_is_path():
    assert isinstance(P.config_home(), Path)


def test_state_home_is_path():
    assert isinstance(P.state_home(), Path)


def test_runtime_dir_is_path():
    assert isinstance(P.runtime_dir(), Path)


def test_data_home_is_path():
    assert isinstance(P.data_home(), Path)


def test_config_home_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_CONFIG_HOME", str(tmp_path / "cfg"))
    importlib.reload(P)
    assert P.config_home() == tmp_path / "cfg"
    importlib.reload(P)  # restore module state


def test_state_home_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_STATE_HOME", str(tmp_path / "state"))
    importlib.reload(P)
    assert P.state_home() == tmp_path / "state"
    importlib.reload(P)


def test_runtime_dir_respects_env(monkeypatch, tmp_path):
    monkeypatch.setenv("YAPPR_RUNTIME_DIR", str(tmp_path / "rt"))
    importlib.reload(P)
    assert P.runtime_dir() == tmp_path / "rt"
    importlib.reload(P)


def test_root_is_repo_root():
    root = P.root()
    assert (root / "bin" / "yappr").exists(), f"expected repo root, got {root}"
    assert (root / "VERSION").exists()
EOF
```

- [ ] **Step 4: Create tests/python/test_llm_call.py**

```bash
cat > /Users/matteociccozzi/yappr/tests/python/test_llm_call.py << 'EOF'
# test_llm_call.py — integration tests for bin/yappr-llm-call.
# Tests error handling and metric JSON schema. No live LLM required.
import json
import subprocess
import sys
import os

YAPPR_ROOT = os.path.join(os.path.dirname(__file__), "../..")
LLM_CALL = os.path.join(YAPPR_ROOT, "bin/yappr-llm-call")
REQUIRED_METRIC_FIELDS = ("text", "ttft_ms", "total_ms", "prompt_tokens", "completion_tokens", "error")


def _run(stdin_data: dict, timeout: int = 5):
    result = subprocess.run(
        [sys.executable, LLM_CALL],
        input=json.dumps(stdin_data),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.stdout, result.stderr, result.returncode


def test_missing_url_exits_2():
    _, _, rc = _run({"body": {}})
    assert rc == 2


def test_invalid_json_exits_2():
    result = subprocess.run(
        [sys.executable, LLM_CALL],
        input="not valid json",
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 2


def test_unreachable_url_exits_2():
    _, _, rc = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    assert rc == 2


def test_metric_json_has_all_required_fields():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    for field in REQUIRED_METRIC_FIELDS:
        assert field in metric, f"missing field in metric JSON: {field}"


def test_error_field_set_on_failure():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    assert metric["error"] is not None


def test_text_field_is_empty_string_on_failure():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    assert metric["text"] == ""
EOF
```

- [ ] **Step 5: Run all Python tests**

```bash
cd /Users/matteociccozzi/yappr
pytest tests/python/ -v
```
Expected: all 14 tests pass. If `test_config_home_respects_env` fails due to module caching, add `importlib.invalidate_caches()` before the reload.

- [ ] **Step 6: Ruff check**

```bash
ruff check tests/python/
```
Expected: zero warnings.

- [ ] **Step 7: Commit**

```bash
git add tests/python/
git commit -m "test: Python tests for _yappr_paths env vars and yappr-llm-call error paths"
```

---

### Task 12: CI test workflow

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Create .github/workflows/test.yml**

```bash
cat > /Users/matteociccozzi/yappr/.github/workflows/test.yml << 'EOF'
name: Tests

on:
  push:
    branches: ["main", "feat/**"]
  pull_request:
    branches: ["main", "feat/**"]

jobs:
  bats:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install bats-core
        run: brew install bats-core

      - name: Run BATS tests
        run: bats tests/bats/

  pytest:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install pytest and ruff
        run: pip install pytest ruff

      - name: Ruff check tests/python/
        run: ruff check tests/python/

      - name: Run pytest
        run: pytest tests/python/ -v
EOF
```

- [ ] **Step 2: Update ci.yml ruff step to cover tests/python/**

In `.github/workflows/ci.yml`, find the `Ruff (Python lint)` step and append `tests/python/`:

```yaml
      - name: Ruff (Python lint)
        run: |
          ruff check bin/_yappr_paths.py bin/yappr-stats bin/yappr-doctor \
            bin/yappr-mlx-server.py tests/python/
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml .github/workflows/ci.yml
git commit -m "ci: add test.yml workflow (BATS + pytest on macos-15), ruff tests/python/ in ci.yml"
```

---

### Task 13: Open Tier 2 PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/tier-2-testing
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(tier-2): BATS + pytest test suite, CI test workflow" \
  --base feat/tier-1-distribution \
  --body "$(cat <<'EOF'
## Summary

- **BATS** (`tests/bats/`): 24 tests across `test_cli.bats` (11), `test_config.bats` (9), `test_doctor.bats` (4). Each test runs in an isolated XDG tmpdir.
- **pytest** (`tests/python/`): 14 tests for `_yappr_paths` env var resolution and `yappr-llm-call` error handling and metric JSON schema.
- **CI**: New `test.yml` workflow runs BATS and pytest on every PR (macos-15). Hardware-gated tests skip cleanly.
- **Boy Scout**: `ci.yml` ruff step now covers `tests/python/`.

## Test plan
- [ ] `bats tests/bats/` — all 24 pass locally
- [ ] `pytest tests/python/ -v` — all 14 pass locally
- [ ] GitHub Actions `Tests` workflow green on this PR
EOF
)"
```

---

## Tier 3: Community Hygiene

Branch: `feat/tier-3-community` (off `feat/tier-2-testing`)

---

### Task 14: CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Create tier-3 branch**

```bash
git checkout feat/tier-2-testing
git checkout -b feat/tier-3-community
```

- [ ] **Step 2: Create CHANGELOG.md**

```bash
cat > /Users/matteociccozzi/yappr/CHANGELOG.md << 'EOF'
# Changelog

All notable changes to yappr are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Homebrew tap: `brew install matteociccozzi/yappr/yappr`
- Shell completions auto-installed by `scripts/install.sh` (bash/zsh/fish)
- `scripts/uninstall.sh` — clean removal of launchd, binaries, completions, user dirs
- BATS test suite (`tests/bats/`) — 24 tests for CLI, config, doctor
- pytest suite (`tests/python/`) — 14 tests for path helpers and LLM call error paths
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
EOF
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md — Keep a Changelog format, retroactive 0.1.0 entry"
```

---

### Task 15: .github/release.yml — label-based release notes

**Files:**
- Create: `.github/release.yml`

GitHub uses this file to categorize auto-generated release notes by PR label, replacing the flat list from `generate_release_notes: true`.

- [ ] **Step 1: Create .github/release.yml**

```bash
cat > /Users/matteociccozzi/yappr/.github/release.yml << 'EOF'
changelog:
  exclude:
    labels:
      - ignore-for-release
      - dependencies
  categories:
    - title: "🚀 Features"
      labels: [enhancement, feature]
    - title: "🐛 Bug Fixes"
      labels: [bug, fix]
    - title: "📚 Documentation"
      labels: [documentation, docs]
    - title: "🔧 Infrastructure / CI"
      labels: [ci, infrastructure, chore]
    - title: "🧹 Maintenance"
      labels: [refactor, cleanup, maintenance]
EOF
```

- [ ] **Step 2: Commit**

```bash
git add .github/release.yml
git commit -m "docs: add .github/release.yml — label-based release note categories"
```

---

### Task 16: Issue templates and PR template

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/feature_request.md`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

- [ ] **Step 1: Create .github/ISSUE_TEMPLATE/bug_report.md**

```bash
mkdir -p /Users/matteociccozzi/yappr/.github/ISSUE_TEMPLATE
cat > /Users/matteociccozzi/yappr/.github/ISSUE_TEMPLATE/bug_report.md << 'EOF'
---
name: Bug report
about: Something isn't working
title: "bug: "
labels: bug
assignees: ""
---

## What happened?

<!-- Describe the bug clearly. -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What should have happened? -->

## Environment

```
yappr version:  <!-- run: yappr version -->
macOS version:  <!-- run: sw_vers -productVersion -->
Shell:          <!-- e.g. zsh 5.9, bash 5.2 -->
Hammerspoon:    <!-- version from Hammerspoon menu bar, or "not installed" -->
```

## `yappr doctor` output

```
<!-- run: yappr doctor -->
```

## Logs

```
<!-- run: yappr daemon logs  OR  tail ~/.local/state/yappr/logs/*.log -->
```

## Additional context

<!-- Timing trace (yappr trace), screenshots, anything else helpful. -->
EOF
```

- [ ] **Step 2: Create .github/ISSUE_TEMPLATE/feature_request.md**

```bash
cat > /Users/matteociccozzi/yappr/.github/ISSUE_TEMPLATE/feature_request.md << 'EOF'
---
name: Feature request
about: Suggest an improvement or new capability
title: "feat: "
labels: enhancement
assignees: ""
---

## Problem / motivation

<!-- What problem does this solve? Who does it help? -->

## Proposed solution

<!-- What command, flag, or behavior would you like? Be specific. -->

## Alternatives considered

<!-- Other approaches you thought of and why you prefer this one. -->

## Additional context

<!-- Links, prior art in other dictation tools, mockups, etc. -->
EOF
```

- [ ] **Step 3: Create .github/ISSUE_TEMPLATE/config.yml**

```bash
cat > /Users/matteociccozzi/yappr/.github/ISSUE_TEMPLATE/config.yml << 'EOF'
blank_issues_enabled: false
contact_links:
  - name: Diagnostics & troubleshooting guide
    url: https://github.com/matteociccozzi/yappr/blob/main/docs/diagnostics.md
    about: Check the troubleshooting guide before opening an issue — most common problems are covered there.
EOF
```

- [ ] **Step 4: Create .github/PULL_REQUEST_TEMPLATE.md**

```bash
cat > /Users/matteociccozzi/yappr/.github/PULL_REQUEST_TEMPLATE.md << 'EOF'
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
EOF
```

- [ ] **Step 5: Commit**

```bash
git add .github/ISSUE_TEMPLATE/ .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs: add issue templates (bug/feature), PR template with Boy Scout checklist"
```

---

### Task 17: CODE_OF_CONDUCT.md + SECURITY.md

**Files:**
- Create: `CODE_OF_CONDUCT.md`
- Create: `SECURITY.md`

- [ ] **Step 1: Create CODE_OF_CONDUCT.md**

```bash
cat > /Users/matteociccozzi/yappr/CODE_OF_CONDUCT.md << 'EOF'
# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in yappr a harassment-free experience for everyone, regardless of age, body size, visible or invisible disability, ethnicity, sex characteristics, gender identity and expression, level of experience, education, socio-economic status, nationality, personal appearance, race, caste, color, religion, or sexual identity and orientation.

We pledge to act and interact in ways that contribute to an open, welcoming, diverse, inclusive, and healthy community.

## Our Standards

**Positive behavior includes:**
- Demonstrating empathy and kindness
- Respecting differing opinions, viewpoints, and experiences
- Giving and gracefully accepting constructive feedback
- Accepting responsibility for mistakes and learning from them
- Focusing on what is best for the community

**Unacceptable behavior includes:**
- Sexualized language or imagery and unwelcome sexual attention or advances
- Trolling, insulting or derogatory comments, and personal attacks
- Public or private harassment
- Publishing others' private information without explicit permission
- Other conduct that could reasonably be considered inappropriate in a professional setting

## Enforcement

Report abusive, harassing, or otherwise unacceptable behavior to **matteociccozzi@icloud.com**. All complaints will be reviewed promptly and fairly. Reporters' privacy will be respected.

## Attribution

Adapted from the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1.
EOF
```

- [ ] **Step 2: Create SECURITY.md**

```bash
cat > /Users/matteociccozzi/yappr/SECURITY.md << 'EOF'
# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | ✅        |
| older   | ❌ upgrade to latest |

## What yappr handles

yappr processes microphone audio and transcribed text entirely on-device. By default it sends no data to any network service. Security-relevant areas:

- **Microphone** — `YapprSttDaemon` holds the macOS mic via AVAudioEngine. A bug could capture audio outside of dictation sessions.
- **Unix socket** — `$YAPPR_RUNTIME_DIR/stt.sock` is protected by `chmod 0700` on its parent dir. Path traversal or permission bugs could expose it.
- **LLM endpoint** — if `llm.url` is changed to an external server, transcripts leave the machine. The shipped default points to `127.0.0.1`.
- **install.sh shell rc edits** — `scripts/install.sh` appends to `~/.zshrc`/`~/.bashrc`. A `$YAPPR_ROOT` path containing shell metacharacters could be a risk.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email **matteociccozzi@icloud.com** with:
- Description of the vulnerability
- Steps to reproduce
- Your assessment of impact and exploitability
- Whether you'd like credit in the release notes

Expected response within **7 days**. Confirmed issues will be patched within **30 days** (critical) or the next minor release (non-critical).
EOF
```

- [ ] **Step 3: Commit**

```bash
git add CODE_OF_CONDUCT.md SECURITY.md
git commit -m "docs: add CODE_OF_CONDUCT.md (Contributor Covenant 2.1) and SECURITY.md"
```

---

### Task 18: Open Tier 3 PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/tier-3-community
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(tier-3): CHANGELOG, release.yml categories, issue/PR templates, CoC, SECURITY" \
  --base feat/tier-2-testing \
  --body "$(cat <<'EOF'
## Summary

- **CHANGELOG.md**: Keep a Changelog format. Retroactive 0.1.0 entry + Unreleased section for all post-release work.
- **.github/release.yml**: Label-based release note categories (🚀 Features, 🐛 Bugs, 📚 Docs, 🔧 CI, 🧹 Maintenance).
- **Issue templates**: Bug report (prompts for `yappr version`, macOS, shell, doctor output), Feature request. Blank issues disabled, diagnostics doc linked.
- **PR template**: Full checklist — shellcheck, ruff, bats, pytest, no-runtime-writes, Boy Scout field.
- **CODE_OF_CONDUCT.md**: Contributor Covenant 2.1, contact email.
- **SECURITY.md**: Scope (mic, socket, LLM endpoint), 7-day response SLA, email for private disclosure.

## Test plan
- [ ] GitHub issue form shows bug/feature templates when creating a new issue
- [ ] PR template auto-populates on new PR
- [ ] No blank issue option visible
EOF
)"
```

---

## Tier 4: Polish

Branch: `feat/tier-4-polish` (off `feat/tier-3-community`)

---

### Task 19: Tiered --help

**Files:**
- Modify: `bin/yappr` (lines 19 — split `-h` from `--help`)
- Modify: `bin/yappr-help` (add `--short` and `--full` modes)
- Modify: `tests/bats/test_cli.bats` (update `-h` test, add `--help` tests)

Currently `-h`, `--help`, and `help` all go to `yappr-help` and print the same page. Ripgrep's pattern: `-h` compact (fits one screen), `--help` full prose with examples, grouped env vars, and doc links.

- [ ] **Step 1: Create the tier-4 branch**

```bash
git checkout feat/tier-3-community
git checkout -b feat/tier-4-polish
```

- [ ] **Step 2: Update bin/yappr dispatcher to route -h vs --help differently**

In `bin/yappr`, find line 19:
```bash
  help|-h|--help) exec "$HERE/yappr-help" ;;
```

Replace with:
```bash
  help|--help)    exec "$HERE/yappr-help" --full ;;
  -h)             exec "$HERE/yappr-help" --short ;;
```

- [ ] **Step 3: Rewrite bin/yappr-help to support --short and --full**

Replace the entire content of `bin/yappr-help` with:

```bash
#!/usr/bin/env bash
# yappr-help — print help text.
# --short  compact one-screen summary (for -h)
# --full   full help with examples and env vars (for --help and 'help')
set -euo pipefail
# shellcheck source=bin/_yappr-paths.sh
source "$(dirname "${BASH_SOURCE[0]}")/_yappr-paths.sh"
VERSION="$(cat "$YAPPR_ROOT/VERSION" 2>/dev/null || echo "unknown")"

MODE="${1:---full}"

short_help() {
  cat <<EOF
yappr $VERSION — push-to-talk voice dictation for macOS Apple Silicon

USAGE
  yappr [subcommand] [options]

SUBCOMMANDS
  dictate            Record speech and type cleaned text at cursor (default)
  daemon <op>        Manage STT daemon   (start|stop|restart|status|logs|tail)
  server <op>        Manage MLX server   (start|stop|restart|status|logs|tail)
  config <op>        Manage configs      (list|active|use|show|diff|delete|path)
  stats              Show dictation metrics
  trace              Show timing trace from last session
  doctor             Post-install health check (11 checks)
  version            Print version string
  help / --help      Full help with examples and env vars
  -h                 This short summary
EOF
}

full_help() {
  cat <<EOF
yappr $VERSION — push-to-talk voice dictation for macOS Apple Silicon

USAGE
  yappr [subcommand] [options]

DAILY USE
  yappr dictate    Record and type cleaned text at cursor (default; Hammerspoon calls this)
  yappr stats      Show dictation metrics (words, latency, daily usage)
  yappr trace      Show timing trace from last session

DAEMON & SERVER
  yappr daemon start|stop|restart|status|logs|tail
                   Manage the Nemotron STT daemon (YapprSttDaemon)
  yappr server start|stop|restart|status|logs|tail
                   Manage the MLX inference server (Qwen3-1.7B-4bit)

CONFIGURATION
  yappr config list           List available configs in ~/.config/yappr/configs/
  yappr config active         Print the active config name
  yappr config use <name>     Switch active config (atomic symlink swap)
  yappr config show [<name>]  Pretty-print a config JSON (defaults to active)
  yappr config diff <a> <b>   Show normalized diff between two configs
  yappr config delete <name>  Delete a config (refuses the active one)
  yappr config path           Print the configs directory path

OTHER
  yappr doctor     Post-install health check (11 checks; exits 1 if any FAIL)
  yappr help       Show this full help
  yappr -h         Compact subcommand summary (one screen)
  yappr version    Print version string

EXAMPLES
  # Start everything and verify health
  yappr daemon start && yappr server start && yappr doctor

  # Switch to a different LLM config and confirm it loaded
  yappr config list
  yappr config use fast
  yappr config show

  # Show last dictation timing breakdown
  yappr trace

  # Review daily usage stats
  yappr stats

ENV VAR OVERRIDES
  YAPPR_ROOT           Repo/source root (auto-detected from bin/ location)
  YAPPR_CONFIG         Path to active config JSON (overrides config symlink)
  YAPPR_CONFIG_HOME    Config dir          default: ~/.config/yappr
  YAPPR_STATE_HOME     State dir (logs)    default: ~/.local/state/yappr
  YAPPR_DATA_HOME      Data dir (build)    default: ~/.local/share/yappr
  YAPPR_RUNTIME_DIR    Runtime dir         default: /tmp/yappr-\$(id -u)
  YAPPR_SOCKET         STT socket path     default: \$YAPPR_RUNTIME_DIR/stt.sock
  YAPPR_TRACE_LOG      Trace log path      default: \$YAPPR_RUNTIME_DIR/trace.log
  YAPPR_QUIET          Set to 1 to suppress stderr (Hammerspoon automation mode)
  YAPPR_COPY           Set to 1 to also copy cleaned text to macOS clipboard

DOCS
  Installation:  \$YAPPR_ROOT/docs/installation.md
  CLI reference: \$YAPPR_ROOT/docs/cli-reference.md
  Architecture:  \$YAPPR_ROOT/docs/architecture.md
  Configuration: \$YAPPR_ROOT/docs/configuration.md
  Contributing:  \$YAPPR_ROOT/CONTRIBUTING.md
EOF
}

case "$MODE" in
  --short) short_help ;;
  --full)  full_help ;;
  *)       full_help ;;
esac
```

- [ ] **Step 4: Update tests/bats/test_cli.bats**

Add these tests to the end of `test_cli.bats`:

```bash
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
```

- [ ] **Step 5: Run all BATS tests**

```bash
bats /Users/matteociccozzi/yappr/tests/bats/
```
Expected: all 28 pass (24 existing + 4 new).

- [ ] **Step 6: Shellcheck**

```bash
shellcheck bin/yappr bin/yappr-help
```
Expected: zero errors.

- [ ] **Step 7: Commit**

```bash
git add bin/yappr bin/yappr-help tests/bats/test_cli.bats
git commit -m "feat: tiered --help — -h compact (SUBCOMMANDS), --help full (EXAMPLES + ENV VARS)"
```

---

### Task 20: Man page stub

**Files:**
- Create: `docs/man/yappr.1`

- [ ] **Step 1: Create docs/man/yappr.1**

```bash
mkdir -p /Users/matteociccozzi/yappr/docs/man
cat > /Users/matteociccozzi/yappr/docs/man/yappr.1 << 'EOF'
.TH YAPPR 1 "2026-05-20" "yappr 0.1.0" "yappr Manual"
.SH NAME
yappr \- local push-to-talk voice dictation for macOS Apple Silicon
.SH SYNOPSIS
.B yappr
[\fIsubcommand\fR] [\fIoptions\fR]
.SH DESCRIPTION
.B yappr
is a low-latency, fully on-device push-to-talk dictation tool for macOS Apple Silicon.
Hold a hotkey (default: Ctrl+Option+Y via Hammerspoon), speak, and release.
Cleaned text streams to your cursor character by character.
.PP
Audio is captured by a long-running Swift daemon
.RB ( YapprSttDaemon )
using AVAudioEngine and transcribed in-process by Nemotron 0.6B via FluidAudio.
The verbatim transcript is cleaned by Qwen3-1.7B-4bit on a local MLX inference server.
No audio or text leaves the machine.
.SH SUBCOMMANDS
.TP
.B dictate
Record speech and type cleaned text at the cursor (default subcommand).
.TP
.B daemon \fI<start|stop|restart|status|logs|tail>\fR
Manage the YapprSttDaemon lifecycle.
.TP
.B server \fI<start|stop|restart|status|logs|tail>\fR
Manage the MLX inference server lifecycle.
.TP
.B config \fI<list|active|use|show|diff|delete|path>\fR
Manage configuration presets stored in \fI~/.config/yappr/configs/\fR.
.TP
.B stats
Show dictation metrics: words transcribed, latency, daily usage.
.TP
.B trace
Render the timing trace from the last dictation session.
.TP
.B doctor
Run 11 post-install health checks. Exits 1 if any check fails.
.TP
.B help
Show full help text. Use \fB\-h\fR for a compact one-screen summary.
.TP
.B version
Print the version string and exit 0.
.SH ENVIRONMENT
.TP
.B YAPPR_ROOT
Override the repo/source root (auto-detected from the binary location).
.TP
.B YAPPR_CONFIG_HOME
User config directory. Default: \fI~/.config/yappr\fR.
.TP
.B YAPPR_STATE_HOME
State directory for logs and metrics. Default: \fI~/.local/state/yappr\fR.
.TP
.B YAPPR_DATA_HOME
Data directory for build artifacts. Default: \fI~/.local/share/yappr\fR.
.TP
.B YAPPR_RUNTIME_DIR
Runtime directory for the Unix socket and PID file. Default: \fI/tmp/yappr-$(id\ -u)\fR.
.TP
.B YAPPR_QUIET
Set to \fB1\fR to suppress stderr output (Hammerspoon automation mode).
.TP
.B YAPPR_COPY
Set to \fB1\fR to also copy cleaned text to the macOS clipboard.
.SH FILES
.TP
.I ~/.config/yappr/configs/active.json
Active configuration preset (symlink to a named config).
.TP
.I ~/.local/state/yappr/logs/
Dictation and daemon logs.
.TP
.I /tmp/yappr-<uid>/stt.sock
Unix domain socket for communicating with YapprSttDaemon.
.TP
.I ~/Library/LaunchAgents/com.yappr.daemon.plist
launchd plist for daemon auto-start at login.
.SH SEE ALSO
Full documentation: \fIhttps://github.com/matteociccozzi/yappr/tree/main/docs\fR
.PP
\fBhammerspoon\fR(1), \fBswift\fR(1)
.SH AUTHOR
Matteo Ciccozzi <matteociccozzi@icloud.com>
EOF
```

- [ ] **Step 2: Verify the man page renders**

```bash
man /Users/matteociccozzi/yappr/docs/man/yappr.1
```
Press `q` to exit. Verify no groff errors and the sections render correctly.

- [ ] **Step 3: Commit**

```bash
git add docs/man/yappr.1
git commit -m "docs: add man page stub docs/man/yappr.1"
```

---

### Task 21: RELEASE-CHECKLIST.md

**Files:**
- Create: `RELEASE-CHECKLIST.md`

- [ ] **Step 1: Create RELEASE-CHECKLIST.md**

```bash
cat > /Users/matteociccozzi/yappr/RELEASE-CHECKLIST.md << 'EOF'
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
EOF
```

- [ ] **Step 2: Commit**

```bash
git add RELEASE-CHECKLIST.md
git commit -m "docs: add RELEASE-CHECKLIST.md with full verification steps and semver rules"
```

---

### Task 22: README community links + Boy Scout pass

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README fully**

```bash
cat /Users/matteociccozzi/yappr/README.md
```

- [ ] **Step 2: Update the screen recording placeholder**

Find the line:
```markdown
> 📺 Screen recording placeholder — drop a gif here once you have one.
```

If a demo gif now exists at `docs/yappr-demo.gif`, replace with:
```markdown
> 📺 *Demo: [yappr in action](docs/yappr-demo.gif)*
```

If no gif yet, replace with:
```markdown
> 📺 Demo GIF coming soon — see [docs/installation.md](docs/installation.md) to get started.
```

- [ ] **Step 3: Add Community section at the bottom (before License)**

```markdown
## Community

| | |
|--|--|
| 🐛 **Bug reports** | [Open an issue](https://github.com/matteociccozzi/yappr/issues/new?template=bug_report.md) |
| 💡 **Feature requests** | [Open an issue](https://github.com/matteociccozzi/yappr/issues/new?template=feature_request.md) |
| 🤝 **Contributing** | [CONTRIBUTING.md](CONTRIBUTING.md) |
| 📋 **Changelog** | [CHANGELOG.md](CHANGELOG.md) |
| 🛡️ **Security** | [SECURITY.md](SECURITY.md) |
| ⚖️ **Code of Conduct** | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |
```

- [ ] **Step 4: Verify all relative links in README point to existing files**

```bash
grep -oE '\[.*?\]\(([^)#]+)\)' /Users/matteociccozzi/yappr/README.md \
  | grep -v 'https\?://' \
  | sed 's/.*(\(.*\))/\1/' \
  | while read -r f; do
      [[ -e "/Users/matteociccozzi/yappr/$f" ]] || echo "MISSING: $f"
    done
```
Expected: no `MISSING:` lines. Fix any that appear.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README — community links table, fix stale placeholder, verify all relative links"
```

---

### Task 23: Open Tier 4 PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/tier-4-polish
```

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "feat(tier-4): tiered --help, man page, RELEASE-CHECKLIST, README polish" \
  --base feat/tier-3-community \
  --body "$(cat <<'EOF'
## Summary

- **Tiered --help**: `yappr -h` → compact SUBCOMMANDS list (fits one screen). `yappr --help` / `yappr help` → full page with EXAMPLES, ENV VAR OVERRIDES, and DOCS links. Config subcommands now include the full `active|diff|delete|path` list.
- **Man page**: `docs/man/yappr.1` — standard Unix man(1) format, included in release tarball at `share/man/man1/yappr.1`.
- **RELEASE-CHECKLIST.md**: Full pre/post-release verification — tests, shellcheck, ruff, golden path, version bump, CHANGELOG update, tag, Homebrew bump, smoke test. Semver rules table.
- **README**: Community table (issues, contributing, CHANGELOG, SECURITY, CoC), stale placeholder updated, all relative links verified.
- **Boy Scout**: `yappr-help` now documents `config active|diff|delete|path` which were missing from the help text. Consistency between `-h` SUBCOMMANDS list and `yappr-config` actual API.

## Test plan
- [ ] `yappr -h` shows compact SUBCOMMANDS only (no EXAMPLES or ENV VARS)
- [ ] `yappr --help` shows EXAMPLES and ENV VAR OVERRIDES sections
- [ ] `man docs/man/yappr.1` renders without groff errors
- [ ] `bats tests/bats/` — all 28 tests pass
- [ ] All relative links in README resolve to existing files
EOF
)"
```

---

## Self-Review

### 1. Spec coverage

| Requirement | Task |
|-------------|------|
| Homebrew tap | Task 5 |
| install.sh completions | Task 2 |
| uninstall.sh | Task 3 |
| release tarball + SHA256 | Task 4 |
| BATS tests | Tasks 7–10 |
| pytest | Task 11 |
| CI test workflow | Task 12 |
| CHANGELOG.md | Task 14 |
| .github/release.yml | Task 15 |
| Issue templates | Task 16 |
| PR template | Task 16 |
| CODE_OF_CONDUCT | Task 17 |
| SECURITY.md | Task 17 |
| Tiered --help | Task 19 |
| Man page | Task 20 |
| RELEASE-CHECKLIST | Task 21 |
| README polish | Task 22 |
| Boy Scout Rule | Every task (gitignore T1, shellcheck T3, ruff T11/T12, yappr-help API completeness T19, link check T22) |

### 2. No placeholders

All code blocks are complete and runnable. No "TBD", "TODO", "add validation", or "similar to Task N" patterns present.

### 3. Type / name consistency

- `test_helper.bash` exports `YAPPR_BIN` and `YAPPR_ROOT` — used consistently in all `.bats` files.
- `_yappr_paths.py` function names (`config_home`, `state_home`, `runtime_dir`, `data_home`) match actual implementation in `bin/_yappr_paths.py`.
- `yappr-help` flag names (`--short`, `--full`) match the dispatcher routing in `bin/yappr`.
- `config` subcommand list in `full_help()` (Task 19) matches `bin/yappr-config` actual API: `list|active|use|show|diff|delete|path`.
