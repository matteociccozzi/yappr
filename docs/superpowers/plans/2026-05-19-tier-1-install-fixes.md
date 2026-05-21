# Tier 1 — Install Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `git clone --recurse-submodules https://github.com/matteociccozzi/yappr && cd yappr && ./scripts/install.sh` succeed cold on any Apple Silicon Mac, with no manual steps between clone and first working dictation.

**Architecture:** Fix 6 independent blockers discovered during a live fresh-install audit: missing vendor submodule, hardcoded developer shebang, missing model download step, hardcoded YAPPR_ROOT defaults in two scripts, missing Hammerspoon init.lua generation, and missing permissions checklist. Each fix is isolated to specific files. No new abstractions — pure correctness fixes.

**Tech Stack:** bash, Python 3, Swift (SPM), git submodules, Hammerspoon Lua templates

**Branch:** `feat/tier-1-install-fixes` branched from `main`
**PR target:** `main`

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `.gitmodules` | Create | Declare FluidAudio as a proper git submodule |
| `.gitignore` | Modify | Remove `vendor/FluidAudio/` line (now a submodule pointer) |
| `scripts/install.sh` | Modify | Add: submodule fetch, model cache warmup, init.lua write, permissions checklist |
| `scripts/templates/hammerspoon-init.lua.tmpl` | Create | Lua template with `@YAPPR_BIN@` placeholder |
| `bin/yappr-mlx-server` | Modify | Replace Python core with a portable bash launcher |
| `bin/yappr-mlx-server.py` | Create | Renamed Python core (unchanged logic, generic shebang) |
| `bin/yappr-stats` | Modify | Fix hardcoded `~/toolkit/yappr/metrics` path |
| `diagnostics/yappr-probe-caching` | Modify | Fix hardcoded `$HOME/toolkit/yappr` YAPPR_ROOT default |
| `README.md` | Modify | Update clone command to `--recurse-submodules` |
| `docs/installation.md` | Modify | Update clone command and remove hardcoded paths |

---

### Task 1: Create branch and verify baseline

**Files:**
- No file changes

- [ ] **Step 1: Create and switch to tier-1 branch**

```bash
cd /Users/matteociccozzi/yappr
git checkout -b feat/tier-1-install-fixes
```

Expected: `Switched to a new branch 'feat/tier-1-install-fixes'`

- [ ] **Step 2: Confirm current state — vendor dir is missing**

```bash
ls vendor/ 2>/dev/null || echo "vendor/ does not exist — expected"
```

Expected: `vendor/ does not exist — expected`

- [ ] **Step 3: Confirm build currently fails (swift build from daemon dir)**

```bash
cd swift/yappr-stt-daemon && swift build -c release 2>&1 | head -5; cd ../..
```

Expected: error mentioning `vendor/FluidAudio` cannot be accessed.

---

### Task 2: Add FluidAudio as a git submodule

**Files:**
- Create: `.gitmodules`
- Modify: `.gitignore`

- [ ] **Step 1: Register the submodule**

```bash
cd /Users/matteociccozzi/yappr
git submodule add https://github.com/FluidInference/FluidAudio.git vendor/FluidAudio
```

Expected: creates `.gitmodules`, clones into `vendor/FluidAudio/`, stages both.

- [ ] **Step 2: Verify Package.swift can be found**

```bash
ls vendor/FluidAudio/Package.swift
```

Expected: file listed.

- [ ] **Step 3: Remove the now-redundant gitignore entry**

Open `.gitignore`. Find and delete the line `vendor/FluidAudio/` (it should appear near the top with other build-artifact ignores). The submodule pointer is tracked by git; the directory contents are not ignored separately.

```bash
grep -n "vendor/FluidAudio" .gitignore
```

Delete that line. Then:

```bash
grep "vendor/FluidAudio" .gitignore && echo "STILL PRESENT — remove it" || echo "removed OK"
```

Expected: `removed OK`

- [ ] **Step 4: Verify git status looks clean**

```bash
git status
```

Expected: `.gitmodules` new file, `vendor/FluidAudio` new file, `.gitignore` modified. No untracked junk.

- [ ] **Step 5: Commit**

```bash
git add .gitmodules vendor/FluidAudio .gitignore
git commit -m "chore: add FluidAudio as git submodule

vendor/FluidAudio was a gitignored full clone with no fetch step in
install.sh. Fresh clones silently lacked it, causing the Swift build to
fail with an opaque CoreML error.

Fixes INSTALL_ISSUES #1."
```

---

### Task 3: Fix hardcoded shebang in bin/yappr-mlx-server

**Files:**
- Create: `bin/yappr-mlx-server.py`
- Modify: `bin/yappr-mlx-server` (replace entirely with bash launcher)

- [ ] **Step 1: Copy the Python core to yappr-mlx-server.py**

```bash
cp bin/yappr-mlx-server bin/yappr-mlx-server.py
```

- [ ] **Step 2: Fix the shebang in the .py file**

The first line of `bin/yappr-mlx-server.py` is currently `#!/Users/mciccozzi/.local/…`. Replace it:

```bash
# Verify the bad shebang is there
head -1 bin/yappr-mlx-server.py

# Replace it
sed -i '' '1s|.*|#!/usr/bin/env python3|' bin/yappr-mlx-server.py

# Verify fixed
head -1 bin/yappr-mlx-server.py
```

Expected after fix: `#!/usr/bin/env python3`

- [ ] **Step 3: Write the new bash launcher as bin/yappr-mlx-server**

Overwrite `bin/yappr-mlx-server` entirely with:

```bash
cat > bin/yappr-mlx-server << 'EOF'
#!/usr/bin/env bash
# yappr-mlx-server — portable launcher for the MLX inference server.
# Resolves the uv-managed mlx-lm Python interpreter at runtime so this
# script works on any machine regardless of home directory path.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=""
if command -v uv >/dev/null 2>&1; then
  PY="$(uv tool run --from mlx-lm python3 -c "import sys; print(sys.executable)" 2>/dev/null || true)"
fi
exec "${PY:-python3}" "$HERE/yappr-mlx-server.py" "$@"
EOF
chmod +x bin/yappr-mlx-server
```

- [ ] **Step 4: Verify the launcher is executable and resolves correctly**

```bash
bash -n bin/yappr-mlx-server && echo "syntax OK"
head -3 bin/yappr-mlx-server
```

Expected: `syntax OK` and the shebang + comment lines.

- [ ] **Step 5: Verify the Python core has the correct shebang**

```bash
head -1 bin/yappr-mlx-server.py
```

Expected: `#!/usr/bin/env python3`

- [ ] **Step 6: Commit**

```bash
git add bin/yappr-mlx-server bin/yappr-mlx-server.py
git commit -m "fix: replace hardcoded shebang in yappr-mlx-server with portable launcher

The shebang was #!/Users/mciccozzi/.local/... — hardcoded to the
developer's home directory. Broke silently on every other machine.

Split into a bash launcher (bin/yappr-mlx-server) that resolves the
uv-managed Python at runtime, and a renamed Python core
(bin/yappr-mlx-server.py). No logic changes to the server itself.

Fixes INSTALL_ISSUES #2."
```

---

### Task 4: Fix YAPPR_ROOT hardcoding in yappr-stats and yappr-probe-caching

**Files:**
- Modify: `bin/yappr-stats` (lines ~20-25)
- Modify: `diagnostics/yappr-probe-caching` (line 13)

- [ ] **Step 1: Find the exact hardcoded lines**

```bash
grep -n "toolkit/yappr" bin/yappr-stats diagnostics/yappr-probe-caching
```

Expected: shows line numbers with `~/toolkit/yappr` defaults.

- [ ] **Step 2: Fix bin/yappr-stats**

Find the block that sets `METRICS_DIR` to a hardcoded path and replace it. The relevant section looks like:

```python
METRICS_DIR = Path.home() / "toolkit" / "yappr" / "metrics"
```

Replace with (add `import os` near the top imports if not already present):

```python
_self = Path(__file__).resolve()
YAPPR_ROOT = Path(os.environ.get("YAPPR_ROOT") or _self.parent.parent)
METRICS_DIR = Path(os.environ.get("YAPPR_METRICS_DIR") or YAPPR_ROOT / "metrics")
```

Verify `import os` is present at the top of the file:
```bash
head -10 bin/yappr-stats | grep "import os" || echo "need to add import os"
```

If missing, add `import os` after the existing `import` block.

- [ ] **Step 3: Fix diagnostics/yappr-probe-caching**

```bash
# Show current line 13
sed -n '13p' diagnostics/yappr-probe-caching
```

Replace whatever `YAPPR_ROOT=...toolkit/yappr...` line is there:

```bash
sed -i '' 's|YAPPR_ROOT="${YAPPR_ROOT:-$HOME/toolkit/yappr}"|YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." \&\& pwd)}"|' diagnostics/yappr-probe-caching
```

Verify:
```bash
grep "YAPPR_ROOT" diagnostics/yappr-probe-caching | head -3
```

Expected: shows self-detection pattern, no `toolkit/yappr`.

- [ ] **Step 4: Quick smoke test yappr-stats path resolution**

```bash
cd /Users/matteociccozzi/yappr
python3 -c "
import sys, os
sys.argv = ['yappr-stats']
# Simulate what the script does
from pathlib import Path
_self = Path('bin/yappr-stats').resolve()
YAPPR_ROOT = Path(os.environ.get('YAPPR_ROOT') or _self.parent.parent)
METRICS_DIR = Path(os.environ.get('YAPPR_METRICS_DIR') or YAPPR_ROOT / 'metrics')
print('YAPPR_ROOT:', YAPPR_ROOT)
print('METRICS_DIR:', METRICS_DIR)
assert str(YAPPR_ROOT) == '/Users/matteociccozzi/yappr', f'Wrong root: {YAPPR_ROOT}'
print('OK')
"
```

Expected: prints the correct paths and `OK`.

- [ ] **Step 5: Commit**

```bash
git add bin/yappr-stats diagnostics/yappr-probe-caching
git commit -m "fix: self-detect YAPPR_ROOT in yappr-stats and yappr-probe-caching

Both scripts defaulted YAPPR_ROOT to ~/toolkit/yappr, breaking on any
other clone location. Applied the same self-detection pattern already
used in bin/yappr and bin/yappr-config.

yappr-stats also now respects YAPPR_METRICS_DIR env var for power users.

Fixes INSTALL_ISSUES #4 (remaining scripts)."
```

---

### Task 5: Create Hammerspoon init.lua template

**Files:**
- Create: `scripts/templates/hammerspoon-init.lua.tmpl`

- [ ] **Step 1: Create the templates directory**

```bash
mkdir -p scripts/templates
```

- [ ] **Step 2: Write the template**

The template is the Lua block from `docs/installation.md` (lines 179–256) with two substitutions:
- `os.getenv("HOME") .. "/toolkit/yappr/bin/yappr"` → `"@YAPPR_BIN@"`
- The hardcoded trace log path in the `trace()` function → `"@YAPPR_TRACE_LOG@"`

```bash
cat > scripts/templates/hammerspoon-init.lua.tmpl << 'TMPL'
-- @yappr-installed@ (managed by scripts/install.sh — re-run install to regenerate)
-- yappr: hold Ctrl+Option+Y to dictate.
-- Press → spawn bin/yappr, which opens the yappr-stt-daemon socket.
-- Release → SIGTERM to bin/yappr → forwarded to YapprSttConnect
--         → half-closes socket → daemon finalizes transcript.
-- bin/yappr runs LLM cleanup and streams cleaned tokens to stdout,
-- which Hammerspoon types at the cursor.

local YAPPR_BIN      = "@YAPPR_BIN@"
local YAPPR_TRACE_LOG = "@YAPPR_TRACE_LOG@"

local recording = false  -- guard against keyDown autorepeat
local task = nil

local function trace(event)
  local us = math.floor(hs.timer.secondsSinceEpoch() * 1e6)
  local f = io.open(YAPPR_TRACE_LOG, "a")
  if f then
    f:write(string.format("%d hs %s\n", us, event))
    f:close()
  end
end

local function start()
  trace("hs_press")
  hs.alert.closeAll()
  hs.alert.show("🎙️ Recording…", 9999)

  local streamCallback = function(_taskHandle, stdOut, _stdErr)
    if stdOut and #stdOut > 0 then
      hs.eventtap.keyStrokes(stdOut)
    end
    return true
  end

  local finalCallback = function(exitCode, _stdOut, stdErr)
    hs.alert.closeAll()
    if exitCode ~= 0 then
      local msg = (stdErr and #stdErr > 0) and stdErr:sub(-200) or ("rc=" .. tostring(exitCode))
      print("[yappr] failed: " .. msg)
      hs.alert.show("❌ " .. msg:sub(1, 120), 3)
    end
  end

  task = hs.task.new(
    "/bin/bash",
    finalCallback,
    streamCallback,
    {
      "-c",
      "YAPPR_QUIET=1 PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin " .. YAPPR_BIN,
    }
  )
  trace("hs_task_start_call")
  task:start()
  trace("hs_task_start_return")
end

local function stop()
  trace("hs_release")
  if task then
    task:terminate()
    task = nil
  end
end

hs.hotkey.bind({"ctrl", "alt"}, "y",
  function()
    if not recording then recording = true; start() end
  end,
  function()
    if recording then recording = false; stop() end
  end
)

hs.alert.show("yappr loaded — hold Ctrl+Option+Y to dictate", 2)
TMPL
```

- [ ] **Step 3: Verify placeholders are present**

```bash
grep "@YAPPR_BIN@\|@YAPPR_TRACE_LOG@\|@yappr-installed@" scripts/templates/hammerspoon-init.lua.tmpl
```

Expected: all three placeholders found.

- [ ] **Step 4: Commit**

```bash
git add scripts/templates/hammerspoon-init.lua.tmpl
git commit -m "feat: add Hammerspoon init.lua template with path placeholders

install.sh will render this at install time using the actual YAPPR_ROOT,
eliminating the need for users to manually copy Lua snippets from the docs
and eliminating the ~/toolkit/yappr hardcoding.

Fixes INSTALL_ISSUES #3 (partial — install.sh wiring is the next task)."
```

---

### Task 6: Wire install.sh — submodule fetch, model cache, init.lua write, permissions

**Files:**
- Modify: `scripts/install.sh`

This is the largest task. Make all changes to `install.sh` then commit once.

- [ ] **Step 1: Add submodule step after sanity checks, before Xcode step**

Find the line `step "Xcode command-line tools"` in `install.sh`. Insert the following block immediately before it:

```bash
# -----------------------------------------------------------------------------
# 1b. Submodules
# -----------------------------------------------------------------------------

step "Submodules (vendor/FluidAudio)"

if [[ ! -f "$YAPPR_ROOT/vendor/FluidAudio/Package.swift" ]]; then
  info "Initializing vendor/FluidAudio submodule..."
  git -C "$YAPPR_ROOT" submodule update --init --recursive
fi
[[ -f "$YAPPR_ROOT/vendor/FluidAudio/Package.swift" ]] \
  || fail "vendor/FluidAudio submodule init failed. Try: git submodule update --init"
ok "vendor/FluidAudio present"
```

- [ ] **Step 2: Add model cache warmup step after Swift daemon build step**

Find the line `step "Codesign daemon binaries"` in `install.sh`. Insert the following block immediately before it:

```bash
# -----------------------------------------------------------------------------
# 7b. Populate Nemotron model cache
# -----------------------------------------------------------------------------

step "Nemotron model cache (~/.cache/fluidaudio/)"

NEMOTRON_CACHE="$HOME/.cache/fluidaudio/models/nemotron-streaming/560ms"
if [[ -f "$NEMOTRON_CACHE/preprocessor.mlmodelc/coremldata.bin" ]]; then
  ok "models already cached at $NEMOTRON_CACHE"
else
  info "Building fluidaudiocli and downloading Nemotron models (~200 MB, one-time)..."
  (cd "$YAPPR_ROOT/vendor/FluidAudio" \
    && swift build -c release --product fluidaudiocli 2>&1 | tail -3)
  WARMUP_WAV="$(mktemp).wav"
  python3 - <<PY
import wave, struct
with wave.open("$WARMUP_WAV", "w") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(struct.pack("<" + "h" * 16000, *([0] * 16000)))
PY
  "$YAPPR_ROOT/vendor/FluidAudio/.build/release/fluidaudiocli" \
    nemotron-transcribe --input "$WARMUP_WAV" --chunk 560 >/dev/null 2>&1
  rm -f "$WARMUP_WAV"
  if [[ -f "$NEMOTRON_CACHE/preprocessor.mlmodelc/coremldata.bin" ]]; then
    ok "models cached at $NEMOTRON_CACHE"
  else
    fail "Model cache still empty after warmup. Run manually: vendor/FluidAudio/.build/release/fluidaudiocli nemotron-transcribe --input <any.wav> --chunk 560"
  fi
fi
```

- [ ] **Step 3: Add Hammerspoon init.lua write step after Hammerspoon install step**

Find the section that ends with `ok "Installed Hammerspoon"` and `info "Launch Hammerspoon once..."`. After that block (still inside the `if [[ $SKIP_OPTIONAL -eq 0 ]]; then` guard), add:

```bash
  # Write Hammerspoon init.lua from template
  step "Hammerspoon config (~/.hammerspoon/init.lua)"
  if [[ -d "/Applications/Hammerspoon.app" ]]; then
    TMPL_FILE="$YAPPR_ROOT/scripts/templates/hammerspoon-init.lua.tmpl"
    HS_DIR="$HOME/.hammerspoon"
    HS_FILE="$HS_DIR/init.lua"
    mkdir -p "$HS_DIR"
    YAPPR_TRACE_DEFAULT="/tmp/yappr-$(id -u)/trace.log"
    if [[ -f "$HS_FILE" ]] && ! grep -q "@yappr-installed@" "$HS_FILE" 2>/dev/null; then
      warn "$HS_FILE already exists and is not yappr-managed."
      if prompt_yn "Back it up and replace with yappr's config?" "N"; then
        cp "$HS_FILE" "$HS_FILE.bak.$(date +%s)"
        ok "backed up to $HS_FILE.bak.*"
      else
        warn "Skipped. Wire init.lua manually — see docs/installation.md (Hammerspoon section)."
        WROTE_HS=0
      fi
    fi
    if [[ "${WROTE_HS:-1}" -eq 1 ]]; then
      sed \
        -e "s|@YAPPR_BIN@|$YAPPR_ROOT/bin/yappr|g" \
        -e "s|@YAPPR_TRACE_LOG@|$YAPPR_TRACE_DEFAULT|g" \
        "$TMPL_FILE" > "$HS_FILE"
      ok "wrote $HS_FILE"
      info "Reload Hammerspoon: menu bar icon → Reload Config"
    fi
  fi
```

- [ ] **Step 4: Rewrite the closing summary block with permissions checklist**

Find the closing `cat <<EOF` block at the bottom of `install.sh` (the "Next steps" section). Replace it entirely with:

```bash
cat <<EOF

${BOLD}${GREEN}✅ Install complete.${RESET}

${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
${BOLD}⚠️  Three permissions you must grant manually${RESET}
   (macOS will not prompt until first use)

  ${BOLD}1. Microphone${RESET} → YapprSttDaemon
     ${DIM}System Settings → Privacy & Security → Microphone${RESET}

  ${BOLD}2. Accessibility${RESET} → Hammerspoon
     ${DIM}System Settings → Privacy & Security → Accessibility${RESET}

  ${BOLD}3. Input Monitoring${RESET} → Hammerspoon
     ${DIM}System Settings → Privacy & Security → Input Monitoring${RESET}

${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}

${BOLD}Next steps:${RESET}

  ${BOLD}1.${RESET} Start the STT daemon (or configure launchd — see docs/installation.md):
       $DAEMON_BIN

  ${BOLD}2.${RESET} Start the MLX inference server:
       $YAPPR_ROOT/bin/yappr-mlx-server \\
         --model mlx-community/Qwen3-1.7B-4bit \\
         --system-prompt-file $YAPPR_ROOT/prompts/cleanup.txt

  ${BOLD}3.${RESET} Reload Hammerspoon config (menu bar icon → Reload Config)
     then grant Accessibility + Input Monitoring when prompted.

  ${BOLD}4.${RESET} Hold ${BOLD}Ctrl+Option+Y${RESET}, speak, release. Cleaned text types at cursor.

  ${BOLD}5.${RESET} Verify everything: ${BOLD}yappr doctor${RESET} (coming in a future release)

Full reference: $YAPPR_ROOT/docs/installation.md
EOF
```

- [ ] **Step 5: Validate the script has no syntax errors**

```bash
bash -n scripts/install.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 6: Grep-verify all four additions landed**

```bash
grep -n "Submodules\|Nemotron model\|Hammerspoon config\|Three permissions" scripts/install.sh
```

Expected: four matching lines, each at reasonable line numbers in the file.

- [ ] **Step 7: Commit**

```bash
git add scripts/install.sh
git commit -m "feat: harden install.sh — submodule, model cache, init.lua, permissions

Four additions to scripts/install.sh:

1. Submodule step: git submodule update --init --recursive before Xcode
   check, so vendor/FluidAudio is present before the Swift build.

2. Nemotron model cache: builds fluidaudiocli from vendor/FluidAudio and
   runs a silent-WAV warmup to populate ~/.cache/fluidaudio/ before the
   daemon is first launched.

3. Hammerspoon init.lua: renders scripts/templates/hammerspoon-init.lua.tmpl
   with actual YAPPR_ROOT path, writing ~/.hammerspoon/init.lua. Backs up
   any existing non-yappr-managed file after user confirmation.

4. Permissions checklist: replaces vague 'Next steps' summary with an
   explicit three-permission list (Microphone, Accessibility, Input
   Monitoring) with exact System Settings navigation paths.

Fixes INSTALL_ISSUES #1, #3, #5, #6, #7."
```

---

### Task 7: Update README and docs with --recurse-submodules

**Files:**
- Modify: `README.md`
- Modify: `docs/installation.md`

- [ ] **Step 1: Update README.md clone command**

Find the Quick Install section in `README.md`. The current clone line is:
```
git clone https://github.com/matteociccozzi/yappr.git ~/toolkit/yappr
```

Replace with (keep the user choosing their own location):
```
git clone --recurse-submodules https://github.com/matteociccozzi/yappr.git
cd yappr
./scripts/install.sh
```

Also remove the hardcoded `~/toolkit/yappr` from anywhere in the Quick Install block. Replace with the generic `yappr/` (i.e. whatever they named their clone dir).

- [ ] **Step 2: Update docs/installation.md clone command**

Find the "Recommended: one-shot install" section in `docs/installation.md`. Update the clone block to `--recurse-submodules`. Add a note: "If you already cloned without `--recurse-submodules`, run `git submodule update --init --recursive` inside the repo."

- [ ] **Step 3: Verify no remaining ~/toolkit/yappr in key user-facing files**

```bash
grep -n "toolkit/yappr" README.md docs/installation.md
```

Expected: no output (all references replaced).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/installation.md
git commit -m "docs: update clone command to --recurse-submodules

FluidAudio is now a git submodule, so fresh clones need
--recurse-submodules. Added fallback instruction for people who already
cloned without it. Removed ~/toolkit/yappr hardcoding from install docs."
```

---

### Task 8: Final verification and PR

**Files:**
- No code changes

- [ ] **Step 1: Run shellcheck on all modified bash files**

```bash
shellcheck scripts/install.sh bin/yappr-mlx-server diagnostics/yappr-probe-caching 2>&1
```

Fix any SC errors (warnings about unused vars etc. are OK to ignore if they pre-existed).

- [ ] **Step 2: Verify the Python stats file has no syntax errors**

```bash
python3 -m py_compile bin/yappr-stats && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Verify the template placeholders are correct**

```bash
# Simulate what install.sh does
YAPPR_ROOT="/Users/matteociccozzi/yappr"
TRACE_DEFAULT="/tmp/yappr-$(id -u)/trace.log"
sed \
  -e "s|@YAPPR_BIN@|$YAPPR_ROOT/bin/yappr|g" \
  -e "s|@YAPPR_TRACE_LOG@|$TRACE_DEFAULT|g" \
  scripts/templates/hammerspoon-init.lua.tmpl > /tmp/test-init.lua
grep "@YAPPR" /tmp/test-init.lua && echo "UNSUBSTITUTED PLACEHOLDERS" || echo "all placeholders substituted"
grep "YAPPR_BIN\|YAPPR_TRACE" /tmp/test-init.lua | head -3
```

Expected: `all placeholders substituted`, and the grep shows the real paths.

- [ ] **Step 4: Review all commits on this branch**

```bash
git log main..HEAD --oneline
```

Expected: 6 commits covering Tasks 2–7.

- [ ] **Step 5: Push and open PR**

```bash
git push -u origin feat/tier-1-install-fixes
```

Then open a PR targeting `main` with title: `feat: Tier 1 — install fixes (INSTALL_ISSUES #1–7)`

PR body should list:
- ✅ FluidAudio as git submodule (fixes fresh-clone build failure)
- ✅ Portable bash launcher for yappr-mlx-server (fixes hardcoded shebang)
- ✅ YAPPR_ROOT self-detection in yappr-stats and yappr-probe-caching
- ✅ Hammerspoon init.lua template + auto-write from install.sh
- ✅ Nemotron model cache warmup in install.sh
- ✅ Permissions checklist in install.sh post-install summary
- ✅ Updated clone command in README and installation.md

**Test plan:** Clone into a fresh directory (not `~/yappr`), run `./scripts/install.sh`, verify hotkey works.
