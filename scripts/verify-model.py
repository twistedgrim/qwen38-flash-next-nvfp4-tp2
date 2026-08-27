#!/usr/bin/env python3
"""Validate checkpoint structure and, optionally, pinned Hugging Face file sizes."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def local_validation(root: Path) -> tuple[int, int]:
    required = ["config.json", "model.safetensors.index.json", "tokenizer.json"]
    missing = [name for name in required if not (root / name).is_file()]
    if missing:
        fail(f"missing required model files: {', '.join(missing)}")

    index = json.loads((root / "model.safetensors.index.json").read_text())
    shards = sorted(set(index.get("weight_map", {}).values()))
    if not shards:
        fail("model index has no weight shards")
    bad = [name for name in shards if not (root / name).is_file() or (root / name).stat().st_size == 0]
    if bad:
        fail(f"missing or empty weight shards: {len(bad)}")
    return len(shards), sum((root / name).stat().st_size for name in shards)


def online_validation(root: Path, model_id: str, revision: str) -> int:
    quoted_id = "/".join(urllib.parse.quote(part, safe="") for part in model_id.split("/"))
    url = f"https://huggingface.co/api/models/{quoted_id}/revision/{revision}?blobs=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        metadata = json.load(response)
    if metadata.get("sha") != revision:
        fail(f"revision mismatch: API returned {metadata.get('sha')!r}")

    mismatches = []
    siblings = metadata.get("siblings", [])
    for item in siblings:
        name = item.get("rfilename")
        expected = item.get("size")
        if not name or expected is None:
            continue
        path = root / name
        if not path.is_file():
            mismatches.append(name)
        elif path.stat().st_size != expected:
            mismatches.append(name)
    if mismatches:
        fail(f"missing or size-mismatched pinned files: {len(mismatches)}")
    return len(siblings)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--model-id")
    parser.add_argument("--revision")
    parser.add_argument("--online", action="store_true")
    args = parser.parse_args()

    if args.online and (not args.model_id or not args.revision):
        parser.error("--online requires --model-id and --revision")
    if not args.path.is_dir():
        fail(f"model directory does not exist: {args.path}")

    shard_count, shard_bytes = local_validation(args.path)
    remote_files = None
    if args.online:
        remote_files = online_validation(args.path, args.model_id, args.revision)

    print(json.dumps({
        "ok": True,
        "path": str(args.path),
        "weight_shards": shard_count,
        "weight_bytes": shard_bytes,
        "pinned_revision": args.revision if args.online else None,
        "pinned_files_checked": remote_files,
    }))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"model validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
