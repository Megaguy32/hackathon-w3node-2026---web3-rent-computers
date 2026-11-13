#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/marketplace"
go build -trimpath -ldflags="-s -w" -o "$ROOT/dist/marketplace-linux-amd64" .
echo "Built $ROOT/dist/marketplace-linux-amd64"
