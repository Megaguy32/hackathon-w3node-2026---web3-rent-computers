#!/usr/bin/env bash
# Scripted on-chain actions for the automated demo (Sepolia). Uses Foundry's `cast` from a container, with the
# THROWAWAY keys in .sepolia-rehearsal.env (git-ignored). Prints only public data; never prints a private key.
#
#   ./scripts/chain-actions.sh init-consumer           create the throwaway demo-consumer wallet (prints its address to fund)
#   ./scripts/chain-actions.sh balances                ETH balances of deployer, provider and demo consumer
#   ./scripts/chain-actions.sh publish <machine> [priceWei] [seconds]   provider lists a machine; prints the listing ID
#   ./scripts/chain-actions.sh rent <listingId>        demo consumer rents it; prints the rental ID
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REHEARSAL_ENV:-$ROOT/.sepolia-rehearsal.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
IMG=ghcr.io/foundry-rs/foundry:stable
RPC_TOPIC_RENTAL=0xec629e63935ac5c5900777ba2f0204a90aa022089dbcccb2689ab9408399d767
RPC_TOPIC_LISTING=0xee9a77e54ddc4ae3475a5616f641d8617975557d8f946292108c2b98c6a7bed3

# cast <args...> with secrets passed through the environment, never on the command line
cast_() { docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e RPC="$SEPOLIA_RPC_URL" -e CONTRACT="$CONTRACT_ADDRESS" \
  -e PROVIDER_PRIVATE_KEY -e DEMO_CONSUMER_PRIVATE_KEY --entrypoint sh "$IMG" -c "$1" -- "${@:2}"; }

case "${1:-}" in
  init-consumer)
    if grep -q '^DEMO_CONSUMER_PRIVATE_KEY=' "$ENV_FILE"; then echo "already exists: $(grep '^DEMO_CONSUMER_ADDRESS=' "$ENV_FILE" | cut -d= -f2)"; exit 0; fi
    out="$(docker run --rm --entrypoint cast "$IMG" wallet new --json)"
    umask 177
    python3 -c '
import json, sys
d = json.load(sys.stdin); d = d[0] if isinstance(d, list) else d
with open(sys.argv[1], "a") as f:
    f.write("DEMO_CONSUMER_PRIVATE_KEY=%s\nDEMO_CONSUMER_ADDRESS=%s\n" % (d["private_key"], d["address"]))
print("demo consumer address:", d["address"])' "$ENV_FILE" <<<"$out"
    ;;
  balances)
    for who in DEPLOYER_ADDRESS PROVIDER_ADDRESS DEMO_CONSUMER_ADDRESS CONSUMER_ADDRESS; do
      a="${!who:-}"; [[ -n "$a" ]] || continue
      b="$(cast_ 'cast balance "$1" --rpc-url "$RPC" --ether' "$a")"; printf '%-22s %s  %s ETH\n' "$who" "${a:0:10}…${a: -4}" "$b"
    done ;;
  publish)
    machine="${2:?machine name}"; price="${3:-${LISTING_PRICE_WEI:-1000000000000000}}"; secs="${4:-${LISTING_DURATION_SECONDS:-3600}}"
    cast_ 'cast send "$CONTRACT" "registerListing(string,uint256,uint256)" "$1" "$2" "$3" --rpc-url "$RPC" --private-key "$PROVIDER_PRIVATE_KEY" --gas-limit 900000 --json' "$machine" "$price" "$secs" \
      | python3 -c "
import json,sys
r=json.load(sys.stdin)
assert r['status'] in ('0x1',1,'1'), 'transaction failed: '+str(r.get('status'))
lg=[l for l in r['logs'] if l['topics'][0]=='$RPC_TOPIC_LISTING'][0]
print(int(lg['topics'][1],16))" ;;
  rent)
    id="${2:?listing id}"; [[ -n "${DEMO_CONSUMER_PRIVATE_KEY:-}" ]] || { echo "Run init-consumer first" >&2; exit 1; }
    price="$(cast_ 'cast call "$CONTRACT" "getListing(uint256)((address,string,uint256,uint256,bool))" "$1" --rpc-url "$RPC"' "$id" | python3 -c 'import sys,re;print(re.search(r"\", (\d+)",sys.stdin.read()).group(1))')"
    cast_ 'cast send "$CONTRACT" "rent(uint256)" "$1" --value "$2" --rpc-url "$RPC" --private-key "$DEMO_CONSUMER_PRIVATE_KEY" --gas-limit 1500000 --json' "$id" "$price" \
      | python3 -c "
import json,sys
r=json.load(sys.stdin)
assert r['status'] in ('0x1',1,'1'), 'transaction failed: '+str(r.get('status'))
lg=[l for l in r['logs'] if l['topics'][0]=='$RPC_TOPIC_RENTAL'][0]
print(int(lg['topics'][1],16))" ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
