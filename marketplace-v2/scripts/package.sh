#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="w3node-compute-marketplace"
OUT="${1:-$(dirname "$ROOT")/${NAME}.zip}"
cd "$(dirname "$ROOT")"
rm -f "$OUT"
# Include .git so the extracted archive is a usable clone of the repository.
# Exclude generated runtime state, Python caches, Foundry build output and local secrets.
zip -qr "$OUT" "$NAME" \
  -x "$NAME/.demo-laptop.env" \
     "$NAME/.demo-state/*" \
     "$NAME/**/__pycache__/*" \
     "$NAME/marketplace/data/*" \
     "$NAME/marketplace/marketplace" \
     "$NAME/contracts/out/*" \
     "$NAME/contracts/cache/*" \
     "$NAME/contracts/broadcast/*" \
     "$NAME/contracts/.env"
echo "Created $OUT"
