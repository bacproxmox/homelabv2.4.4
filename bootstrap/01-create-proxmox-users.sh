#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/env-loader.sh"
source "$SCRIPT_DIR/../utils/logging.sh"
start_log "create-proxmox-users"
require_root
load_all_env

create_linux_user() {
  local user="$1" pass="$2" uid="$3" gid="$4" shell="$5"
  getent group "$user" >/dev/null || groupadd -g "$gid" "$user"
  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -u "$uid" -g "$gid" -s "$shell" "$user"
  fi
  echo "$user:$pass" | chpasswd
}

ensure_pve_user() {
  local user="$1" pass="$2" role="$3"
  if ! pveum user list | awk '{print $1}' | grep -qx "${user}@pam"; then
    pveum user add "${user}@pam"
  fi
  echo "$user:$pass" | chpasswd
  pveum acl modify / -user "${user}@pam" -role "$role"
}

echo "👥 Linux + Proxmox kullanıcıları hazırlanıyor..."
create_linux_user "$MEDIA_USER" "$MEDIA_PASS" "$MEDIA_UID" "$MEDIA_GID" "/usr/sbin/nologin"
create_linux_user "$BACMASTER_USER" "$BACMASTER_PASS" "$BACMASTER_UID" "$BACMASTER_GID" "/bin/bash"
create_linux_user "$TULUMBA_USER" "$TULUMBA_PASS" "$TULUMBA_UID" "$TULUMBA_GID" "/bin/bash"
create_linux_user "$BACKUP_USER" "$BACKUP_PASS" "$BACKUP_UID" "$BACKUP_GID" "/bin/bash"
usermod -aG sudo "$BACMASTER_USER"
usermod -aG sudo "$TULUMBA_USER"

ensure_pve_user "$BACMASTER_USER" "$BACMASTER_PASS" "Administrator"
ensure_pve_user "$TULUMBA_USER" "$TULUMBA_PASS" "PVEAdmin"

echo "✅ Proxmox users tamam."
