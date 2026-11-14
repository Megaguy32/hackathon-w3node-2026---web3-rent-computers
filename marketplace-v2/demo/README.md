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

## Animated pitch scenes

`demo/animation/` holds six animated pitch scenes (hook, problem, how it works, proof, why Web3/RWA, end card) as one HTML page driven by a time function, rendered deterministically to MP4 with headless Chromium and ffmpeg:

```bash
pip install selenium                       # plus chromium, chromedriver and ffmpeg on PATH
python demo/animation/render.py --stills   # PNG stills for review
python demo/animation/render.py            # one MP4 per scene + pitch-animation.mp4 (68 s) in demo/animation/out/
```

Open `scenes.html?scene=3&t=10` in a browser to preview any scene at any time. Every number on screen is one measured on the rehearsal stack.

## Zooms and annotations on the 60 s cut

`demo/annotate.py` re-renders `demo/out/demo-60s.mp4` with a virtual camera that zooms into the relevant tile of the 2x2 screen at each step, rings around the evidence (new VM tile, rental on-chain, rented VM CPU, pod logs, HTCondor result), step captions, and a "Time-lapse" badge on sped-up sections. Event times come from `timeline.json`, mapped with the same speed-up rules as `edit.py`.

```bash
pip install pillow numpy
python demo/annotate.py --stills   # review stills in demo/out/annotated-stills/
python demo/annotate.py            # -> demo/out/demo-60s-annotated.mp4
python demo/annotate.py --no-zoom  # same rings and captions, full 2x2 view -> demo-60s-annotated-nozoom.mp4
```

Ring coordinates are in source pixels of the 1920x1200 recording; adjust them in `build_story()` if you re-record with a different layout.

## The final pitch video

The submitted video ([release v1.0.0](https://github.com/Megaguy32/hackathon-w3node-2026---web3-rent-computers/releases/tag/v1.0.0)) is built from three pieces, all reproducible from this folder:

1. **Animated scenes**: `animation/render.py --scenes 1,2,3,4,5,6 --durations "1=10,2=18.5,3=32.9,4=18.8,5=16.3,6=9.5"`. Scenes stretch to fit the voiceover.
   Extra scenes (7 who it's for, 8 under the hood, 9 roadmap) are included but not used in the final cut.
2. **The recorded demo with annotations**: `annotate.py --no-zoom` (see above).
3. **Voiceover**: 13 clips, one per script section, cut from a single read-through.
   `assemble.py --voice-dir <dir> --prefix w3node- --prenormalised --out out/pitch-final.mp4` lays each clip at its place in the timeline,
   holds the last demo frame so the narration can finish, and mixes the voice. Use `--no-voice` for a silent cut.

`assemble.py` expects the scene clips in `animation/out/` and `out/demo-60s-annotated-nozoom.mp4`.
