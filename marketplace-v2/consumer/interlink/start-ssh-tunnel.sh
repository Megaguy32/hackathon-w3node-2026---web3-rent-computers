#!/usr/bin/env bash
set -euo pipefail
: "${MARKETPLACE_SSH_ADDR:?Set MARKETPLACE_SSH_ADDR=host:22}"
: "${MARKETPLACE_SSH_USER:?Set MARKETPLACE_SSH_USER}"
: "${SSH_KEY:?Set SSH_KEY path}"
INTERLINK_DIR="${INTERLINK_DIR:-$HOME/src/interLink}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
if [[ -n "${SSH_HOST_KEY_FILE:-}" ]]; then SSH_HOST_KEY_FILE="${SSH_HOST_KEY_FILE/#\~/$HOME}"; fi
LOCAL_SOCKET="${LOCAL_SOCKET:-/tmp/interlink.sock}"
PLUGIN_PORT="${PLUGIN_PORT:-4000}"
# TUNNEL_MODE:
#   local-forward (default) - `ssh -L 127.0.0.1:PORT:127.0.0.1:PORT`: the interLink API reaches the
#                             remote plugin at http://127.0.0.1:PORT (SidecarURL in InterLinkConfig.yaml).
#   interlink-ssh-tunnel    - upstream bin/ssh-tunnel. Upstream source does client.Listen on the REMOTE
#                             localhost:<rport> and dials the LOCAL unix socket, i.e. remote->local, and
#                             it cannot bind a remote port the plugin already uses. Only use it if you have
#                             verified that behaviour against your interLink version, and then also change
#                             SidecarURL/SidecarPort to match.
TUNNEL_MODE="${TUNNEL_MODE:-local-forward}"
host="${MARKETPLACE_SSH_ADDR%:*}"; port="${MARKETPLACE_SSH_ADDR##*:}"
[[ "$port" =~ ^[0-9]+$ && "$MARKETPLACE_SSH_ADDR" == *:* ]] || port=22

case "$TUNNEL_MODE" in
  local-forward)
    opts=(-i "$SSH_KEY" -p "$port" -N -L "127.0.0.1:${PLUGIN_PORT}:127.0.0.1:${PLUGIN_PORT}"
          -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes)
    if [[ -n "${SSH_HOST_KEY_FILE:-}" ]]; then
      [[ -f "$SSH_HOST_KEY_FILE" ]] || { echo "SSH_HOST_KEY_FILE not found: $SSH_HOST_KEY_FILE" >&2; exit 1; }
      kh="$(mktemp)"; trap 'rm -f "$kh"' EXIT
      # interLink-style host key file holds "<type> <base64>"; known_hosts needs a host prefix.
      printf '[%s]:%s %s\n' "$host" "$port" "$(awk 'NF>=2{print $1" "$2; exit}' "$SSH_HOST_KEY_FILE")" > "$kh"
      opts+=(-o "UserKnownHostsFile=$kh" -o StrictHostKeyChecking=yes)
    else
      echo "WARNING: SSH_HOST_KEY_FILE not set; trusting the host key on first use." >&2
      opts+=(-o StrictHostKeyChecking=accept-new)
    fi
    exec ssh "${opts[@]}" "${MARKETPLACE_SSH_USER}@${host}"
    ;;
  interlink-ssh-tunnel)
    [[ -x "$INTERLINK_DIR/bin/ssh-tunnel" ]] || { echo "Build interLink first (bin/ssh-tunnel missing)." >&2; exit 1; }
    args=(-addr "$MARKETPLACE_SSH_ADDR" -user "$MARKETPLACE_SSH_USER" -keyfile "$SSH_KEY" -lsock "$LOCAL_SOCKET" -rport "$PLUGIN_PORT")
    [[ -z "${SSH_HOST_KEY_FILE:-}" ]] || args+=(-hostkeyfile "$SSH_HOST_KEY_FILE")
    exec "$INTERLINK_DIR/bin/ssh-tunnel" "${args[@]}"
    ;;
  *) echo "Unknown TUNNEL_MODE: $TUNNEL_MODE" >&2; exit 1 ;;
esac
