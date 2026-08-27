#!/usr/bin/env python3
"""Correctness gates for text, reasoning, tools, replay, and concurrency."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import threading
import time
import urllib.request

from openai_client import get_json, post_json

TOOL = {
    "type": "function",
    "function": {
        "name": "record_probe",
        "description": "Record a probe marker at an absolute path.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
            "additionalProperties": False,
        },
    },
}


def message(response: dict) -> dict:
    choices = response.get("choices", [])
    if not choices:
        raise AssertionError(f"response has no choices: {response}")
    return choices[0]["message"]


def assert_no_corruption(value: object) -> None:
    text = json.dumps(value, ensure_ascii=False)
    if re.search(r"!{8,}", text):
        raise AssertionError("token-ID-0/bang run detected")
    if re.search(r"\b(?:nan|inf)\b", text, re.IGNORECASE):
        raise AssertionError("NaN/Inf marker detected")


def parse_tool_call(msg: dict, marker: str) -> dict:
    calls = msg.get("tool_calls") or []
    if len(calls) != 1:
        raise AssertionError(f"expected one tool call, got {len(calls)}")
    call = calls[0]
    if call.get("function", {}).get("name") != "record_probe":
        raise AssertionError(f"unexpected tool: {call}")
    arguments = json.loads(call["function"]["arguments"])
    if arguments.get("content") != marker or not arguments.get("path", "").startswith("/"):
        raise AssertionError(f"invalid tool arguments: {arguments}")
    return call


def metric_value(metrics_url: str, metric: str) -> float | None:
    try:
        with urllib.request.urlopen(metrics_url, timeout=5) as response:
            text = response.read().decode()
    except Exception:
        return None
    match = re.search(rf"^{re.escape(metric)}(?:\{{[^}}]*\}})?\s+([0-9.eE+-]+)$", text, re.MULTILINE)
    return float(match.group(1)) if match else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:30000/v1")
    parser.add_argument("--model", default="qwen3.8-flash-next-nvfp4")
    parser.add_argument("--concurrency", type=int, default=4)
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    endpoint = base + "/chat/completions"
    metrics_url = base.removesuffix("/v1") + "/metrics"
    models = [item["id"] for item in get_json(base + "/models").get("data", [])]
    if args.model not in models:
        raise AssertionError(f"served model not found: {models}")

    plain = post_json(endpoint, {
        "model": args.model,
        "messages": [{"role": "user", "content": "Reply with exactly QWEN38_SMOKE_OK and nothing else."}],
        "temperature": 0,
        "max_tokens": 64,
    })
    assert_no_corruption(plain)
    if message(plain).get("content", "").strip() != "QWEN38_SMOKE_OK":
        raise AssertionError(f"plain response mismatch: {message(plain)}")
    print("PASS plain text")

    thinking = post_json(endpoint, {
        "model": args.model,
        "messages": [{"role": "user", "content": "Think through 17*19, then put only THINKING_OK in the final answer."}],
        "chat_template_kwargs": {"enable_thinking": True},
        "temperature": 0,
        "max_tokens": 256,
    })
    assert_no_corruption(thinking)
    thinking_msg = message(thinking)
    if "THINKING_OK" not in (thinking_msg.get("content") or ""):
        raise AssertionError(f"thinking final answer mismatch: {thinking_msg}")
    if not thinking_msg.get("reasoning_content"):
        raise AssertionError("reasoning_content was empty")
    print("PASS reasoning separation")

    marker = "QWEN38_TOOL_OK"
    tool_response = post_json(endpoint, {
        "model": args.model,
        "messages": [{"role": "user", "content": f"Call record_probe once with path /tmp/qwen38-smoke.txt and content {marker}. Do not answer in prose."}],
        "tools": [TOOL],
        "tool_choice": {"type": "function", "function": {"name": "record_probe"}},
        "temperature": 0,
        "max_tokens": 256,
    })
    assert_no_corruption(tool_response)
    tool_msg = message(tool_response)
    call = parse_tool_call(tool_msg, marker)
    print("PASS structured tool call")

    replay = post_json(endpoint, {
        "model": args.model,
        "messages": [
            {"role": "user", "content": f"Call record_probe once with path /tmp/qwen38-smoke.txt and content {marker}."},
            tool_msg,
            {"role": "tool", "tool_call_id": call["id"], "content": "recorded"},
            {"role": "user", "content": "Reply with exactly TOOL_ROUNDTRIP_OK."},
        ],
        "tools": [TOOL],
        "temperature": 0,
        "max_tokens": 128,
    })
    assert_no_corruption(replay)
    if message(replay).get("content", "").strip() != "TOOL_ROUNDTRIP_OK":
        raise AssertionError(f"tool replay mismatch: {message(replay)}")
    print("PASS tool-result replay")

    stop_sampling = threading.Event()
    samples: list[tuple[float | None, float | None]] = []

    def sample_metrics() -> None:
        while not stop_sampling.wait(0.2):
            samples.append((
                metric_value(metrics_url, "sglang:num_running_reqs"),
                metric_value(metrics_url, "sglang:mamba_usage"),
            ))

    def concurrent_probe(index: int) -> dict:
        filler = " ".join(f"probe-{index}-{item:04d}" for item in range(700))
        current_marker = f"QWEN38_CONCURRENT_{index}_OK"
        response = post_json(endpoint, {
            "model": args.model,
            "messages": [{"role": "user", "content": (
                f"Context: {filler}\nCall record_probe exactly once with path "
                f"/tmp/qwen38-concurrent-{index}.txt and content {current_marker}."
            )}],
            "tools": [TOOL],
            "tool_choice": {"type": "function", "function": {"name": "record_probe"}},
            "temperature": 0,
            "max_tokens": 256,
        })
        assert_no_corruption(response)
        parse_tool_call(message(response), current_marker)
        return response

    sampler = threading.Thread(target=sample_metrics, daemon=True)
    sampler.start()
    started = time.perf_counter()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            responses = list(pool.map(concurrent_probe, range(args.concurrency)))
    finally:
        stop_sampling.set()
        sampler.join(timeout=2)
    elapsed = time.perf_counter() - started
    running_samples = [item[0] for item in samples if item[0] is not None]
    mamba_samples = [item[1] for item in samples if item[1] is not None]
    if not running_samples or not mamba_samples:
        raise AssertionError("required running-request or Mamba metric was unavailable")
    max_running = max(running_samples)
    max_mamba = max(mamba_samples)
    if len(responses) != args.concurrency:
        raise AssertionError("concurrent response count mismatch")
    if max_running < min(2, args.concurrency):
        raise AssertionError(f"concurrent scheduling was not observed: max_running={max_running:.0f}")
    if max_mamba >= 0.95:
        raise AssertionError(f"Mamba state pool nearly exhausted: {max_mamba:.3f}")
    print(f"PASS concurrency={args.concurrency} elapsed={elapsed:.2f}s max_running={max_running:.0f} max_mamba_usage={max_mamba:.3f}")
    print("SMOKE_OK")


if __name__ == "__main__":
    main()
