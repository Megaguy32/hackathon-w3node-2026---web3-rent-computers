#!/usr/bin/env bash
# Let libvirt VMs (Minikube KVM2 guest, provider VM) work on a host that also runs Docker.
#
# Why: Docker sets the iptables FORWARD policy to DROP, so packets forwarded from a libvirt NAT bridge
# (virbr0, virbr1, ...) to the Internet are dropped. Separately, firewalld's `libvirt` zone only allows
# DHCP/DNS/SSH/TFTP from the VMs to the host and then rejects, so the Minikube VM cannot reach the virtual
# kubelet on 5820 (`kubectl logs/exec`), the provider VM cannot reach the HTCondor pool on 9618, and
# Prometheus in Minikube cannot scrape node_exporter on the host.
#
# What it does (nftables, RUNTIME ONLY: lost on reboot or when libvirt/Docker rebuild their rules):
#   1. DOCKER-USER: accept forwarded traffic from each libvirt bridge's subnet, and replies back to it.
#   2. firewalld (zone libvirt) rich rules, scoped by VM subnet: Minikube bridge -> host tcp/5820 (virtual
#      kubelet) and tcp/9100,9101 (metrics); default bridge (provider VM) -> host tcp/9618 (HTCondor pool).
# nft rules carry the comment "w3node-libvirt" and `undo` also removes the rich rules it added.
#
# Usage:  sudo infrastructure/scripts/libvirt-docker-firewall.sh [apply|undo|status]
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo -- "$0" "$@"
TAG="w3node-libvirt"
VK_PORT="${VK_PORT:-5820}"
POOL_PORT="${POOL_PORT:-9618}"
METRICS_PORTS="${METRICS_PORTS:-9100 9101}"
MINIKUBE_BRIDGES="${MINIKUBE_BRIDGES:-}"   # default: every libvirt bridge except virbr0 (the 'default' NAT network)
action="${1:-apply}"

bridges() { ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^virbr[0-9]+$' || true; }
subnet_of() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1; }   # e.g. 192.168.122.1/24
net_of() { python3 -c 'import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)' "$1"; }
have_rule() { nft -a list chain "$1" "$2" "$3" 2>/dev/null | grep -q "$4"; }

apply() {
  command -v nft >/dev/null || { echo "nft not found" >&2; exit 1; }
  if nft list chain ip filter DOCKER-USER >/dev/null 2>&1; then
    for br in $(bridges); do
      net="$(net_of "$(subnet_of "$br")")"
      if ! have_rule ip filter DOCKER-USER "iifname \"$br\" ip saddr $net accept"; then
        nft insert rule ip filter DOCKER-USER iifname "$br" ip saddr "$net" counter accept comment "\"$TAG\""
        nft insert rule ip filter DOCKER-USER oifname "$br" ip daddr "$net" ct state established,related counter accept comment "\"$TAG\""
        echo "forwarding allowed for $br ($net)"
      fi
    done
  else
    echo "No Docker DOCKER-USER chain found; skipping forwarding rules (nothing to fix on this host)."
  fi
  # Remove the (ineffective) nft rule an earlier version added to libvirt's forward-path chain.
  remove_tagged ip libvirt_network guest_output
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for br in $(bridges); do
      net="$(net_of "$(subnet_of "$br")")"
      if [[ "$br" == virbr0 ]]; then ports="$POOL_PORT"; else ports="$VK_PORT $METRICS_PORTS"; fi
      for p in $ports; do
        rule="rule family=ipv4 source address=$net port port=$p protocol=tcp accept"
        firewall-cmd --zone=libvirt --query-rich-rule="$rule" >/dev/null 2>&1 || firewall-cmd --zone=libvirt --add-rich-rule="$rule" >/dev/null
        echo "firewalld: $net ($br) -> host tcp/$p allowed"
      done
    done
  else
    echo "firewalld not running; skipping zone rules."
  fi
}

remove_tagged() {  # $1 family $2 table $3 chain
  nft -a list chain "$1" "$2" "$3" 2>/dev/null | awk -v t="$TAG" '$0 ~ t {print $NF}' | while read -r h; do
    nft delete rule "$1" "$2" "$3" handle "$h" && echo "removed nft rule handle $h from $3"
  done
}

undo() {
  remove_tagged ip filter DOCKER-USER
  remove_tagged ip libvirt_network guest_output
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for br in $(bridges); do
      net="$(net_of "$(subnet_of "$br")")"
      if [[ "$br" == virbr0 ]]; then ports="$POOL_PORT"; else ports="$VK_PORT $METRICS_PORTS"; fi
      for p in $ports; do
        rule="rule family=ipv4 source address=$net port port=$p protocol=tcp accept"
        firewall-cmd --zone=libvirt --remove-rich-rule="$rule" >/dev/null 2>&1 && echo "removed firewalld rule: $net tcp/$p"
      done
    done
  fi
}

case "$action" in
  apply)  apply ;;
  undo)   undo ;;
  status) nft -a list chain ip filter DOCKER-USER 2>/dev/null | grep "$TAG" || echo "no $TAG rules in DOCKER-USER"
          firewall-cmd --zone=libvirt --list-rich-rules 2>/dev/null || true ;;
  *) echo "Usage: $0 [apply|undo|status]" >&2; exit 2 ;;
esac
