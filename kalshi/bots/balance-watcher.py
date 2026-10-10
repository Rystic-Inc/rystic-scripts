#!/usr/bin/env python3
"""balance-watcher.py — watch your account's four views while a bot trades.

Balance, positions, resting orders and fills are four projections of the
same history. Every two seconds this prints one line reconciling them, so
you can run it next to your bot and see cash, exposure and fills move
together — or catch the moment they stop agreeing.

Usage: python3 balance-watcher.py [base-url]
  base-url defaults to $RYSTIC_ADDR, then http://localhost:8080

Under `rystic grid` (RYSTIC_TICKS set) it ticks that many times and exits
non-zero if any of the four reads ever failed. Standalone it runs until
ctrl-C. Needs only the Python 3 standard library.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request


def default_base():
    addr = os.environ.get("RYSTIC_ADDR")
    if not addr:
        return "http://localhost:8080"
    return addr if "://" in addr else "http://" + addr


BASE = (sys.argv[1] if len(sys.argv) > 1 else default_base()).rstrip("/")
V2 = BASE + "/trade-api/v2/"


def tick_budget():
    """RYSTIC_TICKS caps the run (rystic grid sets it); absent or 0 = ctrl-C."""
    raw = os.environ.get("RYSTIC_TICKS", "")
    try:
        return max(0, int(raw)) if raw else 0
    except ValueError:
        print(f"ignoring RYSTIC_TICKS={raw!r} — not an integer", flush=True)
        return 0


TICKS = tick_budget()


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(V2 + path, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:  # proxies can answer with non-JSON error pages
            return e.code, {"error": raw.decode(errors="replace")[:200]}
    except urllib.error.URLError as e:
        print(f"✗ cannot reach twin at {BASE} ({e.reason}) — is it running?")
        sys.exit(1)


def cash(bal):
    """balance_dollars on current builds; integer cents on older ones."""
    if "balance_dollars" in bal:
        return float(bal["balance_dollars"])
    return float(bal.get("balance") or 0) / 100.0


def qty(p):
    """position_fp on current builds; integer position on older ones."""
    v = p.get("position_fp")
    if v is None:
        v = p.get("position") or 0
    return float(v)


print(f"watching the account via {BASE} — ctrl-C to stop", flush=True)
last = None
failed = 0
n = 0
while TICKS == 0 or n < TICKS:
    n += 1
    st_b, bal = req("GET", "portfolio/balance")
    st_p, pos = req("GET", "portfolio/positions")
    st_o, orders = req("GET", "portfolio/orders")
    st_f, fills = req("GET", "portfolio/fills")
    if st_b != 200 or st_p != 200 or st_o != 200 or st_f != 200:
        print(f"WARN read failed: balance {st_b}, positions {st_p}, "
              f"orders {st_o}, fills {st_f}", flush=True)
        failed += 1
        time.sleep(0.5 if TICKS else 2)
        continue

    mp = (pos or {}).get("market_positions")
    if mp is None:
        mp = (pos or {}).get("positions") or []
    held = [p for p in mp if qty(p) != 0]
    resting = [o for o in (orders or {}).get("orders", [])
               if o.get("status") == "resting"]
    n_fills = len((fills or {}).get("fills", []))

    exposure = ", ".join(
        f"{p.get('ticker')}:{qty(p):+.0f}" for p in held) or "flat"
    now = cash(bal or {})
    delta = "" if last is None else f" ({now - last:+.4f})"
    print(f"balance {now:.4f}{delta}  |  positions {exposure}  |  "
          f"{len(resting)} resting order(s)  |  {n_fills} fill(s)", flush=True)
    last = now
    time.sleep(0.5 if TICKS else 2)

if failed:
    print(f"{failed} of {n} ticks could not read all four views", flush=True)
    sys.exit(1)
print(f"{n} ticks, all four account views read cleanly", flush=True)
