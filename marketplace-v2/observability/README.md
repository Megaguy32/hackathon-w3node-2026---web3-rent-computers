# Observability for the hackathon demo

Observability is useful when it makes the compute handoff visible. Keep it optional: the core demo must work without Grafana.

## Included: Kubernetes / consumer dashboard

`scripts/demo-laptop.sh monitoring` installs `kube-prometheus-stack` into the local Minikube cluster and imports `kubernetes/w3node-dashboard-configmap.yaml`.

The dashboard shows:

- Whether Kubernetes sees the `interlink-node` virtual node as Ready.
- Counts of Running, Succeeded and Failed Pods in the default namespace.
- Pod phase history and container restarts.

This is consumer-side orchestration telemetry. Because interLink offloads work to an external HTCondor pool, the consumer's Minikube node exporter does **not** measure CPU/RAM use on the remote provider. Do not present it as provider hardware telemetry.

Start the Grafana port-forward with:

```bash
./scripts/demo-laptop.sh grafana
```

## Better end-to-end traces: interLink's monitoring stack

The interLink project has a separate monitoring stack based on OpenTelemetry, Grafana Tempo and Grafana. It is more directly relevant to showing interLink's Virtual Kubelet/API request flow (Pod create, status and log operations) than a generic cluster dashboard.
It currently traces the Virtual Kubelet path; it does not automatically give you provider hardware metrics or full HTCondor scheduler telemetry.

Reference:

- <https://github.com/interlink-hq/interlink-monitoring-stack>
- <https://interlink-project.dev/docs/>

The official monitoring configuration requires enabling tracing in the interLink components and pointing their telemetry exporter at the monitoring endpoint. Follow the version-matched upstream deployment instructions rather than copying Helm values from a different interLink release.

## HTCondor metrics (optional future addition)

Recent HTCondor releases provide `condor_metricd` and Prometheus-compatible metrics when the `METRICD` feature is enabled. This could make provider/pool scheduling metrics visible in Grafana, but only add it after checking the installed HTCondor release and confirming the endpoint is accessible to Prometheus. It is not required for the hackathon MVP.

Reference: <https://htcondor.readthedocs.io/>

## What to show judges

A short, convincing observability sequence is:

1. Grafana shows `interlink-node` Ready.
2. The marketplace shows the rental is active.
3. `kubectl apply` creates the workload.
4. `condor_q` shows the HTCondor job queued/running/completed.
5. The provider's `htop` shows execution activity.
6. Kubernetes reports the Pod completed and `kubectl logs` shows the provider hostname.

The provider terminal and the returned execution hostname are the strongest evidence that the work actually ran remotely. Grafana supports that story; it should not replace it.
