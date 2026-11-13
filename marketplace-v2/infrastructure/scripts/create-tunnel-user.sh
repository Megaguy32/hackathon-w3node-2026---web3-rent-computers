#!/usr/bin/env bash
# Create the restricted SSH user the laptop's interLink API tunnels through to reach the plugin.
# Usage (as root, on the Marketplace/pool host): create-tunnel-user.sh /path/to/laptop_key.pub [plugin-port]
# The account has no shell, cannot open arbitrary forwards, and can only reach 127.0.0.1:<plugin-port>.
set -euo pipefail
PUBKEY_FILE="${1:?Usage: $0 /path/to/public_key.pub [plugin-port]}"
PLUGIN_PORT="${2:-4000}"
USER_NAME="${TUNNEL_USER:-interlink-tunnel}"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r "$PUBKEY_FILE" ]] || { echo "Cannot read $PUBKEY_FILE" >&2; exit 1; }
[[ "$PLUGIN_PORT" =~ ^[0-9]+$ ]] || { echo "Plugin port must be numeric." >&2; exit 1; }
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"
id "$USER_NAME" >/dev/null 2>&1 || useradd --create-home --shell "$NOLOGIN" "$USER_NAME"
home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
install -d -m 700 -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" "$home/.ssh"
key="$(awk 'NF>=2 && $1 ~ /^(ssh|ecdsa|sk-)/ {print $1" "$2; exit}' "$PUBKEY_FILE")"
[[ -n "$key" ]] || { echo "No public key found in $PUBKEY_FILE" >&2; exit 1; }
printf 'restrict,port-forwarding,permitopen="127.0.0.1:%s" %s w3node-tunnel\n' "$PLUGIN_PORT" "$key" > "$home/.ssh/authorized_keys"
chown "$USER_NAME:$(id -gn "$USER_NAME")" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
# Global defaults in some distros (e.g. Alpine) disable forwarding; a Match block makes it explicit and tight.
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/w3node-tunnel.conf <<CONF
Match User $USER_NAME
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:$PLUGIN_PORT
    GatewayPorts no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/false
CONF
sshd -t   # fails loudly (set -e) if the new Match block or the host config is invalid
echo "sshd config OK. Reload sshd (systemctl reload sshd) to apply."
echo "Tunnel user '$USER_NAME' ready; it may only forward to 127.0.0.1:$PLUGIN_PORT."
