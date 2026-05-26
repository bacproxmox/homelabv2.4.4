#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/logging.sh"; start_log "vm-resource-audit"
source "$ROOT_DIR/utils/remote.sh"

check_vm() {
  local vmid="$1" name="$2" expected_mem="$3" expected_cores="$4"
  echo
  echo "🖥️ VM $vmid / $name"
  if ! qm status "$vmid" >/dev/null 2>&1; then echo "❌ VM yok"; return 1; fi
  mem="$(qm config "$vmid" | awk '/^memory:/ {print $2}')"
  cores="$(qm config "$vmid" | awk '/^cores:/ {print $2}')"
  [[ "$mem" == "$expected_mem" ]] && echo "✅ RAM doğru: $mem MB" || echo "⚠️ RAM beklenen $expected_mem MB, mevcut ${mem:-?} MB"
  [[ "$cores" == "$expected_cores" ]] && echo "✅ Core doğru: $cores" || echo "⚠️ Core beklenen $expected_cores, mevcut ${cores:-?}"
  qm config "$vmid" | grep -E '^(name|memory|cores|hostpci|vga|scsi0|net0):' | sed 's/^/  /' || true
}

check_vm 101 truenas 16384 4 || true
check_vm 102 docker-arr 16384 6 || true
check_vm 103 docker-network 4096 2 || true
check_vm 104 nextcloud 8192 4 || true
check_vm 105 homeassistant 4096 2 || true
check_vm 106 docker-media 32768 8 || true
check_vm 107 chia-farmer 16384 6 || true
check_vm 110 pbs-backup 8192 4 || true

echo
echo "🎬 VM106 iGPU passthrough / /dev/dri"
qm config 106 | grep -E '^hostpci' || echo "⚠️ VM106 hostpci yok"
rssh 106 'ls -lah /dev/dri 2>/dev/null || true; lspci -nnk | grep -A3 -Ei "UHD Graphics|i915|VGA|Display" || true; vainfo --display drm --device /dev/dri/renderD128 2>/dev/null | head -20 || true' || true

echo
echo "🌱 VM107 NVIDIA + JMicron + Chia disk audit"
qm config 107 | grep -E '^hostpci' || echo "⚠️ VM107 hostpci yok"
rssh 107 'nvidia-smi || true; echo; lspci -nn | grep -Ei "nvidia|jmicron|jmb|jms|sata|ahci" || true; echo; lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,TRAN,MOUNTPOINTS | grep -Ei "NAME|TOSHIBA|QEMU" || true; echo; echo "Plot disks:"; find /dev/disk/by-id -maxdepth 1 -type l | grep -Ei "TOSHIBA_HDWG|HDWG180|HDWG480" | sort | grep -v part || true; echo; df -h | grep /mnt/chia-plots || true; echo; grep -R "parallel_decompressor_count" ~/.chia/mainnet/config/config.yaml 2>/dev/null || true; echo; ss -ltnp | grep 55400 || true' || true
