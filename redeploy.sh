#!/usr/bin/env bash
# Redeploys the three proxies on every host of this deployment.
#   ./redeploy.sh                      # the refs .env names, on every droplet of DO_TAG
#   ./redeploy.sh -r master            # move all three proxies to a ref in .env first
#   ./redeploy.sh -n -r master         # show the refs and hosts, change nothing
#   ./redeploy.sh root@203.0.113.10    # these hosts instead of the droplets of DO_TAG
set -euo pipefail
cd "$(dirname "$0")"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ref=""
dry=0
while getopts 'r:n' opt; do
  case "$opt" in
    r) ref=$OPTARG ;;
    n) dry=1 ;;
    *) die "usage: $0 [-n] [-r ref] [root@HOST...]" ;;
  esac
done
shift $((OPTIND - 1))

[ -f .env ] || die ".env not found: cp .env.example .env and fill it in"
# shellcheck disable=SC1091
. ./.env

: "${MARKET_REPO:=https://github.com/status-im/market-proxy.git}"
: "${RPC_REPO:=https://github.com/status-im/eth-rpc-proxy.git}"
: "${NFT_REPO:=https://github.com/status-im/nft-proxy.git}"

# set_env KEY VALUE: replaces the line in .env or adds it, keeping the file private.
set_env() {
  local tmp
  tmp=$(umask 077 && mktemp .env.XXXXXX)
  awk -v key="$1" -v value="$2" '
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' .env > "$tmp"
  mv "$tmp" .env
}

if [ -n "$ref" ]; then
  # A typo must not reach .env or the hosts. A commit id cannot be looked up this way.
  if ! [[ $ref =~ ^[0-9a-f]{7,40}$ ]]; then
    for repo in "$MARKET_REPO" "$RPC_REPO" "$NFT_REPO"; do
      git ls-remote --exit-code "$repo" "$ref" >/dev/null || die "no ref '$ref' in $repo"
    done
  fi
  if [ "$dry" = 0 ]; then
    for key in MARKET_REF RPC_REF NFT_REF; do
      set_env "$key" "$ref"
    done
  fi
  MARKET_REF=$ref RPC_REF=$ref NFT_REF=$ref
fi

if [ $# -gt 0 ]; then
  hosts=("$@")
else
  # shellcheck disable=SC2207
  hosts=($(./provision.sh ips))
fi
[ ${#hosts[@]} -gt 0 ] || die "no hosts: pass root@HOST or create droplets with ./provision.sh hosts N"

printf 'market   %s\neth-rpc  %s\nnft      %s\nhosts    %s\n' \
  "${MARKET_REF:-deploy-prod}" "${RPC_REF:-deploy-prod}" "${NFT_REF:-deploy-prod}" "${hosts[*]}"

if [ "$dry" = 1 ]; then
  echo "dry run: nothing changed"
  exit 0
fi

exec ./deploy.sh "${hosts[@]}"
