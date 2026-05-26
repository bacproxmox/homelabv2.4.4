#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../utils/logging.sh"
start_log "resize-vm106-vm107"

resize_vm() {
  local vmid="$1" mem="$2" cores="$3" disk_target="$4"
  if ! qm status "$vmid" >/dev/null 2>&1; then echo "⚠️ VM $vmid yok, atlandı"; return 0; fi
  echo "🛠️ VM $vmid resource ayarlanıyor: RAM $mem / cores $cores / disk hedef $disk_target"
  qm set "$vmid" --memory "$mem" --cores "$cores" --balloon 0
  disk_line="$(qm config "$vmid" | awk -F': ' '/^scsi0:/ {print $2}')"
  if [[ -n "$disk_line" ]]; then
    echo "ℹ️ Disk resize idempotent değildir; mevcut disk hedefinden küçükse büyütmeyi dene."
    qm resize "$vmid" scsi0 "$disk_target" || true
  fi
}

resize_vm 106 32768 8 512G
resize_vm 107 16384 6 512G

echo "✅ VM106/VM107 resource repair tamamlandı."
