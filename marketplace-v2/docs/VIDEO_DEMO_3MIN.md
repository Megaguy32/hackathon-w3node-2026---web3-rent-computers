# 3-minute live demo: run-sheet

Everything below is shot live on the real stack (Ethereum Sepolia + Kubernetes + HTCondor). Timings were measured
on the rehearsal stack: after `run`, the pod is **Running at ~+19 s** and **Succeeded at ~+85 s**; a rental is
indexed ~15-25 s after you confirm it in MetaMask (backend runs with `CONFIRMATIONS=1`).
Each take costs 0.001 Sepolia ETH (paid to the throwaway provider account) plus negligible gas.

## Before you hit record (5 min)

Terminal (large font, dark theme), from the repo directory:

```bash
cd marketplace-v2   # the folder holding scripts/, docs/, marketplace/ (the repo root of the standalone project)
./scripts/demo-preflight.sh
```

Every line must be OK ("Ready to record."). Then arrange the screen: terminal on the left, browser on the right,
with these tabs in this order (log in / connect beforehand so nothing sensitive or slow appears on camera):

| Tab | URL | Prepare |
|---|---|---|
| 1 Marketplace | `http://localhost:8090` | Click *Connect MetaMask* once, approve. MetaMask on **Sepolia**, unlocked. |
| 2 Grafana | `http://localhost:3000/d/w3node-compute-demo/w3node-compute-rental-demo?from=now-5m&to=now&refresh=5s` | Log in once (`admin` / the `GRAFANA_ADMIN_PASSWORD` from `.demo-laptop.env`). |
| 3 Explorer | `https://sepolia.etherscan.io/address/<CONTRACT_ADDRESS>` (the `CONTRACT_ADDRESS` from your `.sepolia-rehearsal.env` / marketplace config) | Contract page, "Transactions" visible. |

Never show a seed phrase, private key or the MetaMask "secret recovery" screens. The MetaMask popup shows your
public address only, which is fine.

**Clean-start note:** the fleet counters tell the best story from a clean start (Ready 2, Pending 0, Live 0).
The rehearsal rental #2 (on `w3node-provider`) is still active until **21:06:48**, which shows *Pending 1*
at the start. Either wait until it expires, or just narrate it ("one machine is already rented and waiting").

## The run (target 3:00)

| Time | Screen | Do | Say |
|---|---|---|---|
| 0:00 | Tab 1 Marketplace | Point at *Provider machines* (two real machines, live from HTCondor) and *Available listings*. | "Idle computers advertise themselves from a live HTCondor pool, and owners publish a price on Ethereum." |
| 0:20 | Tab 1 | Click **Rent** on a listing (e.g. `w3node-provider`, 0.001 ETH). MetaMask pops up: **Confirm**. | "A consumer pays the provider directly on Sepolia: no middleman, no escrow." |
| 0:40 | Tab 1 | Wait ~20 s: a row appears under *Recent rentals* with `marketplace.w3node.io/rental-id: "N"`. Note **N**. | "The marketplace indexes the on-chain event and gives me a rental ID." |
| 0:55 | Terminal | `kubectl get nodes` | "My Kubernetes cluster has a virtual node, interLink, that fronts the rented machine." |
| 1:05 | Terminal | `./scripts/demo-laptop.sh run N load` (replace `N`) | "I submit a normal Pod. The only special thing is the rental ID annotation." |
| 1:10 | Tab 2 Grafana | Watch the top row: **Pending/Live computes** change, then CPU and RAM of the provider climb. | "Grafana shows the fleet: ready, pending and live machines, and the CPU and RAM of the rented provider as the workload runs." |
| 2:20 | Terminal | `./scripts/demo-laptop.sh logs w3node-compute-load` | "The Pod ran on the provider: its hostname and my rental ID are in the output." |
| 2:35 | Terminal | `docker exec w3pool condor_history -limit 1 -af ClusterId RentalId JobStatus LastRemoteHost` | "HTCondor confirms it: this rental's job ran on exactly the machine I rented." |
| 2:50 | Tab 3 Explorer | Show the contract and the rental transaction. | "Ethereum records the rental, HTCondor schedules the work, interLink makes it look like Kubernetes." |

Tip: `kubectl get pod w3node-compute-load -w` in a second terminal pane makes the Pending -> Running -> Succeeded
change visible while Grafana is on screen (Ctrl-C when it shows Succeeded).

## If something goes wrong

| Symptom | Fix |
|---|---|
| Rental row never appears | Wait 40 s; check `./scripts/demo-preflight.sh`; confirm MetaMask is on Sepolia and the tx confirmed. |
| `run` says rental is unknown / 403 | The rental isn't indexed yet or has expired (1 h). Rent again. |
| Pod stays Pending > 40 s | `./scripts/demo-preflight.sh`; most common cause is the SSH tunnel or plugin down. |
| `kubectl logs` shows *connection refused* | Re-run the firewall helper (rules are runtime-only): `sudo infrastructure/scripts/libvirt-docker-firewall.sh apply`. |
| Grafana panels empty | Time range must include "now" (`from=now-5m`); counters need ~10 s after the first scrape. |

## Re-takes

Each take just needs a new rental. Rentals last 1 h, so one rental can be reused for several `run N load` takes
inside that hour; only the on-camera "rent" segment needs a fresh payment.

## What the counters mean

- **Ready**: idle provider machines with Apptainer that nobody has rented (available to rent).
- **Pending**: machines with an active rental and no workload running yet.
- **Live**: machines running a rented workload right now.
- **Registered**: all machines advertised in the pool.
