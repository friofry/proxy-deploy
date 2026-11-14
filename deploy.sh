#!/usr/bin/env bash
# Copies this kit and .env to each host and runs remote/install.sh there.
#   ./deploy.sh root@203.0.113.10 [root@203.0.113.11 ...]
#   ./deploy.sh -s caddy root@203.0.113.10        # one step: sync|render|check|up|caddy|smoke|puzzle
set -euo pipefail
cd "$(dirname "$0")"

step=all
while getopts 's:' opt; do
  case "$opt" in
    s) step=$OPTARG ;;
    *) exit 1 ;;
  esac
done
shift $((OPTIND - 1))

[ $# -gt 0 ] || { echo "usage: $0 [-s step] root@HOST [root@HOST...]" >&2; exit 1; }
[ -f .env ] || { echo ".env not found: cp .env.example .env and fill it in" >&2; exit 1; }

kit=/opt/proxies/kit
for host in "$@"; do
  echo "######## $host"
  ssh -o StrictHostKeyChecking=accept-new "$host" "mkdir -p $kit && chmod 700 /opt/proxies"
  rsync -az --delete --exclude .git --exclude .DS_Store ./ "$host:$kit/"
  ssh "$host" "chmod 600 $kit/.env && bash $kit/remote/install.sh $step"
done
