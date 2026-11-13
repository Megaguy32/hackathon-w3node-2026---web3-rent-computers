# Demo security boundary and limitations

This repository is intentionally scoped for a controlled hackathon demonstration.

- `CLAIMTOBE` does not authenticate identities. Never expose the demo pool's TCP/9618 to arbitrary Internet clients.
- `ALLOW_READ/WRITE/NEGOTIATOR/DAEMON = *` is only tolerable behind a strict IP allowlist for known demo participants.
- The supplied nftables helper creates an additional input chain for TCP/9618 without flushing existing firewall rules. It is runtime-only and must be made persistent using the host's normal firewall management before reboot.
- The plugin is patched to bind to `127.0.0.1` and run with Flask debug mode disabled. Reach it through the documented SSH tunnel; do not publish TCP/4000.
- Use a dedicated SSH key and verify the marketplace host key.
- Never commit private keys, RPC API secrets or `.env` files.
- The rental annotation is a lookup key, not proof that the Pod submitter owns the recorded wallet. Do not treat this demo as a public permissionless execution marketplace.
- The plugin checks rental expiry at submission time. It does not terminate a running HTCondor job when the rental expires.
- The contract makes direct payments. There is no escrow or refund path.
- Container isolation and provider policy are not hardened for arbitrary untrusted workloads. Use only trusted demo participants and workloads.
- The contract does not verify that a listing's provider controls the HTCondor machine it names. Anyone can list any pool machine name, collect the payment, and the consumer's job will run on that machine. Use only participants who list their own machines.
- `rent` does not prevent overlapping rentals of one machine, so two consumers can pay for, and share, the same host. Rentals are time-bound access, not exclusive reservations.
- The rental state file lives in `/run/w3node/` (not world-writable `/tmp`) under the systemd units, and the plugin service does not read the env file that holds `RPC_URL`.
- The marketplace page loads htmx and ethers from CDNs until you run `scripts/vendor-ui-deps.sh` and commit `marketplace/static/vendor/`.
