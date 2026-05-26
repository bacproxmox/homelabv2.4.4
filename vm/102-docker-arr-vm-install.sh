#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/logging.sh"
start_log "vm-102-docker-arr"
source "$SCRIPT_DIR/../lib/vm-cloudinit-common.sh"
create_ubuntu_vm 102 "docker-arr" "192.168.50.102/24" 16384 6 256G "yes" "media"
