#!/usr/bin/env bash
# Creates DigitalOcean resources with doctl (must be installed and authorized).
# Everything is found by tag, so the commands are safe to re-run.
#
#   ./provision.sh hosts 2      # make sure droplets <tag>-1 .. <tag>-2 exist
#   ./provision.sh ips          # print root@IP for every droplet, for bootstrap.sh / deploy.sh
#   ./provision.sh lb           # load balancer + cloud firewall in front of the droplets
#   ./provision.sh status       # droplets, load balancer and firewall that belong to this tag
set -euo pipefail
cd "$(dirname "$0")"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v doctl >/dev/null || die "doctl not found (brew install doctl && doctl auth init)"
[ -f .env ] || die ".env not found: cp .env.example .env and fill it in"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DO_TAG:=proxy}"
: "${DO_REGION:=fra1}"
: "${DO_SIZE:=s-2vcpu-4gb}"
: "${DO_IMAGE:=ubuntu-24-04-x64}"

droplet_names() {
  doctl compute droplet list --tag-name "$DO_TAG" --format Name --no-header
}

cmd_hosts() {
  local want=${1:-1} existing missing=() i
  [ -n "${DO_SSH_KEYS:-}" ] || die "DO_SSH_KEYS is empty in .env (see: doctl compute ssh-key list)"
  existing=$(droplet_names)
  for i in $(seq 1 "$want"); do
    grep -qxF "$DO_TAG-$i" <<<"$existing" || missing+=("$DO_TAG-$i")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    echo "All $want droplet(s) already exist."
  else
    echo "Creating: ${missing[*]}  ($DO_SIZE, $DO_IMAGE, $DO_REGION)"
    doctl compute droplet create "${missing[@]}" \
      --region "$DO_REGION" --size "$DO_SIZE" --image "$DO_IMAGE" \
      --ssh-keys "$DO_SSH_KEYS" --tag-name "$DO_TAG" \
      --enable-private-networking --wait \
      --format Name,PublicIPv4,PrivateIPv4,Status
  fi
  echo
  echo "Next:"
  echo "  ./bootstrap.sh \$(./provision.sh ips)"
  echo "  ./deploy.sh \$(./provision.sh ips)"
}

cmd_ips() {
  doctl compute droplet list --tag-name "$DO_TAG" --format PublicIPv4 --no-header | sed 's/^/root@/'
}

lb_id() {
  doctl compute load-balancer list --format ID,Name --no-header | awk -v n="$DO_TAG-lb" '$2 == n {print $1}'
}

cmd_lb() {
  [ "${TLS_MODE:-caddy}" = lb ] || die "set TLS_MODE=lb in .env and redeploy first: the hosts must speak plain HTTP on port 80"
  [ -n "${DO_CERT_ID:-}" ] || die "DO_CERT_ID is empty in .env (see README, 'Behind a load balancer')"
  [ -n "$(droplet_names)" ] || die "no droplets tagged '$DO_TAG'"

  local id
  id=$(lb_id)
  if [ -n "$id" ]; then
    echo "Load balancer $DO_TAG-lb already exists ($id)."
  else
    echo "Creating load balancer $DO_TAG-lb"
    doctl compute load-balancer create --name "$DO_TAG-lb" --region "$DO_REGION" \
      --tag-name "$DO_TAG" --redirect-http-to-https \
      --forwarding-rules "entry_protocol:https,entry_port:443,target_protocol:http,target_port:80,certificate_id:$DO_CERT_ID" \
      --health-check "protocol:http,port:80,path:/healthz,check_interval_seconds:10,response_timeout_seconds:5,healthy_threshold:3,unhealthy_threshold:3" \
      --format ID,Name,Status
    id=$(lb_id)
  fi

  # Port 80 on the hosts is reachable from the balancer only; SSH stays open.
  if doctl compute firewall list --format Name --no-header | grep -qxF "$DO_TAG-fw"; then
    echo "Firewall $DO_TAG-fw already exists."
  else
    echo "Creating firewall $DO_TAG-fw"
    doctl compute firewall create --name "$DO_TAG-fw" --tag-names "$DO_TAG" \
      --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:80,load_balancer_uid:$id" \
      --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,address:0.0.0.0/0,address:::/0" \
      --format ID,Name,Status
  fi

  echo
  echo "Point the three domains at this address once Status is 'active':"
  doctl compute load-balancer get "$id" --format Name,IP,Status
}

cmd_status() {
  echo "Droplets tagged '$DO_TAG':"
  doctl compute droplet list --tag-name "$DO_TAG" --format Name,PublicIPv4,PrivateIPv4,Memory,Status
  echo
  echo "Load balancer $DO_TAG-lb:"
  doctl compute load-balancer list --format Name,IP,Status,Tag --no-header | awk -v n="$DO_TAG-lb" '$1 == n' | grep . || echo "  (none)"
  echo
  echo "Firewall $DO_TAG-fw:"
  doctl compute firewall list --format Name,Status,Tags --no-header | awk -v n="$DO_TAG-fw" '$1 == n' | grep . || echo "  (none)"
}

case "${1:-}" in
  hosts)  cmd_hosts "${2:-1}" ;;
  ips)    cmd_ips ;;
  lb)     cmd_lb ;;
  status) cmd_status ;;
  *)      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
