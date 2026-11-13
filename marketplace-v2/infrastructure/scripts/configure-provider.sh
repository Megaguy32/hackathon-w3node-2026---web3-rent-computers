#!/usr/bin/env bash
set -euo pipefail
: "${POOL_HOSTNAME:?Set POOL_HOSTNAME to the pool host public DNS name}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPTAINER_BIN="$(command -v apptainer || true)"
if [[ -z "$APPTAINER_BIN" ]]; then
  echo "Apptainer is required; install it before configuring this provider." >&2
  exit 1
fi
# Upstream interlink-htcondor-plugin currently invokes the 'singularity'
# executable. Apptainer provides a compatible CLI; install a tiny shim.
sudo tee /usr/local/bin/singularity >/dev/null <<SHIM
#!/bin/sh
exec "$APPTAINER_BIN" "$@"
SHIM
sudo chmod 0755 /usr/local/bin/singularity
sudo install -d -m 0755 /etc/condor/config.d
sudo install -m 0644 "$ROOT/infrastructure/htcondor/00-auth-demo.conf" /etc/condor/config.d/00-auth-demo.conf
sed -e "s/POOL_HOSTNAME/${POOL_HOSTNAME}/g" -e "s#APPTAINER_BINARY#${APPTAINER_BIN}#g" "$ROOT/infrastructure/htcondor/01-provider.conf.template" | sudo tee /etc/condor/config.d/01-provider.conf >/dev/null
sudo systemctl enable --now condor
sudo systemctl restart condor
condor_status -af Machine Name State HasSingularity
