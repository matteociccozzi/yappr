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
