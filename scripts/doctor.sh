#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

failures=0
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

local_fabric() {
  ip -4 addr show dev "$FABRIC_INTERFACE" | grep -Fq "$HEAD_FABRIC_IP/" &&
    [[ "$(cat "/sys/class/net/$FABRIC_INTERFACE/mtu")" -ge 9000 ]]
}
worker_fabric() {
  ssh_worker "ip -4 addr show dev '$FABRIC_INTERFACE' | grep -Fq '$WORKER_FABRIC_IP/' && test \"\$(cat '/sys/class/net/$FABRIC_INTERFACE/mtu')\" -ge 9000"
}
local_roce() {
  [[ -e "/sys/class/infiniband/$NCCL_IB_HCA" && -e /dev/infiniband/rdma_cm ]]
}
worker_roce() {
  ssh_worker "test -e '/sys/class/infiniband/$NCCL_IB_HCA' -a -e /dev/infiniband/rdma_cm"
}
local_model() {
  python3 "$SCRIPT_DIR/verify-model.py" "$MODEL_HOST_PATH"
}
worker_model() {
  ssh_worker "python3 - '$WORKER_MODEL_HOST_PATH'" < "$SCRIPT_DIR/verify-model.py"
}
worker_qsa_source() {
  ssh_worker "docker run --rm --entrypoint python3 '$IMAGE' -c 'import hashlib; import sglang.srt.layers.attention.qwen_sparse_attn_backend as m; print(hashlib.sha256(open(m.__file__, \"rb\").read()).hexdigest())'" |
    grep -qx c959835d05d0f395ad7eae4330cf264af9f6f7c1bff3d45a39bb953d2536f5f2
}

check "docker on head" docker info
check "passwordless worker SSH" ssh_worker true
check "worker SSH over fabric" ssh_worker_fabric true
check "head 10.76 fabric and jumbo MTU" local_fabric
check "worker 10.76 fabric and jumbo MTU" worker_fabric
check "head RoCE device" local_roce
check "worker RoCE device" worker_roce
check "pinned image on head" docker image inspect "$IMAGE"
check "pinned image on worker" ssh_worker docker image inspect "$IMAGE"
check "checkpoint structure on head" local_model
check "checkpoint structure on worker" worker_model
check "QSA patch applies on head" "$SCRIPT_DIR/prepare-qsa-sm121-patch.sh"
check "QSA source matches on worker" worker_qsa_source

if [[ "$QWEN38_NCCL_TRANSPORT" == roce ]]; then
  check "configured RoCE GID exists on head" test -e "/sys/class/infiniband/$NCCL_IB_HCA/ports/1/gids/$NCCL_IB_GID_INDEX"
  check "configured RoCE GID exists on worker" ssh_worker test -e "/sys/class/infiniband/$NCCL_IB_HCA/ports/1/gids/$NCCL_IB_GID_INDEX"
fi

if (( failures )); then
  echo "$failures doctor check(s) failed" >&2
  exit 1
fi
echo "Doctor passed"
