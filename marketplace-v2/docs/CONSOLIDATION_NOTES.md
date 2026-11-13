# Consolidation notes

This repository consolidates the stronger pieces of two independent implementations of the W3Node compute marketplace.

## Decisions retained in this repository

- **Marketplace/backend:** retained the self-contained Go backend, persistent state store, HTCondor discovery, Sepolia log polling and htmx interface. It has no third-party Go dependencies and has unit tests for the event decoding and rental mirror. The contract event schema is kept in lockstep with `contracts/src/ComputeMarketplace.sol` and `marketplace/abi.json`.
- **Smart contract:** retained the contract with direct native-ETH settlement, non-reentrancy protection, positive price/duration validation, provider-only listing updates, and provider/paid-value fields in `RentalCreated`. The alternate contract used a different `RentalCreated` event layout, so its backend event ABI could not be copied unchanged.
- **HTCondor rental integration:** retained the strict source-anchor patcher. It passes the validated rental from `SubmitHandler` to the real submit-description generator and adds the ClassAd requirement before `Queue 1`. The alternative patcher's synthetic test used a generator signature with `pod` as the first positional argument; upstream uses `containers` and `metadata`, so that patch path does not correctly bind the rental when applied to the upstream function.
- **Consumer connectivity:** retained the interLink SSH socket setup and KVM2 Minikube laptop workflow. The alternative demo script defaulted to Docker and mixed a TCP-forwarded plugin endpoint with a separate SSH-socket values file.
- **Provider setup:** retained native Apptainer installation plus the `singularity` compatibility shim needed by the current HTCondor plugin command path, and the restricted nftables allowlist template.
- **Observability and presentation:** retained Prometheus/Grafana dashboard assets and the factual video storyboard.

## Improvements brought into the consolidated version

- Expanded plugin-patcher tests to cover Pod and CreateStruct envelopes, missing/invalid/unknown/expired rentals, invalid machine names, existing `Requirements` expressions, missing queue statements, and idempotence.
- Added a Go test for the exact `RentalCreated` data layout used by this repository's contract, plus a test pinning the event topic constants to the contract event signatures.
- Kept the patcher's fail-closed behaviour: it refuses to modify an upstream `handles.py` when expected source anchors change.

## Validation boundary

The checks in `scripts/check.sh` exercise the repository code and fixtures. They do not replace a live test against a freshly cloned upstream interLink plugin, a live HTCondor pool, a KVM guest, Sepolia, or a consumer Kubernetes cluster. The README and deployment guides identify these external integration steps explicitly.
