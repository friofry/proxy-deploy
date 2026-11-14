#!/usr/bin/env bash
# Runs ON THE SERVER as root, once per fresh Ubuntu/Debian host. Safe to re-run.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Runs a command until it succeeds, for up to 5 minutes.
retry() {
  local attempt
  for attempt in $(seq 1 30); do
    "$@" && return 0
    echo "    not ready, retrying in 10s ($attempt/30)" >&2
    sleep 10
  done
  return 1
}

# A fresh cloud image runs its own apt jobs on first boot (cloud-init, unattended
# upgrades) and holds the apt locks for a minute or two.
echo "==> Waiting for first-boot setup"
if command -v cloud-init >/dev/null; then
  timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
fi
# Every apt call, including the ones inside the Docker installer, waits for the dpkg lock.
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99-lock-timeout

echo "==> Packages"
retry apt-get update -qq
retry apt-get install -y -qq ca-certificates curl git jq rsync ufw openssl >/dev/null

echo "==> Docker"
if ! command -v docker >/dev/null; then
  installer=$(mktemp)
  retry curl -fsSL https://get.docker.com -o "$installer"
  retry sh "$installer" >/dev/null
  rm -f "$installer"
fi
if [ ! -f /etc/docker/daemon.json ]; then
  # Without rotation container logs grow until the disk is full.
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
  systemctl restart docker
fi
docker compose version

echo "==> Swap (the Go and OpenResty builds need headroom on small hosts)"
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Firewall: SSH, 80, 443 only"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null
ufw status | sed -n '1,12p'

mkdir -p /opt/proxies
chmod 700 /opt/proxies
echo "==> Host is ready"
