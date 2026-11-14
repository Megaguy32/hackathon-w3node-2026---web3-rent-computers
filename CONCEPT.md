# Web3 Rent Computers: Project Concept

**W3Node 2026 Hackathon · Track: Real World Assets (RWA)**
*Rent a computer with a wallet tap. Run your Kubernetes workload on it with one `kubectl apply`.*

## Problem statement

Cloud compute is expensive, billed in US dollars and served from data centres far from most of Africa, which means higher cost, higher latency and a credit card requirement that many developers, students and small teams do not have. At the same time, capable local hardware (gaming rigs, office PCs, university lab machines) sits idle for hours every day, earning nothing. There is no simple, trustless way to connect the two.

## Target users in Africa

**Providers (supply side)**
- Owners of powerful PCs and gaming rigs who want income from idle hours
- University and school computer labs, and internet cafés, with machines idle outside opening hours
- Small businesses with spare office hardware

**Renters (demand side)**
- Local developers and student teams who need affordable compute for builds, testing, AI/ML experiments or 3D rendering
- Startups and research groups that cannot get, or cannot afford, international cloud billing
- Cluster administrators who want to add cheap local capacity to a Kubernetes setup they already run

Payment is a wallet transaction, so there is no card, bank account or credit check on either side.

## Core features

- **On-chain listings:** a provider publishes a machine with a price and a rental duration on an Ethereum smart contract. Listings are public and verifiable.
- **Direct wallet payment:** the renter pays from a wallet and the funds go straight to the provider, with no middleman.
- **Kubernetes-native access:** the rented machine appears as a node (via interLink), so the renter submits an ordinary Pod with their rental ID. No new tools to learn.
- **Rental-pinned execution:** a patched HTCondor plugin checks the rental on-chain and runs the job only on the machine that was rented. Proven across two real providers (a container and a KVM virtual machine).
- **Live visibility:** a live marketplace view and Grafana dashboards show machine states (ready, pending, live), CPU and RAM, and the on-chain event feed.

## Track alignment explanation (Real World Assets)

A computer is a tangible, real-world asset that produces measurable work. This project puts that asset on-chain: the machine, its price and its rental terms are recorded in a smart contract, and a rental payment results in real, verifiable compute being delivered on that specific machine. Idle hardware becomes an income-producing, tradeable on-chain asset, and the chain acts as the trust layer between strangers.

The working version runs end to end on Ethereum Sepolia with real virtual machines and a real Kubernetes cluster, covering listing, payment, indexing, job placement and proof of where the job ran. The roadmap, already drafted in the repository's contract, extends the asset model to an ERC-721 token per physical computer (recording its specs and hourly rate), escrowed payment, and uptime-based settlement that pays the owner on completion and refunds the renter on downtime.

## Links

- Repository: https://github.com/Megaguy32/hackathon-w3node-2026---web3-rent-computers
- Pitch video (2:49) and 60 s live demo: https://github.com/Megaguy32/hackathon-w3node-2026---web3-rent-computers/releases/tag/v1.0.0
