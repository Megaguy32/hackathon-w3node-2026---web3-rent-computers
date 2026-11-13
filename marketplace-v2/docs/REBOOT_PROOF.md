# Reboot-proof demo

After a reboot (or from cold), one command brings the whole stack back:

```bash
./scripts/demo-up.sh          # add --skip-firewall to leave the firewall helper alone, --no-build to reuse images
./scripts/demo-preflight.sh   # re-check at any time (demo-up runs it at the end)
./scripts/demo-down.sh        # stop the stack (--all also stops Minikube and the provider VM)
```

## What comes back on its own, and what demo-up does

| Piece | Mechanism |
|---|---|
| Docker, libvirt, firewalld | socket-activated / enabled by the distro |
| Pool host (HTCondor + patched plugin + marketplace), sshd, node exporter | `infrastructure/docker/compose.yaml`, `restart: unless-stopped`; images built from the repo (base pinned by digest, plugin pinned to a commit) |
| Minikube (KVM2) | `demo-up.sh` runs `minikube start` (idempotent) |
| Provider VM | `demo-up.sh` starts it and waits until it registers in the pool (providers re-advertise every 20 s) |
| interLink API, virtual kubelet, SSH tunnel | `demo-up.sh` -> `demo-laptop.sh connect` (pidfiles verify the process, so a recycled PID after reboot is never signalled) |
| Libvirt/Docker firewall rules (runtime-only) | `demo-up.sh` re-applies `infrastructure/scripts/libvirt-docker-firewall.sh` with sudo if missing |
| Grafana access | `demo-up.sh` starts the port-forward |
| Chain state (listings, rentals) | re-indexed from `START_BLOCK`; the contract and listings live on Sepolia |

State lives in `~/.local/state/w3node`, interLink in `~/src/interLink`; nothing important is in `/tmp`.

## Measured (rehearsal host)

- First run, including building the images: ~8.5 min.
- Cold bring-up with everything stopped (both VMs shut off, no containers): **93 s** to a green preflight.
- Placement test on the compose stack: workloads ran on `zenshin` (container provider) and on the KVM provider VM.

## Acceptance test (do this once for real)

1. Reboot the machine. 2. `./scripts/demo-up.sh` (enter your sudo password when asked). 3. Preflight is green.
4. Rent once with MetaMask and run `./scripts/demo-laptop.sh run <id> load`. Repeat the whole thing a second time.
