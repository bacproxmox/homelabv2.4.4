#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "cloudflared-prepare-credentials"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/env-write.sh"
require_root

DOMAIN="${DOMAIN:-bacmastercloud.com}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-homelab-v244}"
CF_DIR="$SECRETS_DIR/cloudflared"
mkdir -p "$CF_DIR" /root/.cloudflared
chmod 700 "$CF_DIR" /root/.cloudflared

is_uuid(){ [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

install_cloudflared(){
  apt-get update -y >/dev/null
  apt-get install -y curl jq ca-certificates >/dev/null
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "📥 Proxmox üzerine geçici cloudflared binary kuruluyor..."
    curl -fsSL -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb >/dev/null
  fi
}

safe_tunnel_list_json(){
  local raw
  raw="$(cloudflared tunnel list --output json 2>/dev/null || true)"
  if [[ -z "$raw" || "$raw" == "null" ]]; then echo '[]'; return; fi
  if echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then echo "$raw"; else echo '[]'; fi
}

get_tunnel_id_by_name(){ safe_tunnel_list_json | jq -r --arg name "$1" '.[]? | select(.name==$name) | .id' | head -n1; }

ensure_cert(){
  if [[ -f "$CF_DIR/cert.pem" && ! -f /root/.cloudflared/cert.pem ]]; then
    cp "$CF_DIR/cert.pem" /root/.cloudflared/cert.pem
    chmod 600 /root/.cloudflared/cert.pem
  fi
  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    cat <<LOGIN

🔑 Cloudflare Tunnel auth gerekiyor.
Açılan URL'yi Windows tarayıcıda açıp ${DOMAIN} domainini authorize et.
Başarılı olunca Proxmox'ta /root/.cloudflared/cert.pem oluşacak.
LOGIN
    cloudflared tunnel login
  fi
  [[ -f /root/.cloudflared/cert.pem ]] || { echo "❌ cert.pem oluşmadı."; exit 1; }
  cp /root/.cloudflared/cert.pem "$CF_DIR/cert.pem"
  chmod 600 "$CF_DIR/cert.pem" /root/.cloudflared/cert.pem
}


route_dns_records(){
  echo "🌐 DNS route kayıtları Proxmox üzerinden oluşturuluyor/güncelleniyor..."
  local f name service host
  for f in "$ROOT_DIR/services/cloudflared/routes.env" "$ROOT_DIR/services/cloudflared/api-routes.env"; do
    [[ -f "$f" ]] || continue
    while IFS='|' read -r name service host; do
      [[ -z "${name:-}" || "${name:-}" =~ ^# || -z "${host:-}" || "${host:-}" =~ ^# ]] && continue
      echo "➡️ $host"
      cloudflared tunnel route dns "$TUNNEL_ID" "$host" || true
    done < "$f"
  done
}

create_or_reuse_tunnel(){
  local id json name out
  name="$TUNNEL_NAME"
  id="$(get_tunnel_id_by_name "$name" || true)"
  if is_uuid "$id" && [[ -f "$CF_DIR/${id}.json" ]]; then
    echo "✅ Hazır tunnel credential mevcut: $name / $id"
    TUNNEL_ID="$id"; TUNNEL_NAME="$name"; return 0
  fi
  if is_uuid "$id" && [[ -f "/root/.cloudflared/${id}.json" ]]; then
    cp "/root/.cloudflared/${id}.json" "$CF_DIR/${id}.json"; chmod 600 "$CF_DIR/${id}.json"
    echo "✅ Local credential bulundu ve saklandı: $name / $id"
    TUNNEL_ID="$id"; TUNNEL_NAME="$name"; return 0
  fi
  if is_uuid "$id"; then
    echo "⚠️ Remote tunnel var ama local JSON yok: $name / $id"
    name="${TUNNEL_NAME}-$(date +%Y%m%d%H%M%S)"
    echo "ℹ️ Yeni versioned tunnel oluşturulacak: $name"
  fi
  out="$(cloudflared tunnel create "$name" 2>&1 || true)"
  echo "$out"
  id="$(echo "$out" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n1 || true)"
  if ! is_uuid "$id"; then id="$(get_tunnel_id_by_name "$name" || true)"; fi
  if ! is_uuid "$id"; then
    json="$(find /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}')"
    [[ -n "$json" ]] && id="$(basename "$json" .json)"
  fi
  is_uuid "$id" || { echo "❌ Tunnel ID bulunamadı."; exit 1; }
  [[ -f "/root/.cloudflared/${id}.json" ]] || { echo "❌ Credential JSON yok: /root/.cloudflared/${id}.json"; exit 1; }
  cp "/root/.cloudflared/${id}.json" "$CF_DIR/${id}.json"
  chmod 600 "$CF_DIR/${id}.json"
  TUNNEL_ID="$id"; TUNNEL_NAME="$name"
}

install_cloudflared
ensure_cert
create_or_reuse_tunnel
route_dns_records
{
  write_env_header
  write_env_line CLOUDFLARE_TUNNEL_NAME "$TUNNEL_NAME"
  write_env_line CLOUDFLARE_TUNNEL_ID "$TUNNEL_ID"
  write_env_line CLOUDFLARE_CERT_FILE "$CF_DIR/cert.pem"
  write_env_line CLOUDFLARE_CREDENTIALS_FILE "$CF_DIR/${TUNNEL_ID}.json"
} > "$CF_DIR/cloudflared.env"
chmod 600 "$CF_DIR/cloudflared.env"

cat <<DONE
✅ Cloudflare Tunnel credentials hazırlandı.
  Tunnel : $TUNNEL_NAME
  ID     : $TUNNEL_ID
  Secret : $CF_DIR/${TUNNEL_ID}.json

Not: cert.pem Proxmox secrets altında kalır; VM103'e sadece tunnel JSON kopyalanacak.
DONE

echo "🧹 Proxmox üzerindeki geçici cloudflared binary otomatik kaldırılıyor; secret dosyaları korunacak."
systemctl disable --now cloudflared >/dev/null 2>&1 || true
apt-get purge -y cloudflared >/dev/null 2>&1 || rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared || true
echo "✅ Proxmox cloudflared binary kaldırıldı. /root/homelab-secrets/cloudflared korundu."
