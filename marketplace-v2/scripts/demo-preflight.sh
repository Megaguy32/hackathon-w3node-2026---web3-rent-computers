#!/usr/bin/env bash
# One-command readiness check for the live demo. Read-only: it only queries local endpoints.
# Usage: ./scripts/demo-preflight.sh        (reads .demo-laptop.env like demo-laptop.sh does)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
ENV_FILE="${DEMO_ENV_FILE:-$ROOT/.demo-laptop.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
PROFILE="${MINIKUBE_PROFILE:-w3node-demo}"
MARKET="${MARKETPLACE_URL:-http://127.0.0.1:8090}"
TUNNEL_PORT="${PLUGIN_LOCAL_PORT:-${PLUGIN_PORT:-4000}}"
GRAFANA="http://127.0.0.1:${GRAFANA_LOCAL_PORT:-3000}"
fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

echo "Marketplace ($MARKET)"
[[ "$(code "$MARKET/healthz")" == 200 ]] && ok "UI/backend answering" || bad "backend not answering at $MARKET"
cfg="$(curl -s -m 5 "$MARKET/api/config" || true)"
echo "$cfg" | grep -q '"configured":true' && ok "chain configured: $(echo "$cfg" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["chainName"],d["contractAddress"][:10]+"...")' 2>/dev/null)" || bad "chain/contract not configured"
python3 - "$MARKET" <<'PY' || fail=1
import json, sys, time, urllib.request
base = sys.argv[1]
def get(p):
    return json.load(urllib.request.urlopen(base + p, timeout=8))
ok = lambda m: print("  \033[32mOK\033[0m    " + m)
bad = lambda m: (print("  \033[31mFAIL\033[0m  " + m), sys.exit(1))
try:
    nodes, listings, rentals = get("/api/nodes"), get("/api/listings"), get("/api/rentals")
except Exception as e:
    bad(f"cannot read marketplace API: {e}")
avail = [n["machine"] for n in nodes if n.get("available")]
ok(f"{len(nodes)} provider machine(s) in the pool, {len(avail)} available: {', '.join(avail) or '-'}") if nodes else bad("no provider machines in the pool")
act = [l for l in listings if l.get("active")]
ok("active listings: " + ", ".join(f"#{l['listingId']} {l['machineName']} {int(l['priceWei'])/1e18:g} ETH" for l in act)) if act else bad("no active listings")
now = int(time.time())
live = [r for r in rentals if r["expiresAt"] > now]
if live:
    ok("active rentals: " + ", ".join(f"#{r['rentalId']} on {r['machineName']} ({(r['expiresAt']-now)//60} min left)" for r in live))
else:
    ok("no active rentals (clean start: you will rent live)")
PY

echo "Kubernetes ($PROFILE)"
st="$(kubectl --context "$PROFILE" get node interlink-node -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[[ "$st" == True ]] && ok "virtual node interlink-node Ready" || bad "virtual node interlink-node not Ready (run: ./scripts/demo-laptop.sh connect)"
[[ "$(code "http://127.0.0.1:${TUNNEL_PORT}/system-info")" == 200 ]] && ok "plugin reachable through the SSH tunnel (127.0.0.1:${TUNNEL_PORT})" || bad "plugin not reachable on 127.0.0.1:${TUNNEL_PORT} (tunnel down?)"
pods="$(kubectl --context "$PROFILE" get pods -n default --no-headers 2>/dev/null | wc -l)"
[[ "$pods" == 0 ]] && ok "no leftover demo pods" || warn "$pods pod(s) in default namespace (the run command replaces its own pod)"

echo "Grafana"
[[ "$(code "$GRAFANA/login")" == 200 ]] && ok "Grafana answering at $GRAFANA (log in once before recording)" || bad "Grafana not reachable at $GRAFANA (run: ./scripts/demo-laptop.sh grafana)"
if [[ -n "${MARKETPLACE_METRICS_TARGET:-}" ]]; then
  m="$(curl -s -m 5 "http://${MARKETPLACE_METRICS_TARGET}/metrics" | grep '^w3node_computes{' | sed 's/w3node_computes//' | tr '\n' ' ')"
  [[ -n "$m" ]] && ok "fleet counters: $m" || warn "marketplace /metrics not answering at ${MARKETPLACE_METRICS_TARGET}"
fi
echo
if [[ $fail == 0 ]]; then printf '\033[32mReady to record.\033[0m\n'; else printf '\033[31mFix the FAIL lines above first.\033[0m\n'; fi
exit $fail
