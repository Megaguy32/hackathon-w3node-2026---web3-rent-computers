#!/usr/bin/env bash
set -euo pipefail

# Add a narrow nftables input chain for the demo HTCondor shared port.
# It does not flush or rewrite the host's existing firewall rules.
: "${PROVIDER_PUBLIC_IPV4:?Set PROVIDER_PUBLIC_IPV4 to the provider public egress IPv4 address}"
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo PROVIDER_PUBLIC_IPV4=... $0" >&2
  exit 1
fi
command -v nft >/dev/null || { echo "nftables (nft) is required" >&2; exit 1; }

nft delete table inet w3node_demo >/dev/null 2>&1 || true
nft add table inet w3node_demo
nft 'add chain inet w3node_demo input { type filter hook input priority -5; policy accept; }'
nft add rule inet w3node_demo input iifname lo tcp dport 9618 accept
nft add rule inet w3node_demo input ip saddr "$PROVIDER_PUBLIC_IPV4" tcp dport 9618 accept
if [[ -n "${PROVIDER_PUBLIC_IPV6:-}" ]]; then
  nft add rule inet w3node_demo input ip6 saddr "$PROVIDER_PUBLIC_IPV6" tcp dport 9618 accept
fi
nft add rule inet w3node_demo input tcp dport 9618 drop

echo "Applied demo firewall rules. Only loopback and the configured provider address(es) can reach TCP/9618."
echo "Inspect with: sudo nft list table inet w3node_demo"
echo "These rules are runtime-only unless you add them to your host firewall's persistent configuration."
