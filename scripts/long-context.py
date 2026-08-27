#!/usr/bin/env python3
"""Deterministic non-repetitive needle retrieval at increasing prompt depths."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import time

from openai_client import post_json


def make_prompt(target_chars: int, markers: list[str]) -> str:
    prefix = (
        "You are reading an audit ledger containing three IMPORTANT SECRET lines. "
        "After reading the entire ledger, output only their values in A|B|C order.\n"
    )
    suffix = "\nEnd of ledger. Output only SECRET_A|SECRET_B|SECRET_C."
    lines: list[str] = []
    size = len(prefix) + len(suffix)
    index = 0
    insert_at = [int(target_chars * fraction) for fraction in (0.05, 0.50, 0.95)]
    inserted = 0
    while size < target_chars:
        if inserted < len(markers) and size >= insert_at[inserted]:
            label = chr(ord("A") + inserted)
            line = f"IMPORTANT SECRET {label}: {markers[inserted]}\n"
            inserted += 1
        else:
            digest = hashlib.sha256(f"qwen38-ledger-{index}".encode()).hexdigest()
            line = f"ledger-record-{index:07d} checksum={digest} class={index % 97:02d}\n"
            index += 1
        lines.append(line)
        size += len(line)
    while inserted < len(markers):
        label = chr(ord("A") + inserted)
        lines.append(f"IMPORTANT SECRET {label}: {markers[inserted]}\n")
        inserted += 1
    return prefix + "".join(lines) + suffix


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:30000/v1")
    parser.add_argument("--model", default="qwen3.8-flash-next-nvfp4")
    parser.add_argument("--depths", type=int, nargs="+", default=[10_000, 60_000, 120_000])
    args = parser.parse_args()

    endpoint = args.base_url.rstrip("/") + "/chat/completions"
    # Numbered hashes tokenize densely with Qwen's tokenizer (~1.4 chars/token).
    # The first request calibrates this value for subsequent depths.
    chars_per_token = 1.45
    results = []
    for target in args.depths:
        markers = [f"GX10_{target}_{label}_OK" for label in ("EARLY", "MIDDLE", "LATE")]
        expected = "|".join(markers)
        prompt = make_prompt(max(12_000, int(target * chars_per_token)), markers)
        started = time.perf_counter()
        response = post_json(endpoint, {
            "model": args.model,
            "messages": [{"role": "user", "content": prompt}],
            "chat_template_kwargs": {"enable_thinking": False},
            "temperature": 0,
            "max_tokens": 64,
        }, timeout=1200)
        elapsed = time.perf_counter() - started
        msg = response["choices"][0]["message"]
        content = (msg.get("content") or "").strip()
        if content != expected:
            raise AssertionError(f"retrieval failed at target {target}: {content!r}")
        if re.search(r"!{8,}", json.dumps(response)):
            raise AssertionError(f"token-ID-0/bang run at target {target}")
        prompt_tokens = int(response.get("usage", {}).get("prompt_tokens", 0))
        if not prompt_tokens:
            raise AssertionError("server did not report prompt token usage")
        chars_per_token = len(prompt) / prompt_tokens
        if not 0.90 * target <= prompt_tokens <= 1.10 * target:
            raise AssertionError(f"prompt calibration outside tolerance: target={target} actual={prompt_tokens}")
        result = {
            "target_tokens": target,
            "prompt_tokens": prompt_tokens,
            "elapsed_s": round(elapsed, 3),
            "markers": markers,
        }
        results.append(result)
        print(f"PASS target={target} actual={prompt_tokens} elapsed={elapsed:.2f}s markers=3", flush=True)
    print(json.dumps({"ok": True, "results": results}))
    print("LONG_CONTEXT_OK")


if __name__ == "__main__":
    main()
