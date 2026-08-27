#!/usr/bin/env python3
"""Streaming C1/C2/C4 throughput benchmark with corruption checks."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import statistics
import threading
import time

from openai_client import stream_chat

PROMPT = """Generate an endless numbered list of distinct Python function definitions.
Each function must return its own integer index. Emit code only and continue until the
response token limit stops you. Do not summarize or conclude."""


def one_stream(endpoint: str, model: str, max_tokens: int, barrier: threading.Barrier) -> dict:
    barrier.wait()
    result = stream_chat(endpoint, {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "temperature": 0,
        "max_tokens": max_tokens,
    })
    combined = result["reasoning_content"] + result["content"]
    if re.search(r"!{8,}", combined):
        raise AssertionError("token-ID-0/bang run detected")
    completion_tokens = int(result["usage"].get("completion_tokens", 0))
    if completion_tokens < max_tokens * 0.75:
        raise AssertionError(f"generation ended early at {completion_tokens}/{max_tokens} tokens")
    latency = result["ended"] - result["started"]
    ttft = None if result["first_token_at"] is None else result["first_token_at"] - result["started"]
    decode_window = None if ttft is None else latency - ttft
    return {
        "completion_tokens": completion_tokens,
        "finish_reason": result["finish_reason"],
        "latency_s": round(latency, 4),
        "ttft_s": round(ttft, 4) if ttft is not None else None,
        "decode_tok_s": round((completion_tokens - 1) / decode_window, 4)
        if completion_tokens > 1 and decode_window and decode_window > 0 else None,
        "started": result["started"],
        "ended": result["ended"],
    }


def batch(endpoint: str, model: str, concurrency: int, max_tokens: int) -> dict:
    barrier = threading.Barrier(concurrency + 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(one_stream, endpoint, model, max_tokens, barrier) for _ in range(concurrency)]
        barrier.wait()
        streams = [future.result() for future in futures]
    wall = max(x["ended"] for x in streams) - min(x["started"] for x in streams)
    tokens = sum(x["completion_tokens"] for x in streams)
    for stream in streams:
        stream.pop("started")
        stream.pop("ended")
    return {
        "wall_s": round(wall, 4),
        "completion_tokens": tokens,
        "aggregate_output_tok_s": round(tokens / wall, 4),
        "streams": streams,
    }


def median(values):
    usable = [value for value in values if value is not None]
    return round(statistics.median(usable), 4) if usable else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:30000/v1")
    parser.add_argument("--model", default="qwen3.8-flash-next-nvfp4")
    parser.add_argument("--concurrency", type=int, nargs="+", default=[1, 2, 4])
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--warmup-tokens", type=int, default=64)
    parser.add_argument("--output")
    parser.add_argument("--minimum-c1", type=float, default=20.0)
    parser.add_argument("--minimum-c2", type=float, default=40.0)
    parser.add_argument("--minimum-c4", type=float, default=65.0)
    args = parser.parse_args()
    if args.runs < 1 or args.max_tokens < 32 or any(level < 1 for level in args.concurrency):
        parser.error("runs/concurrency must be positive and max-tokens >= 32")

    endpoint = args.base_url.rstrip("/") + "/chat/completions"
    minimums = {1: args.minimum_c1, 2: args.minimum_c2, 4: args.minimum_c4}
    levels = []
    for concurrency in args.concurrency:
        batch(endpoint, args.model, concurrency, args.warmup_tokens)
        runs = [batch(endpoint, args.model, concurrency, args.max_tokens) for _ in range(args.runs)]
        streams = [stream for run in runs for stream in run["streams"]]
        level = {
            "concurrency": concurrency,
            "median_ttft_s": median(x["ttft_s"] for x in streams),
            "median_per_stream_decode_tok_s": median(x["decode_tok_s"] for x in streams),
            "median_aggregate_output_tok_s": median(x["aggregate_output_tok_s"] for x in runs),
            "runs": runs,
        }
        minimum = minimums.get(concurrency)
        if minimum is not None and level["median_aggregate_output_tok_s"] < minimum:
            raise AssertionError(
                f"C{concurrency} aggregate throughput {level['median_aggregate_output_tok_s']:.2f} "
                f"is below minimum {minimum:.2f} tok/s"
            )
        levels.append(level)
        print(
            f"C{concurrency}: aggregate={level['median_aggregate_output_tok_s']:.2f} tok/s "
            f"per_stream_decode={level['median_per_stream_decode_tok_s']:.2f} tok/s "
            f"TTFT={level['median_ttft_s']:.3f}s",
            flush=True,
        )

    result = {
        "model": args.model,
        "endpoint": args.base_url,
        "runs_per_level": args.runs,
        "max_tokens": args.max_tokens,
        "cache_state": "warm_after_explicit_warmup",
        "minimum_aggregate_output_tok_s": minimums,
        "levels": levels,
    }
    if args.output:
        with open(args.output, "w") as handle:
            json.dump(result, handle, indent=2)
            handle.write("\n")
    print("BENCH_OK")


if __name__ == "__main__":
    main()
