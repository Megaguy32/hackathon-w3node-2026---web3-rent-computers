#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?Set KUBECONFIG to the consumer cluster kubeconfig}"
INTERLINK_DIR="${INTERLINK_DIR:-$HOME/src/interLink}"
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export INTERLINKCONFIGPATH="${INTERLINKCONFIGPATH:-$CONFIG_DIR/InterLinkConfig.yaml}"
# If the SSH forward's local port differs from the shipped SidecarPort, render a config copy.
if [[ -n "${PLUGIN_LOCAL_PORT:-}" ]]; then
  rendered="$(mktemp --suffix=.yaml)"
  sed "s/^SidecarPort:.*/SidecarPort: \"${PLUGIN_LOCAL_PORT}\"/" "$INTERLINKCONFIGPATH" > "$rendered"
  export INTERLINKCONFIGPATH="$rendered"
fi

if [[ ! -x "$INTERLINK_DIR/bin/interlink" ]]; then
  echo "Missing $INTERLINK_DIR/bin/interlink. Build interLink first." >&2
  exit 1
fi
if [[ -x "$INTERLINK_DIR/bin/vk" ]]; then
  VK_BIN="$INTERLINK_DIR/bin/vk"
elif [[ -x "$INTERLINK_DIR/bin/virtual-kubelet" ]]; then
  VK_BIN="$INTERLINK_DIR/bin/virtual-kubelet"
else
  echo "Missing Virtual Kubelet binary. Expected bin/vk (current upstream) or bin/virtual-kubelet." >&2
  exit 1
fi

"$INTERLINK_DIR/bin/interlink" &
API_PID=$!
cleanup() {
  kill "$API_PID" 2>/dev/null || true
  wait "$API_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
for _ in $(seq 1 30); do
  [[ -S /tmp/interlink.sock ]] && break
  sleep 1
done
if [[ ! -S /tmp/interlink.sock ]]; then
  echo "interLink API did not create /tmp/interlink.sock. Inspect its logs/configuration." >&2
  exit 1
fi
"$VK_BIN" -nodename "${INTERLINK_NODE_NAME:-interlink-node}" -configpath "$CONFIG_DIR/VirtualKubeletConfig.yaml" &
VK_PID=$!
cleanup() {
  kill "$VK_PID" "$API_PID" 2>/dev/null || true
  wait "$VK_PID" "$API_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
wait "$VK_PID"
