#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config
exec python3 "$SCRIPT_DIR/bench.py" --base-url "$(api_base)/v1" --model "$SERVED_MODEL_NAME" "$@"
