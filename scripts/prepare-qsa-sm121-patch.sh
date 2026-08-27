#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

PATCH_DIR="$ROOT/patches/qsa-sm121"
PATCHED_FILE="$PATCH_DIR/qwen_sparse_attn_backend.py"
PATH_FILE="$PATCH_DIR/module-path.env"
EXPECTED_SOURCE_SHA256=c959835d05d0f395ad7eae4330cf264af9f6f7c1bff3d45a39bb953d2536f5f2
mkdir -p "$PATCH_DIR"

docker image inspect "$IMAGE" >/dev/null
MODULE_PATH="$(docker run --rm --entrypoint python3 "$IMAGE" -c 'import sglang.srt.layers.attention.qwen_sparse_attn_backend as m; print(m.__file__)')"

TEMP_DIR="$(mktemp -d)"
CID=""
cleanup() {
  [[ -z "$CID" ]] || docker rm -f "$CID" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

CID="$(docker create "$IMAGE")"
docker cp "$CID:$MODULE_PATH" "$TEMP_DIR/source.py"
docker rm -f "$CID" >/dev/null
CID=""

actual_sha="$(sha256sum "$TEMP_DIR/source.py" | awk '{print $1}')"
[[ "$actual_sha" == "$EXPECTED_SOURCE_SHA256" ]] || {
  echo "QSA source hash changed: expected $EXPECTED_SOURCE_SHA256, got $actual_sha" >&2
  exit 1
}

python3 - "$TEMP_DIR/source.py" "$PATCHED_FILE" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
old = """    from sglang.srt.utils import is_sm100_supported

    if not is_sm100_supported():
        return None"""
new = """    from sglang.srt.utils import is_sm100_supported, is_sm120_supported

    if not (is_sm100_supported() or is_sm120_supported()):
        return None"""
if source.count(old) != 1:
    raise SystemExit(f"expected one SM100 QSA gate, found {source.count(old)}")
patched = source.replace(old, new, 1)
compile(patched, sys.argv[2], "exec")
Path(sys.argv[2]).write_text(patched)
PY

printf 'QSA_MODULE_PATH=%q\nQSA_PATCHED_PATH=%q\n' "$MODULE_PATH" "$PATCHED_FILE" > "$PATH_FILE"
printf 'Prepared pinned QSA SM121 patch: %s\n' "$PATCHED_FILE"
