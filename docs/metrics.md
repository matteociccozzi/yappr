# 📊 Metrics

Every `yappr` run appends one line to `metrics/<YYYY-MM>.jsonl`. Use `yappr-stats` to summarize and slice.

## JSONL record schema

```jsonc
{
  "ts":                 "2026-05-17T19:14:22Z",
  "llm_url":            "http://127.0.0.1:8081/v1/chat/completions",
  "config_version":     "default",
  "config_hash":        "a8f2c1d4e0b3",            // 12 hex chars of sha256(config json)
  "backend":            "yappr-mlx-server",
  "model_name":         "mlx-community/Qwen3-1.7B-4bit",
  "prompt_hash":        "7b3d9e2a01f8",            // 12 hex chars of sha256(prompt file)
  "stt_ms":             420,
  "llm_ttft_ms":        104,                       // real wall-clock TTFT, not curl's lie
  "llm_total_ms":       312,
  "prompt_tokens":      363,
  "completion_tokens":  14,
  "audio_seconds":      4.2,
  "raw_chars":          58,                        // length of raw STT output
  "cleaned_chars":      51                         // length of cleaned LLM output
}
```

## `yappr-stats` commands

```bash
yappr-stats                                       # summary of last 20 runs
yappr-stats -n 100                                # last N
yappr-stats --all                                 # all runs
yappr-stats --since "1 hour ago"                  # also: "today", "2 days ago", ISO ts
yappr-stats --hist llm_ttft_ms                    # ASCII histogram of one metric
yappr-stats --trend llm_ttft_ms                   # ASCII trend chart over the last 60 runs
yappr-stats --by-config                           # one summary block per config_version
yappr-stats --compare-configs default v2-mlx-q4   # side-by-side A/B
yappr-stats --compare 2026-05-17T18:00:00Z        # before/after a cutoff
yappr-stats --raw                                 # dump matching records as JSONL
yappr-stats --clear                               # archive metrics/ → metrics.bak.<ts>/
yappr-stats --clear -y                            # same, no confirmation prompt
```

## Example output

```
20 runs (last: 2026-05-17T19:14:22Z)
  config: default  model: mlx-community/Qwen3-1.7B-4bit  backend: yappr-mlx-server

  stt_ms              mean 412     p50 405     p95 488     max 510
  llm_ttft_ms         mean 104     p50 102     p95 121     max 138
  llm_total_ms        mean 298     p50 285     p95 412     max 480
  prompt_tokens       mean 363     p50 363     p95 363     max 363
  completion_tokens   mean 18      p50 17      p95 28      max 34
  audio_seconds       mean 4.10    p50 4.20    p95 5.80    max 6.20
  raw_chars           mean 62      p50 58      p95 92      max 121
  cleaned_chars       mean 55      p50 51      p95 84      max 110
  tokens_per_sec      mean 71.20   p50 71.80   p95 78.40   max 82.10
  stt_rtf             mean 0.10    p50 0.10    p95 0.12    max 0.14
```

## Derived metrics

Two columns are computed on the fly (not stored in the JSONL):

- `tokens_per_sec` = `completion_tokens / ((llm_total_ms - llm_ttft_ms) / 1000)`. Generation throughput in tokens per second.
- `stt_rtf` (STT real-time factor) = `(stt_ms / 1000) / audio_seconds`. Lower = faster than real-time. Anything below 1.0 means STT is faster than the audio is long.

## Histogram example

```
Histogram of llm_ttft_ms (20 samples):

   100 | █████████████████████████ 12
   105 | ██████ 3
   110 | ██ 1
   115 | █████ 2
   120 |  0
   125 | ██ 1
   130 | ██ 1
   ...
  (n=20, min=99, max=138)
```

## Trend example

```
Trend of llm_ttft_ms:

       138 |          █
       130 |       █  █
       121 |       █  █  █
       115 |  █ █  █  █  █  █
       110 | █████ █  █  █  ██████
       104 | ████████████████████████████████
           +--------------------------------
            32 most recent runs →
```

## A/B comparing two configs

```bash
yappr-stats --compare-configs default v2-mlx-q4
```

Prints two `print_summary` blocks side by side, one per config. The fastest way to verify that a tuning change (model swap, prompt edit, server change) is actually faster — not just feels faster.

## Comparing before/after a change

When you edit something mid-session, note the time, then later:

```bash
yappr-stats --compare 2026-05-17T18:00:00Z
```

Splits records into BEFORE and AFTER the cutoff and shows two summaries.

## Raw dump for ad-hoc analysis

```bash
yappr-stats --raw                       # all matching records as JSONL on stdout
yappr-stats --raw --since "today" | jq -s 'map(.llm_ttft_ms) | add/length'
yappr-stats --raw | duckdb -c "SELECT config_version, AVG(llm_ttft_ms), COUNT(*) FROM read_json_auto('/dev/stdin') GROUP BY 1"
```

## Clearing

`yappr-stats --clear` doesn't delete — it archives the current `metrics/` directory to `metrics.bak.<YYYYMMDD-HHMMSS>/` and starts fresh. Useful when you're about to A/B a big change and want a clean baseline. The archive directory is gitignored.
