#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "========================================="
echo " Homelab v2.4.4 - Repo Audit"
echo "========================================="

fail=0
check() {
  local name="$1" cmd="$2"
  echo; echo "▶️ $name"
  if bash -c "$cmd"; then echo "✅ OK: $name"; else echo "❌ FAIL: $name"; fail=1; fi
}

check "Bash syntax" 'find . -name "*.sh" -print0 | xargs -0 -n1 bash -n'
check "Executable scripts" 'missing=$(find . -name "*.sh" ! -perm -111); [[ -z "$missing" ]] || { echo "$missing"; exit 1; }'
check "Required directories" 'for d in bootstrap vm services config menu utils maintenance lib docs gpu additionals; do [[ -d "$d" ]] || exit 1; done'
check "v2.4.1 VM foundation untouched" 'cmp -s lib/vm-cloudinit-common.sh /tmp/nonexistent 2>/dev/null && exit 1 || grep -q "create_ubuntu_vm" lib/vm-cloudinit-common.sh && ! grep -q "actual_size" lib/vm-cloudinit-common.sh'
check "Guided pipeline exists" 'grep -q "Guided full pipeline" menu/install-menu.sh && grep -q "run_full_install_pipeline" menu/install-menu.sh'
check "VM fixed MAC defaults" 'grep -q "VM101_MAC.*02:23:14:00:01:01" bootstrap/00-bootstrap-secrets.sh && grep -q "VM110_MAC.*02:23:14:00:01:10" bootstrap/00-bootstrap-secrets.sh'
check "nvme-media support" 'grep -q "MLD M500" bootstrap/02-normalize-local-storage.sh && grep -q "MEDIA_VM_STORAGE.*nvme-media" vm/106-media-ai-vm-install.sh && grep -q "CHIA_VM_STORAGE.*nvme-media" vm/107-chia-farmer-vm-install.sh'
check "VM107 512G" 'grep -q "create_ubuntu_vm 107 .* 512G" vm/107-chia-farmer-vm-install.sh && grep -q "resize_vm 107 .* 512G" maintenance/repair/vm/resize-vm106-vm107.sh'
check "PBS install validation" 'grep -q "proxmox-backup-server proxmox-backup-client" services/pbs/01-pbs-service-install.sh && grep -q "https://\${PBS_IP}:8007" services/pbs/01-pbs-service-install.sh && grep -q "BACKUP_PASS" vm/110-pbs-backup-vm-install.sh'
check "Immich CPU fallback" 'grep -q "/dev/dri yok" services/immich/01-immich-service-install.sh && grep -q "docker-compose.gpu.yml" services/immich/01-immich-service-install.sh'
check "Chia TrueNAS cache" 'grep -q "/mnt/chia-db-cache" services/chia/01-chia-farmer-service-install.sh && grep -q "/mnt/tank/chia-db" services/truenas/01-truenas-api-bootstrap-storage.sh'
check "Bacscloud cleanup/social scripts" '[[ -f config/nextcloud/06-bacscloud-admin-overview-cleanup.sh && -f config/nextcloud/07-bacscloud-social-login-and-registration.sh ]] && grep -q "custom_providers.*>/dev/null" config/nextcloud/07-bacscloud-social-login-and-registration.sh'
check "Support bundle redaction" 'grep -q "GOCSPX" maintenance/logs/collect-support-bundle.sh && grep -q "clientSecret" maintenance/logs/collect-support-bundle.sh'

if [[ "$fail" -eq 0 ]]; then
  echo; echo "✅ Repo audit temiz."
else
  echo; echo "❌ Repo audit hata buldu."
fi
exit "$fail"
