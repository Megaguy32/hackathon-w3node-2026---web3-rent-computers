#!/usr/bin/env bash
# Stop the demo stack. Data (chain cursor, volumes, VM disks, Minikube cluster) is kept.
#   ./scripts/demo-down.sh          stop interLink/tunnel, port-forwards and the compose containers
#   ./scripts/demo-down.sh --all    also stop Minikube and shut the provider VM down
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; export PATH="$HOME/.local/bin:$PATH"
ENV_FILE="${DEMO_ENV_FILE:-$ROOT/.demo-laptop.env}"; [[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
STATE="${DEMO_STATE_DIR:-$HOME/.local/state/w3node}"; PROFILE="${MINIKUBE_PROFILE:-w3node-demo}"
"$ROOT/scripts/demo-laptop.sh" disconnect || true
for f in "$STATE"/pids/pf-*.pid; do [[ -f $f ]] && kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
if [[ -f "$ROOT/infrastructure/docker/.env" ]]; then
  TUNNEL_DIR="$STATE/tunnel" MINIKUBE_BRIDGE_IP="${MINIKUBE_BRIDGE_IP:-127.0.0.1}" \
    docker compose -f "$ROOT/infrastructure/docker/compose.yaml" --env-file "$ROOT/infrastructure/docker/.env" down
fi
if [[ "${1:-}" == --all ]]; then
  minikube stop -p "$PROFILE" || true
  virsh -c qemu:///system shutdown "${PROVIDER_VM_NAME:-w3node-provider}" 2>/dev/null || true
fi
echo "Demo stack stopped."
