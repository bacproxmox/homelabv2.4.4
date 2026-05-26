#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "prepare-all-docker-hosts"
source "$ROOT_DIR/utils/remote.sh"
for vm in 102 103 104 105 106 107; do
  echo "▶️ Docker host hazırlanıyor: VM$vm"
  run_remote_script "$vm" "$ROOT_DIR/services/common/00-prepare-docker-host.sh"
done

echo
if [[ -x "$ROOT_DIR/maintenance/repair/repair-gpu-passthrough.sh" ]]; then
  echo "🎮 VM106/VM107 GPU passthrough + driver validation çalışıyor..."
  bash "$ROOT_DIR/maintenance/repair/repair-gpu-passthrough.sh" || echo "⚠️ GPU repair/validation uyarı verdi; maintenance menüsünden tekrar denenebilir."
fi
