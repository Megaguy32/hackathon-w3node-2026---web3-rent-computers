# Automated visual demo (record once, cut to 60 s)

`demo/conductor.py` drives the *real* stack with Selenium and records a ~3-5 minute run; `demo/edit.py` then
cuts it to a minute (waiting is sped up, typing and key moments stay at normal speed).

What the recording shows, in four tiled windows: **Cockpit** (the VMs), **Marketplace Live** (providers, rentals,
on-chain feed), **Grafana** (fleet counters, CPU/RAM) and a **terminal** pane that types and runs the real commands.

## One-time setup

1. Python env (already created if you used the helper): `python3 -m venv ~/.local/share/w3node-venv && ~/.local/share/w3node-venv/bin/pip install selenium obsws-python`
2. Fund the throwaway demo-consumer wallet with a few thousandths of Sepolia ETH (one rental = 0.001 ETH):
   `./scripts/chain-actions.sh init-consumer` prints its address; check with `./scripts/chain-actions.sh balances`.
3. Golden provider image (once): `./scripts/provider-vm.sh golden`. Clones then boot and join the pool in ~25 s.
4. Recording with OBS (Wayland/KDE): add a **Screen Capture (PipeWire)** source and approve the screen prompt once;
   Tools -> WebSocket Server Settings -> enable the server and set a password; then
   `export OBS_WEBSOCKET_PASSWORD=...` (never commit it). Or use `--recorder manual` and start/stop any recorder yourself.
5. Cockpit pane: `sudo pacman -S cockpit cockpit-machines && sudo systemctl enable --now cockpit.socket`, then run with
   `COCKPIT_PASSWORD` set (or you are prompted; it is never stored). Skip it with `--no-cockpit`.

## Secrets (never typed into chat, never committed)

Create `~/.local/state/w3node/demo-secrets.env` yourself, mode 600, with e.g.:

```
COCKPIT_PASSWORD=your-linux-password
OBS_WEBSOCKET_PASSWORD=the-obs-websocket-password
```

The conductor reads it (and refuses it if other users can read it). Use `--countdown 15` to get time to
minimise your terminal before the windows open.

## Before you record

- **Minimise the terminal you launch the conductor from** (or run it from another virtual desktop). KDE keeps an
  active fullscreen terminal above all other windows, so it would cover the four demo windows in the recording.
- `--snapshots` saves a PNG of every pane at key moments to `demo/out/stills/`: useful for slides, and for checking
  the layout without screen capture.

## Each take

```bash
./scripts/demo-up.sh                       # bring the stack up (after a reboot)
export OBS_WEBSOCKET_PASSWORD=...          # if using --recorder obs
~/.local/share/w3node-venv/bin/python demo/conductor.py --recorder obs --cleanup
python3 demo/edit.py "<path to the OBS video printed at the end>" --target 60
```

`--cleanup` deletes the cloned VM afterwards. `--stub-chain` is a development switch that skips the on-chain steps
(it injects a test rental into the pool's local state); never use it for the real recording.
Outputs go to `demo/out/` (git-ignored): `timeline.json` and the edited `demo-60s.mp4`.
