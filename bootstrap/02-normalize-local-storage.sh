#!/usr/bin/env bash
set -Eeuo pipefail

STORAGE_CFG="/etc/pve/storage.cfg"
BACKUP_DIR="/root/homelab-backups/storage"
mkdir -p "$BACKUP_DIR"

echo
echo "🧩 Proxmox local storage normalize ediliyor..."

if [[ ! -f "$STORAGE_CFG" ]]; then
  echo "❌ $STORAGE_CFG bulunamadı. Bu script Proxmox host üzerinde çalışmalı."
  exit 1
fi

cp "$STORAGE_CFG" "$BACKUP_DIR/storage.cfg.backup.before-local.$(date +%F-%H%M%S)"

# Disabled/legacy dir: local bloğunu kaldır.
awk '
BEGIN { skip=0 }
$0=="dir: local" { skip=1; next }
skip && NF==0 { skip=0; next }
!skip { print }
' "$STORAGE_CFG" > /tmp/storage.cfg.new
cat /tmp/storage.cfg.new > "$STORAGE_CFG"

# Fresh BTRFS kurulumlarında local storage farklı isimlerle gelebiliyor.
# Homelab scriptleri klasik local:iso/... beklediği için normalize ediyoruz.
sed -i \
  -e 's/^btrfs: local-system$/btrfs: local/' \
  -e 's/^btrfs: local-btrfs$/btrfs: local/' \
  "$STORAGE_CFG"

# Optional dedicated media/AI/Chia NVMe storage.  This is intentionally isolated
# from the v2.4.1 VM creation library: VM106/107 opt into MEDIA_VM_STORAGE/CHIA_VM_STORAGE.
create_nvme_media_if_requested() {
  local storage="${MEDIA_VM_STORAGE:-nvme-media}"
  [[ "$storage" == "nvme-media" ]] || return 0

  if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx 'nvme-media'; then
    echo "✅ nvme-media storage zaten mevcut."
    return 0
  fi

  echo
  echo "💽 Opsiyonel nvme-media storage kontrolü"
  echo "VM106 docker-media ve VM107 chia-farmer için boş MLD M500 1TB NVMe kullanılabilir."

  local dev="" line name model serial type size
  while read -r name model serial type size; do
    [[ "$type" == "disk" ]] || continue
    if grep -qi 'MLD M500' <<<"$model $serial"; then
      if [[ "$(lsblk -n "/dev/$name" | wc -l)" -eq 1 ]]; then
        dev="/dev/$name"
        echo "✅ Boş aday bulundu: $dev / model=$model / serial=$serial / size=$size"
        break
      else
        echo "⚠️ MLD M500 bulundu ama partition var, otomatik kullanılmayacak: /dev/$name"
      fi
    fi
  done < <(lsblk -dn -o NAME,MODEL,SERIAL,TYPE,SIZE | sed 's/[[:space:]][[:space:]]*/ /g')

  if [[ -z "$dev" ]]; then
    echo "ℹ️ Boş MLD M500 NVMe bulunamadı; nvme-media oluşturulmadı."
    echo "   VM106/VM107 scriptleri nvme-media yoksa net hata verir."
    return 0
  fi

  local ans="${AUTO_CREATE_NVME_MEDIA:-}"
  if [[ "$ans" != "1" ]]; then
    echo
    echo "DİKKAT: Bu işlem $dev diskinin üstünü silip ZFS pool 'nvme-media' oluşturur."
    read -r -p "Bu diski nvme-media olarak kullanmak için büyük harfle YES yaz: " ans
    [[ "$ans" == "YES" ]] || { echo "ℹ️ nvme-media oluşturma atlandı."; return 0; }
  fi

  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y gdisk >/dev/null 2>&1 || true
  wipefs -a "$dev" || true
  sgdisk --zap-all "$dev" || true
  zpool create -f -o ashift=12 nvme-media "$dev"
  pvesm add zfspool nvme-media -pool nvme-media -content images,rootdir -sparse 1 || true
  echo "✅ nvme-media storage oluşturuldu."
}

create_nvme_media_if_requested

# Eski hatalı apt backup dosyalarını sources.list.d dışına taşı; apt warninglerini susturur.
APT_BACKUP_DIR="/root/homelab-backups/apt-sources"
mkdir -p "$APT_BACKUP_DIR"
find /etc/apt/sources.list.d -maxdepth 1 -type f \
  \( -name '*.backup.*' -o -name '*.bak.*' \) \
  -exec mv -f {} "$APT_BACKUP_DIR/" \; 2>/dev/null || true

echo
echo "===== Yeni storage.cfg ====="
cat "$STORAGE_CFG"

echo
echo "===== Proxmox storage durumu ====="
pvesm status || true

echo
echo "✅ local storage normalize tamamlandı."
