#!/usr/bin/env python3
"""Render the animated pitch scenes (scenes.html) to MP4, deterministically, frame by frame.

  python demo/animation/render.py --stills            # a few PNG stills per scene for review
  python demo/animation/render.py                      # one MP4 per scene + pitch-animation.mp4 (all scenes)
  python demo/animation/render.py --scene 3            # just one scene

Needs: chromium + chromedriver, ffmpeg, python `selenium`. Output goes to demo/animation/out/.
"""
import argparse, base64, subprocess, sys
from pathlib import Path
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FPS = 30
NAMES = {1: "hook", 2: "problem", 3: "how-it-works", 4: "proof", 5: "why-web3-rwa", 6: "end-card"}


def driver():
    o = Options()
    o.binary_location = "/usr/bin/chromium"
    for a in ("--headless=new", "--no-sandbox", "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1920,1080"):
        o.add_argument(a)
    d = webdriver.Chrome(options=o)
    d.execute_cdp_cmd("Emulation.setDeviceMetricsOverride", {"width": 1920, "height": 1080, "deviceScaleFactor": 1, "mobile": False})
    d.get((HERE / "scenes.html").as_uri() + "?render=1")
    return d


def shot(d, scene, t):
    d.execute_script("renderFrame(arguments[0], arguments[1])", scene, t)
    r = d.execute_cdp_cmd("Page.captureScreenshot", {"format": "png"})
    return base64.b64decode(r["data"])


def render_scene(d, scene, dur):
    out = OUT / f"{scene}-{NAMES[scene]}.mp4"
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", str(FPS), "-i", "-",
                           "-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)],
                          stdin=subprocess.PIPE)
    n = int(dur * FPS)
    for i in range(n):
        ff.stdin.write(shot(d, scene, i / FPS))
    ff.stdin.close(); ff.wait()
    print(f"scene {scene} {NAMES[scene]}: {n} frames -> {out.name}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stills", action="store_true")
    ap.add_argument("--scene", type=int)
    a = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    d = driver()
    try:
        dur = d.execute_script("return DUR")
        dur = {int(k): v for k, v in dur.items()}
        scenes = [a.scene] if a.scene else sorted(dur)
        if a.stills:
            (OUT / "stills").mkdir(exist_ok=True)
            for s in scenes:
                for frac in (0.25, 0.6, 0.9):
                    t = dur[s] * frac
                    (OUT / "stills" / f"s{s}-{int(frac*100)}.png").write_bytes(shot(d, s, t))
            print("stills in", OUT / "stills"); return
        files = [render_scene(d, s, dur[s]) for s in scenes]
        if not a.scene:
            lst = OUT / "concat.txt"
            lst.write_text("".join(f"file '{f.name}'\n" for f in files))
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy",
                            str(OUT / "pitch-animation.mp4")], check=True)
            lst.unlink()
            print("combined ->", OUT / "pitch-animation.mp4")
    finally:
        d.quit()


if __name__ == "__main__":
    sys.exit(main())
