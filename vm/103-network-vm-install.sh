#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/logging.sh"
start_log "vm-103-docker-network"
source "$SCRIPT_DIR/../lib/vm-cloudinit-common.sh"
create_ubuntu_vm 103 "docker-network" "192.168.50.103/24" 4096 2 64G "yes" "none"
