# Installation

A step-by-step guide to getting yappr running on a fresh M-series Mac.

## Requirements

- **Hardware:** Apple Silicon (M1/M2/M3/M4). Intel Macs are not supported.
- **macOS:** Sonoma (14) or later.
- **Hammerspoon:** for the push-to-talk hotkey.

---

## Homebrew (recommended)

### 1. Install Hammerspoon

```bash
brew install --cask hammerspoon
```

### 2. Install yappr

```bash
brew tap matteociccozzi/yappr
brew install yappr
```

### 3. Run first-time setup

```bash
yappr setup
```

This downloads the Nemotron STT model (~200 MB), installs mlx-lm, creates
your config dirs, and writes `~/.hammerspoon/init.lua`.

### 4. Grant macOS permissions

macOS requires three permissions to be granted manually. yappr cannot do
this for you.

**a) Input Monitoring → Hammerspoon**

> Required so Hammerspoon can detect the Ctrl+Option+Y hotkey globally.
> Without this, the hotkey does nothing.

1. Open **System Settings → Privacy & Security → Input Monitoring**
2. Click the **+** button and add **Hammerspoon**, or toggle it ON if listed.
3. Hammerspoon may prompt you automatically when you reload its config —
   click **Open System Settings** in that dialog.

**b) Accessibility → Hammerspoon**

> Required so Hammerspoon can type the transcribed text at the cursor.
> Without this, you'll see the recording indicator but no text is typed.

1. Open **System Settings → Privacy & Security → Accessibility**
2. Toggle **Hammerspoon** ON.

**c) Microphone → YapprSttDaemon**

> Required for the STT daemon to access the microphone.
> macOS will prompt the first time the daemon starts.

```bash
yappr daemon start
# macOS shows a Microphone permission dialog — click Allow.
```

If you miss the prompt, add it manually:
**System Settings → Privacy & Security → Microphone → add YapprSttDaemon**

### 5. Reload Hammerspoon and start the server

Click the **Hammerspoon menu bar icon → Reload Config**.

You should see a "yappr loaded" toast. Then:

```bash
yappr server start
```

### 6. Verify

```bash
yappr doctor
```

All checks should be green. Hold **Ctrl+Option+Y** to dictate, release to
finalize and type.

---

## From source

### 1. Clone

```bash
git clone --recurse-submodules https://github.com/matteociccozzi/yappr.git
cd yappr
```

> If you already cloned without `--recurse-submodules`:
> `git submodule update --init --recursive`

### 2. Run the install script

```bash
./scripts/install.sh
```

The script handles everything: Xcode tools, Homebrew packages, Hammerspoon,
mlx-lm, Swift build, codesign, shell PATH, and Hammerspoon config.

**Flags:**

| Flag              | What it does                                                  |
|-------------------|---------------------------------------------------------------|
| `-y`, `--yes`     | Assume yes to all prompts (non-interactive)                   |
| `--skip-optional` | Skip Hammerspoon and mlx-lm (CLI mode, external LLM only)    |
| `-h`, `--help`    | Print the help summary                                        |

### 3. Grant macOS permissions

Same three permissions as the Homebrew path — see [Step 4 above](#4-grant-macos-permissions).

---

## Where yappr stores data

yappr follows the [XDG Base Directory](https://specifications.freedesktop.org/basedir-spec/latest/)
spec. Every path is overridable via its env var.

| What               | Env var              | Default                    |
|--------------------|----------------------|----------------------------|
| Config files       | `YAPPR_CONFIG_HOME`  | `~/.config/yappr`          |
| Metrics, logs      | `YAPPR_STATE_HOME`   | `~/.local/state/yappr`     |
| Cached models      | `YAPPR_CACHE_HOME`   | `~/.cache/yappr`           |
| Socket, PID, trace | `YAPPR_RUNTIME_DIR`  | `/tmp/yappr-$(id -u)`      |
| Built binaries     | `YAPPR_DATA_HOME`    | `~/.local/share/yappr`     |

---

## Running the daemon

```bash
yappr daemon start    # start in background
yappr daemon status   # check if running
yappr daemon stop     # stop
yappr daemon logs     # view log
```

---

## Troubleshooting

**Hotkey does nothing** — Hammerspoon is missing Input Monitoring permission.
Open System Settings → Privacy & Security → Input Monitoring and enable Hammerspoon.
Then reload Hammerspoon (menu bar icon → Reload Config).

**Recording indicator appears but no text is typed** — Hammerspoon is missing
Accessibility permission. Open System Settings → Privacy & Security →
Accessibility and enable Hammerspoon.

**Microphone permission denied** — Open System Settings → Privacy & Security →
Microphone and confirm YapprSttDaemon is enabled. To reset:
```bash
tccutil reset Microphone
yappr daemon start   # re-triggers the prompt
```

**`socket not found`** — the daemon isn't running. Run `yappr daemon start`.

**Transcript empty, no text typed** — LLM endpoint unreachable. Check
`yappr server start` ran successfully and `yappr doctor` shows the server green.

**First dictation drops leading audio** — the daemon is still warming up.
Wait a few seconds after `yappr daemon start` before the first press.

For deeper diagnostics see [`docs/diagnostics.md`](diagnostics.md).
