#!/bin/bash
# Host keys live in a volume so the laptop's pinned host key survives rebuilds and reboots.
set -euo pipefail
KEYS=/keys; mkdir -p "$KEYS"
[[ -f $KEYS/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEYS/ssh_host_ed25519_key"
cut -d' ' -f1,2 "$KEYS/ssh_host_ed25519_key.pub" > "$KEYS/hostkey.txt"     # "<type> <base64>" for SSH_HOST_KEY_FILE
install -d /etc/ssh/sshd_config.d
printf 'HostKey %s/ssh_host_ed25519_key\n' "$KEYS" > /etc/ssh/sshd_config.d/00-hostkey.conf
/usr/local/bin/create-tunnel-user.sh /authorized/tunnel.pub "${PLUGIN_PORT:-4000}"
exec /usr/sbin/sshd -D -e -p "${SSH_PORT:-2222}" -o ListenAddress="${SSH_LISTEN:-127.0.0.1}" -o PasswordAuthentication=no
