#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${PLUGIN_INSTALL_DIR:-/opt/w3node/interlink-htcondor-plugin}"
REPO="https://github.com/interlink-hq/interlink-htcondor-plugin.git"
# Pin a known-good upstream commit or tag for reproducible demos, e.g.
#   PLUGIN_REF=<sha-or-tag> plugin/install-plugin.sh
# Empty means the default branch; apply_patch.py still fails closed if anchors moved.
PLUGIN_REF="${PLUGIN_REF:-}"

if ! command -v git >/dev/null; then echo "git is required" >&2; exit 1; fi
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  sudo install -d -o "$(id -un)" -g "$(id -gn)" "$(dirname "$INSTALL_DIR")"
  git clone "$REPO" "$INSTALL_DIR"
else
  # Drop our previous patch so the update cannot conflict; it is re-applied below.
  git -C "$INSTALL_DIR" checkout -- handles.py
  git -C "$INSTALL_DIR" fetch --tags origin
fi
if [[ -n "$PLUGIN_REF" ]]; then
  git -C "$INSTALL_DIR" checkout --detach "$PLUGIN_REF"
else
  git -C "$INSTALL_DIR" checkout --detach origin/HEAD
fi
echo "Upstream plugin at $(git -C "$INSTALL_DIR" rev-parse HEAD)"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install flask pyyaml
python3 "$ROOT/plugin/apply_patch.py" "$INSTALL_DIR"
python3 -m py_compile "$INSTALL_DIR/handles.py"
sudo install -d -m 0775 /var/lib/w3node-interlink/jobs /var/lib/w3node-interlink/jobs/out /var/lib/w3node-interlink/jobs/err /var/lib/w3node-interlink/jobs/log
sudo chown -R w3node:w3node /var/lib/w3node-interlink
sudo chown -R w3node:w3node "$INSTALL_DIR"
sudo install -m 0644 "$ROOT/plugin/SidecarConfig.yaml" "$INSTALL_DIR/SidecarConfig.yaml"
echo "Plugin installed and patched at $INSTALL_DIR"
echo "Set MEGA_RENTALS_FILE=/run/w3node/rentals.json and install infrastructure/systemd/w3node-plugin.service."
