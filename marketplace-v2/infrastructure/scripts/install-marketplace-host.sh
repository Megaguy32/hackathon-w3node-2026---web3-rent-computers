#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$(id -u)" -ne 0 ]]; then echo "Run with sudo: sudo $0" >&2; exit 1; fi
if ! command -v apt-get >/dev/null; then echo "This bootstrap helper targets Debian/Ubuntu. Install Go 1.23+, Python 3, git and HTCondor manually on other distributions." >&2; exit 1; fi
apt-get update
apt-get install -y ca-certificates curl git python3 python3-venv python3-pip
id w3node >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/w3node --shell /usr/sbin/nologin w3node
install -d -o w3node -g w3node /opt/w3node/marketplace /opt/w3node/bin /var/lib/w3node-compute-marketplace
cp -a "$ROOT/marketplace/." /opt/w3node/marketplace/
chown -R w3node:w3node /opt/w3node/marketplace /var/lib/w3node-compute-marketplace
cd /opt/w3node/marketplace
if command -v go >/dev/null 2>&1; then
  GO_VERSION="$(go env GOVERSION | sed 's/^go//')"
  if [[ "$(printf '%s\n' 1.23 "$GO_VERSION" | sort -V | head -n1)" == "1.23" ]]; then
    go build -trimpath -o /opt/w3node/bin/marketplace .
  elif [[ "$(uname -m)" == "x86_64" && -x "$ROOT/dist/marketplace-linux-amd64" ]]; then
    install -m 0755 "$ROOT/dist/marketplace-linux-amd64" /opt/w3node/bin/marketplace
  else
    echo "Go 1.23+ is required to build on this architecture; install Go or provide a compatible binary." >&2
    exit 1
  fi
elif [[ "$(uname -m)" == "x86_64" && -x "$ROOT/dist/marketplace-linux-amd64" ]]; then
  install -m 0755 "$ROOT/dist/marketplace-linux-amd64" /opt/w3node/bin/marketplace
else
  echo "Go 1.23+ or a compatible prebuilt binary is required." >&2
  exit 1
fi
install -o root -g w3node -m 0640 "$ROOT/.env.example" /etc/w3node-marketplace.env
# Update paths for the service account and runtime state.
sed -i 's#DATA_DIR=.*#DATA_DIR=/var/lib/w3node-compute-marketplace#; s#RENTALS_FILE=.*#RENTALS_FILE=/run/w3node/rentals.json#' /etc/w3node-marketplace.env
install -m 0644 "$ROOT/infrastructure/systemd/w3node-marketplace.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable w3node-marketplace.service
cat <<'MSG'
Marketplace binary and systemd unit installed.
Edit /etc/w3node-marketplace.env and set RPC_URL + CONTRACT_ADDRESS after contract deployment.
Then run: systemctl start w3node-marketplace
Plugin installation: run plugin/install-plugin.sh from the project directory, then install w3node-plugin.service.
MSG
