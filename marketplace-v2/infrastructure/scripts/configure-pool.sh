#!/usr/bin/env bash
set -euo pipefail
: "${POOL_HOSTNAME:?Set POOL_HOSTNAME to the pool pool host public DNS name}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sudo install -d -m 0755 /etc/condor/config.d
sudo install -m 0644 "$ROOT/infrastructure/htcondor/00-auth-demo.conf" /etc/condor/config.d/00-auth-demo.conf
sed "s/POOL_HOSTNAME/${POOL_HOSTNAME}/g" "$ROOT/infrastructure/htcondor/01-pool.conf.template" | sudo tee /etc/condor/config.d/01-pool.conf >/dev/null
sudo systemctl enable --now condor
sudo systemctl restart condor
condor_status -af Machine Name State
