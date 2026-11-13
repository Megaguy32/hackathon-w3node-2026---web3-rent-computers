#!/usr/bin/env python3
"""Automated visual demo of the W3Node compute marketplace.

Drives real commands and real browser windows (Selenium) so a screen recording shows the genuine flow:
  1. clone a new provider VM from the golden image and watch it join the pool
  2. the provider publishes it on Ethereum (Sepolia)
  3. a throwaway demo consumer rents it
  4. Kubernetes runs a workload on that exact machine (interLink -> HTCondor -> Apptainer)
  5. proof: pod logs + HTCondor placement
and writes timeline.json so demo/edit.py can cut the recording down to ~60 s.

Usage (from the project root, with the venv):  ~/.local/share/w3node-venv/bin/python demo/conductor.py --help
"""
import argparse, getpass, json, os, re, secrets, subprocess, sys, time, urllib.request
from pathlib import Path
from selenium import webdriver
from selenium.common.exceptions import NoSuchElementException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By

ROOT = Path(__file__).resolve().parent.parent
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def load_env(path):
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = os.path.expandvars(v.strip().strip('"'))
    return env


ENV = {**load_env(ROOT / ".demo-laptop.env")}
PROFILE = ENV.get("MINIKUBE_PROFILE", "w3node-demo")
MARKET = os.environ.get("MARKETPLACE_URL", "http://127.0.0.1:8090")
STATE = Path(ENV.get("DEMO_STATE_DIR", str(Path.home() / ".local/state/w3node")))


class Timeline:
    """Segments are 'keep' (shown at normal speed) or 'fast' (waiting; sped up by edit.py)."""
    def __init__(self):
        self.t0 = time.monotonic(); self.segments = []; self.marks = []

    def now(self):
        return time.monotonic() - self.t0

    def span(self, label, mode):
        tl = self
        class _S:
            def __enter__(s): s.a = tl.now(); return s
            def __exit__(s, *e): tl.segments.append({"label": label, "mode": mode, "start": round(s.a, 2), "end": round(tl.now(), 2)})
        return _S()

    def mark(self, key, label=""):
        self.marks.append({"key": key, "label": label, "t": round(self.now(), 2)}); print(f"  [{self.now():6.1f}s] {key} {label}")


def api(path):
    with urllib.request.urlopen(MARKET + path, timeout=10) as r:
        return json.load(r)


# ---------------------------------------------------------------- recorders
class NoRecorder:
    def start(self): pass
    def stop(self): return None

class ManualRecorder:
    def start(self): input("Start your screen recorder now, then press Enter to begin the demo... ")
    def stop(self): input("Stop your screen recorder, then press Enter... "); return None

class ObsRecorder:
    """Needs OBS running with WebSocket enabled (Tools > WebSocket Server Settings) and a PipeWire screen source."""
    def __init__(self):
        import obsws_python as obs
        self.cl = obs.ReqClient(host="localhost", port=int(os.environ.get("OBS_WEBSOCKET_PORT", "4455")),
                                password=os.environ.get("OBS_WEBSOCKET_PASSWORD", ""), timeout=5)
    def start(self): self.cl.start_record(); time.sleep(1.0)
    def stop(self):
        time.sleep(1.0); return getattr(self.cl.stop_record(), "output_path", None)


# ---------------------------------------------------------------- browser panes
def make_driver():
    o = Options(); o.binary_location = os.environ.get("CHROMIUM", "/usr/bin/chromium")
    prof = STATE / "chrome-demo-profile"; prof.mkdir(parents=True, exist_ok=True)
    for a in (f"--user-data-dir={prof}", "--ozone-platform=x11", "--no-first-run", "--no-default-browser-check",
              "--password-store=basic", "--disable-features=Translate", "--hide-crash-restore-bubble"):
        o.add_argument(a)
    o.add_experimental_option("excludeSwitches", ["enable-automation"]); o.add_experimental_option("useAutomationExtension", False)
    o.set_capability("acceptInsecureCerts", True)
    return webdriver.Chrome(service=Service(os.environ.get("CHROMEDRIVER", "/usr/bin/chromedriver")), options=o)


def open_panes(d, with_cockpit):
    W, H = d.execute_script("return [screen.availWidth, screen.availHeight]")
    names = ["cockpit", "live", "terminal", "grafana"] if with_cockpit else ["live", "grafana", "terminal"]
    if with_cockpit:
        rect = {"cockpit": (0, 0, W // 2, H // 2), "live": (W // 2, 0, W // 2, H // 2), "terminal": (0, H // 2, W // 2, H // 2), "grafana": (W // 2, H // 2, W // 2, H // 2)}
    else:
        rect = {"live": (0, 0, W // 2, H), "grafana": (W // 2, 0, W // 2, H // 2), "terminal": (W // 2, H // 2, W // 2, H // 2)}
    handles = {}
    for i, n in enumerate(names):
        if i: d.switch_to.new_window("window")
        handles[n] = d.current_window_handle
    for n, h in handles.items():
        d.switch_to.window(h); x, y, w, hh = rect[n]; d.set_window_rect(x, y, w, hh)
    return handles


def raise_windows():
    """KDE's focus-stealing prevention keeps the launching terminal on top; mark the automation windows
    'always on top' (X11/XWayland windows only) so a screen recording shows them, not the terminal."""
    try:
        ids = subprocess.run(["xdotool", "search", "--onlyvisible", "--class", "chromium"], capture_output=True, text=True).stdout.split()
        for wid in ids:
            subprocess.run(["wmctrl", "-i", "-r", hex(int(wid)), "-b", "add,above"], capture_output=True)
        # An *active* fullscreen terminal stays above everything; activating our windows (a pager-style
        # request, which KWin allows) drops it. If your terminal is still on top, minimise it before recording.
        for wid in ids:
            subprocess.run(["wmctrl", "-i", "-a", hex(int(wid))], capture_output=True); time.sleep(0.15)
        return len(ids)
    except FileNotFoundError:
        print("  (xdotool/wmctrl not installed: raise the browser windows manually)"); return 0


def goto(d, handles, name, url):
    d.switch_to.window(handles[name]); d.get(url)


def login_grafana(d, handles):
    goto(d, handles, "grafana", "http://127.0.0.1:3000/login")
    try:
        d.find_element(By.CSS_SELECTOR, "input[name=user]").send_keys("admin")
        d.find_element(By.CSS_SELECTOR, "input[name=password]").send_keys(ENV.get("GRAFANA_ADMIN_PASSWORD", "w3node-demo"))
        d.find_element(By.CSS_SELECTOR, "button[type=submit]").click(); time.sleep(2)
    except NoSuchElementException:
        pass  # already logged in
    goto(d, handles, "grafana", "http://127.0.0.1:3000/d/w3node-compute-demo/w3node-compute-rental-demo?from=now-10m&to=now&refresh=5s&kiosk")


def login_cockpit(d, handles):
    goto(d, handles, "cockpit", "https://localhost:9090/machines"); time.sleep(2)
    try:
        user = d.find_element(By.ID, "login-user-input")
    except NoSuchElementException:
        return  # already logged in
    pw = os.environ.get("COCKPIT_PASSWORD") or getpass.getpass("Cockpit password for %s (not stored): " % os.environ.get("COCKPIT_USER", getpass.getuser()))
    user.send_keys(os.environ.get("COCKPIT_USER", getpass.getuser()))
    d.find_element(By.ID, "login-password-input").send_keys(pw); d.find_element(By.ID, "login-button").click(); time.sleep(3)
    goto(d, handles, "cockpit", "https://localhost:9090/machines")


# ---------------------------------------------------------------- terminal pane
class Terminal:
    def __init__(self, d, handle, tl, speed):
        self.d, self.h, self.tl, self.speed = d, handle, tl, speed
        d.switch_to.window(handle); d.get((Path(__file__).parent / "terminal.html").as_uri()); d.set_script_timeout(180)

    def caption(self, text):
        self.d.switch_to.window(self.h); self.d.execute_script("W3.caption(arguments[0])", text)

    def print(self, text):
        self.d.switch_to.window(self.h); self.d.execute_script("W3.print(arguments[0])", text)

    def run(self, cmd, label, quiet=lambda l: False):
        """Type the command (normal speed), then stream its real output (a 'fast' span while it runs)."""
        self.d.switch_to.window(self.h)
        with self.tl.span(f"type: {label}", "keep"):
            self.d.execute_async_script("const [c,s,done]=[arguments[0],arguments[1],arguments[2]]; W3.typeCmd(c,s).then(done)", cmd, self.speed)
        out = []
        with self.tl.span(f"run: {label}", "fast"):
            p = subprocess.Popen(["bash", "-lc", cmd], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 env={**os.environ, "PATH": f"{Path.home()}/.local/bin:{Path.home()}/.docker/cli-plugins:" + os.environ["PATH"]})
            buf = []
            for line in p.stdout:
                line = ANSI.sub("", line.rstrip("\n")); out.append(line)
                if not quiet(line): buf.append(line)
                if len(buf) >= 1:
                    self.d.execute_script("W3.printMany(arguments[0])", buf); buf = []
            rc = p.wait()
        return rc, out


def snapshot(d, handles, out_dir, tag):
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, h in handles.items():
        d.switch_to.window(h); (out_dir / f"{tag}-{name}.png").write_bytes(d.get_screenshot_as_png())


def wait_until(tl, key, label, fn, timeout=240, every=1.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            v = fn()
            if v: tl.mark(key, label); return v
        except Exception:
            pass
        time.sleep(every)
    raise TimeoutError(f"timed out waiting for {key}")


# ---------------------------------------------------------------- the demo
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--recorder", choices=["none", "manual", "obs"], default="manual")
    ap.add_argument("--no-cockpit", action="store_true", help="skip the Cockpit VM pane (no password needed)")
    ap.add_argument("--stub-chain", action="store_true", help="DEV ONLY: skip on-chain publish/rent and inject a test rental instead")
    ap.add_argument("--cleanup", action="store_true", help="delete the cloned VM afterwards")
    ap.add_argument("--keep-open", type=int, default=6, help="seconds to leave the final screen up")
    ap.add_argument("--type-speed", type=int, default=28, help="ms per typed character")
    ap.add_argument("--out", default=str(ROOT / "demo/out"))
    ap.add_argument("--snapshots", action="store_true", help="save a PNG of every pane at key moments to <out>/stills (handy for slides and for checking the layout)")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    vm = "w3node-provider-" + secrets.token_hex(2)

    print("Preflight..."); 
    if subprocess.run([str(ROOT / "scripts/demo-preflight.sh")], capture_output=True).returncode != 0:
        sys.exit("Preflight failed; run ./scripts/demo-preflight.sh and fix the FAIL lines first.")
    rec = {"none": NoRecorder, "manual": ManualRecorder, "obs": ObsRecorder}[a.recorder]()
    d = make_driver()
    try:
        handles = open_panes(d, not a.no_cockpit)
        goto(d, handles, "live", MARKET + "/live"); login_grafana(d, handles)
        if not a.no_cockpit: login_cockpit(d, handles)
        print(f"  raised {raise_windows()} browser windows")
        tl_pre = Timeline(); term = Terminal(d, handles["terminal"], tl_pre, a.type_speed)
        term.caption("W3Node · rent idle computers on Ethereum, run them from Kubernetes")
        raise_windows(); time.sleep(1)
        rec.start(); tl = Timeline(); term.tl = tl
        tl.mark("start", vm)

        # 1. spin up a provider VM
        term.caption("1/5  Spin up a new provider VM")
        rc, _ = term.run(f"./scripts/provider-vm.sh create {vm}", "create provider VM", quiet=lambda l: not l.strip())
        assert rc == 0, "VM creation failed"
        wait_until(tl, "tile_ready", vm, lambda: any(t["machine"] == vm and t["state"] == "ready" for t in api("/api/live")["tiles"]), 60)

        if a.stub_chain:
            # DEV ONLY: a test rental written straight into the pool's local state (no chain)
            rid = str(900 + secrets.randbelow(90))
            term.caption("(dev) injected test rental, no on-chain step")
            term.run(f"docker exec -i w3pool python3 -c \"import json,time;p='/run/w3node/rentals.json';d=json.load(open(p));d['{rid}']={{'rentalId':'{rid}','listingId':'0','consumer':'0xtest','provider':'0xtest','machineName':'{vm}','expiresAt':int(time.time())+1800,'paidWei':'0','createdAt':int(time.time())}};json.dump(d,open(p,'w'));print('test rental {rid} for {vm}')\"", "inject test rental")
        else:
            # 2. provider publishes the machine on-chain
            term.caption("2/5  The provider lists it on Ethereum")
            rc, lines = term.run(f"./scripts/chain-actions.sh publish {vm}", "publish listing")
            assert rc == 0, "publish failed"; lid = lines[-1].strip(); tl.mark("listing_sent", f"listing {lid}")
            wait_until(tl, "listing_visible", f"listing {lid}", lambda: any(t["machine"] == vm and t.get("listingId") == lid for t in api("/api/live")["tiles"]), 120)
            # 3. a consumer rents it
            term.caption("3/5  A consumer rents it: 0.001 ETH paid on-chain")
            rc, lines = term.run(f"./scripts/chain-actions.sh rent {lid}", "rent")
            assert rc == 0, "rent failed"; rid = lines[-1].strip(); tl.mark("rent_sent", f"rental {rid}")
            wait_until(tl, "rental_visible", f"rental {rid}", lambda: any(r["rentalId"] == rid for r in api("/api/rentals")), 120)
            time.sleep(2.5)

        # 4. Kubernetes runs it on that machine
        term.caption(f"4/5  Kubernetes runs a pod on rental #{rid}")
        term.run(f"./scripts/demo-laptop.sh run {rid} load", "run pod", quiet=lambda l: "Rendered manifest" in l or "NAME" in l)
        wait_until(tl, "pod_running", "", lambda: subprocess.run(["kubectl", "--context", PROFILE, "get", "pod", "w3node-compute-load", "-o", "jsonpath={.status.phase}"], capture_output=True, text=True).stdout in ("Running", "Succeeded"), 120, 2)
        wait_until(tl, "tile_live", vm, lambda: any(t["machine"] == vm and t["state"] == "live" for t in api("/api/live")["tiles"]), 60, 1)
        if a.snapshots:
            time.sleep(12); snapshot(d, handles, out / "stills", "running")
        with tl.span("workload running", "fast"):
            wait_until(tl, "pod_succeeded", "", lambda: subprocess.run(["kubectl", "--context", PROFILE, "get", "pod", "w3node-compute-load", "-o", "jsonpath={.status.phase}"], capture_output=True, text=True).stdout == "Succeeded", 240, 2)

        # 5. proof
        term.caption("5/5  Proof: it ran on the machine we rented")
        term.run("./scripts/demo-laptop.sh logs w3node-compute-load 2>&1 | grep -v '^INFO'", "pod logs")
        term.run("docker exec w3pool condor_history -limit 1 -af ClusterId RentalId JobStatus LastRemoteHost", "HTCondor placement")
        term.caption("Ethereum records the rental · HTCondor schedules it · interLink makes it Kubernetes")
        tl.mark("done")
        if a.snapshots: snapshot(d, handles, out / "stills", "done")
        with tl.span("closing screen", "keep"):
            time.sleep(a.keep_open)
        video = rec.stop()
        (out / "timeline.json").write_text(json.dumps({"vm": vm, "rental": rid, "video": video, "segments": tl.segments, "marks": tl.marks}, indent=2))
        print(f"\nTimeline written to {out/'timeline.json'}" + (f"; video: {video}" if video else ""))
    finally:
        d.quit()
        if a.cleanup:
            subprocess.run([str(ROOT / "scripts/provider-vm.sh"), "delete", vm])


if __name__ == "__main__":
    main()
