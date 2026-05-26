#!/usr/bin/env bash
set -Eeuo pipefail
OUT="/root/homelab-support-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
chmod 700 "$OUT"

redact_file(){
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  python3 - "$src" "$dst" <<'PYREDACT' || true
from pathlib import Path
import re, sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
text=src.read_text(errors='ignore')
patterns=[
    r'(?im)^([^#\n]*(?:PASS|PASSWORD|SECRET|TOKEN|API_KEY|CLIENT_SECRET|CLIENTSECRET|APP_PASS|KEY|MNEMONIC)[A-Za-z0-9_]*\s*=\s*).+$',
    r'(?i)("(?:password|token|secret|api[_-]?key|client[_-]?secret|clientSecret|app[_-]?pass|mnemonic)"\s*:\s*")[^"]+("?)',
    r'GOCSPX-[A-Za-z0-9_-]+',
    r'(?i)(clientSecret["\':= ]+)[A-Za-z0-9_./+-]+',
    r'(?i)(client_secret["\':= ]+)[A-Za-z0-9_./+-]+',
]
text=re.sub(patterns[0], r'\1<REDACTED>', text)
text=re.sub(patterns[1], r'\1<REDACTED>\2', text)
text=re.sub(patterns[2], 'GOCSPX-<REDACTED>', text)
text=re.sub(patterns[3], r'\1<REDACTED>', text)
text=re.sub(patterns[4], r'\1<REDACTED>', text)
dst.write_text(text)
PYREDACT
}

echo "📦 Redacted support bundle hazırlanıyor: $OUT"
{
  echo "date=$(date -Is)"
  uname -a
  ip a
  ip r
  df -h
  lsblk -f
  command -v qm >/dev/null && qm list || true
  command -v pvesm >/dev/null && pvesm status || true
} > "$OUT/system.txt" 2>&1

journalctl -n 500 --no-pager > "$OUT/journal-last500.txt" 2>&1 || true
cp -a /root/homelab-logs "$OUT/homelab-logs" 2>/dev/null || true
cp -a /root/homelab-state "$OUT/homelab-state" 2>/dev/null || true

while IFS= read -r f; do
  rel="${f#/}"
  case "$(basename "$f")" in
    docker-compose.yml|compose.yml)
      mkdir -p "$OUT/$(dirname "$rel")"
      cp "$f" "$OUT/$rel" 2>/dev/null || true
      ;;
    .env|*.env)
      redact_file "$f" "$OUT/$rel.redacted"
      ;;
  esac
done < <(find /opt/homelab -maxdepth 4 \( -name 'docker-compose.yml' -o -name 'compose.yml' -o -name '.env' -o -name '*.env' \) -print 2>/dev/null || true)

if [[ -d /root/homelab-secrets ]]; then
  while IFS= read -r f; do
    case "$(basename "$f")" in
      chia-mnemonic.env)
        echo "ℹ️ chia-mnemonic.env support bundle dışında bırakıldı." >> "$OUT/support-bundle-notes.txt"
        continue
        ;;
    esac
    redact_file "$f" "$OUT/${f#/}.redacted"
  done < <(find /root/homelab-secrets -maxdepth 1 -type f -name '*.env' -print)
fi

tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo "✅ Oluşturuldu: $OUT.tar.gz"
echo "ℹ️ .env/secret değerleri redacted olarak eklendi; raw secret kopyalanmadı."
