#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_config

remove_owned_local
remove_owned_worker
echo "Stopped $CONTAINER_NAME on head and worker"
