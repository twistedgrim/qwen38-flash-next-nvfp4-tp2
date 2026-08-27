#!/usr/bin/env python3
"""Small standard-library OpenAI-compatible client used by recipe gates."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any


def get_json(url: str, timeout: float = 30) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def post_json(url: str, payload: dict[str, Any], timeout: float = 900) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {body}") from exc


def stream_chat(url: str, payload: dict[str, Any], timeout: float = 900) -> dict[str, Any]:
    body = dict(payload)
    body["stream"] = True
    body["stream_options"] = {"include_usage": True}
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first_token_at = None
    usage: dict[str, Any] = {}
    content: list[str] = []
    reasoning: list[str] = []
    finish_reason = None
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {error_body}") from exc
    with response:
        for raw in response:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[6:])
            if chunk.get("usage"):
                usage = chunk["usage"]
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {})
                visible = delta.get("content") or delta.get("reasoning_content")
                if visible and first_token_at is None:
                    first_token_at = time.perf_counter()
                if delta.get("content"):
                    content.append(delta["content"])
                if delta.get("reasoning_content"):
                    reasoning.append(delta["reasoning_content"])
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
    ended = time.perf_counter()
    return {
        "content": "".join(content),
        "reasoning_content": "".join(reasoning),
        "finish_reason": finish_reason,
        "usage": usage,
        "started": started,
        "first_token_at": first_token_at,
        "ended": ended,
    }
