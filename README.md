# yappr

<p align="center">
  <img src="docs/yappr-logo.gif" alt="yappr" width="200">
</p>

> **Local, private, low-latency voice dictation for macOS.** Hold a hotkey, talk, release — cleaned-up text streams onto your screen at the cursor. Everything runs on-device on Apple Silicon. No network, no clipboard, no cloud.

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-000000?style=flat-square&logo=apple)
![MLX](https://img.shields.io/badge/MLX-orange?style=flat-square)
![Nemotron](https://img.shields.io/badge/Nemotron%200.6B%20streaming-purple?style=flat-square)
![Qwen3](https://img.shields.io/badge/Qwen3--1.7B--4bit-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

Hold **Ctrl+Option+Y**, speak, release. Under the hood: a resident Swift daemon (Nemotron 0.6B via FluidAudio) owns the mic; each token from the Qwen3-1.7B-4bit cleanup LLM is typed at your cursor as it streams out. All on-device, Apple Silicon only.

---

## Install

### Homebrew (recommended)

```bash
brew install --cask hammerspoon   # push-to-talk hotkey host
brew tap matteociccozzi/yappr
brew install yappr
yappr setup                       # downloads model, installs mlx-lm, writes ~/.hammerspoon/init.lua
```

After setup, grant three macOS permissions (yappr cannot do this for you):

| Permission | App | Where |
|---|---|---|
| Input Monitoring | Hammerspoon | System Settings → Privacy & Security → Input Monitoring |
| Accessibility | Hammerspoon | System Settings → Privacy & Security → Accessibility |
| Microphone | YapprSttDaemon | System Settings → Privacy & Security → Microphone |

Then reload Hammerspoon (menu bar icon → **Reload Config**) and verify:

```bash
yappr doctor
```

Full step-by-step walkthrough: [docs/installation.md](docs/installation.md).

---

## Documentation

| Doc | What's inside |
|---|---|
| [docs/installation.md](docs/installation.md) | Step-by-step setup, permissions, troubleshooting |
| [docs/cli-reference.md](docs/cli-reference.md) | All subcommands, flags, and env var overrides |
| [docs/architecture.md](docs/architecture.md) | Pipeline diagram, component breakdown |
| [docs/performance.md](docs/performance.md) | Benchmark numbers and prefix-caching methodology |
| [docs/configuration.md](docs/configuration.md) | Config schema, env vars, `yappr config` CLI |
| [docs/metrics.md](docs/metrics.md) | Per-run JSONL, `yappr stats` summarizer and A/B comparisons |
| [docs/customization.md](docs/customization.md) | Cleanup prompt, custom vocab, hotkey, model swap |
| [docs/diagnostics.md](docs/diagnostics.md) | Troubleshooting and the cache probe |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev setup, repo layout, how to contribute |

---

## Voice commands

Speak these phrases naturally — the cleanup model interprets them inline and removes the command words from the output.

| Say | Effect |
|---|---|
| "scratch that" / "delete that" / "ignore that" | Remove the previous sentence |
| "new paragraph" | Insert a paragraph break |
| "new line" | Insert a single line break |
| "make this a list" / "bullet list" | Reformat preceding items as a markdown bullet list |
| "all caps X" | Uppercase X (e.g. "all caps qa" → "QA") |
| "period" / "comma" / "question mark" / "colon" | Insert that punctuation when clearly a directive |

Questions and commands in your speech are **rewritten, not answered** — saying "what time is the meeting" yields *"What time is the meeting?"*, not an answer.

---

## Roadmap / known limitations

- English only (Nemotron 0.6B streaming). Multilingual would mean swapping the model in the daemon.
- No speculative decoding yet — there's an [open bug in mlx-lm with the Qwen3 family](https://github.com/ml-explore/mlx-lm/issues/846); revisit later.
- Single-tenant inference server — one lock, one shared cache. Not a load-balanced production thing.
- Full-attention models only — SSM/Mamba/hybrid won't work with the cache primitive.
- Test coverage is growing — BATS CLI tests and Python unit tests run in CI on macOS 15.

---

## Credits

[MLX](https://github.com/ml-explore/mlx) / [mlx-lm](https://github.com/ml-explore/mlx-lm), [FluidAudio](https://github.com/FluidInference/FluidAudio) (streaming Nemotron 0.6B), [Qwen3](https://qwenlm.github.io/), [Hammerspoon](https://www.hammerspoon.org/).

---

## Community

| | |
|--|--|
| Bug reports | [Open an issue](https://github.com/matteociccozzi/yappr/issues/new?template=bug_report.md) |
| Feature requests | [Open an issue](https://github.com/matteociccozzi/yappr/issues/new?template=feature_request.md) |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Changelog | [CHANGELOG.md](CHANGELOG.md) |
| Security | [SECURITY.md](SECURITY.md) |
| Code of Conduct | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |

---

Made by [@matteociccozzi](https://github.com/matteociccozzi) · [MIT License](LICENSE) · PRs and issues welcome.
