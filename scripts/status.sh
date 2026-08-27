#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

show_container() {
  docker inspect "$CONTAINER_NAME" --format \
    'head: running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} image={{.Config.Image}}' 2>/dev/null || echo "head: absent"
}
show_worker_container() {
  ssh_worker "docker inspect '$CONTAINER_NAME' --format 'worker: running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} image={{.Config.Image}}' 2>/dev/null || echo 'worker: absent'"
}

show_container
show_worker_container

base="$(api_base)"
if curl -fsS --max-time 5 "$base/health" >/dev/null 2>&1; then
  echo "endpoint: healthy ($base/v1)"
  curl -fsS --max-time 10 "$base/v1/models" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print("models:", ", ".join(x["id"] for x in d["data"]))'
  curl -fsS --max-time 10 "$base/metrics" | python3 -c '
import re, sys
wanted = {
 "sglang:num_running_reqs", "sglang:num_queue_reqs",
 "sglang:token_usage", "sglang:mamba_usage",
 "sglang:mamba_available_tokens", "sglang:mamba_evictable_tokens",
 "sglang:mamba_used_tokens", "sglang:gen_throughput",
}
for line in sys.stdin:
    name = line.split("{", 1)[0].split(" ", 1)[0]
    if name in wanted:
        value = line.rsplit(" ", 1)[-1].strip()
        print(f"metric {name}={value}")
'
else
  echo "endpoint: unavailable ($base)" >&2
fi

for scope in head worker; do
  echo "recent $scope errors:"
  if [[ "$scope" == head ]]; then
    docker logs --tail 500 "$CONTAINER_NAME" 2>&1 || true
  else
    ssh_worker "docker logs --tail 500 '$CONTAINER_NAME' 2>&1" || true
  fi | grep -Ei 'traceback|fatal|cuda error|nccl.*(error|abort)|out of memory|token.?0|nan' | tail -10 || true
done
