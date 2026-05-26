#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/utils/logging.sh"
start_log "vm-106-docker-media"
source "$REPO_ROOT/lib/vm-cloudinit-common.sh"

MEDIA_VM_STORAGE="${MEDIA_VM_STORAGE:-nvme-media}"
if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$MEDIA_VM_STORAGE"; then
  echo "❌ VM106 için storage bulunamadı: $MEDIA_VM_STORAGE"
  echo "Önce Install Menu -> 12 Normalize Proxmox local storage ile MLD M500 üzerinde nvme-media oluştur."
  exit 1
fi
VM_STORAGE="$MEDIA_VM_STORAGE"

find_intel_igpu() {
  lspci -Dnn | awk '/VGA compatible controller|Display controller|3D controller/ && /Intel/ && /UHD Graphics|Raptor Lake|Alder Lake|Integrated Graphics/ {print $1; exit}'
}
attach_igpu_to_vm106() {
  local pci short
  pci="$(find_intel_igpu || true)"
  if [[ -z "$pci" ]]; then
    echo "⚠️ Intel iGPU detect edilemedi. VM106 GPU passthrough atlandı."
    return 0
  fi
  short="${pci#0000:}"
  echo "🎬 VM106 Intel iGPU passthrough ekleniyor: $short"
  qm set 106 --hostpci0 "$short,pcie=1" || {
    echo "⚠️ VM106 iGPU passthrough eklenemedi. Sonradan repair script kullan: maintenance/repair/repair-gpu-passthrough.sh"
    return 0
  }
}

AUTO_START=0
create_ubuntu_vm 106 "docker-media" "192.168.50.106/24" 32768 8 512G "yes" "media,tankphotos,privatephotos"
attach_igpu_to_vm106

if [[ "${AUTO_START_AFTER_GPU:-1}" == "1" ]]; then
  qm start 106 || true
  wait_for_agent 106 80
fi

echo "✅ VM106 hazır. Sonraki aşamada i915 / /dev/dri validation services/common prepare veya GPU repair ile yapılacak."
