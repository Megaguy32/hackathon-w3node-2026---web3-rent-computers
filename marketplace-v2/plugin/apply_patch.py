#!/usr/bin/env python3
"""Apply the W3Node rental-to-HTCondor pinning patch to upstream handles.py.

The patch is deliberately strict: if upstream changes any expected anchor, it
stops rather than silently producing a broken plugin.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import sys

MARKER = "# W3NODE RENTAL INTEGRATION"
HELPER = r'''# W3NODE RENTAL INTEGRATION
_RENTAL_ID_ANNOTATION = "marketplace.w3node.io/rental-id"


def _load_w3node_rental(pod):
    """Resolve and validate a rental from a Pod or CreateStruct envelope."""
    if isinstance(pod, dict) and "metadata" not in pod and isinstance(pod.get("pod"), dict):
        pod = pod["pod"]
    annotations = (pod.get("metadata") or {}).get("annotations") or {}
    rental_id = str(annotations.get(_RENTAL_ID_ANNOTATION, "")).strip()
    if not rental_id or not re.fullmatch(r"[0-9]{1,78}", rental_id):
        return None, "Missing or invalid marketplace rental ID annotation"

    rentals_path = os.environ.get("MEGA_RENTALS_FILE", "/tmp/rentals.json")
    try:
        with open(rentals_path, "r", encoding="utf-8") as handle:
            rentals = json.load(handle)
    except FileNotFoundError:
        return None, f"Rental state file not found: {rentals_path}"
    except (OSError, json.JSONDecodeError) as exc:
        logging.exception("Unable to read marketplace rental state")
        return None, f"Unable to read rental state: {exc}"

    rental = rentals.get(rental_id) if isinstance(rentals, dict) else None
    if not isinstance(rental, dict):
        return None, f"Unknown marketplace rental ID: {rental_id}"
    try:
        expires_at = int(rental.get("expiresAt", 0))
    except (TypeError, ValueError):
        return None, f"Rental {rental_id} has an invalid expiry"
    if expires_at <= int(time.time()):
        return None, f"Rental {rental_id} has expired"

    machine_name = str(rental.get("machineName", "")).strip()
    # Only accept an HTCondor Machine value composed of hostname-safe characters.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,252}", machine_name):
        return None, f"Rental {rental_id} has an invalid provider machine name"

    return {"rentalId": rental_id, "machineName": machine_name, "expiresAt": expires_at}, None


def _w3node_pin_submit_description(job_text, rental):
    """Add a custom job attribute and constrain matching to the rented machine."""
    rental_id = json.dumps(str(rental["rentalId"]))
    machine_name = json.dumps(str(rental["machineName"]))
    requirement = f"(TARGET.Machine == {machine_name})"

    existing = re.search(r"(?im)^\s*Requirements\s*=\s*(.*?)\s*$", job_text)
    if existing:
        combined = f"Requirements = ({existing.group(1)}) && {requirement}"
        job_text = job_text[:existing.start()] + combined + job_text[existing.end():]
    else:
        queue = re.search(r"(?im)^\s*Queue\s+1\s*$", job_text)
        if not queue:
            raise ValueError("Could not find Queue 1 in generated HTCondor submit description")
        job_text = job_text[:queue.start()] + f"Requirements = {requirement}\n" + job_text[queue.start():]

    queue = re.search(r"(?im)^\s*Queue\s+1\s*$", job_text)
    if not queue:
        raise ValueError("Could not find Queue 1 after applying provider requirement")
    job_text = job_text[:queue.start()] + f"+RentalId = {rental_id}\n" + job_text[queue.start():]
    return job_text
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Expected exactly one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def patch(source: str) -> str:
    if MARKER in source:
        return source

    # Upstream currently imports re; add time only if absent.
    if "import time\n" not in source:
        source = replace_once(source, "import subprocess\n", "import subprocess\nimport time\n", "subprocess import")

    source = replace_once(
        source,
        "def produce_htcondor_singularity_script(\n",
        "def produce_htcondor_singularity_script(\n",
        "generator definition",
    )
    source = replace_once(
        source,
        "    poststart_hooks=None,\n):\n",
        "    poststart_hooks=None,\n    rental=None,\n):\n",
        "generator signature end",
    )

    # Inject the shared rental resolver immediately before SubmitHandler.
    source = replace_once(source, "def SubmitHandler():\n", HELPER + "\n\ndef SubmitHandler():\n", "SubmitHandler definition")

    # Resolve rental after the Pod metadata has been extracted and before generation.
    source = replace_once(
        source,
        '    containers = pod.get("spec", {}).get("containers", [])\n',
        '    containers = pod.get("spec", {}).get("containers", [])\n'
        '    rental, rental_error = _load_w3node_rental(pod)\n'
        '    if rental_error:\n'
        '        return error_response(rental_error, 403)\n'
        '    # Every container must take the pinned Apptainer path; the host-script path is not pinned.\n'
        '    if any("host" in str((c or {}).get("image", "")) for c in containers):\n'
        '        return error_response("Marketplace rentals support Apptainer container workloads only", 400)\n',
        "Pod container extraction",
    )

    # Pass the validated rental through the existing generator call.
    source = replace_once(
        source,
        "            poststart_hooks=poststart_hooks,\n        )\n",
        "            poststart_hooks=poststart_hooks,\n            rental=rental,\n        )\n",
        "generator call",
    )

    # Insert the pinning step after the generated submit text, before it is written.
    generator_start = source.index("def produce_htcondor_singularity_script(")
    generator_end = source.index("def produce_htcondor_host_script(", generator_start)
    generator = source[generator_start:generator_end]
    anchor = 'Queue 1\n"""\n        # print(job)'
    if generator.count(anchor) != 1:
        raise RuntimeError("Could not locate the expected Queue 1 / job string boundary in generator")
    insertion = '''Queue 1
"""
        if rental is not None:
            try:
                job = _w3node_pin_submit_description(job, rental)
            except Exception as exc:
                logging.exception("Unable to apply marketplace rental pinning")
                raise RuntimeError(f"Marketplace rental pinning failed: {exc}") from exc
        # print(job)'''
    generator = generator.replace(anchor, insertion, 1)
    source = source[:generator_start] + generator + source[generator_end:]

    # The official tunneled deployment reaches the plugin over SSH. Bind only
    # to loopback and disable Flask's interactive debugger in the service.
    source = replace_once(
        source,
        '    app.run(port=args.port, host="0.0.0.0", debug=True)\n',
        '    app.run(port=args.port, host="127.0.0.1", debug=False)\n',
        "Flask bind/debug configuration",
    )

    # Sanity checks: new helpers and all wiring points must exist.
    for needle in (MARKER, "rental=rental", "_load_w3node_rental(pod)", "_w3node_pin_submit_description(job, rental)", 'host="127.0.0.1", debug=False'):
        if needle not in source:
            raise RuntimeError(f"Patch sanity check failed: missing {needle!r}")
    return source


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plugin_dir", type=pathlib.Path, help="Path to cloned interlink-htcondor-plugin repository")
    parser.add_argument("--dry-run", action="store_true", help="Validate patch applicability without writing")
    args = parser.parse_args()
    path = args.plugin_dir / "handles.py"
    if not path.is_file():
        parser.error(f"{path} does not exist; clone the upstream plugin repository first")
    original = path.read_text(encoding="utf-8")
    try:
        updated = patch(original)
    except Exception as exc:
        print(f"ERROR: refusing to patch upstream source: {exc}", file=sys.stderr)
        return 1
    if updated == original:
        print("Patch already applied; no changes made.")
        return 0
    if args.dry_run:
        print("Patch anchors verified. Re-run without --dry-run to apply.")
        return 0
    backup = path.with_suffix(".py.w3node-backup")
    shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    print(f"Patched {path}; original saved as {backup}")
    print("Next: python3 -m py_compile handles.py")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
