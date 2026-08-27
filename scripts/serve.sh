#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

[[ "$QWEN38_ENABLE_MTP" == 0 ]] || cat >&2 <<'EOF'
WARNING: experimental MTP is enabled. It is not part of the validated profile.
EOF

"$SCRIPT_DIR/sync-worker.sh"
"$SCRIPT_DIR/stop.sh"

printf 'Starting worker: transport=%s context=%s MTP=%s\n' \
  "$QWEN38_NCCL_TRANSPORT" "$QWEN38_CONTEXT_LENGTH" "$QWEN38_ENABLE_MTP"
ssh_worker "'$WORKER_RECIPE_DIR/scripts/run-rank.sh' worker"

worker_deadline=$((SECONDS + 60))
until container_running_worker; do
  if (( SECONDS >= worker_deadline )); then
    echo "Worker container did not remain running" >&2
    ssh_worker "docker logs --tail 120 '$CONTAINER_NAME' 2>&1" >&2 || true
    exit 1
  fi
  sleep 2
done
sleep 10
container_running_worker || {
  echo "Worker exited during rendezvous setup" >&2
  ssh_worker "docker logs --tail 120 '$CONTAINER_NAME' 2>&1" >&2 || true
  exit 1
}

printf 'Starting head on port %s...\n' "$PORT"
"$SCRIPT_DIR/run-rank.sh" head

base="$(api_base)"
deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
until curl -fsS --max-time 3 "$base/health" >/dev/null 2>&1; do
  if ! container_running_local; then
    echo "Head container exited before readiness" >&2
    docker logs --tail 160 "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
  if ! container_running_worker; then
    echo "Worker container exited before readiness" >&2
    ssh_worker "docker logs --tail 160 '$CONTAINER_NAME' 2>&1" >&2 || true
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "Timed out waiting ${READY_TIMEOUT_SECONDS}s for $base/health" >&2
    docker logs --tail 160 "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
  sleep 5
done

curl -fsS --max-time 10 "$base/v1/models" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("Ready:", ", ".join(x["id"] for x in d["data"]))'
