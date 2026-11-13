# Package contents

This archive is the consolidated Git repository for the W3Node decentralised compute marketplace prototype.

It includes:

- Solidity marketplace contract, Foundry configuration, deployment script and expanded contract tests.
- Go marketplace backend, Sepolia event watcher, HTCondor node discovery, persistent state, htmx templates and frontend assets.
- interLink HTCondor plugin patcher, installer, sidecar configuration and expanded rental/pinning tests.
- HTCondor pool/provider configuration templates, host setup scripts, systemd units and restricted firewall helper.
- Consumer interLink configuration and SSH socket/tunnel startup helpers.
- Kubernetes workload examples and a manual HTCondor test job.
- KVM2 Minikube laptop demo script, optional local KVM provider VM workflow and environment template.
- Optional Prometheus/Grafana dashboard and setup notes.
- Architecture, security/limitations, laptop-demo, consolidation and video-storyboard documentation.
- Prebuilt Linux x86-64 marketplace backend binary under `dist/`.
- Build/check/package scripts, Makefile, GitHub Actions workflow and a Git repository with a clean initial snapshot commit.

## Deliberately excluded

Machine-specific credentials and state are not included: `.env`, `.demo-laptop.env`, private keys, RPC credentials, rental runtime files, demo VM state, Python caches, local Go binaries, and generated Foundry build directories.

## Validation performed

`./scripts/check.sh` passes in the packaging environment: Go unit tests, Go vet/build, Python patcher tests, Python syntax, JavaScript syntax, shell syntax, YAML parsing, embedded Grafana dashboard JSON validation, and the demo-helper smoke test. The plugin tests now also cover pod/CreateStruct envelopes, missing/invalid/unknown/expired rentals, unsafe machine names, existing HTCondor `Requirements`, queue placement, idempotence and fail-closed source-anchor changes.

A Foundry contract test run, Sepolia deployment, KVM/Minikube startup, live plugin patch against the network checkout, and end-to-end execution across real HTCondor/interLink machines were not performed in the packaging environment.
