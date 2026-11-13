# Architecture and execution flow

## Rental model

A listing identifies an HTCondor `Machine` value, a fixed price in wei, and a fixed rental duration. A consumer calls `rent(listingId)` with exactly that price. The contract transfers Sepolia ETH directly to the provider and records a rental with a monotonically increasing rental ID and expiry.

## On-chain to off-chain flow

1. `ListingCreated` is emitted when a provider publishes a listing; `ListingUpdated` changes its price, duration or active flag and is indexed too. The watcher stays 3 blocks behind the head, and its cursor is bound to the chain ID and contract address.
2. The Go backend polls Sepolia JSON-RPC for contract events and materialises listings locally.
3. `RentalCreated` contains the rental ID, listing ID, consumer, provider, machine name, expiry, and amount paid.
4. The backend stores the rental in its state file and mirrors a flat rental-ID-keyed JSON object to `RENTALS_FILE` (default `/tmp/rentals.json`; the systemd units use `/run/w3node/rentals.json`).
5. The patched interLink HTCondor plugin reads `marketplace.w3node.io/rental-id` from the Pod metadata annotation.
6. It checks that the rental exists and has not expired, then adds `+RentalId` and a provider-specific `Requirements = (TARGET.Machine == "...")` to the generated HTCondor submit description.
7. HTCondor's negotiator can match the job only to a machine whose `Machine` ClassAd equals the rented machine.

## Why `Machine`, not slot `Name`

HTCondor may advertise multiple slots per physical host. The listing uses the `Machine` ClassAd, which identifies the host, so the rental pins work to that host while leaving slot selection to HTCondor.

## Kubernetes path

The consumer's Virtual Kubelet and interLink API server run locally with the Kubernetes cluster. The Virtual Kubelet talks to the interLink API over a local Unix socket. The API reaches the remote plugin's loopback TCP port 4000 through an SSH local forward (`TUNNEL_MODE=local-forward`, `127.0.0.1:4000` on the laptop). Upstream's `ssh-tunnel` binary is kept as `TUNNEL_MODE=interlink-ssh-tunnel`; its source listens on the *remote* port and dials the *local* socket, so verify it against your interLink version before using it. The remote plugin runs beside the HTCondor schedd on the marketplace host.

The current integration offloads supported Pod workloads as batch jobs. It does not turn provider machines into conventional Kubernetes worker nodes or provide general Kubernetes Service/Ingress semantics.

## Deliberate trust boundary

The public rental ID is not a wallet signature. The demo assumes trusted participants and a protected control plane. The contract is the payment/rental record; the local backend and plugin enforce the rental-to-machine association for this prototype.
