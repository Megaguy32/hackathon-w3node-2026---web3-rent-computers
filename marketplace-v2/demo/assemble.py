#!/usr/bin/env python3
"""Assemble the full pitch video: animated scenes + annotated recorded demo + your voiceover.

Inputs
  - animation scenes 1-6 rendered to the lengths below (demo/animation/render.py --scenes ... --durations ...)
  - demo/out/demo-60s-annotated-nozoom.mp4 (demo/annotate.py --no-zoom)
  - 13 voice takes (any audio files, e.g. GNOME Sound Recorder), mapped to sections in TAKES

  python demo/assemble.py --voice-dir ~/.local/share/org.gnome.SoundRecorder --prefix w3node- --out demo/out/pitch-full-voiced.mp4
  python demo/assemble.py --no-voice     # silent version

Each take is trimmed of leading/trailing silence and loudness-normalised, then placed at the start offset given
below; the video sections are as long as their voice plus a short pad. Needs ffmpeg/ffprobe.
"""
import argparse, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANIM = HERE / "animation/out"
DEMO = HERE / "out/demo-60s-annotated-nozoom.mp4"
SCENES = {1: "1-hook.mp4", 2: "2-problem.mp4", 3: "3-how-it-works.mp4", 4: "4-proof.mp4", 5: "5-why-web3-rwa.mp4", 6: "6-end-card.mp4"}
# Section order on screen: (kind, key). Voice takes inside each section are placed in order, with the given minimum start
# (seconds from the section start) so they line up with what is on screen.
SECTIONS = [
    ("scene", 1, [(1, 0.5)]),
    ("scene", 2, [(2, 0.3)]),
    ("scene", 3, [(3, 0.3), (4, None)]),                       # take 4 follows take 3 directly
    ("demo", None, [(5, 0.3), (6, 25.0), (7, 36.0), (8, 43.0), (9, 50.2), (10, 55.4)]),
    ("scene", 4, [(11, 0.3)]),
    ("scene", 5, [(12, 0.3)]),
    ("scene", 6, [(13, 0.3)]),
]
GAP = 0.25  # minimum silence between takes in one section


def dur(path):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                                capture_output=True, text=True, check=True).stdout.strip())


def prepare(src, dst, normalise=True):
    if not normalise:  # clips already cut and levelled
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "wav", "-i", str(src), "-ar", "48000", "-ac", "1", str(dst)], check=True); return
    af = ("silenceremove=start_periods=1:start_threshold=-42dB:start_silence=0.08,areverse,"
          "silenceremove=start_periods=1:start_threshold=-42dB:start_silence=0.12,areverse,loudnorm=I=-16:TP=-1.5:LRA=11")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-af", af, "-ar", "48000", "-ac", "1", str(dst)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice-dir"); ap.add_argument("--prefix", default="w3node-")
    ap.add_argument("--no-voice", action="store_true")
    ap.add_argument("--prenormalised", action="store_true", help="voice clips are wav files that are already cut and levelled")
    ap.add_argument("--out", default=str(HERE / "out/pitch-full-voiced.mp4"))
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="pitch-"))

    voice = {}
    if not a.no_voice:
        for i in range(1, 14):
            src = Path(a.voice_dir).expanduser() / f"{a.prefix}{i}"
            if not src.exists(): sys.exit(f"missing take {src}")
            voice[i] = tmp / f"v{i}.wav"; prepare(src, voice[i], not a.prenormalised)

    # lay out: section start times, voice placements, section lengths
    t, placements, parts = 0.0, [], []
    for kind, key, takes in SECTIONS:
        base_len = dur(ANIM / SCENES[key]) if kind == "scene" else dur(DEMO)
        cursor = 0.0
        if voice:
            for take, minstart in takes:
                start = max(cursor + (GAP if cursor else 0), minstart) if minstart is not None else cursor + GAP
                placements.append((take, t + start)); cursor = start + dur(voice[take])
        sect_len = max(base_len, cursor + 0.6)
        parts.append((kind, key, base_len, sect_len)); t += sect_len
    total = t
    print(f"sections: {[(k, round(l, 1)) for _, k, _, l in parts]}  total {total:.1f}s")

    inputs, vf = [], []
    for n, (kind, key, base_len, sect_len) in enumerate(parts):
        inputs += ["-i", str(ANIM / SCENES[key] if kind == "scene" else DEMO)]
        pad = sect_len - base_len
        scale = "scale=-2:1080,pad=1920:1080:(ow-iw)/2:0:color=0x0b0e17" if kind == "demo" else "scale=1920:1080"
        hold = f",tpad=stop_mode=clone:stop_duration={pad:.3f}" if pad > 0.01 else ""
        vf.append(f"[{n}:v]{scale}{hold},setsar=1,fps=30,format=yuv420p[v{n}]")
    graph = ";".join(vf) + ";" + "".join(f"[v{n}]" for n in range(len(parts))) + f"concat=n={len(parts)}:v=1:a=0[v]"
    maps = ["-map", "[v]"]
    if voice:
        base = len(parts)
        for i, (take, at) in enumerate(placements):
            inputs += ["-i", str(voice[take])]
            graph += f";[{base + i}:a]adelay={int(at * 1000)}:all=1[a{i}]"
        graph += ";" + "".join(f"[a{i}]" for i in range(len(placements))) + f"amix=inputs={len(placements)}:normalize=0:duration=longest,alimiter=limit=0.95[a]"
        maps += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"]
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", graph, *maps,
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-movflags", "+faststart", a.out], check=True)
    print(f"done: {a.out} ({dur(a.out):.1f}s)")


if __name__ == "__main__":
    sys.exit(main())
