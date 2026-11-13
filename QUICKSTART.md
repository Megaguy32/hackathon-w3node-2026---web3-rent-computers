# Quickstart

Three paths, from cheapest to most complete.

| Path | Time | Needs |
|---|---|---|
| **A. Verify the code** | 5 min | Go, Python, (Foundry or Docker) |
| **B. Full demo on one Linux laptop** | ~1 h first time, then ~90 s per session | KVM, Docker, libvirt, a Sepolia wallet |
| **C. Real multi-host deployment** | hours | separate pool host, providers, consumer: see [marketplace-v2/docs/MANUAL_DEPLOYMENT.md](marketplace-v2/docs/MANUAL_DEPLOYMENT.md) |

## A. Verify the code (no infrastructure)

```bash
git clone https://github.com/Megaguy32/hackathon-w3node-2026---web3-rent-computers && cd hackathon-w3node-2026---web3-rent-computers

# Go tests + vet, 14 plugin-patcher tests, JS/shell/YAML syntax
(cd marketplace-v2 && ./scripts/check.sh)

# Contract tests (Foundry). Without a local install, prefix with:
#   docker run --rm -v "$PWD":/w -w /w --entrypoint forge ghcr.io/foundry-rs/foundry:stable
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std && forge test -vv          # ComputerRWA, 11 tests
git clone --depth 1 https://github.com/foundry-rs/forge-std marketplace-v2/contracts/lib/forge-std
(cd marketplace-v2/contracts && forge test -vv)                                                       # marketplace contract, 7 tests
```

## B. Full demo on one Linux laptop

Everything runs locally: a Minikube (KVM) consumer cluster, a Docker-composed pool host, and provider machines (the pool container itself plus KVM VMs), against **Ethereum Sepolia**.

### Requirements
- Linux x86-64 with virtualization (`/dev/kvm`), 16 GB RAM or more, ~40 GB free disk. Verified on Arch Linux (KDE).
- Docker with the compose plugin; libvirt + QEMU (`virsh -c qemu:///system list` works); your user in the `docker` and `libvirt` groups.
- `git`, `make`, `go` (builds interLink), `python3`, and `minikube`, `kubectl`, `helm` on your `PATH`.
- A MetaMask account with ~0.05 Sepolia ETH (from any Sepolia faucet) and a Sepolia RPC URL (a public one works; a free Alchemy/Infura key is more reliable).

### 1. Configure
```bash
cd marketplace-v2
cp .demo-laptop.single-laptop.env.example .demo-laptop.env     # edit GRAFANA_ADMIN_PASSWORD; paths use $HOME
cp .sepolia-rehearsal.env.example .sepolia-rehearsal.env       # THROWAWAY keys only; git-ignored
```
Create two throwaway keypairs (deployer, provider) and put the keys in `.sepolia-rehearsal.env` (`PRIVATE_KEY`, `PROVIDER_PRIVATE_KEY`), their addresses
in `DEPLOYER_ADDRESS` / `PROVIDER_ADDRESS`, your MetaMask address in `CONSUMER_ADDRESS`, and your RPC in `SEPOLIA_RPC_URL`:
```bash
docker run --rm --entrypoint cast ghcr.io/foundry-rs/foundry:stable wallet new      # run twice
```
Send ~0.003 Sepolia ETH to each of the two new addresses from MetaMask.

### 2. Deploy the contract
`contracts/deploy-sepolia.sh` uses `forge script`, which simulates against the RPC and can fail with *"block not found"* on load-balanced public RPCs.
Deploying with `forge create` is more robust. Note that Sepolia charges ~7.5M gas to create this contract (fees are still tiny), so give it a high limit:
```bash
git clone --depth 1 https://github.com/foundry-rs/forge-std contracts/lib/forge-std
set -a; . ./.sepolia-rehearsal.env; set +a
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e PRIVATE_KEY -e SEPOLIA_RPC_URL -v "$PWD/contracts:/w" -w /w --entrypoint sh \
  ghcr.io/foundry-rs/foundry:stable -c 'forge create src/ComputeMarketplace.sol:ComputeMarketplace --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --gas-limit 9000000'
```
It prints `Deployed to: 0x…` and a transaction hash. **Check the receipt status is `0x1`** (a failed deployment still prints an address) and note its block:
```bash
docker run --rm -e SEPOLIA_RPC_URL --entrypoint sh ghcr.io/foundry-rs/foundry:stable -c 'cast receipt <TX_HASH> --rpc-url "$SEPOLIA_RPC_URL" status blockNumber'
```
Add `CONTRACT_ADDRESS=0x…` and `START_BLOCK=<blockNumber>` to `.sepolia-rehearsal.env`.

### 3. Build the infrastructure (first time only)
```bash
./scripts/demo-laptop.sh doctor              # checks KVM/libvirt/tools
./scripts/demo-laptop.sh install-deps        # installs missing packages (asks for sudo); log out/in if group membership changed
./scripts/demo-laptop.sh up                  # Minikube (KVM2) cluster "w3node-demo"
./scripts/demo-laptop.sh monitoring          # Prometheus + Grafana + the W3Node dashboard
./scripts/demo-laptop.sh provider-up         # Ubuntu provider VM: HTCondor, Apptainer, node exporter (cloud-init)
./scripts/demo-up.sh                         # builds + starts the pool host, tunnels, interLink; asks for sudo once for firewall rules
```
`demo-up.sh` builds interLink on its first run and ends with a preflight; every line should read `OK`.

### 4. List, rent, run
```bash
./scripts/chain-actions.sh publish w3node-provider      # the provider lists the VM (machine name = its hostname); prints the listing ID
./scripts/chain-actions.sh publish "$(hostname -s)"     # optional: also list the pool container itself as a provider
```
Open **http://localhost:8090** and click **Rent** on a listing (MetaMask, Sepolia, 0.001 ETH). The rental appears with its ID after ~20 s. Then:
```bash
./scripts/demo-laptop.sh run <RENTAL_ID> load           # a Pod on the rented machine ('demo' is a quick hello-world)
./scripts/demo-laptop.sh logs w3node-compute-load       # "Rental ID: … on <machine>"
```
Watch it: **Live view** http://localhost:8090/live · **Grafana** http://localhost:3000 · optional **Cockpit** (`https://localhost:9090`) for the VMs.

### 5. Every session / after a reboot
```bash
./scripts/demo-up.sh            # idempotent; ~90 s from a fully stopped stack
./scripts/demo-preflight.sh     # read-only readiness check
./scripts/demo-down.sh          # stop (add --all to also stop Minikube and the provider VM)
```
Optional extras: `./scripts/provider-vm.sh golden` makes a golden image so `provider-vm.sh create <name>` boots a new provider in ~25 s; the scripted, recorded demo is in [marketplace-v2/demo/README.md](marketplace-v2/demo/README.md).

### 6. Clean up
```bash
./scripts/chain-actions.sh deactivate <LISTING_ID>        # unlist (repeat per listing)
./scripts/demo-down.sh --all && minikube delete -p w3node-demo
sudo infrastructure/scripts/libvirt-docker-firewall.sh undo     # remove the runtime firewall rules
```

## Troubleshooting (every one of these happened)

| Symptom | Cause and fix |
|---|---|
| Provider VM has no internet; `kubectl logs` says *connection refused* | Docker's `FORWARD` policy is DROP and firewalld's `libvirt` zone rejects VM-to-host traffic. `demo-up.sh` applies `infrastructure/scripts/libvirt-docker-firewall.sh` (runtime-only; re-applied each session) |
| `forge script` fails with *block not found* | Load-balanced public RPC. Use `forge create` (step 2) or a dedicated RPC key |
| Deployment "succeeds" but the contract has no code | Out of gas: Sepolia needs ~7.5M gas. Raise `--gas-limit` and check the receipt status |
| Pod stays Pending / ContainerCreating | The Pod requests more CPUs than the provider has (`examples/compute-pod-load.yaml` asks for 2), or the rental is expired/unknown (the plugin returns HTTP 403) |
| Provider tile shows Offline | The listing's machine name does not match the HTCondor `Machine` name, or the VM is not in the pool (`docker exec w3pool condor_status`) |
| `apptainer exec` fails with *Operation not permitted* on Ubuntu 24.04+ | AppArmor blocks unprivileged user namespaces. The cloud-init and `configure-provider.sh` install the profile |
| Provider re-joins slowly after the pool restarts | HTCondor's default re-advertise interval is 5 minutes; the provider templates set 20 s |
| MetaMask will not connect | It must be on **Sepolia** (chain 11155111); the UI switches networks only to that chain |
| Grafana provider CPU/RAM panels empty | Set `PROVIDER_METRICS_TARGETS` (host exporter and provider VM IPs, `:9100`) and re-run `./scripts/demo-laptop.sh monitoring` |

## Tested on

Every piece above runs on real infrastructure (Arch Linux, Docker, libvirt, Minikube KVM2, Sepolia). A cold `demo-up.sh` from a fully stopped stack reaches a
green preflight in about 90 s. Rehearse the full path once on your own machine before a live session, and keep the recorded demo as a backup.
