#!/usr/bin/env python3
"""Runs bot.py against a kalshi-twin for 30 s and holds it to the contract:
a bid and an ask resting at the same time, no crossed order and no fill on a
static book, a clean exit with nothing left resting. Then runs every file under
variants/ and holds each to the opposite: it never rests both sides.

    python3 test_bot.py                       # builds ./public-apis/kalshi/sim, boots tight_book
    KALSHI_BASE_URL=http://localhost:8080 python3 test_bot.py   # a twin already running
    KALSHI_TWIN_BIN=~/.rystic/twins/kalshi-twin/current/kalshi-twin python3 test_bot.py

The scenario is tight_book (KXDEMO-26-A, 0.39 / 0.40, 25 a side). The twin is
reset to it before every bot, through POST /_rystic/scenario.
"""
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TICKER = "KXDEMO-26-A"
SCENARIO = "tight_book"
BOT_SECONDS = float(os.environ.get("BOT_TEST_SECONDS", "30"))
VARIANT_SECONDS = float(os.environ.get("BOT_VARIANT_SECONDS", "6"))


def http(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        return err.code, {}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Twin:
    """The kalshi-twin under test: an already-running one when KALSHI_BASE_URL
    is set, otherwise a binary (KALSHI_TWIN_BIN, or built from this repo)."""

    def __init__(self):
        self.proc = None
        self.tmp = None
        self.base = os.environ.get("KALSHI_BASE_URL", "").rstrip("/")

    def start(self):
        if self.base:
            return
        binary = os.environ.get("KALSHI_TWIN_BIN")
        if not binary:
            self.tmp = tempfile.TemporaryDirectory()
            binary = str(pathlib.Path(self.tmp.name, "kalshi-twin"))
            subprocess.run(["go", "build", "-o", binary, "./public-apis/kalshi/sim"],
                           cwd=ROOT, check=True)
        port = free_port()
        self.base = f"http://127.0.0.1:{port}"
        self.proc = subprocess.Popen([binary], env={**os.environ, "RYSTIC_ADDR": f":{port}"},
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                if http("GET", self.base + "/_rystic/version")[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError("kalshi-twin did not serve")

    def stop(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        if self.tmp:
            self.tmp.cleanup()

    def reset(self):
        status, _ = http("POST", self.base + "/_rystic/scenario", {"name": SCENARIO})
        assert status == 204, f"scenario reset -> {status}"

    def resting(self):
        _, data = http("GET", self.base + "/trade-api/v2/portfolio/orders?status=resting")
        return [o for o in data.get("orders", []) if o.get("ticker") == TICKER]

    def fills(self):
        _, data = http("GET", self.base + "/trade-api/v2/portfolio/fills")
        return data.get("fills", [])


def run_bot(path, twin, seconds):
    """Run one bot file for `seconds`, sampling the resting orders every 0.5 s.
    Returns (exit code, samples, stderr tail); a sample is the list of
    (book_side, yes price in cents) resting at that moment."""
    env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""),
           "KALSHI_BASE_URL": twin.base, "TICKER": TICKER,
           "SESSION_SECONDS": str(seconds), "POLL_SECONDS": "0.5"}
    proc = subprocess.Popen([sys.executable, str(path)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    samples = []
    deadline = time.monotonic() + seconds + 10
    while proc.poll() is None and time.monotonic() < deadline:
        samples.append([(o["book_side"], int(round(float(o["yes_price_dollars"]) * 100)))
                        for o in twin.resting()])
        time.sleep(0.5)
    if proc.poll() is None:
        proc.kill()
    _, err = proc.communicate(timeout=10)
    return proc.returncode, samples, err[-600:]


def two_sided(sample):
    return {side for side, _ in sample} == {"bid", "ask"}


class BotContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.twin = Twin()
        cls.twin.start()

    @classmethod
    def tearDownClass(cls):
        cls.twin.stop()

    def setUp(self):
        self.twin.reset()

    def test_working_bot_makes_a_market_and_leaves_flat(self):
        code, samples, err = run_bot(HERE / "bot.py", self.twin, BOT_SECONDS)
        self.assertEqual(code, 0, err)
        self.assertTrue(any(two_sided(s) for s in samples),
                        f"a bid and an ask never rested together: {samples[:6]}")
        for sample in samples:
            bids = [p for side, p in sample if side == "bid"]
            asks = [p for side, p in sample if side == "ask"]
            if bids and asks:
                self.assertLess(max(bids), min(asks), f"crossed quotes {sample}")
        self.assertEqual(self.twin.fills(), [], "a quote traded on a static book")
        self.assertEqual(self.twin.resting(), [], "orders left resting after exit")

    def test_every_variant_fails_to_rest_both_sides(self):
        variants = sorted((HERE / "variants").glob("*.py"))
        self.assertGreaterEqual(len(variants), 5)
        for path in variants:
            with self.subTest(variant=path.name):
                self.twin.reset()
                code, samples, err = run_bot(path, self.twin, VARIANT_SECONDS)
                self.assertFalse(any(two_sided(s) for s in samples),
                                 f"{path.name} rested both sides — it is not broken")
                self.assertTrue(code != 0 or not any(samples),
                                f"{path.name} exited 0 after resting {samples}")
                for order in self.twin.resting():
                    http("DELETE", f"{self.twin.base}/trade-api/v2/portfolio/events/orders/{order['order_id']}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
