#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/logging.sh"
start_log "vm-104-nextcloud"
source "$SCRIPT_DIR/../lib/vm-cloudinit-common.sh"
create_ubuntu_vm 104 "nextcloud" "192.168.50.104/24" 8192 4 128G "yes" "privatedocuments"
