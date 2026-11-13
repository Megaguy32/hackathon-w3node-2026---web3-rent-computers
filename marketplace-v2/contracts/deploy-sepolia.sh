#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${SEPOLIA_RPC_URL:?Set SEPOLIA_RPC_URL to an Ethereum Sepolia RPC endpoint}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY to the deployer key (do not commit it)}"
if [[ ! -d lib/forge-std ]]; then forge install foundry-rs/forge-std; fi
forge test -vv
forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vvvv

# Print what the backend needs: CONTRACT_ADDRESS and START_BLOCK.
if command -v python3 >/dev/null; then
  python3 - <<'PY'
import glob, json, os
runs = sorted(glob.glob("broadcast/Deploy.s.sol/*/run-latest.json"), key=os.path.getmtime)
if runs:
    run = json.load(open(runs[-1]))
    addr = next((t.get("contractAddress") for t in run.get("transactions", []) if t.get("contractAddress")), None)
    blocks = [int(r["blockNumber"], 16) for r in run.get("receipts", []) if r.get("blockNumber")]
    print(f"\nCONTRACT_ADDRESS={addr}")
    if blocks: print(f"START_BLOCK={min(blocks)}")
PY
fi
