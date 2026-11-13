# Gemini video demonstration brief

Use only screen recordings and screenshots from the actual working prototype. Do not invent transactions, nodes, benchmark results, hardware metrics or completed workloads. Label any architectural animation as illustrative rather than live telemetry.

## Suggested 75–90 second narrative

1. **Problem (0–10s):** Independent computers have spare compute capacity; consumers need more compute without buying more machines.
2. **Provider (10–22s):** Show the provider machine registered in HTCondor and advertised in the marketplace with its actual CPU/RAM listing.
3. **Rental (22–35s):** Show MetaMask on Sepolia, the direct-payment rental transaction, and the resulting rental ID. Never show seed phrases or private keys.
4. **Kubernetes (35–48s):** Show the Minikube consumer cluster and the interLink virtual node. Submit the Pod manifest containing the rental ID annotation.
5. **Remote execution (48–68s):** Show `condor_q` on the pool and activity on the provider machine. Then show the Pod reaching `Succeeded` and its output reporting the provider hostname.
6. **Close (68–90s):** Explain the roles: Ethereum records the rental, HTCondor schedules the workload, interLink exposes remote execution to Kubernetes.

## Visual direction

Keep the presentation technical and restrained. Use clean terminal captures, a simple architecture animation, and the actual marketplace UI. Prioritise legibility over cinematic effects. Avoid generic crypto imagery and avoid implying that the prototype is a fully trustless cloud or a production-grade public compute network.

## Capture checklist

- Marketplace listing and rental ID.
- Sepolia transaction hash and explorer page.
- `kubectl get nodes` showing the virtual node.
- Pod manifest with rental annotation.
- `condor_q` / completed job details.
- Provider-side process activity.
- `kubectl get pod` and `kubectl logs` output showing the provider hostname.
- Optional Grafana view of virtual-node readiness and Pod phases.
