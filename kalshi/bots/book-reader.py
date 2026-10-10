#!/usr/bin/env python3
"""book-reader.py — watch one orderbook and insist it always makes sense.

Places nothing. Polls the book twice a second, prints top-of-book and mid,
and warns if a poll fails to parse, a price leaves (0, 1), or the book
crosses — the shape drifts a strategy would otherwise be the first to hit.

Usage: python3 book-reader.py [base-url] [ticker]
  base-url defaults to $RYSTIC_ADDR, then http://localhost:8080
  ticker   defaults to the first active market on the twin

Under `rystic grid` (RYSTIC_TICKS set) it polls that many times and exits
non-zero if any poll warned. Standalone it runs until ctrl-C.
Needs only the Python 3 standard library.
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


def best(levels):
    """Top of one side of `orderbook_fp`: [["0.4500","500.00"], ...].

    Both sides are quoted as BIDS on their own axis — `no_dollars` is what
    someone pays for NO, so the YES ask is 1 minus the best NO bid.
    """
    if not levels:
        return None, None
    top = max(levels, key=lambda lv: float(lv[0]))
    return float(top[0]), float(top[1])


if len(sys.argv) > 2:
    ticker = sys.argv[2]
else:
    status, out = req("GET", "markets?status=active")
    markets = (out or {}).get("markets") or []
    if not markets:  # older builds may not support the status filter
        status, out = req("GET", "markets")
        markets = (out or {}).get("markets") or []
    if not markets:
        print(f"no markets in the twin's world at {BASE}.\n"
              f"A market exists only once seeded or replayed. Check:\n"
              f"  curl {BASE}/_replay/status   (what tape is loaded, if any)\n"
              f"  curl {BASE}/_replay/markets  (what tapes are available)\n"
              f"then start one from the UI Replay card, or:\n"
              f'  curl -X POST {BASE}/_replay/start -d \'{{"market":"<TICKER>"}}\'')
        sys.exit(1)
    ticker = markets[0]["ticker"]

print(f"reading the {ticker} book via {BASE} — ctrl-C to stop", flush=True)
warned = 0
n = 0
while TICKS == 0 or n < TICKS:
    n += 1
    status, body = req("GET", f"markets/{ticker}/orderbook")
    if status != 200:
        print(f"WARN book read failed ({status})", flush=True)
        warned += 1
    else:
        b = body or {}
        fp = b.get("orderbook_fp") or (b.get("orderbook") or {}).get("orderbook_fp") or {}
        bid, bid_size = best(fp.get("yes_dollars"))
        no_bid, ask_size = best(fp.get("no_dollars"))
        if bid is None or no_bid is None:
            print("empty book — no bid or no ask", flush=True)
        else:
            ask = 1.0 - no_bid
            line = (f"bid {bid:.4f} x {bid_size:.0f}  |  "
                    f"ask {ask:.4f} x {ask_size:.0f}  |  mid {(bid + ask) / 2:.4f}")
            warns = []
            if not (0.0 < bid < 1.0 and 0.0 < ask < 1.0):
                warns.append("price outside (0,1)")
            if bid > ask:
                warns.append("book crossed")
            if warns:
                warned += 1
            print(line + ("  WARN " + ", ".join(warns) if warns else ""), flush=True)
    time.sleep(0.5)

if warned:
    print(f"{warned} of {n} polls warned", flush=True)
    sys.exit(1)
print(f"{n} polls, book well-formed throughout", flush=True)
