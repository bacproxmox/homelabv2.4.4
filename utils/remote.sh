#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env-loader.sh"
load_all_env
SSH_USER="${BACMASTER_USER:-bacmaster}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts -o ConnectTimeout=8)
vm_ip(){ case "$1" in 101) echo 192.168.50.101;;102) echo 192.168.50.102;;103) echo 192.168.50.103;;104) echo 192.168.50.104;;105) echo 192.168.50.105;;106) echo 192.168.50.106;;107) echo 192.168.50.107;;110) echo 192.168.50.110;;*) echo "$1";; esac; }
rssh(){ local target="$(vm_ip "$1")"; shift; ssh "${SSH_OPTS[@]}" "$SSH_USER@$target" "$@"; }
rscp(){ local src="$1" dst_vm="$2" dst="$3"; local ip="$(vm_ip "$dst_vm")"; scp "${SSH_OPTS[@]}" -r "$src" "$SSH_USER@$ip:$dst"; }
wait_ssh(){ local vm="$1" ip; ip="$(vm_ip "$vm")"; echo "⏳ SSH bekleniyor: $SSH_USER@$ip"; for _ in $(seq 1 60); do ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" 'echo ok' >/dev/null 2>&1 && { echo "✅ SSH hazır: $ip"; return 0; }; sleep 5; done; echo "❌ SSH açılamadı: $ip"; return 1; }
run_remote_script(){ local vm="$1" script="$2"; shift 2; local ip; ip="$(vm_ip "$vm")"; wait_ssh "$vm"; scp "${SSH_OPTS[@]}" "$script" "$SSH_USER@$ip:/tmp/$(basename "$script")"; ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "chmod +x /tmp/$(basename "$script") && sudo /tmp/$(basename "$script") $*"; }
