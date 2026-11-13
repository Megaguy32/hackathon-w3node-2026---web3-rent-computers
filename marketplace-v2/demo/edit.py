#!/usr/bin/env python3
"""Cut a raw screen recording down to a target length using demo/out/timeline.json.

'keep' segments (typing, key moments) stay at normal speed; 'fast' segments (waiting for boots, chain
confirmations, the workload) are sped up just enough to hit the target. Needs ffmpeg.
Usage: python3 demo/edit.py <raw-video> [--target 60] [--timeline demo/out/timeline.json] [--out demo/out/demo-60s.mp4]
"""
import argparse, json, subprocess, sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("video"); ap.add_argument("--target", type=float, default=60.0)
ap.add_argument("--timeline", default=str(Path(__file__).parent / "out/timeline.json"))
ap.add_argument("--out", default=str(Path(__file__).parent / "out/demo-60s.mp4"))
ap.add_argument("--size", default="1920:-2", help="ffmpeg scale, e.g. 1920:-2")
a = ap.parse_args()

tl = json.loads(Path(a.timeline).read_text())
segs = [s for s in tl["segments"] if s["end"] - s["start"] > 0.05]
segs.sort(key=lambda s: s["start"])
# Gaps between recorded segments (waiting that was not wrapped in a span) are sped up, not dropped.
filled, cursor = [], 0.0
for s in segs:
    if s["start"] - cursor > 0.2:
        filled.append({"label": "(gap)", "mode": "fast", "start": cursor, "end": s["start"]})
    filled.append(s); cursor = max(cursor, s["end"])
segs = filled
keep = sum(s["end"] - s["start"] for s in segs if s["mode"] == "keep")
fast = sum(s["end"] - s["start"] for s in segs if s["mode"] == "fast")
# keep segments may use at most 65% of the target; they are sped up uniformly if they exceed it
keep_speed = max(1.0, keep / (0.65 * a.target))
budget = a.target - keep / keep_speed
fast_speed = max(1.0, fast / budget) if budget > 1 else 40.0
print(f"keep {keep:.1f}s (x{keep_speed:.2f}), fast {fast:.1f}s (x{fast_speed:.1f}) -> ~{keep/keep_speed + fast/fast_speed:.1f}s")

parts, labels = [], []
for i, s in enumerate(segs):
    sp = keep_speed if s["mode"] == "keep" else fast_speed
    parts.append(f"[0:v]trim=start={s['start']}:end={s['end']},setpts=(PTS-STARTPTS)/{sp:.4f}[v{i}]")
    labels.append(f"[v{i}]")
graph = ";".join(parts) + f";{''.join(labels)}concat=n={len(segs)}:v=1:a=0,scale={a.size},format=yuv420p[out]"
cmd = ["ffmpeg", "-y", "-i", a.video, "-filter_complex", graph, "-map", "[out]", "-an", "-c:v", "libx264", "-crf", "20", "-preset", "medium", a.out]
print(" ".join(cmd[:6]), "...")
sys.exit(subprocess.run(cmd).returncode)
