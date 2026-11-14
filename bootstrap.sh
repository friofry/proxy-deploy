#!/usr/bin/env bash
# Prepares fresh hosts: Docker, firewall, swap.
#   ./bootstrap.sh root@203.0.113.10 [root@203.0.113.11 ...]
set -euo pipefail
cd "$(dirname "$0")"
[ $# -gt 0 ] || { echo "usage: $0 root@HOST [root@HOST...]" >&2; exit 1; }

for host in "$@"; do
  echo "######## $host"
  ssh -o StrictHostKeyChecking=accept-new "$host" 'bash -s' < remote/bootstrap-remote.sh
done
