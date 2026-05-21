# test_llm_call.py — integration tests for bin/yappr-llm-call.
# Tests error handling and metric JSON schema. No live LLM required.
import json
import subprocess
import sys
import os

YAPPR_ROOT = os.path.join(os.path.dirname(__file__), "../..")
LLM_CALL = os.path.join(YAPPR_ROOT, "bin/yappr-llm-call")
REQUIRED_METRIC_FIELDS = ("text", "ttft_ms", "total_ms", "prompt_tokens", "completion_tokens", "error")


def _run(stdin_data: dict, timeout: int = 5):
    result = subprocess.run(
        [sys.executable, LLM_CALL],
        input=json.dumps(stdin_data),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.stdout, result.stderr, result.returncode


def test_missing_url_exits_2():
    _, _, rc = _run({"body": {}})
    assert rc == 2


def test_invalid_json_exits_2():
    result = subprocess.run(
        [sys.executable, LLM_CALL],
        input="not valid json",
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 2


def test_unreachable_url_exits_2():
    _, _, rc = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    assert rc == 2


def test_metric_json_has_all_required_fields():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    for field in REQUIRED_METRIC_FIELDS:
        assert field in metric, f"missing field in metric JSON: {field}"


def test_error_field_set_on_failure():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    assert metric["error"] is not None


def test_text_field_is_empty_string_on_failure():
    _, stderr, _ = _run({
        "url": "http://127.0.0.1:1/v1/chat/completions",
        "body": {"messages": [], "max_tokens": 1},
        "timeout": 2,
    })
    last_line = stderr.strip().splitlines()[-1]
    metric = json.loads(last_line)
    assert metric["text"] == ""
