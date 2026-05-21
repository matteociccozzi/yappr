> **Historical record.** These issues were discovered during a fresh-install audit on 2026-05-19 and fixed in the Tier 1 branch (`feat/tier-1-install-fixes`). Kept here for reference.

---

# Installation Issues — Fresh Install Audit (2026-05-19)

Discovered during a live fresh install on macOS 15.7.4 / Apple Silicon M1.
Repo was cloned to `~/yappr` (README assumes `~/toolkit/yappr`).

---

## Blockers (install fails without manual intervention)

### #1 — `vendor/FluidAudio` missing from repo

`Package.swift` references `../../vendor/FluidAudio` as a local path dependency,
but `vendor/` doesn't exist in the repo and is not a git submodule. The install
script has no step to fetch it.

**Symptom:** Swift build fails immediately with an opaque CoreML/NSCocoaErrorDomain
error — no hint that a missing directory is the cause.

**Fix:** Add to `install.sh` before the Swift build step:
```bash
git clone https://github.com/FluidInference/FluidAudio.git vendor/FluidAudio
```
Or make it a proper git submodule. Document in the README Quick Install section.

---

### #2 — Hardcoded developer username in `bin/yappr-mlx-server` shebang

Shebang line is `#!/Users/mciccozzi/.local/share/uv/tools/mlx-lm/bin/python3` —
hardcoded to the developer's home directory. Silently fails on any other machine
with `No such file or directory`.

**Fix:** After installing mlx-lm, `install.sh` should rewrite the shebang:
```bash
UV_PYTHON=$(uv run --from mlx-lm python3 -c "import sys; print(sys.executable)")
sed -i '' "1s|.*|#!${UV_PYTHON}|" bin/yappr-mlx-server
```

---

### #3 — Nemotron model weights not downloaded during install

First daemon launch fails with:
```
[ERROR] model load failed: The model is not found at
~/.cache/fluidaudio/models/nemotron-streaming/560ms/preprocessor.mlmodelc
Run `fluidaudiocli nemotron-transcribe --input X --chunk 560` once to populate the cache.
```

But `fluidaudiocli` is not on PATH — it lives inside `vendor/FluidAudio` and must
be built separately. The install script never does this.

**Fix:** Add to `install.sh` after the Swift daemon build:
```bash
# Build fluidaudiocli to trigger model download
(cd vendor/FluidAudio && swift build -c release --product fluidaudiocli)

# Create a 1-second silent WAV and run transcription to populate model cache
python3 -c "
import wave, struct
with wave.open('/tmp/yappr-warmup.wav', 'w') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(struct.pack('<' + 'h'*16000, *([0]*16000)))
"
vendor/FluidAudio/.build/release/fluidaudiocli nemotron-transcribe \
    --input /tmp/yappr-warmup.wav --chunk 560
rm -f /tmp/yappr-warmup.wav
```

---

### #4 — `bin/yappr` and `bin/yappr-config` hardcode `YAPPR_ROOT=~/toolkit/yappr`

Both scripts default `YAPPR_ROOT` to `$HOME/toolkit/yappr`. Any clone outside that
path produces a cryptic `rc=1` error: "No yappr config at ~/toolkit/yappr/configs/active.json".

**Symptom:** Hotkey shows `❌ rc=1` in Hammerspoon alert.

**Fix (one line, already applied as hotfix):** Replace the hardcoded default with
self-detection in both `bin/yappr` and `bin/yappr-config`:
```bash
# Before
YAPPR_ROOT="${YAPPR_ROOT:-$HOME/toolkit/yappr}"

# After
YAPPR_ROOT="${YAPPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
```
Same pattern the install script already uses correctly.

---

## Friction (manual steps not covered by install script or docs)

### #5 — Hammerspoon `init.lua` not written by install script

Users must manually copy a Lua snippet from `docs/installation.md` into
`~/.hammerspoon/init.lua`. The snippet also hardcodes `~/toolkit/yappr/bin/yappr`,
so anyone who clones elsewhere gets a broken `YAPPR_BIN` path and the hotkey silently does nothing.

**Fix:** `install.sh` should write `~/.hammerspoon/init.lua` using `$YAPPR_ROOT`
(which it already knows), prompting the user if a file already exists.

---

### #6 — Clone location assumed to be `~/toolkit/yappr` throughout docs

README Quick Install hardcodes `git clone ... ~/toolkit/yappr`. All doc examples,
the Hammerspoon snippet, and the default `YAPPR_ROOT` in scripts assume this path.
Any deviation causes multiple silent breakages.

**Fix:** Use `$YAPPR_ROOT` as a variable throughout docs, and have `install.sh`
substitute the actual path when writing `init.lua` and any other generated files.

---

### #7 — Hammerspoon Accessibility + Input Monitoring permissions not mentioned prominently

After install, `hs.eventtap.keyStrokes` silently does nothing if Hammerspoon lacks
these permissions. The hotkey fires, recording works, LLM runs — but no text is
typed. There's no error message anywhere.

**Fix:** Add a verification step to `install.sh` (or a prominent post-install
checklist in the README) that tells users exactly where to grant these permissions:
System Settings → Privacy & Security → Accessibility and Input Monitoring.

---

## What worked well

- Xcode CLT, Homebrew, `jq`, `python@3.12` checks — idempotent and correct
- `brew install --cask hammerspoon` — works cleanly
- `uv tool install mlx-lm` — fast, clean, all 18 executables on PATH
- Swift daemon build — succeeds (warnings from FluidAudio are harmless)
- Ad-hoc codesign — works, survives rebuilds
- PATH addition to `~/.zshrc` — correct
- STT pipeline end-to-end — fast, accurate once everything is set up
