#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

[[ "$(basename "$WORKER_RECIPE_DIR")" == qwen38-flash-next-nvfp4-tp2 ]] || {
  echo "Unsafe WORKER_RECIPE_DIR: expected basename qwen38-flash-next-nvfp4-tp2" >&2
  exit 1
}
ssh_worker "test ! -L '$WORKER_RECIPE_DIR' && mkdir -p '$WORKER_RECIPE_DIR'"
rsync -a \
  -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
  --exclude .git/ \
  --exclude config.env \
  --exclude patches/ \
  --exclude results/ \
  --exclude backups/ \
  --exclude __pycache__/ \
  --exclude '*.pyc' \
  "$ROOT/" "$WORKER_SSH_HOST:$WORKER_RECIPE_DIR/"
scp -q -o BatchMode=yes -o ConnectTimeout=10 \
  "$CONFIG_FILE" "$WORKER_SSH_HOST:$WORKER_RECIPE_DIR/config.env"
ssh_worker "grep -qx 'qwen38-flash-next-nvfp4-tp2' '$WORKER_RECIPE_DIR/.qwen38-recipe-root' && chmod 0755 '$WORKER_RECIPE_DIR/qwen38' '$WORKER_RECIPE_DIR'/scripts/*.sh '$WORKER_RECIPE_DIR'/scripts/*.py"
echo "Synchronized recipe to $WORKER_SSH_HOST:$WORKER_RECIPE_DIR"
