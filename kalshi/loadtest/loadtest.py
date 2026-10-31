#!/usr/bin/env python3
"""loadtest.py — loads a full Kalshi seed (every tape in it, as one group)
into one kalshi-twin and reports what the load costs: time to prepare, time
to the first checkpoint, time to load the inject schedule, and the twin's RSS
loaded and at peak, sampled once a second.

Usage:
  python3 loadtest.py --seed SEED --twin ./kalshi-twin
  python3 loadtest.py --seed SEED --rystic rystic

Needs only the Python 3 standard library. See README.md.
"""
import argparse
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def parse_args():
    ap = argparse.ArgumentParser(description="Load a whole Kalshi seed into one twin and measure it.")
    ap.add_argument("--seed", required=True, help="seed dir: manifest.json, inject.json, tape/events/<ticker>/")
    who = ap.add_mutually_exclusive_group(required=True)
    who.add_argument("--twin", metavar="BIN", help="kalshi-twin binary to boot directly")
    who.add_argument("--rystic", metavar="CLI", help="rystic CLI; boots `rystic run kalshi-twin` in the foreground")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--inject-mode", choices=("post", "start"), default="post",
                    help="post: POST /_rystic/inject with ats shifted by rebase_offset_ms after the checkpoint; "
                         "start: pass the file in /_replay/start, ats on tape time (kalshi-twin 0.0.47+, needs state_set)")
    ap.add_argument("--inject", help="inject file (default SEED/inject.json)")
    ap.add_argument("--metadata", choices=("on", "off"), default="off", help="RYSTIC_REPLAY_METADATA for the twin")
    ap.add_argument("--checkpoint-ms", type=int,
                    help="first pause, absolute tape ms (default: manifest.json start + 1 ms)")
    ap.add_argument("--load-timeout-s", type=float, default=14400, help="give up on prepare/start after this long")
    ap.add_argument("--out", help="write the JSON result here too")
    return ap.parse_args()


# --- HTTP --------------------------------------------------------------------

BASE = ""


def req(method, path, body=None, timeout=60):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw, code = resp.read(), resp.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    try:
        return code, (json.loads(raw) if raw else None)
    except ValueError:
        return code, raw.decode(errors="replace")


def must(code, body, ok, what):
    if code not in ok:
        sys.exit(f"{what}: HTTP {code}: {str(body)[:500]}")


# --- memory --------------------------------------------------------------------

def tree_rss_mb(root):
    """RSS of root and every descendant: under `rystic run` the twin is the CLI's child."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    kids, rss = {}, {}
    for line in out.splitlines():
        f = line.split()
        if len(f) != 3:
            continue
        pid, ppid, kb = int(f[0]), int(f[1]), int(f[2])
        kids.setdefault(ppid, []).append(pid)
        rss[pid] = kb
    total, todo = 0, [root]
    while todo:
        p = todo.pop()
        total += rss.get(p, 0)
        todo.extend(kids.get(p, []))
    return total / 1024


class Sampler(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.stop, self.peak, self.samples, self.t0 = pid, False, 0.0, [], time.time()

    def run(self):
        while not self.stop:
            r = tree_rss_mb(self.pid)
            self.peak = max(self.peak, r)
            self.samples.append([round(time.time() - self.t0, 1), round(r)])
            time.sleep(1)

    def now(self):
        r = tree_rss_mb(self.pid)
        self.peak = max(self.peak, r)
        return round(r)


# --- seed ------------------------------------------------------------------------

def seed_markets(seed):
    ev = os.path.join(seed, "tape", "events")
    if not os.path.isdir(ev):
        sys.exit(f"{ev}: not a directory")
    dot = next(iter(glob.iglob(os.path.join(seed, "tape", "**", "._*"), recursive=True)), None)
    if dot:
        sys.exit(f"{dot}: macOS AppleDouble files in the seed; delete them first: "
                 f"find {os.path.join(seed, 'tape')} -name '._*' -delete")
    mk = sorted(d for d in os.listdir(ev) if os.path.isdir(os.path.join(ev, d)))
    if not mk:
        sys.exit(f"{ev}: no tapes")
    return mk


def default_checkpoint(seed):
    m = json.load(open(os.path.join(seed, "manifest.json")))
    start = datetime.fromisoformat(m["start"].replace("Z", "+00:00"))
    return int(start.timestamp() * 1000) + 1


def shifted(events, offset_ms):
    out = []
    for e in events:
        t = datetime.fromisoformat(e["at"].replace("Z", "+00:00")) + timedelta(milliseconds=offset_ms)
        e2 = dict(e)
        e2["at"] = t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        out.append(e2)
    return out


# --- twin ------------------------------------------------------------------------

def port_free(port):
    with socket.socket() as so:
        return so.connect_ex(("127.0.0.1", port)) != 0


def boot(a, tape_dir, log):
    if not port_free(a.port):
        sys.exit(f":{a.port} already has a listener; stop it or pass --port")
    if a.twin:
        env = dict(os.environ, RYSTIC_ADDR=f":{a.port}", KALSHI_CAPTURE_DIR=tape_dir,
                   RYSTIC_REPLAY_METADATA=a.metadata)
        cmd = [a.twin]
    else:
        env = dict(os.environ)
        cmd = [a.rystic, "run", "kalshi-twin", "--tapes", tape_dir, "--port", str(a.port),
               "--env", f"RYSTIC_REPLAY_METADATA={a.metadata}"]
    p = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(600):
        if p.poll() is not None:
            sys.exit(f"twin exited with {p.returncode}; see {log.name}")
        try:
            if req("GET", "/_replay/status", timeout=5)[0] == 200:
                return p
        except Exception:
            pass
        time.sleep(0.5)
    stop(p)
    sys.exit("twin did not answer /_replay/status in 300 s")


def stop(p):
    if p.poll() is not None:
        return
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(30)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()


def wait_checkpoint(cp, timeout):
    t = time.time()
    while time.time() - t < timeout:
        st = req("GET", "/_replay/status")[1] or {}
        if st.get("at_checkpoint_ms") == cp:
            return st
        if st.get("done") or (not st.get("playing") and st.get("at_checkpoint_ms") is None and time.time() - t > 5):
            sys.exit(f"replay stopped short of checkpoint {cp}: {json.dumps(st)[:500]}")
        time.sleep(0.5)
    sys.exit(f"no checkpoint {cp} after {timeout:.0f} s")


# --- main ------------------------------------------------------------------------

def main():
    global BASE
    a = parse_args()
    seed = os.path.abspath(os.path.expanduser(a.seed))
    tape_dir = os.path.join(seed, "tape")
    inject = os.path.abspath(a.inject or os.path.join(seed, "inject.json"))
    cp = a.checkpoint_ms or default_checkpoint(seed)
    BASE = f"http://localhost:{a.port}"
    markets = seed_markets(seed)
    events = json.load(open(inject))["events"] if a.inject_mode == "post" else None

    out = {"seed": seed, "tapes": len(markets), "boot": "twin" if a.twin else "rystic",
           "inject_mode": a.inject_mode, "metadata": a.metadata, "checkpoint_ms": cp,
           "host": os.uname().nodename, "nproc": os.cpu_count()}
    log_path = os.path.abspath(f"loadtest-twin-{a.port}.log")
    log = open(log_path, "w")

    def say(k, v):
        out[k] = v
        print(f"{time.strftime('%H:%M:%S')} {k} {json.dumps(v)}", flush=True)

    p = boot(a, tape_dir, log)
    sam = Sampler(p.pid)
    sam.start()
    try:
        say("idle_rss_mb", sam.now())

        t = time.time()
        c, b = req("POST", "/_replay/prepare", {"markets": markets}, timeout=a.load_timeout_s)
        must(c, b, (200, 204), "/_replay/prepare")
        say("prepare", {"s": round(time.time() - t, 1), "rss_mb": sam.now(), "peak_rss_mb": round(sam.peak)})

        body = {"markets": markets, "speed": 1, "rebase": True, "checkpoints": [cp]}
        if a.inject_mode == "start":
            body["inject"] = inject
        t = time.time()
        c, b = req("POST", "/_replay/start", body, timeout=a.load_timeout_s)
        must(c, b, (204,), "/_replay/start")
        st = wait_checkpoint(cp, a.load_timeout_s)
        say("start_to_checkpoint", {"s": round(time.time() - t, 1), "rss_mb": sam.now(), "peak_rss_mb": round(sam.peak),
                                    "total": st.get("total"), "start_ms": st.get("start_ms"),
                                    "rebase_offset_ms": st.get("rebase_offset_ms"), "inject": st.get("inject")})

        if a.inject_mode == "post":
            off = st.get("rebase_offset_ms") or 0
            raw = json.dumps({"events": shifted(events, off)}).encode()
            t = time.time()
            c, b = req("POST", "/_rystic/inject", raw, timeout=600)
            must(c, b, (200, 204), "/_rystic/inject")
            say("inject_post", {"s": round(time.time() - t, 2), "events": len(events), "offset_ms": off})

        time.sleep(2)
        r = sam.now()
        say("loaded", {"rss_mb": r, "peak_rss_mb": round(sam.peak), "mb_per_tape": round(r / len(markets), 3)})
    finally:
        sam.stop = True
        out["rss_samples"] = sam.samples
        stop(p)
        log.close()
    if a.out:
        json.dump(out, open(a.out, "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "rss_samples"}, indent=1))


if __name__ == "__main__":
    main()
