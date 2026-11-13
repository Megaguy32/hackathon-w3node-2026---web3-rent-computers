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
# Ubuntu 24.04+ restricts unprivileged user namespaces with AppArmor, and the archive's apptainer has no
# profile for them ("Failed to create container process: Operation not permitted"). Allow the starter.
if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == 1 ]] && command -v apparmor_parser >/dev/null; then
  STARTER="$(dpkg -L apptainer 2>/dev/null | grep -E '/apptainer/bin/starter$' | head -1 || true)"
  if [[ -n "$STARTER" && ! -e /etc/apparmor.d/apptainer ]]; then
    sudo tee /etc/apparmor.d/apptainer >/dev/null <<PROFILE
abi <abi/4.0>,
include <tunables/global>

profile apptainer $STARTER flags=(unconfined) {
  userns,
  include if exists <local/apptainer>
}
PROFILE
    sudo apparmor_parser -r /etc/apparmor.d/apptainer
  fi
fi
sudo install -d -m 0755 /etc/condor/config.d
sudo install -m 0644 "$ROOT/infrastructure/htcondor/00-auth-demo.conf" /etc/condor/config.d/00-auth-demo.conf
sed -e "s/POOL_HOSTNAME/${POOL_HOSTNAME}/g" -e "s#APPTAINER_BINARY#${APPTAINER_BIN}#g" "$ROOT/infrastructure/htcondor/01-provider.conf.template" | sudo tee /etc/condor/config.d/01-provider.conf >/dev/null
sudo systemctl enable --now condor
sudo systemctl restart condor
condor_status -af Machine Name State HasSingularity
