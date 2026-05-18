# ⚙️ Configuration

Configs are JSON files in `configs/`. `configs/active.json` is an atomic symlink to whichever one is current. Switching is one command.

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

* default              Default baseline: Qwen3-1.7B-4bit via custom yappr-mlx-server with explicit prefix caching (port 8081).
  v1-baseline          Qwen3-1.7B Q8 via llama-server. The first working cleanup setup.
  v2-mlx-q4            Qwen3-1.7B 4-bit via mlx_lm.server. Default since 2026-05-17.

Active: default
```

## Configs shipped

| Name           | Backend            | Model                          | Port  | Notes                                          |
|----------------|--------------------|--------------------------------|-------|------------------------------------------------|
| `default`      | `yappr-mlx-server` | mlx-community/Qwen3-1.7B-4bit  | 8081  | **Recommended.** Prefix-cached.                |
| `v1-baseline`  | `llama-server`     | Qwen/Qwen3-1.7B-GGUF:Q8_0      | 8080  | Original setup, kept for comparison.           |
| `v2-mlx-q4`    | `mlx_lm.server`    | mlx-community/Qwen3-1.7B-4bit  | 8080  | Stock MLX server. **No prefix caching.**       |

## Config schema

```jsonc
{
  "version": "default",                            // human label, matches filename
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

### Hashing

Every metric record stamps:
- `config_version`: the label
- `config_hash`: SHA-256 of the normalized JSON (sorted keys) — captures structural changes
- `prompt_hash`: SHA-256 of the prompt file content — captures prompt edits independently

So if you edit the prompt without bumping `config_version`, the metrics still distinguish before-edit from after-edit runs.

## Adding a new config

Just write a new JSON file in `configs/` matching the schema, then switch:

```bash
cat > configs/v3-spec-decoding.json <<'EOF'
{
  "version": "v3-spec-decoding",
  "description": "Test config for speculative decoding (when mlx-lm Qwen3 bug clears)",
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

yappr-config use v3-spec-decoding
```

Now every yappr run uses the new config and metrics will show the new `config_version`. A/B comparison:

```bash
yappr-stats --compare-configs default v3-spec-decoding
```

## Active = symlink

`configs/active.json` is a symlink. `yappr-config use NAME` does an atomic `ln -sfn NAME.json active.json`. The rest of yappr (and `yappr-mlx-server` when restarted) just reads `active.json`.

You can also point at a config explicitly without changing the symlink:

```bash
YAPPR_CONFIG=~/toolkit/yappr/configs/v2-mlx-q4.json yappr
```

Useful for one-off tests without disrupting your default.
