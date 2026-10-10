#!/usr/bin/env python3
"""simple-bot.py — the simplest possible twin bot: buys 1 YES contract at the
best ask, every second, until stopped (ctrl-C).

Usage: python3 simple-bot.py [base-url] [ticker]
  base-url defaults to $RYSTIC_ADDR, then http://localhost:8080
  ticker   defaults to the first active market on the twin

Needs only the Python 3 standard library. Orders are immediate_or_cancel, so
each tick either fills against the book or does nothing.

Under `rystic grid` (RYSTIC_TICKS set) it buys that many times and exits
non-zero if the twin ever answered with a server error, or if orders were
attempted but none was ever accepted. Standalone it runs until ctrl-C.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid


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


def price_grid(ticker):
    """The market's DECLARED price grid, as [(start, end, step)] in
    centi-cents (dollars * 1e4 — the exchange's own unit).

    Read price_ranges and nothing else. It is the authoritative tick source,
    and a price off it comes back 400 invalid_price. Two traps this avoids:
    price_level_structure is an ADVISORY label (never infer a tick from it),
    and "cents" is not a safe default — a BTC 15-minute market takes tenths
    of a cent below $0.10 and above $0.90 and whole cents in between.
    """
    _, out = req("GET", f"markets/{ticker}")
    market = (out or {}).get("market") or {}
    bands = []
    for r in market.get("price_ranges") or []:
        try:
            bands.append((cc(r["start"]), cc(r["end"]), cc(r["step"])))
        except (KeyError, TypeError, ValueError):
            continue
    return bands


def cc(dollars):
    """A 4-dp dollar string as an integer number of centi-cents."""
    return int(round(float(dollars) * 10000))


def on_grid(price_cc, bands):
    """Is this price placeable? Strictly inside (0, $1) and on-step within
    some declared band — the exchange's own rule."""
    if not 0 < price_cc < 10000:
        return False
    return any(start <= price_cc <= end and step > 0
               and (price_cc - start) % step == 0
               for start, end, step in bands)


def best_yes_ask(ticker, bands):
    """Best price a YES buyer can lift: lowest NO bid mirrored to 1 - price.

    Rendered at FOUR decimal places, because that is the wire format and the
    book really does quote sub-cent prices. Rounding to cents here would send
    a price that is not the one resting — and on a market whose grid is not
    cents, one the exchange refuses outright.
    """
    _, book = req("GET", f"markets/{ticker}/orderbook")
    nos = (book or {}).get("orderbook_fp", {}).get("no_dollars") or []
    if not nos:
        return None
    best_no_bid = max(cc(p) for p, _ in nos)
    ask_cc = 10000 - best_no_bid
    if bands and not on_grid(ask_cc, bands):
        # The book should never quote off its own grid; if it does, say so
        # rather than sending an order that will be rejected for reasons the
        # log would not explain.
        print(f"! book quotes {ask_cc / 10000:.4f}, which is off the market's "
              f"declared price_ranges — skipping", flush=True)
        return None
    return f"{ask_cc / 10000:.4f}"


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

# The grid is read once: it is stable per-market metadata, and it changes only
# through an explicit lifecycle event.
bands = price_grid(ticker)
if not bands:
    print(f"! {ticker} declares no price_ranges — a real market always does; "
          f"pricing without it is guesswork", flush=True)

print(f"buying 1 contract/sec on {ticker} via {BASE} — ctrl-C to stop", flush=True)
server_errors = 0
attempted = 0
accepted = 0
n = 0
while TICKS == 0 or n < TICKS:
    n += 1
    ask = best_yes_ask(ticker, bands)
    if ask is None:
        print("no asks in the book — skipping tick", flush=True)
    else:
        attempted += 1
        status, out = req("POST", "portfolio/events/orders", {
            "ticker": ticker, "side": "bid", "price": ask, "count": "1",
            "time_in_force": "immediate_or_cancel",
            "self_trade_prevention_type": "taker_at_cross",
            "client_order_id": str(uuid.uuid4()),
        })
        if status == 201:
            accepted += 1
            filled = out.get("fill_count", "0")
            _, bal = req("GET", "portfolio/balance")
            print(f"buy 1 @ {ask}: filled {filled} — "
                  f"balance {(bal or {}).get('balance_dollars', '?')}", flush=True)
        else:
            print(f"order rejected ({status}): {json.dumps(out)[:120]}", flush=True)
            if status >= 500:
                server_errors += 1
    time.sleep(1)

if server_errors:
    print(f"{server_errors} of {n} ticks hit a server error", flush=True)
    sys.exit(1)
if attempted and not accepted:
    # A canary that never got an order in tested nothing: all-4xx is a broken
    # order route, not a pass. (A book with no asks attempts nothing and is a
    # legitimate pass — an empty world is the book's fault, not the route's.)
    print(f"{attempted} orders attempted, none accepted", flush=True)
    sys.exit(1)
print(f"{n} ticks, {accepted} of {attempted} orders accepted", flush=True)
