#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $0 <backend-port>" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# llama-swap allocates the private backend port. Propagate it to both TP ranks.
export QWEN38_PORT="$1"
"$ROOT/qwen38" serve

# serve daemonizes both containers. Keep this process alive so llama-swap owns
# their lifecycle; cmdStop removes both ranks and lets this loop exit.
source "$ROOT/scripts/lib.sh"
load_config
while container_running_local; do
  sleep 5
done
