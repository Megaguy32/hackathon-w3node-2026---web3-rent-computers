# Web3 Rent Computers

W3Node 2026 Hackathon
- Member: Ethan Le Roux (`Megaguy32`) - Programmer
- Track: Real World Assets (RWA)
- Idea: Tokenize computers, rent computation

## Problem Statement
Cloud compute in Africa is expensive and high-latency because servers sit overseas and bill in USD. Meanwhile, local PCs, gaming rigs, and lab computers sit idle for hours every day. This project tokenizes physical computers on-chain so owners can rent out spare computation directly.

## Target Users in Africa
- Providers: PC owners, Computer labs.

- Renters: Local developers, Cluster administrators, service owners in need of scale, AI/3D builders needing cheap compute without credit cards or credit checks.

## Core Features
- Hardware Tokenization (ERC-721): Token correlates to a physical computer and records its specs and hourly rate.

- Escrow Rental: Smart contract locks the renter's payment for the booked hours.

- Container Access: Host daemon spins up an isolated Docker or SSH session during an active lease.

- Uptime Settlement: Contract pays the host owner on completion or refunds the renter on downtime.

## Track Alignment (Real World Assets)
Regarding the context of Real World Assets, a physical computer is tangible hardware that does measurable work. Linking a machine's specs and rental leases to a smart contract pragmatically turns idle hardware into an on-chain asset.

## Working implementation (marketplace-v2)

`marketplace-v2/` is a runnable, tested implementation of the rental flow: a Solidity
marketplace contract on Ethereum Sepolia, a Go + htmx marketplace UI/indexer, and a patched
`interlink-htcondor-plugin` that pins a Kubernetes Pod to the machine a wallet rented.
It was rehearsed end to end on Sepolia (MetaMask rent -> Kubernetes pod via interLink ->
HTCondor/Apptainer job on the rented machine -> Grafana). See
`marketplace-v2/docs/DEMO_RUNBOOK.md` for the checklist, results and known gaps.

Note: v2 deliberately has no escrow, ERC-721 tokenization or uptime settlement (the payment goes
straight to the provider). Those remain the design goals above and live in `contracts/ComputerRWA.sol`.
