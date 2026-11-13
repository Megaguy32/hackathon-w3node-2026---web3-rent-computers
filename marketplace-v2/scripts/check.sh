#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/marketplace"
printf '\n== Go tests ==\n'
go test ./...
printf '\n== Go vet ==\n'
go vet ./...
printf '\n== Go build ==\n'
go build ./...
cd "$ROOT"
printf '\n== Python patcher tests ==\n'
python3 -m unittest discover -s tests -v
printf '\n== Python syntax ==\n'
python3 -m py_compile plugin/apply_patch.py
printf '\n== JavaScript syntax ==\n'
if command -v node >/dev/null 2>&1; then node --check marketplace/static/app.js; else echo 'SKIP: node not installed'; fi
printf '\n== Shell syntax ==\n'
while IFS= read -r -d '' f; do bash -n "$f"; done < <(find . -type f -name '*.sh' -print0)
printf '\n== YAML syntax ==\n'
python3 - <<'PY'
try:
    import yaml
except ImportError:
    print('SKIP: PyYAML not installed')
else:
    from pathlib import Path
    for p in Path('.').rglob('*.yaml'):
        doc = yaml.safe_load(p.read_text())
        print('OK', p)
        if p.name == 'w3node-dashboard-configmap.yaml':
            import json
            json.loads(doc['data']['w3node-compute-demo.json'])
            print('OK embedded Grafana dashboard JSON')
PY
printf '\n== Demo helper smoke test ==\n'
./scripts/demo-laptop.sh help >/dev/null
printf '\nAll available checks passed. Foundry tests require forge and forge-std.\n'
