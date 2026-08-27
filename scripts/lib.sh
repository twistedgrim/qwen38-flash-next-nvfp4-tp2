#!/usr/bin/env bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${QWEN38_CONFIG:-$ROOT/config.env}"

load_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Missing $CONFIG_FILE; copy config.example.env to config.env" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  local required=(
    MODEL_ID MODEL_REVISION MODEL_HOST_PATH WORKER_MODEL_HOST_PATH
    MODEL_CONTAINER_PATH IMAGE CONTAINER_NAME SERVED_MODEL_NAME PORT
    WORKER_SSH_HOST WORKER_FABRIC_SSH_HOST WORKER_RECIPE_DIR
    HEAD_FABRIC_IP WORKER_FABRIC_IP FABRIC_INTERFACE MASTER_PORT
    QWEN38_NCCL_TRANSPORT NCCL_IB_HCA NCCL_IB_GID_INDEX
    NCCL_IB_ROCE_VERSION_NUM NCCL_NET_PLUGIN NCCL_NVLS_ENABLE NCCL_CUMEM_ENABLE
    QWEN38_CONTEXT_LENGTH QWEN38_MEM_FRACTION
    QWEN38_MAX_RUNNING_REQUESTS QWEN38_CHUNKED_PREFILL_SIZE
    QWEN38_MAMBA_TRACK_INTERVAL QWEN38_ENABLE_MTP CACHE_HOST_ROOT
  )
  local name
  for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || {
      echo "Missing required setting: $name" >&2
      return 1
    }
  done
}

ssh_worker() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH_HOST" "$@"
}

ssh_worker_fabric() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_FABRIC_SSH_HOST" "$@"
}

api_base() {
  printf 'http://127.0.0.1:%s' "$PORT"
}

container_running_local() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true
}

container_running_worker() {
  ssh_worker "docker inspect -f '{{.State.Running}}' '$CONTAINER_NAME' 2>/dev/null" | grep -qx true
}

remove_owned_local() {
  if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    return 0
  fi
  local label
  label="$(docker inspect -f '{{index .Config.Labels "io.github.twistedgrim.recipe"}}' "$CONTAINER_NAME")"
  if [[ "$label" != qwen38-flash-next-nvfp4-tp2 && "${QWEN38_ALLOW_UNLABELED_CONTAINER:-0}" != 1 ]]; then
    echo "Refusing to remove unowned container $CONTAINER_NAME (label=$label)" >&2
    return 1
  fi
  docker rm -f "$CONTAINER_NAME" >/dev/null
}

remove_owned_worker() {
  if ! ssh_worker "docker container inspect '$CONTAINER_NAME' >/dev/null 2>&1"; then
    return 0
  fi
  local label
  label="$(ssh_worker "docker inspect -f '{{index .Config.Labels \"io.github.twistedgrim.recipe\"}}' '$CONTAINER_NAME'")"
  if [[ "$label" != qwen38-flash-next-nvfp4-tp2 && "${QWEN38_ALLOW_UNLABELED_CONTAINER:-0}" != 1 ]]; then
    echo "Refusing to remove unowned worker container $CONTAINER_NAME (label=$label)" >&2
    return 1
  fi
  ssh_worker "docker rm -f '$CONTAINER_NAME' >/dev/null"
}
