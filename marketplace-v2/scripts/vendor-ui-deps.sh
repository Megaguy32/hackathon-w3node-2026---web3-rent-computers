#!/usr/bin/env bash
# Vendor the two browser dependencies into marketplace/static/vendor/ and point
# index.html at the local copies, so the wallet-signing page loads no third-party
# scripts at demo time. Needs npm and network access. Run once, then commit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTMX=2.0.4; ETHERS=6.13.5
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
npm pack "htmx.org@$HTMX" "ethers@$ETHERS" --silent
mkdir h e
tar xzf "htmx.org-$HTMX.tgz" -C h
tar xzf "ethers-$ETHERS.tgz" -C e
dest="$ROOT/marketplace/static/vendor"
mkdir -p "$dest"
cp h/package/dist/htmx.min.js "$dest/htmx.min.js"
cp e/package/dist/ethers.umd.min.js "$dest/ethers.umd.min.js"
cp h/package/LICENSE "$dest/htmx.LICENSE"
cp e/package/LICENSE.txt "$dest/ethers.LICENSE" 2>/dev/null || cp e/package/LICENSE* "$dest/ethers.LICENSE"
sed -i \
  -e 's#https://unpkg.com/htmx.org@[0-9.]*#/static/vendor/htmx.min.js#; s#/static/vendor/htmx.min.js"#/static/vendor/htmx.min.js"#' \
  -e 's#https://cdn.jsdelivr.net/npm/ethers@[0-9.]*/dist/ethers.umd.min.js#/static/vendor/ethers.umd.min.js#' \
  "$ROOT/marketplace/templates/index.html"
grep -n 'static/vendor' "$ROOT/marketplace/templates/index.html"
sha256sum "$dest"/*.js
