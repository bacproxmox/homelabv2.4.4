#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "full-health-check"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"
echo "🩺 Homelab v2.4.4 health check"
echo
for vm in 101 102 103 104 105 106 107 110; do
  ip="$(vm_ip "$vm")"
  printf "VM%s %-15s " "$vm" "$ip"
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then echo "✅ ping"; else echo "❌ ping yok"; fi
done
check_http(){ local name="$1" url="$2"; if curl -kfsS --max-time 4 "$url" >/dev/null 2>&1; then echo "✅ $name $url"; else echo "⚠️ $name cevap yok: $url"; fi; }
check_http qBittorrent http://192.168.50.102:8080
check_http Sonarr http://192.168.50.102:8989
check_http Radarr http://192.168.50.102:7878
check_http Prowlarr http://192.168.50.102:9696
check_http Bazarr http://192.168.50.102:6767
check_http Seerr http://192.168.50.102:5055
check_http UptimeKuma http://192.168.50.103:3001
check_http Nextcloud http://192.168.50.104:8080/status.php
check_http Jellyfin http://192.168.50.106:8096
check_http Immich http://192.168.50.106:2283
check_http OpenWebUI http://192.168.50.106:3000
check_http HomeAssistant http://192.168.50.105:8123
check_http Lidarr http://192.168.50.106:8686
check_http PBS https://192.168.50.110:8007

for vm in 102 103 104 105 106 107; do
  echo; echo "🐳 VM$vm containers"
  rssh "$vm" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true" || true
done

echo; echo "☁️ Nextcloud tank data mount"
rssh 104 'docker exec hb-nextcloud test -f /var/www/html/version.php && echo version.php OK || true; docker exec hb-nextcloud df -h /var/www/html/data 2>/dev/null || true' || true

echo; echo "🎬 VM106 /dev/dri/i915"
rssh 106 'ls -lah /dev/dri 2>/dev/null || true; lspci -nnk | grep -A3 -Ei "UHD Graphics|i915" || true' || true

echo; echo "🌱 VM107 Chia health"
rssh 107 'nvidia-smi >/dev/null 2>&1 && echo "nvidia-smi OK" || echo "nvidia-smi missing"; expected=${EXPECTED_CHIA_PLOT_DISKS:-5}; mounted=$(findmnt -rn -o TARGET | grep -E "^/mnt/chia-plots/disk[0-9]+$" | sort -V | wc -l); echo "mounted plot disks=${mounted} / expected=${expected}"; if [ "$mounted" -lt "$expected" ]; then echo "⚠️ ${expected} plot disk bekleniyor; eksik disk/passthrough/cable/power kontrol et."; fi; df -h | grep /mnt/chia-plots || true; grep -R "parallel_decompressor_count" ~/.chia/mainnet/config/config.yaml 2>/dev/null || true; ss -ltnp | grep 55400 || true' || true
