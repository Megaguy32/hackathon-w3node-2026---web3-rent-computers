# Demo runbook

Verification status as of 2026-11-13 (see "What was and was not verified").

## Pre-demo checklist (do the day before)

1. Deploy the contract to Sepolia: `SEPOLIA_RPC_URL=... PRIVATE_KEY=... contracts/deploy-sepolia.sh`
   Note the printed `CONTRACT_ADDRESS` and `START_BLOCK`.
2. Pool host: `infrastructure/scripts/install-marketplace-host.sh`, then set
   `RPC_URL`, `CONTRACT_ADDRESS`, `START_BLOCK` in the env file. Pin the plugin:
   `PLUGIN_REF=5f9ecdb2d213932eb5c72b7f975ec405ad4548d4 plugin/install-plugin.sh`
   (the commit the patcher was verified against), and set the repo variable
   `UPSTREAM_PLUGIN_REF` to the same SHA.
3. Provider: register the machine (`configure-provider.sh` or `provider-up`), confirm
   `condor_status -af Machine HasApptainer` on the pool host shows it.
4. Laptop: `cp .demo-laptop.env.example .demo-laptop.env`, edit, then
   `./scripts/demo-laptop.sh install-deps && ./scripts/demo-laptop.sh prepare`.
   Missing on the rehearsal laptop: minikube, kubectl, helm.
5. Dry-run the tunnel once (`TUNNEL_MODE=local-forward` is the default) and check
   `curl http://127.0.0.1:4000/system-info` from the laptop.
6. Register a listing for the provider machine, rent it from a second wallet, and run
   `./scripts/demo-laptop.sh run <rental-id>` end to end once before presenting.

## Live sequence

1. Show marketplace UI (`marketplace-ui`), listing + node table.
2. Rent the listing in the wallet; the rental row appears with its pod annotation.
3. `./scripts/demo-laptop.sh run <rental-id>`; `watch`; `logs`.
4. Show the job ran on the rented machine (`condor_history -af RentalId LastRemoteHost`).
5. Optional negative demo: submit with a bogus or expired rental ID, expect HTTP 403.
6. Optional: `monitoring` and `grafana`.

## What was and was not verified

Verified locally (rehearsal harness, not the real topology):

- `scripts/check.sh` (Go tests, vet, 14 Python tests, JS/shell/YAML syntax).
- `forge test`: 7/7 contract tests pass (Foundry stable, solc 0.8.24).
- Patcher applies cleanly to upstream `interlink-htcondor-plugin` at 5f9ecdb and the
  patched `handles.py` compiles and serves `/create` (Flask, fake `condor_submit`).
  Valid rental -> 200; expired, unknown, malformed, missing annotation -> 403;
  host-image second container -> 400.
- Deployed the real contract to Anvil, created/updated listings, rented; the Go
  backend indexed `ListingCreated`, `ListingUpdated`, `RentalCreated` and wrote a
  `rentals.json` the plugin accepted.
- Real HTCondor 25.13 (`htcondor/mini`): the generated submit file pinned to a
  nonexistent machine stayed idle (0 matches); pinned to the existing machine it ran
  and completed, with `RentalId` set on the job.
- UI served with vendored htmx/ethers (no CDN requests).

Not verified (needs real infrastructure):

(Superseded: Sepolia, MetaMask, interLink/VK, Minikube and Apptainer execution were all
exercised later; see "Full rehearsal on real Sepolia" below.)

- The SSH `-L` tunnel, KVM2 Minikube driver, CCB through NAT, and provider VM cloud-init
  (`htcondor` and `apptainer` package availability on the Ubuntu image).

Known minor: `Listing.createdAt` stores a block number while `Rental.createdAt` stores
processing time. Neither is displayed.

## Full rehearsal on real Sepolia (2026-11-13)

Result: PASS end to end. MetaMask Rent (0.001 ETH) on Sepolia -> backend indexed
`RentalCreated` and wrote `rentals.json` -> `kubectl apply` via `demo-laptop.sh run 1` ->
interLink virtual node -> patched plugin validated rental 1 -> HTCondor job pinned to the
rented machine -> Apptainer ran `alpine` -> output returned through `kubectl logs`, pod
`Succeeded`, `Rental ID: 1` in the output. Grafana "W3Node Compute Rental Demo" showed the
virtual node Ready and the pod phases.

Sepolia gotchas found while doing it:
- Sepolia now charges far more gas for state creation than local Anvil/Foundry tests suggest:
  contract creation ~7.5M gas, `registerListing` ~583k. Fees are still negligible at current
  gas prices, but never hard-code low gas limits (2M and 4M deploys ran out of gas and
  reverted; the "Deployed to" line printed anyway, so check the receipt `status`).
- `forge script` against the load-balanced publicnode RPC can fail with "block not found".
  `forge create ... --gas-limit 9000000` worked.
- The UI re-renders the listings table every 10 s; automation should click
  `.rent-button[data-listing-id="1"]` by selector.

Fixed in this pass: `scripts/demo-laptop.sh monitoring` used `--set` for a string-valued chart
value (current kube-prometheus-stack rejects it); now `--set-string`.

Provider container requirements (relevant if the provider runs in Docker): relaxed seccomp
and AppArmor, `--device /dev/fuse`, `--cap-add SYS_ADMIN`. A normal VM needs none of this.

Still not exercised: the SSH `-L` tunnel (the rehearsal used host networking, so interLink
talked to the plugin directly on 127.0.0.1:4000), KVM2 Minikube driver (rehearsal used the
Docker driver), and the cloud-init provider VM.

## SSH tunnel verification (real sshd)

Tested `consumer/interlink/start-ssh-tunnel.sh` (TUNNEL_MODE=local-forward) against an Ubuntu 24.04 sshd configured
by `infrastructure/scripts/create-tunnel-user.sh`: pinned host key + permitted port works (plugin answers on the
local end), a wrong pinned host key is refused, a forward to any other port is blocked, and the account has no
shell. Found and fixed: user-level `ControlMaster auto` in `~/.ssh/config` made the forward outlive the script and
bypass host-key pinning; the scripts now pass `-o ControlMaster=no -o ControlPath=none -o ControlPersist=no`.
