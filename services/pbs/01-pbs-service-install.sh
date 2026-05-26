#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "pbs-service-install"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"

: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik. Önce Install Menu -> 1 Bootstrap secrets/env çalıştır.}"

PBS_VM="110"
PBS_IP="192.168.50.110"
TMP_REMOTE="/tmp/homelab-pbs-install-remote.sh"
ENV_REMOTE="/tmp/homelab-pbs.env"

sq() { printf "%s" "$1" | sed "s/'/'\\''/g; s/^/'/; s/$/'/"; }

cat > /tmp/homelab-pbs.env <<ENV
BACKUP_USER=$(sq "$BACKUP_USER")
BACKUP_PASS=$(sq "$BACKUP_PASS")
PBS_DATASTORE_NAME=${PBS_DATASTORE_NAME:-pi-pbs-a}
PBS_DATASTORE_PATH=${PBS_DATASTORE_PATH:-/mnt/pi-pbs-a}
PBS_NFS_SOURCE=${PBS_NFS_SOURCE:-192.168.50.99:/srv/pbs-a/datastore}
ENV
chmod 600 /tmp/homelab-pbs.env

cat > /tmp/homelab-pbs-install-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log(){ echo "[$(date -Is)] $*"; }
need_env(){ local v="$1"; [[ -n "${!v:-}" ]] || { echo "❌ $v eksik"; exit 1; }; }
need_env BACKUP_USER
need_env BACKUP_PASS
PBS_DATASTORE_NAME="${PBS_DATASTORE_NAME:-pi-pbs-a}"
PBS_DATASTORE_PATH="${PBS_DATASTORE_PATH:-/mnt/pi-pbs-a}"
PBS_NFS_SOURCE="${PBS_NFS_SOURCE:-192.168.50.99:/srv/pbs-a/datastore}"

log "PBS root/SSH erişimi BACKUP_PASS ile ayarlanıyor..."
printf 'root:%s\n' "$BACKUP_PASS" | chpasswd
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-homelab-root-login.conf <<'SSHCONF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
SSHCONF
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true

log "PBS repo ve paketleri hazırlanıyor..."
apt-get update
apt-get install -y wget curl ca-certificates gnupg lsb-release jq openssh-server sudo nfs-common
CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-trixie}")"
[[ -n "$CODENAME" ]] || CODENAME="trixie"

wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
cat >/etc/apt/sources.list.d/proxmox-pbs.sources <<PBSREPO
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
PBSREPO

# Disable every known enterprise PBS source format.
find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*pbs*enterprise*' -o -name '*enterprise*pbs*' \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if [[ "$f" == *.sources ]]; then
    if grep -qi '^Enabled:' "$f"; then sed -i 's/^Enabled:.*/Enabled: false/i' "$f"; else printf '\nEnabled: false\n' >> "$f"; fi
  else
    sed -i 's/^deb /# deb /' "$f" || true
  fi
done

apt-get update
log "proxmox-backup-server/client kuruluyor..."
apt-get install -y proxmox-backup-server proxmox-backup-client

if ! command -v proxmox-backup-manager >/dev/null 2>&1; then
  echo "❌ proxmox-backup-manager bulunamadı; PBS server kurulumu başarısız."
  dpkg -l | grep -Ei 'proxmox-backup|pbs' || true
  exit 1
fi

log "backup Linux/PAM kullanıcısı hazırlanıyor..."
if ! id "$BACKUP_USER" >/dev/null 2>&1; then useradd -m -s /bin/bash "$BACKUP_USER"; fi
printf '%s:%s\n' "$BACKUP_USER" "$BACKUP_PASS" | chpasswd
usermod -aG sudo "$BACKUP_USER" || true

log "PBS kullanıcı/ACL ayarlanıyor: ${BACKUP_USER}@pam"
proxmox-backup-manager user create "${BACKUP_USER}@pam" --comment "Homelab backup user" 2>/dev/null || proxmox-backup-manager user update "${BACKUP_USER}@pam" --enable true 2>/dev/null || true
proxmox-backup-manager acl update / Admin --auth-id "${BACKUP_USER}@pam" || true

log "NFS datastore mount hazırlanıyor: $PBS_NFS_SOURCE -> $PBS_DATASTORE_PATH"
mkdir -p "$PBS_DATASTORE_PATH"
if ! grep -q "${PBS_NFS_SOURCE} ${PBS_DATASTORE_PATH}" /etc/fstab; then
  echo "${PBS_NFS_SOURCE} ${PBS_DATASTORE_PATH} nfs4 vers=4.2,proto=tcp,hard,noatime,_netdev,x-systemd.automount,x-systemd.device-timeout=30 0 0" >> /etc/fstab
fi
systemctl daemon-reload
mount "$PBS_DATASTORE_PATH" || mount -a || true
if ! mountpoint -q "$PBS_DATASTORE_PATH"; then
  echo "⚠️ NFS datastore mount olmadı: $PBS_DATASTORE_PATH. Geçici local datastore kullanılacak; v2.4.4 automation tekrar deneyebilir."
  mkdir -p /backup/datastore/homelab
  PBS_DATASTORE_PATH="/backup/datastore/homelab"
fi
chown -R backup:backup "$PBS_DATASTORE_PATH" 2>/dev/null || true

log "Datastore hazırlanıyor: ${PBS_DATASTORE_NAME} -> ${PBS_DATASTORE_PATH}"
if ! proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -e --arg n "$PBS_DATASTORE_NAME" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
  proxmox-backup-manager datastore create "$PBS_DATASTORE_NAME" "$PBS_DATASTORE_PATH"
else
  echo "✅ Datastore zaten mevcut: $PBS_DATASTORE_NAME"
fi
proxmox-backup-manager acl update "/datastore/${PBS_DATASTORE_NAME}" DatastoreAdmin --auth-id "${BACKUP_USER}@pam" || true

systemctl enable --now proxmox-backup proxmox-backup-proxy
log "PBS 8007 bekleniyor..."
for i in {1..60}; do
  if ss -ltn | grep -q ':8007'; then break; fi
  sleep 2
done
ss -ltn | grep -q ':8007' || { echo "❌ PBS 8007 açılmadı"; systemctl --no-pager --full status proxmox-backup-proxy proxmox-backup || true; exit 1; }
curl -k -fsSI --connect-timeout 5 --max-time 10 https://127.0.0.1:8007 >/dev/null || { echo "❌ PBS WebUI local check başarısız"; exit 1; }

proxmox-backup-manager versions || true
proxmox-backup-manager datastore list || true

echo
cat <<DONE
✅ Proxmox Backup Server kuruldu ve doğrulandı.
Web UI: https://192.168.50.110:8007
Login : ${BACKUP_USER}@pam veya root@pam
Şifre : BACKUP_PASS
Datastore: ${PBS_DATASTORE_NAME} -> ${PBS_DATASTORE_PATH}
DONE
REMOTE
chmod +x /tmp/homelab-pbs-install-remote.sh

wait_ssh "$PBS_VM"
scp "${SSH_OPTS[@]}" /tmp/homelab-pbs.env "$SSH_USER@$PBS_IP:$ENV_REMOTE" >/dev/null
scp "${SSH_OPTS[@]}" /tmp/homelab-pbs-install-remote.sh "$SSH_USER@$PBS_IP:$TMP_REMOTE" >/dev/null
ssh "${SSH_OPTS[@]}" "$SSH_USER@$PBS_IP" "chmod +x '$TMP_REMOTE' && sudo bash -c 'set -a; source $ENV_REMOTE; set +a; $TMP_REMOTE; rm -f $ENV_REMOTE'"

rm -f /tmp/homelab-pbs.env /tmp/homelab-pbs-install-remote.sh

# Validate from Proxmox side too.
for i in {1..30}; do
  if curl -k -fsSI --connect-timeout 5 --max-time 10 "https://${PBS_IP}:8007" >/dev/null; then
    echo "✅ PBS service install tamamlandı: https://${PBS_IP}:8007"
    exit 0
  fi
  sleep 2
done
echo "❌ PBS dış erişim validation başarısız: https://${PBS_IP}:8007"
exit 1
