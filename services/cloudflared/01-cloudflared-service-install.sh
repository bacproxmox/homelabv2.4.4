#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "cloudflared-service-install"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"

VM=103
DOMAIN="${DOMAIN:-bacmastercloud.com}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-homelab-v244}"
WORK="/tmp/hv2313-cloudflared"
rm -rf "$WORK"; mkdir -p "$WORK"

cp "$ROOT_DIR/services/cloudflared/routes.env" "$WORK/routes.env"
cp "$ROOT_DIR/services/cloudflared/api-routes.env" "$WORK/api-routes.env"
# Optional v2.4.4 early-prepared credentials from Proxmox bootstrap phase.
if [[ -f "$SECRETS_DIR/cloudflared/cloudflared.env" ]]; then
  cp "$SECRETS_DIR/cloudflared/cloudflared.env" "$WORK/prepared-cloudflared.env"
  # shellcheck disable=SC1090
  source "$SECRETS_DIR/cloudflared/cloudflared.env"
  if [[ -n "${CLOUDFLARE_CREDENTIALS_FILE:-}" && -f "$CLOUDFLARE_CREDENTIALS_FILE" ]]; then
    cp "$CLOUDFLARE_CREDENTIALS_FILE" "$WORK/prepared-credentials.json"
    chmod 600 "$WORK/prepared-credentials.json"
  fi
fi

cat > "$WORK/install-cloudflared-native.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
set +H

DOMAIN="${DOMAIN:-bacmastercloud.com}"
TUNNEL_NAME="${TUNNEL_NAME:-homelab-v239}"
ROUTES_FILE="/tmp/hv2313-cloudflared/routes.env"
API_ROUTES_FILE="/tmp/hv2313-cloudflared/api-routes.env"

export DEBIAN_FRONTEND=noninteractive

say() { echo -e "$*"; }
die() { say "❌ $*"; exit 1; }

is_uuid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

install_packages() {
  say "📦 Paketler kontrol ediliyor..."
  apt update >/dev/null
  apt install -y curl jq python3 ca-certificates >/dev/null

  if ! command -v cloudflared >/dev/null 2>&1; then
    say "📥 cloudflared kuruluyor..."
    curl -fsSL -o /tmp/cloudflared.deb \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
  fi
}

ensure_dirs() {
  mkdir -p /root/.cloudflared /etc/cloudflared
  chmod 700 /root/.cloudflared /etc/cloudflared || true
}

use_prepared_credentials_if_present() {
  local env_file="/tmp/hv2313-cloudflared/prepared-cloudflared.env"
  local cred_src="/tmp/hv2313-cloudflared/prepared-credentials.json"
  [[ -f "$env_file" && -f "$cred_src" ]] || return 1
  # shellcheck disable=SC1090
  source "$env_file"
  if is_uuid "${CLOUDFLARE_TUNNEL_ID:-}"; then
    TUNNEL_ID="$CLOUDFLARE_TUNNEL_ID"
    TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-$TUNNEL_NAME}"
    cp "$cred_src" "/etc/cloudflared/${TUNNEL_ID}.json"
    chmod 600 "/etc/cloudflared/${TUNNEL_ID}.json"
    say "✅ Proxmox'ta erken hazırlanmış Cloudflare tunnel credential kullanılıyor: $TUNNEL_NAME / $TUNNEL_ID"
    return 0
  fi
  return 1
}

ensure_login_cert() {
  ensure_dirs

  local root_cert="/root/.cloudflared/cert.pem"
  local home_cert="${HOME}/.cloudflared/cert.pem"
  local etc_cert="/etc/cloudflared/cert.pem"

  if [[ ! -f "$root_cert" && -f "$home_cert" ]]; then
    cp "$home_cert" "$root_cert"
  fi

  if [[ ! -f "$root_cert" && -f "$etc_cert" ]]; then
    cp "$etc_cert" "$root_cert"
  fi

  if [[ ! -f "$root_cert" ]]; then
    cat <<LOGIN

🔑 Cloudflare login gerekiyor.
Açılan URL'yi Windows tarayıcıda açıp ${DOMAIN} domainini authorize et.
Token istenmez; browser login + cert.pem yöntemi kullanılır.

LOGIN
    cloudflared tunnel login
  fi

  if [[ ! -f "$root_cert" ]]; then
    die "Cloudflare cert.pem bulunamadı: $root_cert. Tekrar dene: cloudflared tunnel login"
  fi

  cp "$root_cert" "$etc_cert" || true
  chmod 600 "$root_cert" "$etc_cert" 2>/dev/null || true
}

safe_tunnel_list_json() {
  # cloudflared bazı durumlarda boş/null dönebiliyor. jq '.[]' patlamasın diye daima array döndür.
  local raw=""
  raw="$(cloudflared tunnel list --output json 2>/dev/null || true)"

  if [[ -z "$raw" || "$raw" == "null" ]]; then
    echo '[]'
    return 0
  fi

  if echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$raw"
  else
    echo '[]'
  fi
}

get_tunnel_id_by_name() {
  local name="$1"
  safe_tunnel_list_json | jq -r --arg name "$name" '.[]? | select(.name==$name) | .id' | head -n1
}

cred_path_for_id() {
  local id="$1"
  local p
  for p in \
    "/etc/cloudflared/${id}.json" \
    "/root/.cloudflared/${id}.json" \
    "${HOME}/.cloudflared/${id}.json"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

copy_credentials_for_id() {
  local id="$1"
  local src=""
  local dst="/etc/cloudflared/${id}.json"

  src="$(cred_path_for_id "$id" || true)"
  [[ -n "$src" ]] || return 1

  cp "$src" "$dst"
  chmod 600 "$dst"
  [[ -f "$dst" ]]
}

newest_root_credentials_json() {
  find /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR==1 {print $2}'
}

create_tunnel_and_get_id() {
  local name="$1"
  local before after id out

  say "🕳️ Tunnel oluşturuluyor: $name"
  before="$(find /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
  out="$(cloudflared tunnel create "$name" 2>&1 || true)"
  echo "$out"

  id="$(echo "$out" | grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n1 || true)"

  if ! is_uuid "$id"; then
    id="$(get_tunnel_id_by_name "$name" || true)"
  fi

  if ! is_uuid "$id"; then
    after="$(find /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
    # Prefer newly-created file when possible.
    local f
    for f in $(find /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null | sort); do
      if ! grep -qw "$f" <<< "$before"; then
        id="${f%.json}"
        break
      fi
    done
  fi

  if ! is_uuid "$id"; then
    local newest
    newest="$(newest_root_credentials_json || true)"
    [[ -n "$newest" ]] && id="$(basename "$newest" .json)"
  fi

  is_uuid "$id" || return 1
  echo "$id"
}

choose_existing_local_credential() {
  # Last resort: use an already copied/local credential JSON if it is the only thing we can trust.
  local p id
  p="$(find /etc/cloudflared /root/.cloudflared -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR==1 {print $2}')"
  [[ -n "$p" ]] || return 1
  id="$(basename "$p" .json)"
  is_uuid "$id" || return 1
  echo "$id"
}

ensure_tunnel_with_credentials() {
  say
  say "🕳️ Tunnel kontrol/oluşturma..."

  ensure_dirs

  local existing_id=""
  existing_id="$(get_tunnel_id_by_name "$TUNNEL_NAME" || true)"

  if is_uuid "$existing_id"; then
    say "✅ Remote tunnel bulundu: $TUNNEL_NAME / $existing_id"
    if copy_credentials_for_id "$existing_id"; then
      TUNNEL_ID="$existing_id"
      return 0
    fi

    say "⚠️ Remote tunnel var ama local credentials JSON yok: $existing_id"
    say "   Fresh install/rollback sonrası normal olabilir. Yeni tunnel oluşturulacak."
    TUNNEL_NAME="${TUNNEL_NAME}-$(date +%Y%m%d%H%M%S)"
    TUNNEL_ID="$(create_tunnel_and_get_id "$TUNNEL_NAME")" || die "Yeni tunnel ID alınamadı."
    copy_credentials_for_id "$TUNNEL_ID" || die "Yeni tunnel credentials JSON bulunamadı: $TUNNEL_ID"
    return 0
  fi

  # No remote tunnel by list, or list output was null. Create tunnel, then infer ID from create output / new JSON.
  TUNNEL_ID="$(create_tunnel_and_get_id "$TUNNEL_NAME" || true)"

  if ! is_uuid "${TUNNEL_ID:-}"; then
    # If cloudflared created a JSON but list output was null, use local credential.
    TUNNEL_ID="$(choose_existing_local_credential || true)"
  fi

  is_uuid "${TUNNEL_ID:-}" || die "Tunnel ID bulunamadı. /root/.cloudflared ve /etc/cloudflared kontrol et."
  copy_credentials_for_id "$TUNNEL_ID" || die "Credentials JSON bulunamadı/kopyalanamadı: $TUNNEL_ID"

  say "✅ Tunnel credentials hazır: /etc/cloudflared/${TUNNEL_ID}.json"
}

write_config() {
  local CONFIG="/etc/cloudflared/config.yml"
  [[ -f "$CONFIG" ]] && cp "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)" || true

  write_ingress_entry() {
    local name="$1" service="$2" host="$3"
    [[ -z "$host" || "$host" =~ ^# ]] && return 0
    cat >> "$CONFIG" <<YAML
  - hostname: ${host}
    service: ${service}
YAML
    if [[ "$service" == https://192.168.50.100:8006* || "$service" == https://192.168.50.110:8007* ]]; then
      cat >> "$CONFIG" <<'YAML'
    originRequest:
      noTLSVerify: true
YAML
    fi
  }

  say
  say "📝 config.yml yazılıyor: $CONFIG"
  cat > "$CONFIG" <<YAML
# Generated by Homelab v2.4.4 cloudflared hotfix
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

protocol: quic
loglevel: info

ingress:
YAML

  while IFS='|' read -r name service host; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    write_ingress_entry "$name" "$service" "$host"
  done < "$ROUTES_FILE"

  while IFS='|' read -r name service host; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    write_ingress_entry "$name" "$service" "$host"
  done < "$API_ROUTES_FILE"

  cat >> "$CONFIG" <<'YAML'
  - service: http_status:404
YAML

  chmod 600 "/etc/cloudflared/${TUNNEL_ID}.json"

  say
  say "🔎 Ingress validate..."
  cloudflared tunnel --config "$CONFIG" ingress validate
}

route_dns_records() {
  say
  say "🌐 DNS route kayıtları oluşturuluyor/güncelleniyor..."
  route_dns() {
    local host="$1"
    [[ -z "$host" || "$host" =~ ^# ]] && return 0
    say "➡️ $host"
    # ID ile route etmek, tunnel adı değişse bile daha güvenli.
    cloudflared tunnel route dns "$TUNNEL_ID" "$host" || true
  }

  while IFS='|' read -r name service host; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    route_dns "$host"
  done < "$ROUTES_FILE"

  while IFS='|' read -r name service host; do
    [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
    route_dns "$host"
  done < "$API_ROUTES_FILE"
}

install_service() {
  say
  say "🔧 cloudflared servisi kuruluyor/güncelleniyor..."

  cloudflared service install >/dev/null 2>&1 || true
  systemctl daemon-reload || true
  systemctl enable --now cloudflared || true
  systemctl restart cloudflared || true

  sleep 4

  say
  say "📋 cloudflared status:"
  systemctl --no-pager --full status cloudflared | sed -n '1,26p' || true
}

final_validate() {
  say
  say "🧪 Final doğrulama..."
  test -f "/etc/cloudflared/${TUNNEL_ID}.json" || die "Credentials yok: /etc/cloudflared/${TUNNEL_ID}.json"
  test -f /etc/cloudflared/config.yml || die "Config yok: /etc/cloudflared/config.yml"
  cloudflared tunnel info "$TUNNEL_ID" >/dev/null 2>&1 || say "⚠️ cloudflared tunnel info doğrulaması başarısız; DNS/service yine de denenmiş olabilir."
}

echo
echo "🌩️ Homelab v2.4.4 hotfix - Cloudflared resilient credentials"
echo "Tunnel : $TUNNEL_NAME"
echo "Domain : $DOMAIN"
echo

install_packages
ensure_dirs
if ! use_prepared_credentials_if_present; then
  ensure_login_cert
  ensure_tunnel_with_credentials
fi
write_config
route_dns_records
install_service
final_validate

echo
echo "✅ Cloudflared tamamlandı."
echo "Config: /etc/cloudflared/config.yml"
echo "Tunnel: $TUNNEL_NAME / $TUNNEL_ID"
REMOTE

chmod +x "$WORK/install-cloudflared-native.sh"
rscp "$WORK" "$VM" "/tmp/"
rssh "$VM" "sudo DOMAIN='$DOMAIN' TUNNEL_NAME='$TUNNEL_NAME' bash /tmp/hv2313-cloudflared/install-cloudflared-native.sh"
