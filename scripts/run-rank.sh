#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
case "$ROLE" in
  head|worker) ;;
  *) echo "Usage: $0 head|worker" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

case "$ROLE" in
  head)
    NODE_RANK=0
    SGLANG_HOST_IP="$HEAD_FABRIC_IP"
    ROLE_MODEL_HOST_PATH="$MODEL_HOST_PATH"
    ;;
  worker)
    NODE_RANK=1
    SGLANG_HOST_IP="$WORKER_FABRIC_IP"
    ROLE_MODEL_HOST_PATH="$WORKER_MODEL_HOST_PATH"
    ;;
esac

case "$QWEN38_NCCL_TRANSPORT" in
  socket)
    NCCL_NET=Socket
    NCCL_IB_DISABLE=1
    ;;
  roce)
    NCCL_NET=IB
    NCCL_IB_DISABLE=0
    ;;
  *)
    echo "Unsupported QWEN38_NCCL_TRANSPORT=$QWEN38_NCCL_TRANSPORT" >&2
    exit 2
    ;;
esac

ip -4 addr show dev "$FABRIC_INTERFACE" | grep -Fq "$SGLANG_HOST_IP/" || {
  echo "$FABRIC_INTERFACE does not own $SGLANG_HOST_IP" >&2
  exit 1
}
[[ -f "$ROLE_MODEL_HOST_PATH/config.json" ]] || {
  echo "Model is missing: $ROLE_MODEL_HOST_PATH" >&2
  exit 1
}

"$SCRIPT_DIR/prepare-qsa-sm121-patch.sh"
# shellcheck disable=SC1091
source "$ROOT/patches/qsa-sm121/module-path.env"

mkdir -p "$CACHE_HOST_ROOT/sglang" "$CACHE_HOST_ROOT/triton" "$CACHE_HOST_ROOT/flashinfer"
remove_owned_local

OPTIONAL_ARGS=()
[[ -z "${QWEN38_MAX_TOTAL_TOKENS:-}" ]] || OPTIONAL_ARGS+=(--max-total-tokens "$QWEN38_MAX_TOTAL_TOKENS")
[[ -z "${QWEN38_MAX_MAMBA_CACHE_SIZE:-}" ]] || OPTIONAL_ARGS+=(--max-mamba-cache-size "$QWEN38_MAX_MAMBA_CACHE_SIZE")
[[ "${QWEN38_ENABLE_CACHE_REPORT:-0}" != 1 ]] || OPTIONAL_ARGS+=(--enable-cache-report)

MTP_ARGS=()
if [[ "$QWEN38_ENABLE_MTP" == 1 ]]; then
  MTP_ARGS=(
    --speculative-algorithm NEXTN
    --speculative-num-steps "$QWEN38_MTP_NUM_STEPS"
    --speculative-eagle-topk "$QWEN38_MTP_TOPK"
    --speculative-num-draft-tokens "$QWEN38_MTP_NUM_DRAFT_TOKENS"
    --speculative-draft-model-quantization unquant
  )
  [[ -z "${QWEN38_MTP_ATTENTION_MODE:-}" ]] || MTP_ARGS+=(--speculative-attention-mode "$QWEN38_MTP_ATTENTION_MODE")
fi

exec docker run -d \
  --name "$CONTAINER_NAME" \
  --label io.github.twistedgrim.recipe=qwen38-flash-next-nvfp4-tp2 \
  --network host \
  --ipc host \
  --shm-size 64g \
  --ulimit memlock=-1:-1 \
  --ulimit stack=67108864 \
  --device nvidia.com/gpu=all \
  --device /dev/infiniband \
  -v "$ROLE_MODEL_HOST_PATH:$MODEL_CONTAINER_PATH:ro" \
  -v "$QSA_PATCHED_PATH:$QSA_MODULE_PATH:ro" \
  -v "$CACHE_HOST_ROOT/sglang:/root/.cache/sglang" \
  -v "$CACHE_HOST_ROOT/triton:/root/.cache/triton" \
  -v "$CACHE_HOST_ROOT/flashinfer:/root/.cache/flashinfer" \
  -e HOME=/root \
  -e SGLANG_HOST_IP="$SGLANG_HOST_IP" \
  -e TP_SOCKET_IFNAME="$FABRIC_INTERFACE" \
  -e NCCL_NET="$NCCL_NET" \
  -e NCCL_IB_DISABLE="$NCCL_IB_DISABLE" \
  -e NCCL_SOCKET_IFNAME="$FABRIC_INTERFACE" \
  -e GLOO_SOCKET_IFNAME="$FABRIC_INTERFACE" \
  -e NCCL_IB_HCA="$NCCL_IB_HCA" \
  -e NCCL_IB_GID_INDEX="$NCCL_IB_GID_INDEX" \
  -e NCCL_IB_ROCE_VERSION_NUM="$NCCL_IB_ROCE_VERSION_NUM" \
  -e NCCL_NET_PLUGIN="$NCCL_NET_PLUGIN" \
  -e NCCL_NVLS_ENABLE="$NCCL_NVLS_ENABLE" \
  -e NCCL_CUMEM_ENABLE="$NCCL_CUMEM_ENABLE" \
  -e NCCL_DEBUG="${NCCL_DEBUG:-WARN}" \
  -e NCCL_IGNORE_CPU_AFFINITY="${NCCL_IGNORE_CPU_AFFINITY:-1}" \
  --entrypoint python3 \
  "$IMAGE" \
  -m sglang.launch_server \
  --model-path "$MODEL_CONTAINER_PATH" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --tp 2 --nnodes 2 --node-rank "$NODE_RANK" \
  --dist-init-addr "$HEAD_FABRIC_IP:$MASTER_PORT" \
  --quantization modelopt_fp4 \
  --fp4-gemm-backend flashinfer_cutlass \
  --page-size 64 \
  --mamba-radix-cache-strategy extra_buffer \
  --mamba-track-interval "$QWEN38_MAMBA_TRACK_INTERVAL" \
  --prefill-attention-backend triton \
  --decode-attention-backend trtllm_mha \
  --linear-attn-prefill-backend triton \
  --linear-attn-decode-backend flashinfer \
  --mamba-ssm-dtype bfloat16 \
  --kv-cache-dtype bfloat16 \
  --no-ple-offload-embedding \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --language-only \
  --context-length "$QWEN38_CONTEXT_LENGTH" \
  --mem-fraction-static "$QWEN38_MEM_FRACTION" \
  --chunked-prefill-size "$QWEN38_CHUNKED_PREFILL_SIZE" \
  --max-running-requests "$QWEN38_MAX_RUNNING_REQUESTS" \
  --enable-metrics \
  --enable-request-time-stats-logging \
  --allow-auto-truncate \
  --host 0.0.0.0 \
  --port "$PORT" \
  "${OPTIONAL_ARGS[@]}" \
  "${MTP_ARGS[@]}"
