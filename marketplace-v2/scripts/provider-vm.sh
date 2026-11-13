#!/usr/bin/env bash
# Fast provider VMs from a golden image: boot a fully provisioned provider (HTCondor + Apptainer + exporter)
# in seconds instead of waiting for a first-boot package install.
#
#   ./scripts/provider-vm.sh golden            turn the current provider VM into a golden image (briefly reboots it)
#   ./scripts/provider-vm.sh create <name>     clone a new provider VM (name: w3node-provider-<suffix>); waits until it is in the pool
#   ./scripts/provider-vm.sh delete <name>     remove a clone created by this script
#   ./scripts/provider-vm.sh list              list provider VMs
#
# A clone's hostname is its HTCondor Machine name: publish a listing with exactly that name.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
ENV_FILE="${DEMO_ENV_FILE:-$ROOT/.demo-laptop.env}"; [[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
STATE="${DEMO_STATE_DIR:-$HOME/.local/state/w3node}"
IMG_DIR="${PROVIDER_VM_DIR:-/var/lib/libvirt/images/w3node}"
GOLDEN="$IMG_DIR/golden-provider.qcow2"
BASE_VM="${PROVIDER_VM_NAME:-w3node-provider}"
KEY="$STATE/provider/provider_ed25519"
VM_USER="${PROVIDER_VM_USER:-demo}"
POOL="${POOL_HOSTNAME:?Set POOL_HOSTNAME in .demo-laptop.env}"
CLONE_MEM="${CLONE_VM_MEMORY:-2048}"; CLONE_CPUS="${CLONE_VM_CPUS:-2}"
log() { printf '\033[1;36m[provider-vm]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
virsh_() { virsh -c qemu:///system "$@"; }
vmip() { virsh_ domifaddr "$1" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1; }
vmssh() { local ip; ip="$(vmip "$1")"; shift; ssh -F /dev/null -i "$KEY" -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/vm_known_hosts" -o ConnectTimeout=5 "$VM_USER@$ip" "$@"; }
qemu_owner() { getent passwd libvirt-qemu >/dev/null && echo libvirt-qemu || echo qemu; }
valid_clone() { [[ "$1" =~ ^w3node-provider-[a-z0-9]+$ ]] || die "clone names must look like w3node-provider-<letters/digits>"; }

cmd_golden() {
  virsh_ dominfo "$BASE_VM" >/dev/null 2>&1 || die "Base VM $BASE_VM does not exist (run ./scripts/demo-laptop.sh provider-up first)."
  virsh_ domstate "$BASE_VM" | grep -q running || virsh_ start "$BASE_VM" >/dev/null
  log "Waiting for $BASE_VM to answer SSH"; for _ in $(seq 1 40); do vmssh "$BASE_VM" true 2>/dev/null && break; sleep 3; done
  log "Removing identity and runtime state from $BASE_VM (cloud-init state, machine-id, condor logs/spool)"
  vmssh "$BASE_VM" 'sudo systemctl stop condor prometheus-node-exporter; \
    sudo rm -rf /var/log/condor/* /var/lock/condor/* /var/lib/condor/spool/* /var/lib/condor/execute/* 2>/dev/null; \
    sudo cloud-init clean --logs --machine-id; sudo apt-get clean; sudo journalctl --rotate >/dev/null 2>&1; sudo journalctl --vacuum-time=1s >/dev/null 2>&1; \
    sudo shutdown -h now' || true
  log "Waiting for shutdown"; for _ in $(seq 1 40); do virsh_ domstate "$BASE_VM" | grep -q 'shut off' && break; sleep 3; done
  virsh_ domstate "$BASE_VM" | grep -q 'shut off' || die "$BASE_VM did not shut down"
  log "Flattening the disk into the golden image (this reads the whole backing chain)"
  sudo rm -f "$GOLDEN"
  sudo qemu-img convert -O qcow2 "$IMG_DIR/${BASE_VM}.qcow2" "$GOLDEN"
  sudo chown "$(qemu_owner):$(id -gn "$(qemu_owner)")" "$GOLDEN"; sudo chmod 0640 "$GOLDEN"
  log "Golden image: $(sudo du -h "$GOLDEN" | cut -f1) at $GOLDEN"
  log "Restarting $BASE_VM (it re-initialises itself from its original seed)"
  virsh_ start "$BASE_VM" >/dev/null
}

cmd_create() {
  local name="${1:?Usage: $0 create <name>}"; valid_clone "$name"
  sudo test -f "$GOLDEN" || die "No golden image yet; run: $0 golden"
  virsh_ dominfo "$name" >/dev/null 2>&1 && die "VM $name already exists"
  local dir="$STATE/provider/$name"; mkdir -p "$dir"
  local disk="$IMG_DIR/${name}.qcow2" t0=$SECONDS
  sudo qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$disk"
  sudo chown "$(qemu_owner):$(id -gn "$(qemu_owner)")" "$disk"; sudo chmod 0640 "$disk"
  cat > "$dir/user-data" <<CLOUD
#cloud-config
hostname: ${name}
manage_etc_hosts: true
users:
  - default
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
package_update: false
write_files:
  - path: /etc/condor/config.d/01-w3node-provider.conf
    permissions: '0644'
    content: |
      CONDOR_HOST = ${POOL}
      COLLECTOR_HOST = \$(CONDOR_HOST):9618
      CCB_ADDRESS = \$(COLLECTOR_HOST)
      USE_SHARED_PORT = True
      SINGULARITY = /usr/bin/apptainer
      DAEMON_LIST = MASTER, STARTD, SHARED_PORT
      UPDATE_INTERVAL = 20
      SEC_DEFAULT_AUTHENTICATION = OPTIONAL
      SEC_DEFAULT_AUTHENTICATION_METHODS = CLAIMTOBE
      ALLOW_READ = *
      ALLOW_WRITE = *
      ALLOW_NEGOTIATOR = *
      ALLOW_DAEMON = *
runcmd:
  - [apparmor_parser, -r, /etc/apparmor.d/apptainer]
  - [systemctl, enable, --now, prometheus-node-exporter]
  - [systemctl, restart, condor]
CLOUD
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$name" "$(date +%s)" "$name" > "$dir/meta-data"
  log "Creating $name from the golden image"
  virt-install --connect qemu:///system --name "$name" --memory "$CLONE_MEM" --vcpus "$CLONE_CPUS" \
    --disk "path=$disk,format=qcow2,bus=virtio" --osinfo detect=on,require=off --network network=default,model=virtio \
    --cloud-init "user-data=$dir/user-data,meta-data=$dir/meta-data" --graphics none --import --noautoconsole >/dev/null 2>&1
  log "Booting; waiting for $name to register in the pool"
  local booted=0
  for _ in $(seq 1 120); do
    if ((!booted)) && [[ -n "$(vmip "$name")" ]]; then booted=$((SECONDS - t0)); log "got an IP after ${booted}s"; fi
    if docker exec w3pool condor_status -af Machine 2>/dev/null | grep -qx "$name"; then
      log "$name is in the pool after $((SECONDS - t0))s"; echo "$name"; return
    fi
    sleep 2
  done
  die "$name did not register in the pool within 4 minutes"
}

cmd_delete() {
  local name="${1:?Usage: $0 delete <name>}"; valid_clone "$name"
  virsh_ destroy "$name" >/dev/null 2>&1 || true
  virsh_ undefine "$name" --nvram >/dev/null 2>&1 || virsh_ undefine "$name" >/dev/null 2>&1 || true
  sudo rm -f "$IMG_DIR/${name}.qcow2"; rm -rf "$STATE/provider/$name"
  log "removed $name"
}

case "${1:-}" in
  golden) cmd_golden ;;
  create) shift; cmd_create "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  list)   virsh_ list --all | grep -E "Name|w3node" ;;
  *) sed -n 2,11p "$0"; exit 2 ;;
esac
