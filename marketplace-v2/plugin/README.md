# W3Node rental patch for interlink-htcondor-plugin

`apply_patch.py` applies a small, guarded patch to the upstream `handles.py` file. It does not copy or reimplement the upstream plugin.

The patch:

1. Reads `marketplace.w3node.io/rental-id` from the incoming Pod metadata annotations.
2. Loads the matching record from `MEGA_RENTALS_FILE` (default `/tmp/rentals.json`; the systemd units set `/run/w3node/rentals.json`).
3. Rejects missing, unknown or expired rentals.
4. Validates the provider's HTCondor `Machine` name.
5. Adds `+RentalId = "<id>"` and `Requirements = (TARGET.Machine == "<machine>")` to the generated submit description before `Queue 1`.

HTCondor still appends its default resource requirements for the existing `RequestCpus` and `RequestMemory` settings.

## Install

From the project root, run `plugin/install-plugin.sh`. It clones or fast-forward updates the upstream `main` branch, creates a Python virtual environment, installs Flask/PyYAML, applies the patch, and compiles the patched file.

The patcher backs up the original as `handles.py.w3node-backup`. It is intentionally strict: if upstream changes the insertion points, it exits rather than applying a partial patch. It also binds Flask to `127.0.0.1` and disables debug mode; the consumer-side interLink tunnel is the intended way to reach the plugin.

## State file format

The Go backend writes an atomic JSON document keyed by decimal rental ID:

```json
{
  "1": {
    "rentalId": "1",
    "listingId": "1",
    "consumer": "0x...",
    "provider": "0x...",
    "machineName": "provider-01.example",
    "expiresAt": 1790000000,
    "paidWei": "1000000000000000",
    "createdAt": 1789996400
  }
}
```

The plugin only uses `rentalId`, `machineName`, and `expiresAt` for the prototype.

## Important boundary

The annotation carries a public rental ID, not a cryptographic wallet proof. This prototype assumes trusted demo participants. It is not a production authorization system. A rental is checked at job submission; an already-running job is not automatically terminated when the rental expires.
