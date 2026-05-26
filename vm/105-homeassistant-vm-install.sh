#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/logging.sh"
start_log "vm-105-homeassistant"
source "$SCRIPT_DIR/../lib/vm-cloudinit-common.sh"
create_ubuntu_vm 105 "homeassistant" "192.168.50.105/24" 4096 2 64G "yes" "none"
