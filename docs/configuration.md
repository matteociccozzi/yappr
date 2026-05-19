# Configuration

Configs are JSON files in `configs/`. `configs/active.json` is an atomic symlink to whichever one is current. Switching is one command.

Configs in `configs/` only describe the **LLM cleanup stage**. The streaming-STT parameters (model, chunk size, HAL buffer) live in the Swift daemon and are intentionally not exposed as config knobs — see [Daemon-side constants](#daemon-side-constants) below.

## The `yappr-config` CLI

```bash
yappr-config list                # show all configs, mark the active one
yappr-config active              # print active name
yappr-config use v2-mlx-q4       # atomically switch (symlink swap)
yappr-config show                # pretty-print active config
yappr-config show v1-baseline    # pretty-print a specific one
yappr-config diff default v2-mlx-q4   # normalized diff
yappr-config path                # print the configs directory
```

Example `list` output:

```
Configs in /Users/you/toolkit/yappr/configs:

* default              Streaming STT (Nemotron 0.6B @ 560ms via yappr-stt-daemon) + Qwen3-1.7B-4bit cleanup via yappr-mlx-server.
  v1-baseline          Qwen3-1.7B Q8 via llama-server. The first working cleanup setup.
  v2-mlx-q4            Qwen3-1.7B 4-bit via mlx_lm.server. Stock MLX server, no prefix caching.

Active: default
```

## Config schema

```jsonc
{
  "version": "v3-streaming",                       // human label, matches filename
  "description": "...",                            // shown in `yappr-config list`
  "backend": "yappr-mlx-server",                   // informational
  "llm": {
    "url":          "http://127.0.0.1:8081/v1/chat/completions",
    "model_name":   "mlx-community/Qwen3-1.7B-4bit",
    "max_tokens":   512,
    "temperature":  0,
    "extra_params": {                              // freeform; merged into the request body
      "chat_template_kwargs": {"enable_thinking": false}
    }
  },
  "prompt_file": "prompts/cleanup.txt"             // relative to YAPPR_ROOT
}
```

All `llm.*` fields are read by `bin/yappr` at call-time. `extra_params` is merged into the chat-completions body alongside `max_tokens` and `temperature` — use it for backend-specific knobs (e.g. MLX `chat_template_kwargs`).

`prompt_file` points at the cleanup-LLM system prompt; `prompts/cleanup.txt` is the shipped one.

### Hashing

Every metric record stamps:

| Field            | Source                                                       |
|------------------|--------------------------------------------------------------|
| `config_version` | the `version` field (label)                                  |
| `config_hash`    | SHA-256 of the normalized JSON (sorted keys)                 |
| `prompt_hash`    | SHA-256 of the prompt file content                           |

Prompt and config are hashed independently, so editing the prompt without bumping `config_version` still distinguishes before-edit from after-edit runs in the metrics.

## Env vars

Read by `bin/yappr` at call time:

| Var             | Default                              | Purpose                                                                  |
|-----------------|--------------------------------------|--------------------------------------------------------------------------|
| `YAPPR_ROOT`    | `$HOME/toolkit/yappr`                | Repo root.                                                               |
| `YAPPR_CONFIG`  | `$YAPPR_ROOT/configs/active.json`    | Path to active config. Override for one-off tests without swapping symlink. |
| `YAPPR_QUIET`   | `0`                                  | `1` = stdout is just the streamed text, no end-of-run report. Hammerspoon sets this. |
| `YAPPR_COPY`    | `0`                                  | `1` = also `pbcopy` the cleaned text.                                    |
| `YAPPR_DEBUG`   | `1`                                  | `1` = verbose log lines to the per-run log file.                         |

## Adding a new config

Drop a new JSON file in `configs/` matching the schema, then switch:

```bash
cat > configs/v4-spec-decoding.json <<'EOF'
{
  "version": "v4-spec-decoding",
  "description": "Speculative decoding test (when mlx-lm Qwen3 bug clears)",
  "backend": "yappr-mlx-server-spec",
  "llm": {
    "url": "http://127.0.0.1:8082/v1/chat/completions",
    "model_name": "mlx-community/Qwen3-1.7B-4bit",
    "max_tokens": 512,
    "temperature": 0,
    "extra_params": {
      "chat_template_kwargs": {"enable_thinking": false}
    }
  },
  "prompt_file": "prompts/cleanup.txt"
}
EOF

yappr-config use v4-spec-decoding
```

Every yappr run now stamps the new `config_version`. A/B compare:

```bash
yappr-stats --compare-configs default v4-spec-decoding
```

## Active = symlink

`configs/active.json` is a symlink. `yappr-config use NAME` does an atomic `ln -sfn NAME.json active.json`. The rest of yappr (and `yappr-mlx-server` when restarted) just reads `active.json`.

Point at a config explicitly without changing the symlink:

```bash
YAPPR_CONFIG=~/toolkit/yappr/configs/v2-mlx-q4.json yappr
```

Useful for one-off tests without disrupting your default.

## Daemon-side constants

The STT side of the pipeline lives in `swift/yappr-stt-daemon/`. Its parameters are **hard-coded in Swift** and require a rebuild to change — there are no env vars or config fields for them. This is deliberate (per "no config knobs in personal tools"): a config flag for every alternative keeps dead code alive, so the daemon commits to one set of values and the others are deleted.

| Constant            | Value             | Where                                                                   |
|---------------------|-------------------|-------------------------------------------------------------------------|
| Model               | Nemotron 0.6B     | `swift/yappr-stt-daemon/Sources/YapprSttDaemon/Daemon.swift` (`chunkSize`, `cacheSubdir`) |
| Chunk size          | 560 ms            | same                                                                    |
| HAL buffer          | 256 frames        | `MicCapture.swift`                                                      |
| Socket path         | `/tmp/yappr-stt.sock` | `Daemon.swift` (`socketPath`)                                       |

To switch any of these: edit the constant, `swift build -c release`, restart the daemon.
