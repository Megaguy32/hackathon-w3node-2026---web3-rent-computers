#!/usr/bin/env python3
"""Add smooth zooms, highlight rings and captions to the edited 60 s demo (demo/out/demo-60s.mp4).

The raw recording is a 2x2 tiled screen (top-left Cockpit, top-right marketplace Live view, bottom-left terminal,
bottom-right Grafana). This script re-renders the edited video with a virtual camera that zooms into the tile that
matters at each moment, draws rings around the evidence, and shows a caption for each step. Event times come from
demo/out/timeline.json, mapped through the same speed-up rules as demo/edit.py, so it stays in sync.

  python demo/annotate.py                  # -> demo/out/demo-60s-annotated.mp4
  python demo/annotate.py --stills         # PNG stills at key moments, for review

Needs: ffmpeg/ffprobe, python3 with pillow + numpy. Ring coordinates are in source pixels (1920x1200).
"""
import argparse, json, math, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = Path(__file__).resolve().parent
W, H, FPS = 1920, 1200, 30
FONT_B = "/usr/share/fonts/noto/NotoSans-Bold.ttf"
FONT_R = "/usr/share/fonts/noto/NotoSans-SemiBold.ttf"
BLUE, PURPLE, GREEN, ORANGE = (79, 140, 255), (155, 107, 255), (49, 208, 127), (255, 171, 64)


# ---------- time mapping (mirrors demo/edit.py) ----------
def load_timeline(tl_path, target=60.0):
    tl = json.loads(Path(tl_path).read_text())
    segs = sorted([s for s in tl["segments"] if s["end"] - s["start"] > 0.05], key=lambda s: s["start"])
    filled, cur = [], 0.0
    for s in segs:
        if s["start"] - cur > 0.2:
            filled.append({"label": "(gap)", "mode": "fast", "start": cur, "end": s["start"]})
        filled.append(s); cur = max(cur, s["end"])
    keep = sum(s["end"] - s["start"] for s in filled if s["mode"] == "keep")
    fast = sum(s["end"] - s["start"] for s in filled if s["mode"] == "fast")
    ks = max(1.0, keep / (0.65 * target)); budget = target - keep / ks
    fs = max(1.0, fast / budget) if budget > 1 else 40.0
    out, o = [], 0.0
    for s in filled:
        sp = ks if s["mode"] == "keep" else fs
        d = (s["end"] - s["start"]) / sp
        out.append({**s, "o0": o, "o1": o + d, "speed": sp}); o += d
    return tl, out


def make_mapper(segs):
    def src2out(t):
        for s in segs:
            if s["start"] <= t <= s["end"]:
                return s["o0"] + (t - s["start"]) / s["speed"]
        return segs[-1]["o1"] if t > segs[-1]["end"] else 0.0
    return src2out


# ---------- the story: camera moves, rings, captions (output seconds; None = resolved from marks) ----------
def build_story(M):
    """M: dict of mark key -> output time."""
    ready, listed, rented, running, ok, done = M["tile_ready"], M["listing_visible"], M["rental_visible"], M["tile_live"], M["pod_succeeded"], M["done"]
    TL, TR, BL, BR = (480, 300), (1440, 300), (480, 900), (1440, 900)
    cam = [  # (start, end of the move, centre x, centre y, zoom)
        (0.0, 0.0, 960, 600, 1.0),
        (1.0, 2.0, *BL, 2.0),                 # terminal: VM boots
        (ready - .4, ready + .6, *TR, 2.0),   # live view: tile appears, listing, rental
        (rented - 1.2, rented - .2, *BL, 2.0),   # terminal: pod submitted
        (running - .4, running + .6, *TR, 2.0),  # tile goes live
        (running + 3.0, running + 4.2, 560, 330, 2.6),  # Cockpit: CPU of the rented VM
        (running + 9.0, running + 10.2, *BR, 2.0),      # Grafana: fleet counters
        (ok - .4, ok + .6, *BL, 2.0),         # terminal: proof
        (done + 2.4, done + 3.6, 960, 600, 1.0),  # back to the full picture
    ]
    # rings in SOURCE pixels (x0, y0, x1, y1), time window, label, colour, label side
    rings = [
        (ready + .2, listed - .2, (1138, 408, 1332, 500), "New VM: ready", GREEN, "below"),
        (listed, rented - 1.2, (1536, 218, 1732, 260), "Listed on Ethereum", BLUE, "left"),
        (rented, running - .2, (1536, 218, 1732, 260), "Rental #5 on-chain", ORANGE, "left"),
        (running, running + 3.0, (1138, 408, 1332, 500), "LIVE", BLUE, "below"),
        (running + 5.4, running + 9.4, (205, 348, 920, 382), "Rented VM: CPU up to 97%", ORANGE, "below"),
        (M["htc"] + .4, done - .1, (22, 1018, 600, 1046), "Pod ran on w3node-provider-e2b5", GREEN, "above"),
        (done, done + 2.0, (20, 1098, 330, 1126), "HTCondor: same machine", GREEN, "above"),
    ]
    caps = [  # (start, end, step number or None, text)
        (0.0, 1.6, None, "Real Sepolia transactions. Real VMs. Real Kubernetes."),
        (1.6, ready, 1, "A new provider VM boots from an image"),
        (ready, listed, 2, "Joined the pool in 25 s and listed on Ethereum"),
        (listed, rented - 1.2, 3, "A consumer rents it: 0.001 ETH, paid to the provider"),
        (rented - 1.2, running - .4, 4, "A Kubernetes pod is submitted with the rental ID"),
        (running - .4, running + 3.0, None, "The rented machine goes live"),
        (running + 3.0, running + 9.4, None, "Workload running: watch the rented VM's CPU"),
        (running + 9.4, ok - .4, None, "Grafana tracks the rented machine live"),
        (ok - .4, M["htc"], 5, "Proof: the pod's own logs name the machine"),
        (M["htc"], done + 2.2, None, "HTCondor confirms: the job ran on exactly that machine"),
        (done + 2.2, 60.0, None, "End to end, on Ethereum Sepolia"),
    ]
    return cam, rings, caps


# ---------- camera ----------
def ease(x):
    x = min(1.0, max(0.0, x)); return x * x * (3 - 2 * x)


def camera_at(cam, t):
    state = cam[0][2:]  # cx, cy, z
    for (a, b, cx, cy, z) in cam[1:]:
        if t < a: break
        k = ease((t - a) / max(b - a, 1e-6))
        sx, sy, sz = state
        state = (sx + (cx - sx) * k, sy + (cy - sy) * k, math.exp(math.log(sz) + (math.log(z) - math.log(sz)) * k))
        if t >= b: state = (cx, cy, z)
        else: break
    cx, cy, z = state
    vw, vh = W / z, H / z
    x0 = min(max(cx - vw / 2, 0), W - vw); y0 = min(max(cy - vh / 2, 0), H - vh)
    return x0, y0, z


# ---------- drawing ----------
_fonts = {}
def font(path, size):
    k = (path, size)
    if k not in _fonts: _fonts[k] = ImageFont.truetype(path, size)
    return _fonts[k]


def window_alpha(t, a, b, fade=.35):
    if t < a or t > b: return 0.0
    return min(1.0, (t - a) / fade, (b - t) / fade)


def pill(draw, xy_center, text, color, size=34, alpha=1.0, anchor="mm", num=None):
    f = font(FONT_B, size)
    tw = draw.textlength(text, font=f); pad = 26
    nw = size + 22 if num else 0
    w, h = tw + pad * 2 + nw, size + 30
    cx, cy = xy_center
    x0, y0 = cx - w / 2, cy - h / 2
    a = int(255 * alpha)
    draw.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=h / 2, fill=(11, 14, 23, int(235 * alpha)), outline=color + (a,), width=3)
    tx = x0 + pad
    if num:
        r = size / 2 + 4
        draw.ellipse((x0 + 14, cy - r, x0 + 14 + 2 * r, cy + r), fill=color + (a,))
        draw.text((x0 + 14 + r, cy + 1), str(num), font=font(FONT_B, size - 6), fill=(11, 14, 23, a), anchor="mm")
        tx = x0 + 14 + 2 * r + 14
    draw.text((tx, cy + 1), text, font=f, fill=(238, 241, 251, a), anchor="lm")
    return (x0, y0, x0 + w, y0 + h)


def render_frame(frame_rgb, t, cam, rings, caps, fast_ranges):
    x0, y0, z = camera_at(cam, t)
    img = Image.fromarray(frame_rgb)
    if z > 1.001:
        img = img.resize((W, H), Image.LANCZOS, box=(x0, y0, x0 + W / z, y0 + H / z))
    over = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(over)
    # rings and their labels
    for (a, b, (rx0, ry0, rx1, ry1), label, col, side) in rings:
        al = window_alpha(t, a, b)
        if al <= 0: continue
        ox0, oy0, ox1, oy1 = (rx0 - x0) * z, (ry0 - y0) * z, (rx1 - x0) * z, (ry1 - y0) * z
        if ox1 < 0 or oy1 < 0 or ox0 > W or oy0 > H: continue  # off screen right now
        pulse = 1 + .04 * math.sin(t * 6)
        g = 8 * pulse
        d.rounded_rectangle((ox0 - g, oy0 - g, ox1 + g, oy1 + g), radius=16, outline=col + (int(255 * al),), width=6)
        cx = (ox0 + ox1) / 2
        if side == "below": c = (cx, oy1 + 60)
        elif side == "above": c = (cx, oy0 - 56)
        elif side == "left": c = (ox0 - 20 - (font(FONT_B, 32).getlength(label) + 70) / 2, (oy0 + oy1) / 2)
        else: c = (ox1 + 20 + (font(FONT_B, 32).getlength(label) + 70) / 2, (oy0 + oy1) / 2)
        c = (min(max(c[0], 200), W - 200), min(max(c[1], 150), H - 40))
        pill(d, c, label, col, size=32, alpha=al)
    # caption (top centre)
    for (a, b, num, text) in caps:
        al = window_alpha(t, a, b, .3)
        if al > 0:
            pill(d, (W / 2, 62), text, BLUE if num is None else PURPLE, size=38, alpha=al, num=num)
    # time-lapse badge
    for (a, b, sp) in fast_ranges:
        al = window_alpha(t, a, b, .25)
        if al > 0:
            f = font(FONT_B, 28); s = f"Time-lapse x{sp:.0f}"
            tw = d.textlength(s, font=f)
            d.rounded_rectangle((W - tw - 78, 24, W - 24, 76), radius=26, fill=(11, 14, 23, int(220 * al)), outline=ORANGE + (int(255 * al),), width=2)
            d.text((W - 24 - (tw + 54) / 2, 51), s, font=f, fill=ORANGE + (int(255 * al),), anchor="mm")
    img = img.convert("RGBA"); img.alpha_composite(over)
    return np.asarray(img.convert("RGB"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", default=str(HERE / "out/demo-60s.mp4"))
    ap.add_argument("--timeline", default=str(HERE / "out/timeline.json"))
    ap.add_argument("--out", default=str(HERE / "out/demo-60s-annotated.mp4"))
    ap.add_argument("--stills", action="store_true")
    a = ap.parse_args()

    tl, segs = load_timeline(a.timeline)
    s2o = make_mapper(segs)
    M = {m["key"]: s2o(m["t"]) for m in tl["marks"]}
    htc = next(s for s in segs if s["label"] == "type: HTCondor placement")
    M["htc"] = htc["o0"]
    cam, rings, caps = build_story(M)
    fast_ranges = [(s["o0"], s["o1"], s["speed"]) for s in segs if s["mode"] == "fast" and s["o1"] - s["o0"] > 1.5]
    print("marks (output s):", {k: round(v, 1) for k, v in M.items()})

    if a.stills:
        outdir = HERE / "out/annotated-stills"; outdir.mkdir(parents=True, exist_ok=True)
        for t in [0.8, 5, M["tile_ready"] + 2, M["listing_visible"] + 1.5, M["rental_visible"] + 1, M["tile_live"] + 1.5,
                  M["tile_live"] + 6, M["tile_live"] + 12, M["htc"] + 1.2, M["done"] + 1.0, 58]:
            raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", a.video, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                 capture_output=True, check=True).stdout
            fr = np.frombuffer(raw, np.uint8).reshape(H, W, 3)
            Image.fromarray(render_frame(fr, t, cam, rings, caps, fast_ranges)).save(outdir / f"t{t:05.1f}.png")
        print("stills in", outdir); return

    dec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", a.video, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    enc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
                            "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", a.out], stdin=subprocess.PIPE)
    n, size = 0, W * H * 3
    while True:
        buf = dec.stdout.read(size)
        if len(buf) < size: break
        enc.stdin.write(render_frame(np.frombuffer(buf, np.uint8).reshape(H, W, 3), n / FPS, cam, rings, caps, fast_ranges).tobytes())
        n += 1
        if n % 300 == 0: print(f"{n} frames", flush=True)
    enc.stdin.close(); enc.wait(); dec.wait()
    print(f"done: {n} frames -> {a.out}")


if __name__ == "__main__":
    sys.exit(main())
