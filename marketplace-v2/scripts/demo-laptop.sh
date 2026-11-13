#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
ENV_FILE="${DEMO_ENV_FILE:-$ROOT/.demo-laptop.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PROFILE="${MINIKUBE_PROFILE:-w3node-demo}"
CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-8192}"
DISK_SIZE="${MINIKUBE_DISK_SIZE:-30g}"
DRIVER="${MINIKUBE_DRIVER:-kvm2}"
INTERLINK_DIR="${INTERLINK_DIR:-$HOME/src/interLink}"
INTERLINK_REF="${INTERLINK_REF:-main}"
MARKETPLACE_UI_LOCAL_PORT="${MARKETPLACE_UI_LOCAL_PORT:-8080}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-w3node-demo}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"
PROVIDER_VM_NAME="${PROVIDER_VM_NAME:-w3node-provider}"
PROVIDER_VM_USER="${PROVIDER_VM_USER:-demo}"
PROVIDER_VM_CPUS="${PROVIDER_VM_CPUS:-4}"
PROVIDER_VM_MEMORY="${PROVIDER_VM_MEMORY:-4096}"
PROVIDER_VM_DISK_SIZE="${PROVIDER_VM_DISK_SIZE:-25G}"
UBUNTU_CLOUD_IMAGE_URL="${UBUNTU_CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img}"

STATE_DIR="${DEMO_STATE_DIR:-$ROOT/.demo-state}"
LOG_DIR="$STATE_DIR/logs"
PID_DIR="$STATE_DIR/pids"
RENDER_DIR="$STATE_DIR/manifests"
mkdir -p "$LOG_DIR" "$PID_DIR" "$RENDER_DIR"

log() { printf '\n\033[1;36m[W3Node demo]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warning]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. Run '$0 install-deps' or install it manually."; }

usage() {
  cat <<USAGE
W3Node local demo helper

Usage: $0 <command> [args]

Laptop consumer cluster (KVM2 Minikube):
  doctor                 Check KVM/libvirt and required local tools
  install-deps           Install common prerequisites (Arch or Debian/Ubuntu)
  up                     Create/start the KVM-based Minikube consumer cluster
  build-interlink        Clone/build interLink binaries (interlink, vk, ssh-tunnel)
  connect                Start SSH socket tunnel, interLink API and Virtual Kubelet
  prepare                Run up, build-interlink and connect in sequence
  disconnect             Stop laptop-side interLink/tunnel processes
  marketplace-ui         SSH-forward the remote marketplace UI to localhost:${MARKETPLACE_UI_LOCAL_PORT}
  run <rental-id> [demo|load]  Render and apply a Pod for the rental ('load' burns CPU/RAM for Grafana)
  status                 Show Minikube, virtual node and demo Pod status
  logs [pod]             Fetch demo Pod logs
  watch                  Watch Pod status (Ctrl-C to stop)
  monitoring             Install optional kube-prometheus-stack + W3Node dashboard
  grafana                Port-forward Grafana to localhost:${GRAFANA_LOCAL_PORT}
  down                   Stop interLink processes and Minikube (retain cluster)
  destroy                Delete the Minikube profile and local state (confirmation required)

Optional local provider VM (joins your existing remote HTCondor pool via CCB):
  provider-up            Create Ubuntu KVM guest and configure HTCondor + Apptainer
  provider-ip            Print the provider VM's DHCP address
  provider-ssh           SSH into the provider VM
  provider-status        Show HTCondor registration and Apptainer ClassAds
  provider-down          Stop and undefine the provider VM (retains disk)

Configuration:
  Copy .demo-laptop.env.example to .demo-laptop.env and edit it.
  This script sets up the laptop-side consumer cluster. It expects an existing
  Marketplace/HTCondor pool host and a patched HTCondor plugin reachable over SSH.
  The optional provider VM runs locally but joins that existing remote pool.

Logs and PID files: $LOG_DIR and $PID_DIR
USAGE
}

check_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "KVM provider image helper currently targets x86_64; detected $(uname -m). Minikube KVM2 may support other architectures separately." ;;
  esac
}

cmd_doctor() {
  log "Host and tool checks"
  printf 'OS: '; . /etc/os-release 2>/dev/null && printf '%s %s\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
  printf 'Architecture: %s\n' "$(uname -m)"
  if grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then echo 'CPU virtualization extensions: present'; else warn 'No vmx/svm flag found in /proc/cpuinfo'; fi
  [[ -e /dev/kvm ]] && echo '/dev/kvm: present' || warn '/dev/kvm missing; enable virtualization in firmware and load kvm modules.'
  for c in virsh virt-host-validate minikube kubectl git make go ssh curl python3; do
    if command -v "$c" >/dev/null 2>&1; then printf '%-22s %s\n' "$c" "$(command -v "$c")"; else warn "$c not installed"; fi
  done
  if command -v helm >/dev/null 2>&1; then echo "helm: $(command -v helm)"; else warn 'helm not installed (only required for optional Grafana stack)'; fi
  if command -v virt-host-validate >/dev/null 2>&1; then
    echo
    virt-host-validate qemu || warn 'virt-host-validate reported one or more issues; inspect the messages above.'
  fi
  if command -v virsh >/dev/null 2>&1; then
    echo
    virsh -c qemu:///system list --all || warn 'Cannot access qemu:///system. Start libvirt and ensure your user has the appropriate group permissions.'
  fi
  echo
  if id -nG "$USER" 2>/dev/null | grep -Eq '(^| )(libvirt|libvirt-qemu)( |$)'; then
    echo 'libvirt group membership: detected'
  else
    warn 'Your user is not visibly in the libvirt group. On Arch, add yourself with: sudo usermod -aG libvirt "$USER" (then log out/in).'
  fi
  echo
  echo 'Configuration file:'
  [[ -f "$ENV_FILE" ]] && echo "$ENV_FILE" || echo "Missing $ENV_FILE (copy .demo-laptop.env.example first)."
}

install_minikube_binary() {
  local bin_dir="$HOME/.local/bin" arch
  mkdir -p "$bin_dir"
  arch="$(uname -m)"; [[ "$arch" == x86_64 ]] && arch=amd64
  curl -fsSL "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$arch" -o "$bin_dir/minikube"
  chmod +x "$bin_dir/minikube"
  case ":$PATH:" in *":$bin_dir:"*) ;; *) warn "Add $bin_dir to PATH." ;; esac
}

install_kubectl_binary() {
  local bin_dir="$HOME/.local/bin" arch version
  mkdir -p "$bin_dir"
  arch="$(uname -m)"; [[ "$arch" == x86_64 ]] && arch=amd64
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl" -o "$bin_dir/kubectl"
  chmod +x "$bin_dir/kubectl"
}

install_helm_binary() {
  local bin_dir="$HOME/.local/bin" arch version tmp
  mkdir -p "$bin_dir"
  arch="$(uname -m)"; [[ "$arch" == x86_64 ]] && arch=amd64
  version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)"
  [[ "$version" == v* ]] || die "Could not determine latest Helm release tag: $version"
  tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-${version}-linux-${arch}.tar.gz" -o "$tmp/helm.tgz"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  install -m 0755 "$tmp/linux-${arch}/helm" "$bin_dir/helm"
  rm -rf "$tmp"
}

cmd_install_deps() {
  check_arch
  [[ -r /etc/os-release ]] || die 'Cannot identify this Linux distribution.'
  . /etc/os-release
  case "${ID:-unknown}" in
    arch|endeavouros|manjaro)
      need pacman
      sudo pacman -Syu --needed qemu-full libvirt virt-install dnsmasq iptables-nft git make go openssh curl jq python
      sudo systemctl enable --now libvirtd.service || true
      sudo usermod -aG libvirt "$USER" || true
      ;;
    ubuntu|debian|linuxmint|pop)
      need apt-get
      sudo apt-get update
      sudo apt-get install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst dnsmasq-base git make golang-go openssh-client curl jq python3 python3-yaml
      sudo systemctl enable --now libvirtd.service || true
      sudo usermod -aG libvirt "$USER" || true
      ;;
    fedora)
      sudo dnf install -y @virtualization qemu-kvm qemu-img libvirt virt-install dnsmasq git make golang openssh-clients curl jq python3
      sudo systemctl enable --now libvirtd.service || true
      sudo usermod -aG libvirt "$USER" || true
      ;;
    *) die "Unsupported distribution: ${ID:-unknown}. Install QEMU/KVM, libvirt, minikube, kubectl, Go, Git, SSH and curl manually." ;;
  esac
  if ! command -v minikube >/dev/null 2>&1; then install_minikube_binary; fi
  if ! command -v kubectl >/dev/null 2>&1; then install_kubectl_binary; fi
  if ! command -v helm >/dev/null 2>&1; then install_helm_binary; fi
  log 'Dependency installation attempted. Log out/in if your libvirt group membership changed, then run doctor.'
}

cmd_up() {
  need minikube; need kubectl; need virsh
  check_arch
  [[ -e /dev/kvm ]] || die '/dev/kvm is missing. Enable virtualization in firmware and ensure kvm_intel or kvm_amd is loaded.'
  virsh -c qemu:///system net-info default >/dev/null 2>&1 || {
    sudo virsh net-autostart default || true
    sudo virsh net-start default || true
  }
  log "Starting Minikube profile '$PROFILE' with driver '$DRIVER'"
  minikube start -p "$PROFILE" --driver="$DRIVER" --cpus="$CPUS" --memory="$MEMORY" --disk-size="$DISK_SIZE" --addons=metrics-server,storage-provisioner,default-storageclass
  minikube -p "$PROFILE" update-context
  kubectl config use-context "$PROFILE" >/dev/null
  kubectl --context "$PROFILE" wait --for=condition=Ready node --all --timeout=180s
  log 'Consumer Minikube cluster is ready.'
  kubectl --context "$PROFILE" get nodes -o wide
}

cmd_build_interlink() {
  need git; need make; need go
  if [[ ! -d "$INTERLINK_DIR/.git" ]]; then
    mkdir -p "$(dirname "$INTERLINK_DIR")"
    git clone https://github.com/interlink-hq/interLink.git "$INTERLINK_DIR"
  fi
  if [[ "$INTERLINK_REF" != "main" ]]; then git -C "$INTERLINK_DIR" fetch origin "$INTERLINK_REF"; git -C "$INTERLINK_DIR" checkout "$INTERLINK_REF"; else git -C "$INTERLINK_DIR" pull --ff-only origin main; fi
  git -C "$INTERLINK_DIR" submodule update --init --recursive
  log "Building interLink ($INTERLINK_REF)"
  make -C "$INTERLINK_DIR" all
  for binary in interlink vk; do
    [[ -x "$INTERLINK_DIR/bin/$binary" ]] || die "Expected binary not produced: $INTERLINK_DIR/bin/$binary. Check the upstream Makefile/build output."
  done
  log 'Built bin/interlink and bin/vk.'
}

pid_alive() { [[ -f "$PID_DIR/$1.pid" ]] && kill -0 "$(cat "$PID_DIR/$1.pid")" 2>/dev/null; }
start_bg() {
  local name="$1"; shift
  if pid_alive "$name"; then log "$name already running (PID $(cat "$PID_DIR/$name.pid"))."; return; fi
  local logfile="$LOG_DIR/$name.log"
  nohup "$@" >>"$logfile" 2>&1 </dev/null &
  echo "$!" > "$PID_DIR/$name.pid"
  sleep 2
  if ! kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
    tail -80 "$logfile" >&2 || true
    die "$name exited during startup. See $logfile"
  fi
  log "Started $name (PID $(cat "$PID_DIR/$name.pid")); log: $logfile"
}
stop_bg() {
  local name="$1" pidfile="$PID_DIR/$1.pid"
  if [[ -f "$pidfile" ]]; then
    local pid; pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    rm -f "$pidfile"
    log "Stopped $name."
  fi
}

cmd_prepare() {
  cmd_up
  cmd_build_interlink
  cmd_connect
  log 'Laptop consumer environment is prepared. Open the marketplace UI in another terminal, rent compute, then run: demo-laptop.sh run <rental-id>.'
}

cmd_connect() {
  need kubectl
  [[ -x "$INTERLINK_DIR/bin/interlink" && -x "$INTERLINK_DIR/bin/vk" ]] || die "Build interLink first: $0 build-interlink"
  if [[ "${TUNNEL_MODE:-local-forward}" == interlink-ssh-tunnel ]]; then
    [[ -x "$INTERLINK_DIR/bin/ssh-tunnel" ]] || die "TUNNEL_MODE=interlink-ssh-tunnel needs $INTERLINK_DIR/bin/ssh-tunnel"
  fi
  export TUNNEL_MODE="${TUNNEL_MODE:-local-forward}"
  : "${MARKETPLACE_SSH_ADDR:?Set MARKETPLACE_SSH_ADDR in .demo-laptop.env}"
  : "${MARKETPLACE_SSH_USER:?Set MARKETPLACE_SSH_USER in .demo-laptop.env}"
  : "${SSH_KEY:?Set SSH_KEY in .demo-laptop.env}"
  export INTERLINK_DIR
  export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
  export SSH_KEY="${SSH_KEY/#\~/$HOME}"
  [[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"
  [[ -z "${SSH_HOST_KEY_FILE:-}" ]] || export SSH_HOST_KEY_FILE="${SSH_HOST_KEY_FILE/#\~/$HOME}"
  minikube -p "$PROFILE" status >/dev/null 2>&1 || die "Minikube profile '$PROFILE' is not running. Run '$0 up'."
  stop_bg interlink-tunnel || true
  stop_bg interlink-vk || true
  rm -f /tmp/interlink.sock
  start_bg interlink-tunnel "$ROOT/consumer/interlink/start-ssh-tunnel.sh"
  # The API server must reach the VK's kubelet endpoint (kubectl logs/exec): advertise the
  # laptop address on the Minikube network as the virtual node's InternalIP.
  POD_IP="${POD_IP:-$(ip route get "$(minikube -p "$PROFILE" ip)" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)}"
  [[ -n "$POD_IP" ]] || warn 'Could not detect laptop IP on the Minikube network; set POD_IP in .demo-laptop.env.'
  export POD_IP
  start_bg interlink-vk "$ROOT/consumer/interlink/start-api-and-vk.sh"
  # Upstream VK requests a kubelet-serving certificate via CSR; approve it so kubectl logs works.
  for _ in $(seq 1 30); do
    csr="$(kubectl --context "$PROFILE" get csr -o name 2>/dev/null | grep vk-interlink || true)"
    [[ -n "$csr" ]] && { kubectl --context "$PROFILE" certificate approve $csr >/dev/null && log "Approved $csr"; break; }
    sleep 2
  done
  sleep 5
  kubectl --context "$PROFILE" get nodes -o wide
  if ! kubectl --context "$PROFILE" get node interlink-node >/dev/null 2>&1; then
    warn 'Virtual node not visible yet. Inspect logs/interlink-vk.log and logs/interlink-tunnel.log.'
  fi
}

cmd_disconnect() {
  stop_bg interlink-vk || true
  stop_bg interlink-tunnel || true
  rm -f /tmp/interlink.sock
}

cmd_marketplace_ui() {
  need ssh
  : "${MARKETPLACE_SSH_ADDR:?Set MARKETPLACE_SSH_ADDR in .demo-laptop.env}"
  : "${MARKETPLACE_SSH_USER:?Set MARKETPLACE_SSH_USER in .demo-laptop.env}"
  : "${SSH_KEY:?Set SSH_KEY in .demo-laptop.env}"
  local host port key
  host="${MARKETPLACE_SSH_ADDR%:*}"
  port="${MARKETPLACE_SSH_ADDR##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || port=22
  key="${SSH_KEY/#\~/$HOME}"
  log "Forwarding remote marketplace UI to http://127.0.0.1:${MARKETPLACE_UI_LOCAL_PORT}"
  exec ssh -i "$key" -p "$port" -N -L "${MARKETPLACE_UI_LOCAL_PORT}:127.0.0.1:8080" -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none -o ControlPersist=no "${MARKETPLACE_SSH_USER}@${host}"
}

cmd_run() {
  need kubectl; need python3
  local rental_id="${1:-}" workload="${2:-demo}" src pod
  [[ -n "$rental_id" ]] || die "Usage: $0 run <rental-id> [demo|load]"
  [[ "$rental_id" =~ ^[0-9]+$ ]] || die 'Rental ID must be a non-negative integer.'
  case "$workload" in
    demo) src="$ROOT/examples/compute-pod.yaml"; pod=w3node-compute-demo ;;
    load) src="$ROOT/examples/compute-pod-load.yaml"; pod=w3node-compute-load ;;
    *) die "Unknown workload '$workload' (use demo or load)." ;;
  esac
  local dst="$RENDER_DIR/${pod}-${rental_id}.yaml"
  RENTAL_ID="$rental_id" SOURCE_MANIFEST="$src" TARGET_MANIFEST="$dst" python3 - <<'PY'
import os, re, pathlib
source = pathlib.Path(os.environ['SOURCE_MANIFEST']).read_text()
pattern = r'(?m)^(\s*marketplace\.w3node\.io/rental-id:\s*)"[^"]*"(.*)$'
updated, count = re.subn(pattern, lambda m: f'{m.group(1)}"{os.environ["RENTAL_ID"]}"{m.group(2)}', source, count=1)
if count != 1:
    raise SystemExit('Could not find the rental ID annotation in the source Pod manifest.')
pathlib.Path(os.environ['TARGET_MANIFEST']).write_text(updated)
PY
  log "Applying workload for rental $rental_id"
  # A finished Pod with the same name would never be resubmitted, so start clean.
  kubectl --context "$PROFILE" delete pod "$pod" --ignore-not-found --wait=true
  kubectl --context "$PROFILE" apply -f "$dst"
  kubectl --context "$PROFILE" get pod "$pod" -o wide || true
  echo "Rendered manifest: $dst"
}

cmd_status() {
  minikube -p "$PROFILE" status || true
  kubectl --context "$PROFILE" get nodes -o wide || true
  kubectl --context "$PROFILE" get pods -A -o wide || true
}

cmd_logs() {
  need kubectl
  kubectl --context "$PROFILE" logs "${1:-w3node-compute-demo}" --all-containers=true
}

cmd_watch() {
  need kubectl
  kubectl --context "$PROFILE" get pods -A -w
}

cmd_monitoring() {
  need helm; need kubectl
  log 'Installing kube-prometheus-stack into the local Minikube consumer cluster.'
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  # PROVIDER_METRICS_TARGETS="host:9100,host2:9100": node_exporter endpoints on the rented provider
  # machines (the workload runs there, not in Minikube). They feed the dashboard's CPU/RAM panels.
  local values="$STATE_DIR/monitoring-values.yaml"
  PROVIDER_METRICS_TARGETS="${PROVIDER_METRICS_TARGETS:-}" python3 - "$values" <<'PY'
import os, sys
targets = [t.strip() for t in os.environ.get("PROVIDER_METRICS_TARGETS", "").split(",") if t.strip()]
lines = ["prometheus:", "  prometheusSpec:"]
if targets:
    lines += ["    additionalScrapeConfigs:", "      - job_name: w3node-provider", "        scrape_interval: 5s",
              "        static_configs:", "          - targets:"]
    lines += [f"              - '{t}'" for t in targets]
else:
    lines += ["    {}"]
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
  helm upgrade --install w3node-observability prometheus-community/kube-prometheus-stack \
    --kube-context "$PROFILE" --namespace monitoring --create-namespace -f "$values" \
    --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
    --set grafana.sidecar.dashboards.label=grafana_dashboard \
    --set-string grafana.sidecar.dashboards.labelValue=1 \
    --set grafana.service.type=ClusterIP
  kubectl --context "$PROFILE" apply -f "$ROOT/observability/kubernetes/w3node-dashboard-configmap.yaml"
  log 'Grafana and Prometheus are installed. Run the grafana command in another terminal.'
  echo "Grafana login: admin / value of GRAFANA_ADMIN_PASSWORD in .demo-laptop.env"
}

cmd_grafana() {
  need kubectl
  log "Forwarding Grafana to http://127.0.0.1:${GRAFANA_LOCAL_PORT} (Ctrl-C to stop)"
  exec kubectl --context "$PROFILE" -n monitoring port-forward svc/w3node-observability-grafana "${GRAFANA_LOCAL_PORT}:80"
}

provider_ip() {
  need virsh
  local mac
  mac="$(virsh -c qemu:///system domiflist "$PROVIDER_VM_NAME" 2>/dev/null | awk '$2 == "network" && $3 == "default" {print $5; exit}')"
  [[ -n "$mac" ]] || return 1
  virsh -c qemu:///system net-dhcp-leases default 2>/dev/null | awk -v mac="$mac" '$3 == mac {split($5, a, "/"); print a[1]; exit}'
}

cmd_provider_up() {
  need virsh; need virt-install; need qemu-img; need curl; need ssh-keygen
  : "${POOL_HOSTNAME:?Set POOL_HOSTNAME in .demo-laptop.env to your existing public HTCondor pool host}"
  virsh -c qemu:///system net-info default >/dev/null 2>&1 || die "libvirt's 'default' NAT network is not defined. Create/enable it before using the optional provider VM."
  local egress_ip
  egress_ip="$(curl -4 -fsS https://api.ipify.org || true)"
  warn "Before the guest can join, allowlist this laptop's public egress IP (${egress_ip:-unknown}) on the remote pool host's TCP/9618 firewall rule."
  if virsh -c qemu:///system dominfo "$PROVIDER_VM_NAME" >/dev/null 2>&1; then die "VM '$PROVIDER_VM_NAME' already exists. Use provider-status or provider-down first."; fi
  mkdir -p "$STATE_DIR/provider"
  local base="$STATE_DIR/provider/ubuntu-cloud.img" user_data="$STATE_DIR/provider/user-data" meta_data="$STATE_DIR/provider/meta-data" key="$STATE_DIR/provider/provider_ed25519"
  local provider_dir="${PROVIDER_VM_DIR:-/var/lib/libvirt/images/w3node}" disk="$provider_dir/${PROVIDER_VM_NAME}.qcow2" libvirt_base="$provider_dir/ubuntu-cloud.img"
  if [[ ! -f "$base" ]]; then
    log "Downloading Ubuntu cloud image: $UBUNTU_CLOUD_IMAGE_URL"
    curl -fL "$UBUNTU_CLOUD_IMAGE_URL" -o "$base"
  fi
  if [[ ! -f "$key" ]]; then ssh-keygen -q -t ed25519 -N '' -f "$key"; fi
  local pubkey
  pubkey="$(cat "$key.pub")"
  cat > "$user_data" <<CLOUD
#cloud-config
hostname: ${PROVIDER_VM_NAME}
manage_etc_hosts: true
users:
  - default
  - name: ${PROVIDER_VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${pubkey}
ssh_pwauth: false
package_update: true
apt:
  sources:
    ubuntu-universe:
      source: "deb http://archive.ubuntu.com/ubuntu \$RELEASE universe"
packages:
  - htcondor
  - apptainer
  - openssh-server
write_files:
  - path: /usr/local/bin/singularity
    permissions: '0755'
    content: |
      #!/bin/sh
      exec /usr/bin/apptainer "\$@"
  - path: /etc/condor/config.d/01-w3node-provider.conf
    permissions: '0644'
    content: |
      CONDOR_HOST = ${POOL_HOSTNAME}
      COLLECTOR_HOST = \$(CONDOR_HOST):9618
      CCB_ADDRESS = \$(COLLECTOR_HOST)
      USE_SHARED_PORT = True
      SINGULARITY = /usr/bin/apptainer
      DAEMON_LIST = MASTER, STARTD, SHARED_PORT
      SEC_DEFAULT_AUTHENTICATION = OPTIONAL
      SEC_DEFAULT_AUTHENTICATION_METHODS = CLAIMTOBE
      ALLOW_READ = *
      ALLOW_WRITE = *
      ALLOW_NEGOTIATOR = *
      ALLOW_DAEMON = *
runcmd:
  - [systemctl, enable, --now, ssh]
  - [systemctl, enable, --now, condor]
  - [systemctl, restart, condor]
final_message: "W3Node provider VM initialized."
CLOUD
  cat > "$meta_data" <<META
instance-id: ${PROVIDER_VM_NAME}
local-hostname: ${PROVIDER_VM_NAME}
META
  sudo install -d -m 0755 "$provider_dir"
  if ! sudo test -f "$libvirt_base"; then sudo install -m 0644 "$base" "$libvirt_base"; fi
  if ! sudo test -f "$disk"; then
    sudo qemu-img create -f qcow2 -F qcow2 -b "$libvirt_base" "$disk" "$PROVIDER_VM_DISK_SIZE"
  else
    log "Reusing existing provider overlay disk: $disk"
  fi
  local qemu_user="" qemu_group=""
  if getent passwd libvirt-qemu >/dev/null 2>&1; then qemu_user=libvirt-qemu; elif getent passwd qemu >/dev/null 2>&1; then qemu_user=qemu; fi
  if [[ -n "$qemu_user" ]]; then
    qemu_group="$(id -gn "$qemu_user")"
    sudo chown "$qemu_user:$qemu_group" "$libvirt_base" "$disk"
    sudo chmod 0640 "$libvirt_base" "$disk"
  else
    warn 'Could not identify the libvirt QEMU service account; verify it can read/write the provider VM image files.'
  fi
  sudo virsh -c qemu:///system net-start default >/dev/null 2>&1 || true
  sudo virsh -c qemu:///system net-autostart default >/dev/null 2>&1 || true
  virt-install --connect qemu:///system --name "$PROVIDER_VM_NAME" \
    --memory "$PROVIDER_VM_MEMORY" --vcpus "$PROVIDER_VM_CPUS" \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --osinfo detect=on,require=off --network network=default,model=virtio \
    --cloud-init "user-data=$user_data,meta-data=$meta_data" \
    --graphics none --console pty,target_type=serial --import --noautoconsole
  log 'Provider VM created. Waiting for DHCP lease and cloud-init.'
  for _ in $(seq 1 90); do
    local ip; ip="$(provider_ip || true)"
    if [[ -n "$ip" ]] && ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${PROVIDER_VM_USER}@${ip}" 'cloud-init status --wait >/dev/null 2>&1 && systemctl is-active --quiet condor' 2>/dev/null; then
      echo "Provider VM: ${PROVIDER_VM_USER}@${ip}"
      echo "SSH: ssh -i '$key' ${PROVIDER_VM_USER}@${ip}"
      echo "Public egress IP to allowlist on pool host: $(curl -4 -fsS https://api.ipify.org || echo unknown)"
      return
    fi
    sleep 5
  done
  warn 'The VM was created but did not become ready within the wait window. Inspect: virsh console and cloud-init status.'
  echo "Provider SSH key: $key"
}

cmd_provider_ip() {
  local ip; ip="$(provider_ip || true)"
  [[ -n "$ip" ]] || die 'Provider VM IP not found. Is the VM running and on libvirt default network?'
  echo "$ip"
}

cmd_provider_ssh() {
  local ip; ip="$(provider_ip || true)"
  [[ -n "$ip" ]] || die 'Provider VM IP not found.'
  exec ssh -i "$STATE_DIR/provider/provider_ed25519" -o StrictHostKeyChecking=accept-new "${PROVIDER_VM_USER}@${ip}"
}

cmd_provider_status() {
  local ip; ip="$(provider_ip || true)"
  [[ -n "$ip" ]] || die 'Provider VM IP not found.'
  ssh -i "$STATE_DIR/provider/provider_ed25519" -o StrictHostKeyChecking=accept-new "${PROVIDER_VM_USER}@${ip}" \
    'cloud-init status --long; systemctl is-active condor; apptainer --version; condor_status -af Machine Name State HasSingularity'
}

cmd_provider_down() {
  need virsh
  sudo virsh -c qemu:///system destroy "$PROVIDER_VM_NAME" >/dev/null 2>&1 || true
  sudo virsh -c qemu:///system undefine "$PROVIDER_VM_NAME" --nvram >/dev/null 2>&1 || sudo virsh -c qemu:///system undefine "$PROVIDER_VM_NAME" >/dev/null 2>&1 || true
  log "Provider VM undefined. Its disk and cloud image remain under $STATE_DIR/provider."
}

cmd_down() {
  cmd_disconnect || true
  if command -v minikube >/dev/null 2>&1; then minikube -p "$PROFILE" stop || true; fi
  log 'Minikube stopped; cluster data retained.'
}

cmd_destroy() {
  read -r -p "Delete Minikube profile '$PROFILE' and local demo state? [y/N] " answer
  [[ "$answer" == [yY] ]] || { log 'Cancelled.'; return; }
  cmd_disconnect || true
  minikube -p "$PROFILE" delete || true
  rm -rf "$LOG_DIR" "$PID_DIR" "$RENDER_DIR"
  log 'Minikube profile and consumer-side runtime state removed. Provider VM keys/cache are preserved so a stopped provider can be restarted.'
  echo "To remove provider VM data too: run provider-down, then remove $STATE_DIR/provider and ${PROVIDER_VM_DIR:-/var/lib/libvirt/images/w3node}."
}

command="${1:-help}"
shift || true
case "$command" in
  help|-h|--help) usage ;;
  doctor) cmd_doctor ;;
  install-deps) cmd_install_deps ;;
  up) cmd_up ;;
  build-interlink) cmd_build_interlink ;;
  connect) cmd_connect ;;
  prepare) cmd_prepare ;;
  disconnect) cmd_disconnect ;;
  marketplace-ui) cmd_marketplace_ui ;;
  run) cmd_run "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  watch) cmd_watch ;;
  monitoring) cmd_monitoring ;;
  grafana) cmd_grafana ;;
  provider-up) cmd_provider_up ;;
  provider-ip) cmd_provider_ip ;;
  provider-ssh) cmd_provider_ssh ;;
  provider-status) cmd_provider_status ;;
  provider-down) cmd_provider_down ;;
  down) cmd_down ;;
  destroy) cmd_destroy ;;
  *) usage >&2; die "Unknown command: $command" ;;
esac
