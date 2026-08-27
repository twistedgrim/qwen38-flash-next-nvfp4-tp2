#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

MODE=download
SKIP_WORKER_SYNC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check ;;
    --skip-worker-sync) SKIP_WORKER_SYNC=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

verify_local() {
  python3 "$SCRIPT_DIR/verify-model.py" "$MODEL_HOST_PATH" \
    --online --model-id "$MODEL_ID" --revision "$MODEL_REVISION"
}
verify_worker() {
  ssh_worker "python3 - '$WORKER_MODEL_HOST_PATH' --online --model-id '$MODEL_ID' --revision '$MODEL_REVISION'" < "$SCRIPT_DIR/verify-model.py"
}

if [[ "$MODE" == check ]]; then
  docker image inspect "$IMAGE" >/dev/null
  ssh_worker "docker image inspect '$IMAGE' >/dev/null"
  verify_local
  verify_worker
  echo "Pinned image and checkpoint verified on both nodes"
  exit 0
fi

echo "Pulling immutable image on both nodes..."
docker pull "$IMAGE"
ssh_worker "docker pull '$IMAGE'"

if verify_local >/dev/null 2>&1; then
  echo "Head checkpoint already matches the pinned revision"
else
  parent="$(dirname "$MODEL_HOST_PATH")"
  name="$(basename "$MODEL_HOST_PATH")"
  mkdir -p "$parent"
  echo "Downloading $MODEL_ID@$MODEL_REVISION directly on the head..."
  TOKEN_ARGS=()
  [[ -z "${HF_TOKEN:-}" ]] || TOKEN_ARGS=(-e HF_TOKEN)
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    "${TOKEN_ARGS[@]}" \
    -v "$parent:/models" \
    --entrypoint python3 \
    "$IMAGE" - "$MODEL_ID" "$MODEL_REVISION" "/models/$name" <<'PY'
from huggingface_hub import snapshot_download
import sys
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
PY
  verify_local
fi
printf '%s\n' "$MODEL_REVISION" > "$MODEL_HOST_PATH/.qwen38-recipe-revision"

if [[ "$SKIP_WORKER_SYNC" == 0 ]]; then
  if verify_worker >/dev/null 2>&1; then
    echo "Worker checkpoint already matches the pinned revision"
  else
    echo "Synchronizing checkpoint to the worker over the 200 Gbit/s fabric..."
    ssh_worker_fabric "mkdir -p '$WORKER_MODEL_HOST_PATH'"
    rsync -a --partial --info=progress2 \
      -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
      "$MODEL_HOST_PATH/" "$WORKER_FABRIC_SSH_HOST:$WORKER_MODEL_HOST_PATH/"
    verify_worker
  fi
fi

echo "Download and validation complete"
