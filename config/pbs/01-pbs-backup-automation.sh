#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "pbs-backup-automation"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env

PBS_IP="${PBS_IP:-192.168.50.110}"
PBS_STORAGE_ID="${PBS_STORAGE_ID:-pbs-pi-a}"
PBS_DATASTORE_NAME="${PBS_DATASTORE_NAME:-pi-pbs-a}"
PBS_USER_REALM="${PBS_USER_REALM:-${BACKUP_USER:-backup}@pam}"
PBS_FINGERPRINT_FILE="/root/homelab-secrets/pbs-fingerprint.env"

: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik.}"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y sshpass curl jq >/dev/null

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

echo "🔎 PBS API/WebUI erişim kontrolü: https://${PBS_IP}:8007"
if ! curl -k -fsSI --connect-timeout 5 --max-time 10 "https://${PBS_IP}:8007" >/dev/null; then
  echo "⚠️ PBS reachable değil; önce service install repair deneniyor."
  bash "$ROOT_DIR/services/pbs/01-pbs-service-install.sh"
fi
curl -k -fsSI --connect-timeout 5 --max-time 10 "https://${PBS_IP}:8007" >/dev/null || { echo "❌ PBS hala reachable değil."; exit 1; }

FINGERPRINT=""
if [[ -f "$PBS_FINGERPRINT_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$PBS_FINGERPRINT_FILE"
  FINGERPRINT="${PBS_FINGERPRINT:-}"
fi
if [[ -z "$FINGERPRINT" ]]; then
  FINGERPRINT="$(sshpass -p "$BACKUP_PASS" ssh "${SSH_OPTS[@]}" root@"$PBS_IP" "proxmox-backup-manager cert info --output-format json 2>/dev/null | jq -r '.fingerprint // empty'" || true)"
fi
if [[ -z "$FINGERPRINT" ]]; then
  echo "⚠️ PBS fingerprint alınamadı, pvesm add sslfingerprint olmadan denenecek."
else
  mkdir -p /root/homelab-secrets; chmod 700 /root/homelab-secrets
  printf 'PBS_FINGERPRINT=%q\n' "$FINGERPRINT" > "$PBS_FINGERPRINT_FILE"
  chmod 600 "$PBS_FINGERPRINT_FILE"
fi

echo "🔐 PBS storage secret ayarlanıyor: $PBS_STORAGE_ID"
printf '%s\n' "$BACKUP_PASS" > /tmp/pbs-storage-pass
chmod 600 /tmp/pbs-storage-pass
if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$PBS_STORAGE_ID"; then
  echo "✅ PVE storage mevcut: $PBS_STORAGE_ID"
else
  args=(pbs "$PBS_STORAGE_ID" --server "$PBS_IP" --datastore "$PBS_DATASTORE_NAME" --username "$PBS_USER_REALM" --password /tmp/pbs-storage-pass --content backup)
  [[ -n "$FINGERPRINT" ]] && args+=(--fingerprint "$FINGERPRINT")
  pvesm add "${args[@]}"
fi
rm -f /tmp/pbs-storage-pass
pvesm status | grep -E "^${PBS_STORAGE_ID}[[:space:]]" || { echo "❌ PVE PBS storage doğrulanamadı."; exit 1; }

# Create/update daily backup job. Use pvesh when available; fallback prints manual command.
JOB_ID="homelab-daily-pbs"
SCHEDULE="${PBS_BACKUP_SCHEDULE:-03:30}"
VMIDS="${PBS_BACKUP_VMIDS:-101,102,103,104,105,106,107}"
# PBS VM110 is intentionally excluded from default backups to avoid recursion; add manually if desired.

echo "🗓️ PVE backup job hazırlanıyor: $JOB_ID -> $PBS_STORAGE_ID"
if command -v pvesh >/dev/null 2>&1; then
  existing="$(pvesh get /cluster/backup --output-format json 2>/dev/null | jq -r --arg id "$JOB_ID" '.[]? | select(.id==$id) | .id' || true)"
  if [[ -n "$existing" ]]; then
    pvesh set "/cluster/backup/${JOB_ID}" --storage "$PBS_STORAGE_ID" --schedule "$SCHEDULE" --vmid "$VMIDS" --mode snapshot --compress zstd --enabled 1 --notes-template '{{guestname}} {{vmid}}' >/dev/null || true
  else
    pvesh create /cluster/backup --id "$JOB_ID" --storage "$PBS_STORAGE_ID" --schedule "$SCHEDULE" --vmid "$VMIDS" --mode snapshot --compress zstd --enabled 1 --notes-template '{{guestname}} {{vmid}}' >/dev/null
  fi
else
  echo "⚠️ pvesh yok; backup job otomatik eklenemedi."
fi

echo "🧹 Retention policy notu: PBS datastore prune/verify PBS WebUI/API üzerinden yönetilir."
echo "   Öneri: keep-daily=7, keep-weekly=4, keep-monthly=3, weekly verify."

echo "✅ PBS backup automation tamamlandı."
