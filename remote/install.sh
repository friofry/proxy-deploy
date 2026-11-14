#!/usr/bin/env bash
# Runs ON THE SERVER; deploy.sh copies the kit there and calls this.
# Idempotent: re-run after changing .env, a ref or a template.
#
#   install.sh [all|sync|render|check|up|caddy|smoke|puzzle]
#   install.sh dc <market|rpc|nft> <docker compose args...>
set -euo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=${PROXIES_ROOT:-/opt/proxies}
EDGE_NET=proxy-edge
CURL_IMAGE=curlimages/curl:8.11.1
GO_IMAGE=golang:1.24-alpine

log()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$KIT/.env" ] || die "$KIT/.env not found (copy .env.example and fill it in)"
set -a
# shellcheck disable=SC1091
. "$KIT/.env"
set +a

: "${MARKET_REPO:=https://github.com/status-im/market-proxy.git}"
: "${RPC_REPO:=https://github.com/status-im/eth-rpc-proxy.git}"
: "${NFT_REPO:=https://github.com/status-im/nft-proxy.git}"
: "${MARKET_REF:=deploy-prod}"
: "${RPC_REF:=deploy-prod}"
: "${NFT_REF:=deploy-prod}"

need() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is empty in .env"
  done
}

# pick PREFIX NAME -> $PREFIX_NAME when set, otherwise $NAME
pick() {
  local specific="${1}_${2}"
  printf '%s' "${!specific:-${!2:-}}"
}

# ---------------------------------------------------------------- compose

# Sets DIR and FILES for one proxy.
compose_for() {
  case "$1" in
    market)
      DIR=$ROOT/market-proxy
      FILES=(-f docker-compose.yml -f "$KIT/overrides/market.yml")
      if grep -qE '^  auth-service:' "$DIR/docker-compose.yml"; then
        FILES+=(-f "$KIT/overrides/market-auth.yml")
      fi
      ;;
    rpc)
      DIR=$ROOT/eth-rpc-proxy
      FILES=(-f docker-compose.yml -f "$KIT/overrides/eth-rpc.yml")
      ;;
    nft)
      DIR=$ROOT/nft-proxy
      FILES=(-f docker-compose.yml -f "$KIT/overrides/nft.yml")
      ;;
    *) die "unknown proxy '$1' (market|rpc|nft)" ;;
  esac
}

dc() {
  local name=$1
  shift
  compose_for "$name"
  (cd "$DIR" && docker compose "${FILES[@]}" "$@")
}

# ---------------------------------------------------------------- sync

sync_repo() {
  local dir=$ROOT/$1 url=$2 ref=$3
  if [ ! -d "$dir/.git" ]; then
    git clone -q "$url" "$dir"
  fi
  git -C "$dir" remote set-url origin "$url"
  git -C "$dir" fetch -q --tags --prune origin
  if git -C "$dir" rev-parse -q --verify "origin/$ref^{commit}" >/dev/null; then
    git -C "$dir" checkout -q --detach "origin/$ref"
  else
    git -C "$dir" checkout -q --detach "$ref"
  fi
  git -C "$dir" submodule update -q --init --recursive
  printf '%-14s %s  %s\n' "$1" "$ref" "$(git -C "$dir" log -1 --format='%h %s')"
}

step_sync() {
  log "Fetching sources"
  mkdir -p "$ROOT"
  chmod 700 "$ROOT"
  sync_repo market-proxy  "$MARKET_REPO" "$MARKET_REF"
  sync_repo eth-rpc-proxy "$RPC_REPO"    "$RPC_REF"
  sync_repo nft-proxy     "$NFT_REPO"    "$NFT_REF"
}

# ---------------------------------------------------------------- render

# Files are world-readable on purpose: nginx workers and the Go services read
# them as non-root users inside the containers. $ROOT itself is root-only.
put() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod 644 "$path"
}

render_htpasswd() {
  local user pass
  user=$(pick "$1" BASIC_AUTH_USER)
  pass=$(pick "$1" BASIC_AUTH_PASSWORD)
  printf '%s:%s\n' "$user" "$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)" | put "$2"
}

render_auth_config() {
  jq --arg secret "$(pick "$1" JWT_SECRET)" '.jwt_secret = $secret' \
    "$KIT/templates/auth_config.json" | put "$2"
}

csv_to_json_array='split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'

step_render() {
  log "Writing secret files"
  need BASIC_AUTH_USER BASIC_AUTH_PASSWORD JWT_SECRET INFURA_API_KEY ALCHEMY_API_KEY

  local m=$ROOT/market-proxy r=$ROOT/eth-rpc-proxy n=$ROOT/nft-proxy

  # market-proxy
  render_htpasswd MARKET "$m/secrets/.htpasswd"
  render_auth_config MARKET "$m/secrets/auth_config.json"
  jq -n --arg pro "${COINGECKO_API_KEYS:-}" --arg demo "${COINGECKO_DEMO_API_KEYS:-}" \
    "{api_tokens: (\$pro | $csv_to_json_array), demo_api_tokens: (\$demo | $csv_to_json_array)}" \
    | put "$m/secrets/coingecko_api_tokens.json"
  printf 'MARKET_PROXY_USER=%s\nMARKET_PROXY_PASSWORD=%s\n' \
    "$(pick MARKET BASIC_AUTH_USER)" "$(pick MARKET BASIC_AUTH_PASSWORD)" | put "$m/.env"
  if [ -z "${COINGECKO_API_KEYS:-}${COINGECKO_DEMO_API_KEYS:-}" ]; then
    echo "WARN: no CoinGecko keys, market-fetcher will run keyless"
  fi

  # eth-rpc-proxy
  render_htpasswd RPC "$r/secrets/.htpasswd"
  render_auth_config RPC "$r/secrets/auth_config.json"
  local set_keys='if .type == "infura" then .authToken = $infura
                  elif .type == "alchemy" then .authToken = $alchemy else . end'
  jq --arg infura "$INFURA_API_KEY" --arg alchemy "$ALCHEMY_API_KEY" \
    "(.chains[].providers[]) |= ($set_keys)" \
    "$KIT/templates/default_providers.json" | put "$r/secrets/default_providers.json"
  jq --arg infura "$INFURA_API_KEY" --arg alchemy "$ALCHEMY_API_KEY" \
    "(.chains[].provider) |= ($set_keys)" \
    "$KIT/templates/reference_providers.json" | put "$r/secrets/reference_providers.json"
  if [ -n "${KEYDB_URL:-}" ]; then
    printf '%s' "$KEYDB_URL" | put "$r/secrets/.keydb-url"
    put "$r/secrets/cache_config.yaml" < "$r/go-proxy-cache/cache_config.yaml"
    echo "eth-rpc cache: L1 memory + L2 KeyDB"
  else
    : | put "$r/secrets/.keydb-url"
    # Flip only the "enabled" that belongs to the top-level keydb: section.
    awk '/^keydb:/ {k = 1}
         k && /enabled:/ {sub(/true/, "false"); k = 0}
         {print}' "$r/go-proxy-cache/cache_config.yaml" | put "$r/secrets/cache_config.yaml"
    echo "eth-rpc cache: L1 memory only (KEYDB_URL is empty)"
  fi

  # nft-proxy
  local nft_key
  nft_key=$(pick NFT ALCHEMY_API_KEY)
  render_htpasswd NFT "$n/secrets/.htpasswd"
  render_auth_config NFT "$n/secrets/auth_config.json"
  jq -n --arg key "$nft_key" '{api_tokens: [$key]}' | put "$n/secrets/alchemy_api_keys.json"
  printf 'ALCHEMY_API_KEY=%s\n' "$nft_key" | put "$n/.env"
}

# ---------------------------------------------------------------- check / up

step_check() {
  log "Validating compose files"
  local p
  for p in market rpc nft; do
    dc "$p" config -q
    echo "$p ok"
  done
}

ensure_network() {
  docker network inspect "$EDGE_NET" >/dev/null 2>&1 || docker network create "$EDGE_NET" >/dev/null
}

step_up() {
  ensure_network
  local p
  for p in market rpc nft; do
    log "Building and starting $p"
    dc "$p" up -d --build --remove-orphans
  done
}

# ---------------------------------------------------------------- caddy

public_ip() {
  if [ -n "${PUBLIC_IP:-}" ]; then
    echo "$PUBLIC_IP"
  else
    ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
  fi
}

points_here() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | grep -qxF "$2"
}

# site_names LABEL DOMAIN IP -> comma-separated host names Caddy should serve
site_names() {
  local label=$1 domain=$2 ip=$3 names=""
  if [ "${FORCE_DOMAINS:-0}" = 1 ] || points_here "$domain" "$ip"; then
    names=$domain
  else
    echo "WARN: $domain does not resolve to $ip yet, not served (re-run deploy after the DNS switch)" >&2
  fi
  if [ "${SSLIP_TEST_DOMAINS:-1}" = 1 ]; then
    names=${names:+$names, }$label.${ip//./-}.sslip.io
  fi
  printf '%s' "$names"
}

step_caddy() {
  log "Configuring Caddy"
  need MARKET_DOMAIN RPC_DOMAIN NFT_DOMAIN
  ensure_network
  local ip names dir=$ROOT/caddy
  ip=$(public_ip)
  [ -n "$ip" ] || die "cannot detect the public IP, set PUBLIC_IP in .env"
  mkdir -p "$dir/conf"
  cp "$KIT/caddy/docker-compose.yml" "$dir/docker-compose.yml"

  {
    if [ -n "${ACME_EMAIL:-}" ]; then
      printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL"
    fi
    local spec label domain
    for spec in "market:$MARKET_DOMAIN" "rpc:$RPC_DOMAIN" "nft:$NFT_DOMAIN"; do
      label=${spec%%:*}
      domain=${spec#*:}
      names=$(site_names "$label" "$domain" "$ip")
      [ -n "$names" ] || continue
      printf '%s {\n\treverse_proxy %s-front:8080\n}\n\n' "$names" "$label"
    done
  } > "$dir/conf/Caddyfile"

  grep -q reverse_proxy "$dir/conf/Caddyfile" || die "no host names to serve: DNS is not switched and SSLIP_TEST_DOMAINS=0"
  cat "$dir/conf/Caddyfile"

  local was_running
  was_running=$(docker ps -q -f name='^proxy-caddy$')
  (cd "$dir" && docker compose up -d)
  if [ -n "$was_running" ]; then
    docker exec proxy-caddy caddy reload --config /etc/caddy/Caddyfile
  fi
}

# ---------------------------------------------------------------- smoke

FAILED=0

http_code() {
  docker run --rm --network "$EDGE_NET" "$CURL_IMAGE" \
    -s -o /dev/null -m 30 -w '%{http_code}' "$@" 2>/dev/null || true
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# mint_jwt SECRET -> a short-lived token shaped like the ones auth-service issues.
# Lets the smoke test check that nginx accepts a bearer token on API routes
# without solving a puzzle first (step_puzzle covers the issuing side).
mint_jwt() {
  local now head body
  now=$(date +%s)
  head=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  body=$(printf '{"request_limit":100,"challenge":"smoke-%d","exp":%d,"iat":%d,"jti":"smoke-%d"}' \
    "$now" "$((now + 300))" "$now" "$now" | b64url)
  printf '%s.%s.%s' "$head" "$body" \
    "$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -hmac "$1" -binary | b64url)"
}

# expect DESCRIPTION WANTED_CODE curl-args...   (retries: services warm up after a start)
expect() {
  local desc=$1 want=$2 got="" _
  shift 2
  for _ in $(seq 1 "${SMOKE_RETRIES:-12}"); do
    got=$(http_code "$@")
    [ "$got" = "$want" ] && break
    sleep 10
  done
  if [ "$got" = "$want" ]; then
    printf '  ok    %-44s %s\n' "$desc" "$got"
  else
    printf '  FAIL  %-44s got %s, want %s\n' "$desc" "${got:-none}" "$want"
    FAILED=$((FAILED + 1))
  fi
}

step_smoke() {
  log "Smoke tests (inside the docker network, no TLS)"
  local rpc_body='{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  local nft_path='/ethereum/mainnet/nft/v3/getOwnersForContract?contractAddress=0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D'
  local mu mp ru rp nu np
  mu=$(pick MARKET BASIC_AUTH_USER); mp=$(pick MARKET BASIC_AUTH_PASSWORD)
  ru=$(pick RPC BASIC_AUTH_USER);    rp=$(pick RPC BASIC_AUTH_PASSWORD)
  nu=$(pick NFT BASIC_AUTH_USER);    np=$(pick NFT BASIC_AUTH_PASSWORD)

  local mt rt nt
  mt="Authorization: Bearer $(mint_jwt "$(pick MARKET JWT_SECRET)")"
  rt="Authorization: Bearer $(mint_jwt "$(pick RPC JWT_SECRET)")"
  nt="Authorization: Bearer $(mint_jwt "$(pick NFT JWT_SECRET)")"
  local json='Content-Type: application/json'

  echo "market"
  expect "puzzle endpoint"        200 http://market-front:8080/auth/puzzle
  expect "no credentials -> 401"  401 http://market-front:8080/v1/leaderboard/prices
  expect "basic auth -> 200"      200 -u "$mu:$mp" http://market-front:8080/v1/leaderboard/prices
  expect "bearer token -> 200"    200 -H "$mt" http://market-front:8080/v1/leaderboard/prices

  echo "eth-rpc"
  expect "puzzle endpoint"        200 http://rpc-front:8080/auth/puzzle
  expect "no credentials -> 401"  401 -X POST -H "$json" -d "$rpc_body" http://rpc-front:8080/ethereum/mainnet
  expect "basic auth -> 200"      200 -u "$ru:$rp" -X POST -H "$json" -d "$rpc_body" http://rpc-front:8080/ethereum/mainnet
  expect "bearer token -> 200"    200 -H "$rt" -X POST -H "$json" -d "$rpc_body" http://rpc-front:8080/ethereum/mainnet

  echo "nft"
  expect "puzzle endpoint"        200 http://nft-front:8080/auth/puzzle
  expect "no credentials -> 401"  401 "http://nft-front:8080$nft_path"
  expect "basic auth -> 200"      200 -u "$nu:$np" "http://nft-front:8080$nft_path"
  expect "bearer token -> 200"    200 -H "$nt" "http://nft-front:8080$nft_path"
}

# Solves a real puzzle against each proxy with the tester that ships in proxy-common:
# /auth/puzzle -> solve -> /auth/solve -> /auth/verify.
step_puzzle() {
  log "Puzzle auth end to end"
  local src=$ROOT/eth-rpc-proxy/proxy-common label
  [ -d "$src/auth/cmd/test-puzzle-auth" ] || die "puzzle tester not found in $src"
  for label in market rpc nft; do
    echo "--- $label"
    if docker run --rm --network "$EDGE_NET" -v "$src:/src:ro" -v proxy-go-cache:/go -w /src \
         "$GO_IMAGE" go run ./auth/cmd/test-puzzle-auth "http://$label-front:8080" 2>&1 | tail -n 14; then
      printf '  ok    %s puzzle solved, token verified\n' "$label"
    else
      printf '  FAIL  %s puzzle auth\n' "$label"
      FAILED=$((FAILED + 1))
    fi
  done
}

finish() {
  [ "$FAILED" -eq 0 ] || die "$FAILED check(s) failed, see FAIL lines above"
  log "All checks passed"
}

# ---------------------------------------------------------------- main

cmd=${1:-all}
case "$cmd" in
  sync)   step_sync ;;
  render) step_render ;;
  check)  step_check ;;
  up)     step_up ;;
  caddy)  step_caddy ;;
  smoke)  step_smoke; finish ;;
  puzzle) step_puzzle; finish ;;
  dc)     shift; dc "$@" ;;
  all)
    step_sync
    step_render
    step_check
    step_up
    step_caddy
    step_smoke
    step_puzzle
    finish
    ;;
  *) die "unknown command '$cmd'" ;;
esac
