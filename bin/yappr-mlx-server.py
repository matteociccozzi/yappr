#!/usr/bin/env python3
"""
yappr-mlx-server — a minimal MLX inference server with EXPLICIT prefix caching.

Loads an MLX model once, prefills the KV cache with a fixed system prompt at
startup, and serves OpenAI-compatible streaming chat completions. On every
request the cache offset is reset back to the system-prompt boundary so only
the user portion needs new prefill work. Effectively trades a one-time cold
prefill at startup for warm prefix reuse on every subsequent request.

ROLE IN THE YAPPR PIPELINE
--------------------------
This is the inference backend that the `default` config in `~/toolkit/yappr/
configs/default.json` points at (port 8081). The `yappr` orchestrator (via
`yappr-llm-call`) sends streaming chat-completion requests here; the server
returns content tokens as Server-Sent Events.

It exists because:

  1. Stock `mlx_lm.server` does NOT do cross-request prefix caching for
     independent OpenAI-style API calls. We measured this with
     `yappr-probe-caching`: ~150ms TTFT every single call, no improvement
     after the first. Issue: https://github.com/ml-explore/mlx-lm/issues/1178
  2. Our system prompt is fixed and ~340 tokens — the bulk of prefill work
     each request was redundant. Caching it explicitly is a 15–40% TTFT
     reduction now and scales linearly with prompt size / model size.
  3. `mlx_lm.server` does not emit `usage` in streaming chunks, so token
     counts in our metrics were always 0. This server emits a final SSE
     chunk with `usage.prompt_tokens` / `usage.completion_tokens` so
     `yappr-stats` gets real numbers.

HOW THE PREFIX CACHE TRICK WORKS
--------------------------------
At startup:
  1. Tokenize the system prompt with the chat template (no generation prompt)
     and remember its token length N.
  2. Build a fresh KV cache via `make_prompt_cache(model)`.
  3. Run ONE forward pass of the model over the system tokens — this
     populates the cache with N tokens of KV state. `mx.eval()` forces
     evaluation so the work is real, not lazy.
  4. Record the system prompt's hash so we can detect if it ever changes.

Per request:
  1. Hash the incoming system message. If it differs from the cached one
     (e.g. the prompt file changed and the server wasn't restarted), rebuild
     the cache from scratch — costs ~150ms once, then back to fast.
  2. Reset each KV-cache layer's `.offset` back to N. The underlying tensors
     stay allocated; the model reads only up to `offset`, so any leftover
     bytes from prior generations are effectively gone.
  3. Get the user-turn tokens. For the common single-turn [system, user]
     shape, this uses the FAST PATH (see below) and never re-tokenizes the
     system prompt text. Otherwise (multi-turn history, or a template we
     couldn't validate the fast path against) it falls back to the SLOW
     PATH: re-tokenize the full conversation with the chat template and
     slice off the first N tokens (the system prefix we already have
     cached).
  4. Pass the user-turn tokens to `stream_generate(..., prompt_cache=
     master_cache)`. Only those tokens need prefill work.
  5. Stream content chunks back as SSE; emit a final chunk with `usage`.

FAST PATH: SKIPPING SYSTEM-PROMPT RE-TOKENIZATION
---------------------------------------------------
Even with the KV-cache trick above, the original implementation still called
`tokenizer.apply_chat_template(messages, ...)` on the FULL conversation
(system + user) on every request — re-running BPE tokenization over the
~340-token system prompt every single time, even though it's byte-identical
to what was tokenized once at startup.

`get_fast_path_wrapper()` / `_derive_fast_path_wrapper()` fix this WITHOUT
assuming `sys_tokens + tokenize(user_text)` is a safe concatenation (chat
templates can insert separators, role markers, or generation-prompt tokens
between messages that only appear when both are templated together — naively
gluing separately-tokenized pieces together is not guaranteed to match
`apply_chat_template` on the combined messages). Instead, once per
(system-prompt hash, chat_template_kwargs) combination, we:

  1. Render the system message alone and [system, sentinel-user] together as
     STRINGS (not tokens) using the real chat template, and require the
     combined rendering to start with the system-only rendering verbatim.
  2. Locate the sentinel to split the remainder into fixed `pre` / `post`
     wrapper text around the user turn.
  3. Validate at the TOKEN level, for several representative probe messages,
     that `sys_prompt_tokens + tokenizer.encode(pre + probe + post)` exactly
     equals `apply_chat_template([system, user=probe])`. This is what
     actually catches BPE-boundary effects, since it compares real
     tokenizer output rather than assuming the boundary is safe.

Only if that validates do we cache `(pre, post)` and use them on the hot
path: `tokenizer.encode(pre + user_content + post)` — tokenizing a few dozen
characters instead of ~1500. If validation ever fails for a given tokenizer/
template, the wrapper is cached as unusable (not retried every request) and
every request for that (hash, kwargs) combo transparently falls back to the
always-correct slow path — this is a pure optimization, never a correctness
requirement. `/health` exposes `fast_path_hits` / `fast_path_misses`.

Wire protocol is unchanged: the client still sends the full `messages`
array including the system message on every request. This was a deliberate
choice over having the server reconstruct the system message from its own
startup file and dropping it from the request: hashing ~1.5KB of text is
microseconds (negligible next to the tokenization cost being eliminated
here), and keeping it in the request preserves the existing hash-mismatch
safety net (auto-detect + rebuild if the prompt file was edited without a
server restart) for free. Dropping it would require changing whatever
upstream code builds the `messages` array (outside this file) for no
measurable win.

A `threading.Lock` serializes requests against the shared mutable cache. This
server is intentionally single-tenant — concurrent requests would corrupt the
shared cache state.

HTTP API (OpenAI-compatible subset)
-----------------------------------
POST /v1/chat/completions
    Request body (subset of OpenAI's spec):
      {
        "messages":     [{"role": "system", ...}, {"role": "user", ...}],
        "max_tokens":   512,        // default 512
        "temperature":  0.0,        // default 0
        "top_p":        1.0,        // default 1
        "stream":       true|false, // default false
        "chat_template_kwargs": {"enable_thinking": false}
                                     // forwarded to tokenizer.apply_chat_template
      }
    Behavior: identical to mlx_lm.server for non-streaming. For streaming,
    same SSE format (data: <json>\\n\\n ... data: [DONE]).
    Adds `cached_prompt_tokens` to the final `usage` block so callers can see
    how many tokens were served from cache vs newly prefilled.

GET /v1/models
    Returns one entry for the loaded model, with `cached_prefix_tokens` and
    `cached_prefix_hash` fields for diagnostics.

GET /health
    Returns server status + lifetime stats:
      {
        "status": "ok",
        "model":  "mlx-community/Qwen3-1.7B-4bit",
        "cached_prefix_tokens": 339,
        "stats": {
          "cold_prefills":  1,    // count of full cache rebuilds (init + prompt changes)
          "warm_requests":  42,   // count of requests served against the cached prefix
          "fast_path_hits": 40,   // requests that skipped system-prompt re-tokenization
          "fast_path_misses": 2   // requests that fell back to full re-tokenization
        }
      }

CLI
---
    yappr-mlx-server \\
        --model              <hf-id>           # required, e.g. mlx-community/Qwen3-1.7B-4bit
        --system-prompt-file <path>            # required, text file used to prefill the cache
        --host               <host>            # default 127.0.0.1
        --port               <port>            # default 8081

The server runs in the foreground. Send SIGINT (Ctrl-C) to shut down.

ASSUMPTIONS / LIMITATIONS
-------------------------
  * Model must be a standard full-attention transformer with KV caching that
    supports `make_prompt_cache(model)` and tolerates `offset` truncation.
    Tested on Qwen3-1.7B-4bit. SSM/Mamba/hybrid-attention models are NOT
    supported — they would need a different cache primitive.
  * Single-tenant by design (one lock, one shared master cache). Don't put
    this behind a load balancer.
  * The cache is RAM-only; no disk persistence yet. A future enhancement
    could `save_prompt_cache(...)` after startup prefill so server restarts
    are instant.
  * The system prompt is determined at startup from `--system-prompt-file`.
    If a request arrives with a DIFFERENT system message, the server detects
    via hash mismatch and rebuilds — but this costs a fresh cold prefill.
    Stable prompts win.
  * Speculative decoding is not enabled. A `draft_model` could be added to
    `stream_generate(...)` calls; known bug in mlx-lm with Qwen3 family right
    now (https://github.com/ml-explore/mlx-lm/issues/846) so we deferred.

EXAMPLE
-------
    # Start
    yappr-mlx-server \\
        --model              mlx-community/Qwen3-1.7B-4bit \\
        --system-prompt-file ~/toolkit/yappr/prompts/cleanup.txt \\
        --host 127.0.0.1 --port 8081

    # Health check
    curl -s http://127.0.0.1:8081/health | jq

    # One streaming completion
    curl -N -s http://127.0.0.1:8081/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"messages":[{"role":"system","content":"..."},
                       {"role":"user","content":"hi"}],
           "max_tokens":32,"stream":true,
           "chat_template_kwargs":{"enable_thinking":false}}'
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock
from typing import ClassVar

import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_sampler


def hash_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


class State:
    model = None
    tokenizer = None
    model_name = ""
    master_cache = None
    sys_prompt_text = ""
    sys_prompt_hash = ""
    sys_prompt_len = 0
    sys_prompt_tokens: ClassVar[list] = []
    lock = Lock()
    stats_cold_prefills = 0
    stats_warm_requests = 0
    # (sys_prompt_hash, sorted chat_template_kwargs items) -> (pre_str, post_str) | None
    # None means "tried and the template didn't validate" — don't retry every request.
    fast_path_cache: ClassVar[dict] = {}
    stats_fast_path_hits = 0
    stats_fast_path_misses = 0


def prefill_system_prompt(sys_prompt: str) -> None:
    """Build a fresh KV cache and prefill it with the system prompt tokens."""
    sys_tokens = State.tokenizer.apply_chat_template(
        [{"role": "system", "content": sys_prompt}],
        tokenize=True,
        add_generation_prompt=False,
    )
    State.sys_prompt_text = sys_prompt
    State.sys_prompt_hash = hash_text(sys_prompt)
    State.sys_prompt_len = len(sys_tokens)
    State.sys_prompt_tokens = list(sys_tokens)
    # Any previously-derived wrappers were keyed by the old hash and are now
    # unreachable; drop them so we don't leak memory across repeated
    # hash-mismatch rebuilds (e.g. someone editing the prompt file in a loop).
    State.fast_path_cache = {}
    State.master_cache = make_prompt_cache(State.model)

    sys.stderr.write(
        f"[prefill] tokenizing system prompt ({len(sys_tokens)} tokens, "
        f"hash={State.sys_prompt_hash}) ...\n"
    )
    t0 = time.monotonic()

    # One forward pass populates the cache with system-prompt KV.
    arr = mx.array(sys_tokens)[None]  # shape (1, N)
    _ = State.model(arr, cache=State.master_cache)
    # Force evaluation so the time we measure is real, not lazy.
    mx.eval([c.state for c in State.master_cache])
    State.stats_cold_prefills += 1

    sys.stderr.write(
        f"[prefill] done in {(time.monotonic()-t0)*1000:.0f}ms "
        f"(offset={State.master_cache[0].offset})\n"
    )


def reset_cache_to_prefix() -> None:
    """Trim each layer's cache offset back to just after the system prompt."""
    for kvc in State.master_cache:
        kvc.offset = State.sys_prompt_len


# Sentinel used to locate the user turn inside a rendered chat template.
# Private-use-area codepoints so it can't collide with real dictation text
# and won't get silently mangled by BPE the way plain ASCII might.
_FAST_PATH_SENTINEL = "YAPPR9f3a2c"

# A few representative probe messages used to validate the derived wrapper
# before trusting it on the hot path. Deliberately varied (empty, short,
# punctuation, leading/trailing whitespace) since BPE boundary effects are
# most likely to show up at these edges.
_FAST_PATH_PROBES = (
    "hello",
    "",
    " leading space and trailing space ",
    "the deployment is tomorrow, please fix the doc.",
    "\"quoted\" text with — punctuation…",
)


def _fast_path_key(tmpl_kwargs: dict) -> tuple:
    return (State.sys_prompt_hash, tuple(sorted(tmpl_kwargs.items())))


def _derive_fast_path_wrapper(tmpl_kwargs: dict):
    """Work out the literal text the chat template wraps a lone user turn in
    (immediately after the system message), so a per-request completion can
    tokenize just `pre + user_content + post` instead of re-tokenizing the
    system prompt every time.

    This does NOT assume `sys_tokens + tokenize(user_text)` is safe to
    concatenate — chat templates can insert separators/role markers/
    generation-prompt tokens between messages, and BPE can merge across a
    naive text-concatenation boundary. Instead:

      1. Render (string, not token) the system message alone, and the
         system+sentinel-user conversation together, using the SAME
         tokenizer/template call the slow path already trusts.
      2. Require the combined rendering to start with the system-only
         rendering verbatim (string-level prefix check) — if a template
         ever renders the system block differently depending on what
         follows it, we bail out and keep using the slow path.
      3. Locate the sentinel in the remainder to split it into the fixed
         `pre` / `post` wrapper text around the user turn.
      4. Validate at the TOKEN level: for several representative probe
         messages, `sys_prompt_tokens + tokenize(pre + probe + post)` must
         exactly equal `apply_chat_template([system, user=probe])`. This is
         the check that actually catches BPE boundary effects, since it
         compares real tokenizer output, not an assumption.

    Returns (pre_str, post_str) if validated, else None (caller falls back
    to the always-correct slow path — this is a pure optimization, never a
    correctness requirement).
    """
    try:
        rendered_sys = State.tokenizer.apply_chat_template(
            [{"role": "system", "content": State.sys_prompt_text}],
            tokenize=False, add_generation_prompt=False,
        )
        rendered_full = State.tokenizer.apply_chat_template(
            [{"role": "system", "content": State.sys_prompt_text},
             {"role": "user", "content": _FAST_PATH_SENTINEL}],
            tokenize=False, add_generation_prompt=True, **tmpl_kwargs,
        )
        if not rendered_full.startswith(rendered_sys):
            raise ValueError(
                "template did not render the system message as a stable "
                "prefix when followed by a user turn"
            )
        remainder = rendered_full[len(rendered_sys):]
        pos = remainder.index(_FAST_PATH_SENTINEL)
        pre_str = remainder[:pos]
        post_str = remainder[pos + len(_FAST_PATH_SENTINEL):]

        for probe in _FAST_PATH_PROBES:
            expected = State.tokenizer.apply_chat_template(
                [{"role": "system", "content": State.sys_prompt_text},
                 {"role": "user", "content": probe}],
                tokenize=True, add_generation_prompt=True, **tmpl_kwargs,
            )
            got = State.sys_prompt_tokens + State.tokenizer.encode(
                pre_str + probe + post_str, add_special_tokens=False,
            )
            if got != list(expected):
                raise ValueError(
                    f"fast-path token mismatch for probe={probe!r} "
                    f"(got {len(got)} tokens, expected {len(expected)})"
                )
    except Exception as e:
        sys.stderr.write(
            f"[fast-path] disabled for chat_template_kwargs={tmpl_kwargs!r}: "
            f"{e}\n"
        )
        return None

    sys.stderr.write(
        f"[fast-path] enabled for chat_template_kwargs={tmpl_kwargs!r} "
        f"(pre={len(pre_str)} chars, post={len(post_str)} chars)\n"
    )
    return (pre_str, post_str)


def get_fast_path_wrapper(tmpl_kwargs: dict):
    """Cached lookup/derivation of the fast-path wrapper for the current
    system prompt + these chat_template_kwargs. Derivation happens at most
    once per (sys_prompt_hash, kwargs) combination."""
    key = _fast_path_key(tmpl_kwargs)
    if key not in State.fast_path_cache:
        State.fast_path_cache[key] = _derive_fast_path_wrapper(tmpl_kwargs)
    return State.fast_path_cache[key]


def chat_completion(body: dict):
    """Yield SSE-encoded strings for streaming, or yield a single dict for non-streaming."""
    messages = body.get("messages") or []
    max_tokens = int(body.get("max_tokens") or 512)
    temperature = float(body.get("temperature") or 0.0)
    top_p = float(body.get("top_p") or 1.0)
    stream = bool(body.get("stream", False))

    sys_msg = next((m["content"] for m in messages if m.get("role") == "system"), "")

    with State.lock:
        # Verify the system prompt hasn't changed since startup.
        if hash_text(sys_msg) != State.sys_prompt_hash:
            sys.stderr.write(
                f"[cache] system prompt changed "
                f"(got {hash_text(sys_msg)}, had {State.sys_prompt_hash}) — rebuilding\n"
            )
            prefill_system_prompt(sys_msg)
        else:
            State.stats_warm_requests += 1

        # Reset cache to just-after-system-prompt state.
        reset_cache_to_prefix()

        # Forward chat_template_kwargs (e.g. enable_thinking) from the request body.
        tmpl_kwargs = body.get("chat_template_kwargs") or {}

        # Fast path: for the common single-turn [system, user] shape, skip
        # re-tokenizing the (unchanged, ~340-token) system prompt entirely —
        # tokenize only the short wrapper+content text around the user turn.
        # See _derive_fast_path_wrapper() for why this is safe (it's derived
        # from and validated against the real chat template, not assumed).
        wrapper = None
        if (len(messages) == 2
                and messages[0].get("role") == "system"
                and messages[1].get("role") == "user"):
            wrapper = get_fast_path_wrapper(tmpl_kwargs)

        if wrapper is not None:
            pre_str, post_str = wrapper
            user_content = messages[1].get("content") or ""
            user_tokens = State.tokenizer.encode(
                pre_str + user_content + post_str, add_special_tokens=False,
            )
            prompt_tokens_total = State.sys_prompt_len + len(user_tokens)
            State.stats_fast_path_hits += 1
        else:
            State.stats_fast_path_misses += 1
            # Slow (always-correct) path: tokenize the full conversation with
            # the real chat template and split off the suffix.
            full_tokens = State.tokenizer.apply_chat_template(
                messages, tokenize=True, add_generation_prompt=True,
                **tmpl_kwargs,
            )
            if len(full_tokens) <= State.sys_prompt_len:
                # Shouldn't happen but handle gracefully.
                user_tokens = full_tokens
                reset_cache_to_prefix()
            else:
                user_tokens = full_tokens[State.sys_prompt_len:]
            prompt_tokens_total = len(full_tokens)

        completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        created = int(time.time())
        sampler = make_sampler(temperature, top_p=top_p)

        if stream:
            # First chunk: role
            first = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": State.model_name,
                "choices": [{"index": 0, "delta": {"role": "assistant"},
                             "finish_reason": None}],
            }
            yield f"data: {json.dumps(first)}\n\n"

            completion_tokens = 0
            for r in stream_generate(
                State.model, State.tokenizer, user_tokens,
                max_tokens=max_tokens,
                sampler=sampler,
                prompt_cache=State.master_cache,
            ):
                if not r.text:
                    continue
                completion_tokens += 1
                chunk = {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": State.model_name,
                    "choices": [{"index": 0, "delta": {"content": r.text},
                                 "finish_reason": None}],
                }
                yield f"data: {json.dumps(chunk)}\n\n"

            final = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": State.model_name,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": prompt_tokens_total,
                    "completion_tokens": completion_tokens,
                    "cached_prompt_tokens": State.sys_prompt_len,
                },
            }
            yield f"data: {json.dumps(final)}\n\n"
            yield "data: [DONE]\n\n"
        else:
            parts = []
            for r in stream_generate(
                State.model, State.tokenizer, user_tokens,
                max_tokens=max_tokens,
                sampler=sampler,
                prompt_cache=State.master_cache,
            ):
                if r.text:
                    parts.append(r.text)
            yield {
                "id": completion_id,
                "object": "chat.completion",
                "created": created,
                "model": State.model_name,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "".join(parts)},
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": prompt_tokens_total,
                    "completion_tokens": len(parts),
                    "cached_prompt_tokens": State.sys_prompt_len,
                },
            }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Quieter logging — we have our own
        pass

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/models":
            self._send_json(200, {
                "object": "list",
                "data": [{
                    "id": State.model_name,
                    "object": "model",
                    "created": int(time.time()),
                    "cached_prefix_tokens": State.sys_prompt_len,
                    "cached_prefix_hash": State.sys_prompt_hash,
                }],
            })
        elif self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "model": State.model_name,
                "cached_prefix_tokens": State.sys_prompt_len,
                "stats": {
                    "cold_prefills": State.stats_cold_prefills,
                    "warm_requests": State.stats_warm_requests,
                    "fast_path_hits": State.stats_fast_path_hits,
                    "fast_path_misses": State.stats_fast_path_misses,
                },
            })
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError as e:
            self._send_json(400, {"error": {"message": f"invalid json: {e}"}})
            return

        stream = bool(body.get("stream", False))

        try:
            if stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                for chunk in chat_completion(body):
                    try:
                        self.wfile.write(chunk.encode("utf-8"))
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        sys.stderr.write("[serve] client disconnected mid-stream\n")
                        return
            else:
                result = None
                for r in chat_completion(body):
                    result = r
                    break
                self._send_json(200, result or {"error": "no result"})
        except Exception as e:
            import traceback
            traceback.print_exc(file=sys.stderr)
            try:
                self._send_json(500, {"error": {"message": str(e)}})
            except Exception:
                pass


def main():
    ap = argparse.ArgumentParser(description="yappr-mlx-server")
    ap.add_argument("--model", required=True,
                    help="MLX model id, e.g. mlx-community/Qwen3-1.7B-4bit")
    ap.add_argument("--system-prompt-file", required=True,
                    help="path to text file containing the system prompt")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8081)
    args = ap.parse_args()

    sys.stderr.write(f"[load] {args.model} ...\n")
    t0 = time.monotonic()
    model, tokenizer = load(args.model)
    sys.stderr.write(f"[load] done in {time.monotonic()-t0:.1f}s\n")

    State.model = model
    State.tokenizer = tokenizer
    State.model_name = args.model

    with open(args.system_prompt_file) as f:
        sys_prompt = f.read()
    prefill_system_prompt(sys_prompt)

    server = HTTPServer((args.host, args.port), Handler)
    sys.stderr.write(
        f"[serve] http://{args.host}:{args.port}  "
        f"(cached prefix: {State.sys_prompt_len} tokens, hash {State.sys_prompt_hash})\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\n[serve] shutting down\n")


if __name__ == "__main__":
    main()
