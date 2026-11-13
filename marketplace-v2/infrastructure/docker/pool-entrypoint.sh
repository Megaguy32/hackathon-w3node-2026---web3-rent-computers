#!/bin/bash
# Pool host entrypoint: render the repo's HTCondor pool config, supervise the plugin and the marketplace
# backend, then become the HTCondor start script (so the container lives and dies with the pool).
set -uo pipefail
: "${POOL_HOSTNAME:?Set POOL_HOSTNAME to the address providers use to reach this host (e.g. the libvirt gateway)}"
log() { echo "[entrypoint] $*"; }

# --- HTCondor: replace the single-machine "minicondor" role with the repo's pool config.
install -m 0644 /opt/w3node/htcondor/00-auth-demo.conf /etc/condor/config.d/00-auth-demo.conf
sed "s/POOL_HOSTNAME/${POOL_HOSTNAME}/g" /opt/w3node/htcondor/01-pool.conf.template > /etc/condor/config.d/01-pool.conf
[[ -f /etc/condor/config.d/00-minicondor ]] && mv /etc/condor/config.d/00-minicondor /opt/w3node/00-minicondor.disabled
if [[ "${POOL_RUN_STARTD:-true}" == true ]]; then   # this host is also a provider (the demo's first machine)
  printf 'DAEMON_LIST = MASTER, COLLECTOR, NEGOTIATOR, SCHEDD, SHARED_PORT, STARTD\nUSE_SHARED_PORT = True\n' > /etc/condor/config.d/99-local-execute.conf
fi
if [[ "${CONDOR_FAST:-true}" == true ]]; then       # snappier matching for a live demo
  printf 'NEGOTIATOR_INTERVAL = 5\nNEGOTIATOR_CYCLE_DELAY = 2\n' > /etc/condor/config.d/99-fast.conf
fi

# --- supervised helpers: restart on exit, wait for the pool first.
run_forever() {
  local name=$1; shift
  ( while true; do
      "$@" 2>&1 | sed -u "s/^/[$name] /"
      log "$name exited; restarting in 3s"; sleep 3
    done ) &
}
wait_condor='until condor_status >/dev/null 2>&1; do sleep 2; done'

run_forever plugin bash -c "$wait_condor; cd /opt/plugin && exec runuser -u plug -- env MEGA_RENTALS_FILE=/run/w3node/rentals.json python3 handles.py --port 4000"
run_forever marketplace bash -c "$wait_condor; exec runuser -u w3node -- env \
  RPC_URL='${RPC_URL:-}' CHAIN_ID='${CHAIN_ID:-11155111}' CONTRACT_ADDRESS='${CONTRACT_ADDRESS:-}' START_BLOCK='${START_BLOCK:-0}' \
  CONFIRMATIONS='${CONFIRMATIONS:-3}' CHAIN_POLL_SECONDS='${CHAIN_POLL_SECONDS:-4}' LISTEN_ADDR='${LISTEN_ADDR:-127.0.0.1:8090}' \
  METRICS_ADDR='${METRICS_ADDR:-}' DATA_DIR=/var/lib/w3node-marketplace RENTALS_FILE=/run/w3node/rentals.json HTCONDOR_STATUS=condor_status \
  /usr/local/bin/w3node-marketplace"

log "starting HTCondor (pool address ${POOL_HOSTNAME})"
exec /start.sh
