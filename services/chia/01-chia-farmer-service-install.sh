#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/utils/env-loader.sh"
source "$REPO_ROOT/utils/logging.sh"
source "$REPO_ROOT/utils/remote.sh"
source "$REPO_ROOT/utils/state.sh"
source "$REPO_ROOT/utils/env-write.sh"
start_log "chia-farmer-install"
load_all_env

CHIA_MNEMONIC_ENV="$SECRETS_DIR/chia-mnemonic.env"
CHIA_BOOTSTRAP_ENV="$SECRETS_DIR/chia-bootstrap.env"
ask_mnemonic_hidden(){
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

if [[ ! -f "$CHIA_MNEMONIC_ENV" ]]; then
  echo "⚠️ $CHIA_MNEMONIC_ENV yok. Güvenli fallback olarak burada sorulacak ve başarıdan sonra silinecek."
  ask_mnemonic_hidden
  { write_env_header; write_env_line CHIA_MNEMONIC "$CHIA_MNEMONIC"; } > "$CHIA_MNEMONIC_ENV"
  chmod 600 "$CHIA_MNEMONIC_ENV"
fi

if [[ ! -f "$CHIA_BOOTSTRAP_ENV" ]]; then
  echo "⚠️ $CHIA_BOOTSTRAP_ENV yok. Official latest torrent + TrueNAS cache varsayılanı yazılıyor."
  {
    write_env_header
    write_env_line CHIA_KEY_LABEL "bacmaster"
    write_env_line CHIA_DB_BOOTSTRAP_MODE "official_torrent"
    write_env_line CHIA_DB_MODE "official_torrent"
    write_env_line CHIA_DB_TORRENT_URL "https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
    write_env_line CHIA_DB_DOWNLOAD_URL "https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
    write_env_line CHIA_DB_MANUAL_PATH ""
    write_env_line CHIA_DB_CACHE_NFS "192.168.50.101:/mnt/tank/chia-db"
    write_env_line CHIA_DB_CACHE_MOUNT "/mnt/chia-db-cache"
    write_env_line CHIA_DB_DOWNLOAD_DIR "/mnt/chia-db-cache"
    write_env_line EXPECTED_CHIA_PLOT_DISKS "5"
  } > "$CHIA_BOOTSTRAP_ENV"
  chmod 600 "$CHIA_BOOTSTRAP_ENV"
fi

# shellcheck disable=SC1090
source "$CHIA_MNEMONIC_ENV"
# shellcheck disable=SC1090
source "$CHIA_BOOTSTRAP_ENV"
CHIA_DB_MODE="${CHIA_DB_BOOTSTRAP_MODE:-${CHIA_DB_MODE:-fresh}}"
CHIA_DB_DOWNLOAD_URL="${CHIA_DB_DOWNLOAD_URL:-${CHIA_DB_TORRENT_URL:-}}"
CHIA_DB_MANUAL_PATH="${CHIA_DB_MANUAL_PATH:-}"
CHIA_DB_CACHE_NFS="${CHIA_DB_CACHE_NFS:-192.168.50.101:/mnt/tank/chia-db}"
CHIA_DB_CACHE_MOUNT="${CHIA_DB_CACHE_MOUNT:-/mnt/chia-db-cache}"
CHIA_DB_DOWNLOAD_DIR="${CHIA_DB_DOWNLOAD_DIR:-$CHIA_DB_CACHE_MOUNT}"
CHIA_KEY_LABEL="${CHIA_KEY_LABEL:-}"

wait_ssh 107
TMP_REMOTE="/tmp/homelab-chia-install.sh"
MNEMONIC_REMOTE="/tmp/chia-mnemonic.txt"

printf '%s\n' "$CHIA_MNEMONIC" > /tmp/chia-mnemonic.txt
chmod 600 /tmp/chia-mnemonic.txt
scp "${SSH_OPTS[@]}" /tmp/chia-mnemonic.txt "$SSH_USER@192.168.50.107:$MNEMONIC_REMOTE" >/dev/null
shred -u /tmp/chia-mnemonic.txt || rm -f /tmp/chia-mnemonic.txt

cat > /tmp/homelab-chia-install.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
CHIA_HOME="/home/bacmaster/.chia/mainnet"
CHIA_SRC="/opt/chia-blockchain"
MNEMONIC_FILE="/tmp/chia-mnemonic.txt"
DB_MODE="${CHIA_DB_MODE:-fresh}"
DB_URL="${CHIA_DB_DOWNLOAD_URL:-}"
DB_MANUAL_PATH="${CHIA_DB_MANUAL_PATH:-}"
CACHE_NFS="${CHIA_DB_CACHE_NFS:-192.168.50.101:/mnt/tank/chia-db}"
CACHE_MOUNT="${CHIA_DB_CACHE_MOUNT:-/mnt/chia-db-cache}"
DOWNLOAD_DIR="${CHIA_DB_DOWNLOAD_DIR:-$CACHE_MOUNT}"
CHIA_KEY_LABEL="${CHIA_KEY_LABEL:-}"
DB_TARGET="$CHIA_HOME/db/blockchain_v2_mainnet.sqlite"
CHIA_BIN="/opt/chia-blockchain/venv/bin/chia"
KEY_IMPORT_OK=0

sudo apt update
sudo apt install -y git curl ca-certificates build-essential python3 python3-venv python3-pip python3-dev lsb-release jq tmux unzip rsync aria2 gzip tar pv file nfs-common sqlite3

mount_cache(){
  mkdir -p "$CACHE_MOUNT"
  if ! grep -qs " $CACHE_MOUNT " /etc/fstab; then
    echo "$CACHE_NFS $CACHE_MOUNT nfs defaults,_netdev,x-systemd.automount,nofail 0 0" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$CACHE_MOUNT" 2>/dev/null || true
  mountpoint -q "$CACHE_MOUNT"
}

if mount_cache; then
  echo "✅ Chia DB cache mount hazır: $CACHE_MOUNT -> $CACHE_NFS"
  DOWNLOAD_DIR="$CACHE_MOUNT"
else
  echo "⚠️ Chia DB cache mount yok: $CACHE_MOUNT"
  echo "   Büyük torrent/download local diske yapılmayacak; hazır cache yoksa fresh sync'e düşülecek."
fi

if [[ ! -d "$CHIA_SRC/.git" ]]; then
  sudo git clone https://github.com/Chia-Network/chia-blockchain.git -b latest --recurse-submodules "$CHIA_SRC"
else
  cd "$CHIA_SRC"
  sudo git fetch --all --tags
  sudo git checkout latest || true
  sudo git pull --recurse-submodules || true
  sudo git submodule update --init --recursive
fi

sudo chown -R bacmaster:bacmaster "$CHIA_SRC"
cd "$CHIA_SRC"
sudo -u bacmaster bash -lc 'sh install.sh'
sudo -u bacmaster bash -lc 'cd /opt/chia-blockchain && . ./activate && chia init'
[[ -x "$CHIA_BIN" ]] || { echo "❌ Chia binary bulunamadı: $CHIA_BIN"; exit 1; }

if [[ -s "$MNEMONIC_FILE" ]]; then
  echo "🔐 Chia mnemonic import ediliyor (içerik loga basılmaz)..."
  if sudo -u bacmaster bash -lc "cd /opt/chia-blockchain && . ./activate && printf '%s\n' \"${CHIA_KEY_LABEL:-}\" | chia keys add -f '$MNEMONIC_FILE'"; then
    KEY_IMPORT_OK=1
    shred -u "$MNEMONIC_FILE" || sudo rm -f "$MNEMONIC_FILE"
  else
    echo "❌ Chia key import başarısız; mnemonic dosyası güvenli inceleme için VM107 /tmp altında bırakılmadı."
    shred -u "$MNEMONIC_FILE" || sudo rm -f "$MNEMONIC_FILE"
    exit 1
  fi
fi

find_db_candidate(){
  local root="$1"
  find "$root" -maxdepth 4 -type f \
    \( -name 'blockchain_v2_mainnet.sqlite' -o -name 'blockchain_v2_mainnet.sqlite.gz' -o -name '*.sqlite' -o -name '*.sqlite.gz' -o -name '*.zip' -o -name '*.tar.gz' -o -name '*.tgz' \) \
    -printf '%s %p\n' 2>/dev/null | sort -nr | awk '{$1=""; sub(/^ /,""); print; exit}'
}

validate_db(){
  local db="$1"
  [[ -s "$db" ]] || { echo "❌ DB boş/0 byte: $db"; return 1; }
  local bytes; bytes="$(stat -c '%s' "$db")"
  [[ "$bytes" -gt 1000000000 ]] || { echo "❌ DB boyutu şüpheli küçük: $bytes byte"; return 1; }
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$db" 'PRAGMA quick_check;' | grep -q ok || { echo "❌ sqlite quick_check başarısız"; return 1; }
  else
    file "$db" | grep -qi sqlite || { echo "❌ DB SQLite görünmüyor"; return 1; }
  fi
}

stream_tar_db(){
  local archive="$1" member=""
  member="$(tar -tzf "$archive" | grep -E '(^|/)blockchain_v2_mainnet\.sqlite(\.gz)?$|\.sqlite(\.gz)?$' | head -n1 || true)"
  [[ -n "$member" ]] || { echo "❌ tar.gz içinde sqlite DB bulunamadı"; return 1; }
  echo "🗜️ tar.gz içinden local DB path'e stream ediliyor: $member"
  if [[ "$member" == *.gz ]]; then
    tar -xOzf "$archive" "$member" | gzip -dc > "$DB_TARGET.tmp"
  else
    tar -xOzf "$archive" "$member" > "$DB_TARGET.tmp"
  fi
}

bootstrap_db(){
  sudo -u bacmaster mkdir -p "$CHIA_HOME/db"
  local src="$1"
  echo "📦 DB import kaynağı: $src"
  sudo systemctl stop chia-farmer.service >/dev/null 2>&1 || true
  sudo -u bacmaster "$CHIA_BIN" stop all -d >/dev/null 2>&1 || true
  rm -f "$DB_TARGET.tmp"
  case "$src" in
    *.tar.gz|*.tgz) stream_tar_db "$src" ;;
    *.sqlite.gz) gzip -dc "$src" > "$DB_TARGET.tmp" ;;
    *.zip)
      tmpd="/tmp/chia-db-unzip-$$"; rm -rf "$tmpd"; mkdir -p "$tmpd"
      unzip -o "$src" -d "$tmpd" >/dev/null
      found="$(find_db_candidate "$tmpd")"
      [[ -n "$found" ]] || { echo "❌ zip içinde DB bulunamadı"; return 1; }
      bootstrap_db "$found"; rm -rf "$tmpd"; return 0 ;;
    *.sqlite) cp "$src" "$DB_TARGET.tmp" ;;
    *) file "$src" | grep -qi SQLite && cp "$src" "$DB_TARGET.tmp" || { echo "❌ Desteklenmeyen DB dosyası: $src"; return 1; } ;;
  esac
  validate_db "$DB_TARGET.tmp"
  mv "$DB_TARGET.tmp" "$DB_TARGET"
  sudo chown -R bacmaster:bacmaster "$CHIA_HOME"
  echo "✅ Chia DB hazır: $DB_TARGET ($(du -h "$DB_TARGET" | awk '{print $1}'))"
}

show_download_hint(){
  cat <<HINT

📥 Chia DB download takip bilgisi
  VM107 cache : $DOWNLOAD_DIR
  Log         : $DOWNLOAD_DIR/aria2.log
  Canlı takip : tail -f $DOWNLOAD_DIR/aria2.log

HINT
}

# Prefer cache if it already contains a usable DB/archive.
if mountpoint -q "$CACHE_MOUNT"; then
  echo "🔍 Chia DB cache içinde hazır DB/arşiv aranıyor..."
  cached="$(find_db_candidate "$CACHE_MOUNT" || true)"
  if [[ -n "$cached" ]]; then
    bootstrap_db "$cached" || echo "⚠️ Cache bulundu ama import başarısız; seçilen bootstrap moduna geçilecek."
  fi
fi

case "$DB_MODE" in
  official_torrent)
    DB_URL="${DB_URL:-https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent}"
    ;&
  torrent)
    if [[ ! -f "$DB_TARGET" ]]; then
      if ! mountpoint -q "$CACHE_MOUNT"; then
        echo "⚠️ Cache mount yok; torrent local diske indirilmeyecek. Fresh sync ile devam."
      else
        [[ -n "$DB_URL" && "$DB_URL" != "1" ]] || DB_URL="https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
        mkdir -p "$DOWNLOAD_DIR"; chown -R bacmaster:bacmaster "$DOWNLOAD_DIR"
        echo "📦 Chia DB torrent/magnet ile TrueNAS cache'e indiriliyor..."
        show_download_hint
        sudo -u bacmaster aria2c -c --seed-time=0 --summary-interval=30 --download-result=full --console-log-level=notice --log="$DOWNLOAD_DIR/aria2.log" --log-level=notice --dir="$DOWNLOAD_DIR" "$DB_URL" || echo "⚠️ aria2c hata/interrupt döndürdü; mevcut dosyalar kontrol edilecek."
        found="$(find_db_candidate "$DOWNLOAD_DIR" || true)"
        [[ -n "$found" ]] && bootstrap_db "$found" || echo "⚠️ Torrent klasöründe DB dosyası bulunamadı; fresh sync ile devam."
      fi
    fi
    ;;
  url)
    if [[ ! -f "$DB_TARGET" ]]; then
      if ! mountpoint -q "$CACHE_MOUNT"; then
        echo "⚠️ Cache mount yok; URL download local diske yapılmayacak. Fresh sync ile devam."
      elif [[ -n "$DB_URL" ]]; then
        mkdir -p "$DOWNLOAD_DIR"; chown -R bacmaster:bacmaster "$DOWNLOAD_DIR"
        out="$DOWNLOAD_DIR/$(basename "${DB_URL%%\?*}")"
        sudo -u bacmaster curl -fL --progress-bar -C - "$DB_URL" -o "$out"
        bootstrap_db "$out" || echo "⚠️ DB import başarısız; fresh sync ile devam edilecek."
      fi
    fi
    ;;
  manual)
    if [[ ! -f "$DB_TARGET" && -n "$DB_MANUAL_PATH" && -f "$DB_MANUAL_PATH" ]]; then
      bootstrap_db "$DB_MANUAL_PATH" || echo "⚠️ Manuel DB import başarısız; fresh sync ile devam."
    fi
    ;;
  *) echo "ℹ️ Fresh sync seçildi; DB bootstrap atlandı." ;;
esac

sudo tee /etc/systemd/system/chia-farmer.service >/dev/null <<'UNIT'
[Unit]
Description=Chia Farmer
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=bacmaster
WorkingDirectory=/opt/chia-blockchain
Environment=CHIA_ROOT=/home/bacmaster/.chia/mainnet
ExecStart=/bin/bash -lc 'cd /opt/chia-blockchain && . ./activate && chia start farmer -r'
ExecStop=/bin/bash -lc 'cd /opt/chia-blockchain && . ./activate && chia stop all -d'
Restart=on-failure
RestartSec=20
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT

sudo ln -sf "$CHIA_BIN" /usr/local/bin/chia || true
sudo systemctl daemon-reload
sudo systemctl enable chia-farmer.service

CONFIG="/home/bacmaster/.chia/mainnet/config/config.yaml"
if [[ -f "$CONFIG" ]]; then
  sudo -u bacmaster python3 - <<'PY'
from pathlib import Path
p=Path('/home/bacmaster/.chia/mainnet/config/config.yaml')
text=p.read_text()
lines=text.splitlines(); out=[]; in_h=False; inserted=False
for line in lines:
    if line.startswith('harvester:'):
        in_h=True; out.append(line); continue
    if in_h and line and not line.startswith(' '):
        if not inserted: out.append('  parallel_decompressor_count: 1'); inserted=True
        in_h=False
    if line.strip().startswith('parallel_decompressor_count:'):
        indent=line[:len(line)-len(line.lstrip())]
        out.append(f'{indent}parallel_decompressor_count: 1'); inserted=True
    else:
        out.append(line)
if not inserted:
    if not any(l.startswith('harvester:') for l in out): out += ['harvester:', '  parallel_decompressor_count: 1']
    else:
        new=[]; done=False
        for l in out:
            new.append(l)
            if l.startswith('harvester:') and not done:
                new.append('  parallel_decompressor_count: 1'); done=True
        out=new
p.write_text('\n'.join(out)+'\n')
PY
fi

sudo systemctl restart chia-farmer.service || true
sleep 8
sudo -u bacmaster bash -lc 'cd /opt/chia-blockchain && . ./activate && chia show -s || true'
REMOTE

scp "${SSH_OPTS[@]}" /tmp/homelab-chia-install.sh "$SSH_USER@192.168.50.107:$TMP_REMOTE" >/dev/null
{
  printf 'CHIA_DB_MODE=%q\n' "${CHIA_DB_MODE:-fresh}"
  printf 'CHIA_DB_DOWNLOAD_URL=%q\n' "${CHIA_DB_DOWNLOAD_URL:-}"
  printf 'CHIA_DB_MANUAL_PATH=%q\n' "${CHIA_DB_MANUAL_PATH:-}"
  printf 'CHIA_DB_CACHE_NFS=%q\n' "${CHIA_DB_CACHE_NFS:-192.168.50.101:/mnt/tank/chia-db}"
  printf 'CHIA_DB_CACHE_MOUNT=%q\n' "${CHIA_DB_CACHE_MOUNT:-/mnt/chia-db-cache}"
  printf 'CHIA_DB_DOWNLOAD_DIR=%q\n' "${CHIA_DB_DOWNLOAD_DIR:-/mnt/chia-db-cache}"
  printf 'CHIA_KEY_LABEL=%q\n' "${CHIA_KEY_LABEL:-}"
} > /tmp/chia-remote.env
scp "${SSH_OPTS[@]}" /tmp/chia-remote.env "$SSH_USER@192.168.50.107:/tmp/chia-remote.env" >/dev/null
rm -f /tmp/chia-remote.env
ssh "${SSH_OPTS[@]}" "$SSH_USER@192.168.50.107" "chmod +x $TMP_REMOTE && sudo bash -c 'set -a; source /tmp/chia-remote.env; set +a; $TMP_REMOTE; rm -f /tmp/chia-remote.env'"
rm -f /tmp/homelab-chia-install.sh

if [[ -f "$CHIA_MNEMONIC_ENV" ]]; then
  echo "🧹 Chia mnemonic secret dosyası siliniyor: $CHIA_MNEMONIC_ENV"
  shred -u "$CHIA_MNEMONIC_ENV" || rm -f "$CHIA_MNEMONIC_ENV"
fi

echo "🔧 Chia plot disk / compressed plot repair uygulanıyor..."
bash "$REPO_ROOT/maintenance/repair/repair-chia-plot-disks.sh" || echo "⚠️ Chia plot disk repair tamamlanamadı; maintenance menüsünden tekrar çalıştırabilirsin."

state_set chia_farmer_installed true
state_set chia_farmer_installed_at "$(date -Is)"
echo "✅ Chia farmer kurulumu tamamlandı."
