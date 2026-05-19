# 📊 Metrics

Every `yappr` run appends one line to `metrics/<YYYY-MM>.jsonl`. Use `yappr-stats` to summarize and slice.

> See also: `docs/diagnostics.md` for `/tmp/yappr-trace.log`, the finer-grained per-stage span log emitted by the streaming daemon.

## JSONL record schema

```jsonc
{
  "ts":                 "2026-05-19T04:28:01Z",
  "llm_url":            "http://127.0.0.1:8081/v1/chat/completions",
  "config_version":     "v3-streaming",
  "config_hash":        "884185e13d7c",            // 12 hex chars of sha256(config json)
  "backend":            "yappr-mlx-server",
  "model_name":         "mlx-community/Qwen3-1.7B-4bit",
  "prompt_hash":        "669b3b383465",            // 12 hex chars of sha256(prompt file)
  "stt_ms":             72,                        // post-EOF finalize only (see note)
  "stt_total_held_ms":  14140,                     // YapprSttConnect start → transcript received
  "llm_ttft_ms":        227,                       // real wall-clock TTFT
  "llm_total_ms":       463,
  "prompt_tokens":      1580,
  "completion_tokens":  44,
  "audio_seconds":      13.883,                    // authoritative sample count from the daemon
  "raw_chars":          212,
  "cleaned_chars":      212
}
```

### Fields

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | UTC ISO-8601 timestamp of the metric append. |
| `llm_url` | string | Chat-completions endpoint used for cleanup. |
| `config_version` | string | `version` field from the active config (e.g. `v3-streaming`). |
| `config_hash` | string | First 12 hex of `sha256(canonical config json)`. |
| `backend` | string | Cleanup backend label from config (e.g. `yappr-mlx-server`). |
| `model_name` | string | Cleanup model id. |
| `prompt_hash` | string | First 12 hex of `sha256(prompt file)`. Independent from `config_hash`. |
| `stt_ms` | int | **Finalize-only**: time from socket half-close to transcript received. Typically 30–80 ms with streaming. |
| `stt_total_held_ms` | int | Wall-clock from `YapprSttConnect` spawn to transcript received. Use this for true held-time analysis. |
| `llm_ttft_ms` | int | Real wall-clock time-to-first-token. |
| `llm_total_ms` | int | Full LLM call duration (request → last token). |
| `prompt_tokens` | int | Prompt tokens reported by the server. |
| `completion_tokens` | int | Completion tokens reported by the server. |
| `audio_seconds` | float | Recorded audio length from the daemon's authoritative sample count. |
| `raw_chars` | int | Length of raw STT output. |
| `cleaned_chars` | int | Length of cleaned LLM output. |

### `stt_ms` semantics — important

The streaming refactor changed what `stt_ms` measures:

- **Pre-streaming**: `stt_ms` = total STT wall-clock (record + transcribe).
- **Now** (`config_version: v3-streaming`): `stt_ms` = post-EOF finalize only. For end-to-end held time, use `stt_total_held_ms`.

Rows from before the bump are still in `metrics/*.jsonl`. When A/B-comparing across versions, filter by `config_version` (e.g. `--compare-configs default v3-streaming`) and remember that `stt_ms` numbers from the two regimes are not comparable.

## `yappr-stats` commands

```bash
yappr-stats                                       # summary of last 20 runs
yappr-stats -n 100                                # last N
yappr-stats --all                                 # all runs
yappr-stats --since "1 hour ago"                  # also: "today", "yesterday", "2 days ago", ISO ts
yappr-stats --config v3-streaming                 # filter to one config_version
yappr-stats --hist llm_ttft_ms                    # ASCII histogram
yappr-stats --trend llm_ttft_ms                   # ASCII trend chart over recent runs
yappr-stats --by-config                           # one summary per config_version
yappr-stats --compare-configs default v3-streaming  # side-by-side A/B
yappr-stats --compare 2026-05-18T00:00:00Z        # before/after a cutoff
yappr-stats --raw                                 # dump matching records as JSONL
yappr-stats --clear                               # archive metrics/ → metrics.bak.<ts>/
yappr-stats --clear -y                            # same, no confirmation prompt
```

Note: `stt_total_held_ms` is emitted in records but not yet in the summary/hist/trend metric list — pull it via `--raw` for now.

### Available metrics for `--hist` / `--trend`

`stt_ms`, `llm_ttft_ms`, `llm_total_ms`, `prompt_tokens`, `completion_tokens`, `audio_seconds`, `raw_chars`, `cleaned_chars`, `tokens_per_sec`, `stt_rtf`.

## Derived metrics

Computed on the fly, not stored:

- `tokens_per_sec` = `completion_tokens / ((llm_total_ms - llm_ttft_ms) / 1000)`. Generation throughput.
- `stt_rtf` = `(stt_ms / 1000) / audio_seconds`. **Caveat under streaming**: because `stt_ms` is finalize-only now, this is effectively "finalize cost per second of audio" — not the classic STT RTF. For the older meaning, compute `(stt_total_held_ms / 1000) / audio_seconds` from `--raw`.

## Example summary

```
📊 20 runs (last: 2026-05-19T04:28:01Z)
  config: v3-streaming  model: mlx-community/Qwen3-1.7B-4bit  backend: yappr-mlx-server

  stt_ms              mean 68      p50 71      p95 78      max 82
  llm_ttft_ms         mean 224     p50 227     p95 241     max 248
  llm_total_ms        mean 322     p50 281     p95 463     max 510
  prompt_tokens       mean 1550    p50 1549    p95 1580    max 1605
  completion_tokens   mean 17      p50 13      p95 44      max 51
  audio_seconds       mean 5.48    p50 3.68    p95 13.88   max 15.02
  raw_chars           mean 83      p50 51      p95 212     max 240
  cleaned_chars       mean 74      p50 51      p95 212     max 240
  tokens_per_sec      mean 145.20  p50 148.50  p95 168.30  max 172.10
  stt_rtf             mean 0.02    p50 0.02    p95 0.04    max 0.07
```

## A/B comparing two configs

```bash
yappr-stats --compare-configs default v3-streaming
```

Side-by-side summary per `config_version`. Use when verifying a tuning change (model swap, prompt edit, server change) is actually faster — not just feels faster.

## Comparing before/after a change

When you edit mid-session, note the time, then later:

```bash
yappr-stats --compare 2026-05-19T04:00:00Z
```

Splits records into BEFORE and AFTER the cutoff and prints both summaries.

## Raw dump for ad-hoc analysis

```bash
yappr-stats --raw                                              # all matching records as JSONL
yappr-stats --raw --since "today" | jq -s 'map(.stt_total_held_ms) | add/length'
yappr-stats --raw | duckdb -c "SELECT config_version, AVG(llm_ttft_ms), COUNT(*) FROM read_json_auto('/dev/stdin') GROUP BY 1"
```

## Clearing

`yappr-stats --clear` archives `metrics/` to `metrics.bak.<YYYYMMDD-HHMMSS>/` (gitignored) and starts fresh. Useful before A/B-ing a big change.
