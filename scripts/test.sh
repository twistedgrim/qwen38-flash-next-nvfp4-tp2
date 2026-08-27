#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
find "$ROOT" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
PYCACHE_DIR="$(mktemp -d)"
trap 'rm -r "$PYCACHE_DIR"' EXIT
PYTHONPYCACHEPREFIX="$PYCACHE_DIR" python3 -m compileall -q "$ROOT/scripts"
python3 - "$ROOT/config.example.env" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
required = {
    "MODEL_REVISION": "7b719225242aacd3dbd3f9407468c2ee9a9d2594",
    "QWEN38_ENABLE_MTP": '"${QWEN38_ENABLE_MTP:-0}"',
    "QWEN38_CONTEXT_LENGTH": '"${QWEN38_CONTEXT_LENGTH:-262144}"',
    "QWEN38_MAMBA_TRACK_INTERVAL": '"${QWEN38_MAMBA_TRACK_INTERVAL:-64}"',
}
values = dict(re.findall(r"^([A-Z0-9_]+)=(.*)$", text, re.MULTILINE))
for key, expected in required.items():
    if values.get(key) != expected:
        raise SystemExit(f"{key}: expected {expected!r}, got {values.get(key)!r}")
if "HF_TOKEN=" in text or "API_KEY=" in text:
    raise SystemExit("protected credential field must not be stored in config.example.env")
print("config defaults: OK")
PY

if command -v shellcheck >/dev/null 2>&1; then
  find "$ROOT" -type f -name '*.sh' -print0 | xargs -0 shellcheck -e SC1091
else
  echo "shellcheck: unavailable (skipped)"
fi

echo "STATIC_TESTS_OK"
