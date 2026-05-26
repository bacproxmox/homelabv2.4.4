#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/env-loader.sh"
source "$SCRIPT_DIR/../utils/logging.sh"
source "$SCRIPT_DIR/../utils/env-write.sh"
start_log "bootstrap-secrets"
require_root

ask_visible_confirm() {
  local var="$1" prompt="$2" a="" b=""
  while true; do
    read -r -p "$prompt: " a
    read -r -p "$prompt tekrar: " b
    [[ -n "$a" ]] || { echo "❌ Boş bırakılamaz."; continue; }
    [[ "$a" == "$b" ]] || { echo "❌ Girdiler eşleşmedi."; continue; }
    printf -v "$var" "%s" "$a"
    break
  done
}

ask_hidden_confirm() {
  local var="$1" prompt="$2" a="" b=""
  while true; do
    read -r -s -p "$prompt: " a; echo
    read -r -s -p "$prompt tekrar: " b; echo
    [[ -n "$a" ]] || { echo "❌ Boş bırakılamaz."; continue; }
    [[ "$a" == "$b" ]] || { echo "❌ Girdiler eşleşmedi."; continue; }
    printf -v "$var" "%s" "$a"
    break
  done
}

ask_yes_no_default() {
  local var="$1" prompt="$2" def="${3:-Y}" value=""
  local suffix="[Y/n]"
  [[ "$def" =~ ^[Nn]$ ]] && suffix="[y/N]"
  read -r -p "$prompt $suffix: " value
  value="${value:-$def}"
  if [[ "$value" =~ ^[Yy]$ ]]; then printf -v "$var" "%s" "true"; else printf -v "$var" "%s" "false"; fi
}

ask_chia_mnemonic_hidden() {
  local a="" wc=""
  while true; do
    read -r -s -p "Chia 24-word mnemonic (gizli input, ekranda/logda görünmez): " a; echo
    a="$(echo "$a" | xargs)"
    wc="$(awk '{print NF}' <<<"$a")"
    [[ -n "$a" ]] || { echo "❌ Mnemonic boş olamaz."; continue; }
    [[ "$wc" -eq 24 ]] || { echo "❌ Mnemonic $wc kelime görünüyor; 24 kelime olmalı."; continue; }
    echo "✅ Mnemonic alındı, 24 kelime doğrulandı. İçerik loga basılmadı."
    CHIA_MNEMONIC="$a"
    break
  done
}

ask_visible_once() {
  local var="$1" prompt="$2" value=""
  read -r -p "$prompt: " value
  printf -v "$var" "%s" "$value"
}

ask_text_default() {
  local var="$1" prompt="$2" def="$3" value=""
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " value
    printf -v "$var" "%s" "${value:-$def}"
  else
    read -r -p "$prompt: " value
    printf -v "$var" "%s" "$value"
  fi
}

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# v2.2 uyumluluğu: eski scriptlerin /root/.secrets aramasını bozma.
if [[ ! -e /root/.secrets ]]; then
  ln -s "$SECRETS_DIR" /root/.secrets
elif [[ -d /root/.secrets && ! -L /root/.secrets ]]; then
  echo "ℹ️ /root/.secrets mevcut; homelab-secrets ile senkron kullanılacak."
fi

echo
echo "🔐 Homelab v2.4.4 - secrets/env bootstrap"
echo "Klasör: $SECRETS_DIR"
echo "Not: Bazı kritik secret değerleri gizli input ile alınır ve loga basılmaz."
echo

if [[ ! -f "$SECRETS_DIR/global.env" ]]; then
  DOMAIN="bacmastercloud.com"
  LAN_GW="192.168.50.1"
  LAN_DNS="1.1.1.1"
  VM_STORAGE="nvme-vm"
  MEDIA_VM_STORAGE="nvme-media"
  CHIA_VM_STORAGE="nvme-media"
  PBS_VM_STORAGE="nvme-vm"
  echo "🏗️ Mimari varsayılanları otomatik kullanılacak:"
  echo "  DOMAIN=$DOMAIN"
  echo "  LAN_GW=$LAN_GW"
  echo "  LAN_DNS=$LAN_DNS"
  echo "  VM_STORAGE=$VM_STORAGE"
  echo "  MEDIA_VM_STORAGE=$MEDIA_VM_STORAGE"
  echo "  CHIA_VM_STORAGE=$CHIA_VM_STORAGE"
  echo "  PBS_VM_STORAGE=$PBS_VM_STORAGE"
  read -r -p "Advanced override ister misin? [y/N]: " ADVANCED_OVERRIDE
  if [[ "${ADVANCED_OVERRIDE:-N}" =~ ^[Yy]$ ]]; then
    ask_text_default DOMAIN "Ana domain" "$DOMAIN"
    ask_text_default LAN_GW "Gateway" "$LAN_GW"
    ask_text_default LAN_DNS "DNS" "$LAN_DNS"
    ask_text_default VM_STORAGE "Proxmox VM storage" "$VM_STORAGE"
    ask_text_default MEDIA_VM_STORAGE "Proxmox media/AI VM storage" "$MEDIA_VM_STORAGE"
    ask_text_default CHIA_VM_STORAGE "Proxmox Chia VM storage" "$CHIA_VM_STORAGE"
    ask_text_default PBS_VM_STORAGE "Proxmox PBS VM storage" "$PBS_VM_STORAGE"
  fi
  {
    write_env_header
    write_env_line HOMELAB_VERSION "2.4.4"
    write_env_line DOMAIN "$DOMAIN"
    write_env_line LAN_GW "$LAN_GW"
    write_env_line LAN_DNS "$LAN_DNS"
    write_env_line VM_STORAGE "$VM_STORAGE"
    write_env_line MEDIA_VM_STORAGE "$MEDIA_VM_STORAGE"
    write_env_line CHIA_VM_STORAGE "$CHIA_VM_STORAGE"
    write_env_line PBS_VM_STORAGE "$PBS_VM_STORAGE"
    write_env_line STACKS_DIR "/opt/homelab"
    write_env_line DOCKER_NETWORK "homelab"
    write_env_line TZ "Europe/Istanbul"
    write_env_line VM101_MAC "02:23:14:00:01:01"
    write_env_line VM102_MAC "02:23:14:00:01:02"
    write_env_line VM103_MAC "02:23:14:00:01:03"
    write_env_line VM104_MAC "02:23:14:00:01:04"
    write_env_line VM105_MAC "02:23:14:00:01:05"
    write_env_line VM106_MAC "02:23:14:00:01:06"
    write_env_line VM107_MAC "02:23:14:00:01:07"
    write_env_line VM110_MAC "02:23:14:00:01:10"
  } > "$SECRETS_DIR/global.env"
  chmod 600 "$SECRETS_DIR/global.env"
fi

if [[ ! -f "$SECRETS_DIR/users.env" ]]; then
  ask_visible_confirm BACMASTER_PASS "bacmaster şifresi"
  ask_visible_confirm TULUMBA_PASS "tulumba şifresi"
  ask_visible_confirm MEDIA_PASS "media servis kullanıcısı şifresi"
  ask_visible_confirm BACKUP_PASS "backup kullanıcısı/PBS şifresi"
  ask_visible_confirm ATLON_PASS "Jellyfin atlon şifresi"
  ask_visible_confirm ELIFEZEL_PASS "Jellyfin elifezel şifresi"
  {
    write_env_header
    write_env_line MEDIA_USER "media"
    write_env_line MEDIA_PASS "$MEDIA_PASS"
    write_env_line MEDIA_UID "1000"
    write_env_line MEDIA_GID "1000"
    write_env_line BACMASTER_USER "bacmaster"
    write_env_line BACMASTER_PASS "$BACMASTER_PASS"
    write_env_line BACMASTER_UID "1100"
    write_env_line BACMASTER_GID "1100"
    write_env_line TULUMBA_USER "tulumba"
    write_env_line TULUMBA_PASS "$TULUMBA_PASS"
    write_env_line TULUMBA_UID "1200"
    write_env_line TULUMBA_GID "1200"
    write_env_line BACKUP_USER "backup"
    write_env_line BACKUP_PASS "$BACKUP_PASS"
    write_env_line BACKUP_UID "1300"
    write_env_line BACKUP_GID "1300"
    write_env_line ATLON_USER "atlon"
    write_env_line ATLON_PASS "$ATLON_PASS"
    write_env_line ELIFEZEL_USER "elifezel"
    write_env_line ELIFEZEL_PASS "$ELIFEZEL_PASS"
    write_env_line NEXTCLOUD_ADMIN_USER "bacmaster"
    write_env_line NEXTCLOUD_ADMIN_PASS "$BACMASTER_PASS"
    write_env_line NEXTCLOUD_DB_PASS "$MEDIA_PASS"
    write_env_line IMMICH_ADMIN_EMAIL "admin@bacmastercloud.com"
    write_env_line IMMICH_ADMIN_PASS "$BACMASTER_PASS"
    write_env_line IMMICH_SECOND_USER_EMAIL "cinarburhan1601@gmail.com"
    write_env_line IMMICH_SECOND_USER_PASS "$BACMASTER_PASS"
    write_env_line OPENWEBUI_ADMIN_EMAIL "admin@bacmastercloud.com"
    write_env_line OPENWEBUI_ADMIN_PASS "$BACMASTER_PASS"
    write_env_line ARR_USER "bacmaster"
    write_env_line ARR_PASS "$BACMASTER_PASS"
  } > "$SECRETS_DIR/users.env"
  chmod 600 "$SECRETS_DIR/users.env"
fi

if [[ ! -f "$SECRETS_DIR/truenas-login.env" ]]; then
  echo
  echo "🧊 TrueNAS SSH login bilgisi"
  echo "Bu şifre, manuel TrueNAS kurulumundan sonra WebUI'den SSH'i açınca post-install helper tarafından kullanılacak."
  echo "Kullanıcı sabit: truenas_admin"
  ask_visible_confirm TRUENAS_SSH_PASS "TrueNAS truenas_admin şifresi"
  {
    write_env_header
    write_env_line TRUENAS_VMID "101"
    write_env_line TRUENAS_SSH_USER "truenas_admin"
    write_env_line TRUENAS_SSH_PASS "$TRUENAS_SSH_PASS"
    write_env_line TRUENAS_HOST "192.168.50.101"
    write_env_line TRUENAS_FINAL_IP "192.168.50.101"
    write_env_line TRUENAS_GATEWAY "192.168.50.1"
    write_env_line TRUENAS_DNS1 "192.168.50.1"
    write_env_line TRUENAS_DNS2 "192.168.50.1"
    write_env_line TRUENAS_DNS3 "1.1.1.1"
    write_env_line TRUENAS_FIXED_MAC "02:23:14:00:01:01"
  } > "$SECRETS_DIR/truenas-login.env"
  chmod 600 "$SECRETS_DIR/truenas-login.env"
else
  echo "✅ TrueNAS SSH login env mevcut: $SECRETS_DIR/truenas-login.env"
fi

if [[ ! -f "$SECRETS_DIR/smtp.env" ]]; then
  echo
  echo "📧 SMTP app password bilgileri. Boş bırakırsan ilgili servis sonra atlanır."
  ask_visible_once ZOHO_NEXTCLOUD_APP_PASS "Zoho Nextcloud app password"
  ask_visible_once ZOHO_IMMICH_APP_PASS "Zoho Immich app password"
  ask_visible_once ZOHO_SEERR_APP_PASS "Zoho Seerr app password"
  ask_visible_once ZOHO_UPTIME_KUMA_APP_PASS "Zoho Uptime Kuma app password"
  ask_visible_once ZOHO_TRUENAS_APP_PASS "Zoho TrueNAS app password"
  {
    write_env_header
    write_env_line SMTP_FROM "admin@bacmastercloud.com"
    write_env_line SMTP_HOST "smtppro.zoho.eu"
    write_env_line SMTP_PORT "465"
    write_env_line SMTP_SECURITY "SSL/TLS"
    write_env_line SMTP_SECURE "ssl"
    write_env_line SMTP_TEST_TO "admin@bacmastercloud.com"
    write_env_line ZOHO_NEXTCLOUD_APP_PASS "$ZOHO_NEXTCLOUD_APP_PASS"
    write_env_line ZOHO_IMMICH_APP_PASS "$ZOHO_IMMICH_APP_PASS"
    write_env_line ZOHO_SEERR_APP_PASS "$ZOHO_SEERR_APP_PASS"
    write_env_line ZOHO_JELLYSEERR_APP_PASS "$ZOHO_SEERR_APP_PASS"
    write_env_line ZOHO_UPTIME_KUMA_APP_PASS "$ZOHO_UPTIME_KUMA_APP_PASS"
    write_env_line ZOHO_TRUENAS_APP_PASS "$ZOHO_TRUENAS_APP_PASS"
  } > "$SECRETS_DIR/smtp.env"
  chmod 600 "$SECRETS_DIR/smtp.env"
fi

if [[ ! -f "$SECRETS_DIR/google.env" ]]; then
  ask_text_default GOOGLE_CLIENT_ID "Google Client ID" ""
  ask_visible_once GOOGLE_CLIENT_SECRET "Google Client Secret"
  {
    write_env_header
    write_env_line GOOGLE_CLIENT_ID "$GOOGLE_CLIENT_ID"
    write_env_line GOOGLE_CLIENT_SECRET "$GOOGLE_CLIENT_SECRET"
  } > "$SECRETS_DIR/google.env"
  chmod 600 "$SECRETS_DIR/google.env"
fi

# Bacscloud Social Login/Registration shares the same Google OAuth values by default.
# Keep a separate env file so the Nextcloud script can be rerun/rotated safely.
if [[ ! -f "$SECRETS_DIR/nextcloud-sociallogin.env" ]]; then
  if [[ -f "$SECRETS_DIR/google.env" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_DIR/google.env"
  fi
  {
    write_env_header
    write_env_line NEXTCLOUD_GOOGLE_CLIENT_ID "${GOOGLE_CLIENT_ID:-}"
    write_env_line NEXTCLOUD_GOOGLE_CLIENT_SECRET "${GOOGLE_CLIENT_SECRET:-}"
    write_env_line NEXTCLOUD_REGISTRATION_ENABLED "true"
    write_env_line NEXTCLOUD_REGISTRATION_APPROVAL_REQUIRED "true"
    write_env_line NEXTCLOUD_REGISTRATION_ALLOWED_DOMAINS "gmail.com,googlemail.com,bacmastercloud.com"
    write_env_line NEXTCLOUD_DEFAULT_USER_QUOTA "5 GB"
  } > "$SECRETS_DIR/nextcloud-sociallogin.env"
  chmod 600 "$SECRETS_DIR/nextcloud-sociallogin.env"
fi

if [[ ! -f "$SECRETS_DIR/cloudflare.env" ]]; then
  {
    write_env_header
    write_env_line CLOUDFLARE_AUTH_MODE "interactive-login"
    write_env_line CLOUDFLARE_NOTE "cloudflared tunnel login will be used during cloudflared install; no token is requested at bootstrap"
  } > "$SECRETS_DIR/cloudflare.env"
  chmod 600 "$SECRETS_DIR/cloudflare.env"
fi


if [[ ! -f "$SECRETS_DIR/chia-mnemonic.env" ]]; then
  echo
  echo "🌱 Chia mnemonic bilgisi"
  echo "Bu değer geçici tutulur; Chia kurulumu başarıyla bitince silinecek. Support bundle raw mnemonic dosyasını dahil etmez."
  ask_chia_mnemonic_hidden
  {
    write_env_header
    write_env_line CHIA_MNEMONIC "$CHIA_MNEMONIC"
  } > "$SECRETS_DIR/chia-mnemonic.env"
  chmod 600 "$SECRETS_DIR/chia-mnemonic.env"
else
  echo "✅ Chia mnemonic env mevcut: $SECRETS_DIR/chia-mnemonic.env"
fi

if [[ ! -f "$SECRETS_DIR/chia-bootstrap.env" ]]; then
  echo
  echo "🌱 Chia bootstrap tercihleri"
  ask_text_default CHIA_KEY_LABEL "Chia key label (boş bırakılabilir)" "bacmaster"
  echo "Chia mainnet DB bootstrap yöntemi:"
  echo "  1) Fresh sync / DB atla"
  echo "  2) Official latest torrent otomatik indir"
  echo "  3) Manual HTTP/HTTPS/torrent/magnet URL kullan"
  echo "  4) VM107 üzerinde mevcut dosya path'i kullan"
  read -r -p "Seçim [2]: " CHIA_DB_CHOICE
  CHIA_DB_CHOICE="${CHIA_DB_CHOICE:-2}"
  CHIA_DB_BOOTSTRAP_MODE="official_torrent"
  CHIA_DB_TORRENT_URL="https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
  CHIA_DB_DOWNLOAD_URL="$CHIA_DB_TORRENT_URL"
  CHIA_DB_MANUAL_PATH=""
  case "$CHIA_DB_CHOICE" in
    1) CHIA_DB_BOOTSTRAP_MODE="fresh"; CHIA_DB_DOWNLOAD_URL=""; CHIA_DB_TORRENT_URL="" ;;
    2) CHIA_DB_BOOTSTRAP_MODE="official_torrent" ;;
    3)
      CHIA_DB_BOOTSTRAP_MODE="url"
      ask_text_default CHIA_DB_DOWNLOAD_URL "Chia DB URL veya magnet" ""
      CHIA_DB_TORRENT_URL="$CHIA_DB_DOWNLOAD_URL"
      ;;
    4)
      CHIA_DB_BOOTSTRAP_MODE="manual"
      ask_text_default CHIA_DB_MANUAL_PATH "VM107 üzerindeki DB dosyası path'i" "/mnt/chia-db-cache/blockchain_v2_mainnet.sqlite"
      CHIA_DB_DOWNLOAD_URL=""
      CHIA_DB_TORRENT_URL=""
      ;;
    *) CHIA_DB_BOOTSTRAP_MODE="official_torrent" ;;
  esac
  {
    write_env_header
    write_env_line CHIA_KEY_LABEL "$CHIA_KEY_LABEL"
    write_env_line CHIA_DB_BOOTSTRAP_MODE "$CHIA_DB_BOOTSTRAP_MODE"
    write_env_line CHIA_DB_MODE "$CHIA_DB_BOOTSTRAP_MODE"
    write_env_line CHIA_DB_TORRENT_URL "$CHIA_DB_TORRENT_URL"
    write_env_line CHIA_DB_DOWNLOAD_URL "$CHIA_DB_DOWNLOAD_URL"
    write_env_line CHIA_DB_MANUAL_PATH "$CHIA_DB_MANUAL_PATH"
    write_env_line CHIA_DB_CACHE_NFS "192.168.50.101:/mnt/tank/chia-db"
    write_env_line CHIA_DB_CACHE_MOUNT "/mnt/chia-db-cache"
    write_env_line CHIA_DB_DOWNLOAD_DIR "/mnt/chia-db-cache"
    write_env_line EXPECTED_CHIA_PLOT_DISKS "5"
  } > "$SECRETS_DIR/chia-bootstrap.env"
  chmod 600 "$SECRETS_DIR/chia-bootstrap.env"
else
  echo "✅ Chia bootstrap env mevcut: $SECRETS_DIR/chia-bootstrap.env"
fi

if [[ ! -f "$SECRETS_DIR/ollama-models.env" ]]; then
  echo
  echo "🤖 Ollama model tercihleri"
  ask_yes_no_default OLLAMA_PULL_MODELS "Kurulum sırasında Ollama modelleri indirilsin mi?" "Y"
  OLLAMA_MODELS=""
  if [[ "$OLLAMA_PULL_MODELS" == "true" ]]; then
    ask_text_default OLLAMA_MODELS "İndirilecek Ollama modelleri (virgül veya boşluk ayrımlı)" "llama3.1:8b qwen2.5-coder:7b nomic-embed-text"
  fi
  {
    write_env_header
    write_env_line OLLAMA_PULL_MODELS "$OLLAMA_PULL_MODELS"
    write_env_line OLLAMA_MODELS "$OLLAMA_MODELS"
  } > "$SECRETS_DIR/ollama-models.env"
  chmod 600 "$SECRETS_DIR/ollama-models.env"
else
  echo "✅ Ollama model env mevcut: $SECRETS_DIR/ollama-models.env"
fi

if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  echo "🔑 Proxmox root SSH key oluşturuluyor..."
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
else
  echo "✅ SSH key mevcut."
fi

chmod 700 /root/.ssh
chmod 600 "$SECRETS_DIR"/*.env

echo
echo "✅ Secrets hazır."
ls -lah "$SECRETS_DIR"
