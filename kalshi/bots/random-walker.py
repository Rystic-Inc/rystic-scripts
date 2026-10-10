#!/usr/bin/env python3
"""random-walker.py — throw arbitrary orders at the twin and ask it to cope.

Random side, size, price and time-in-force from a pinned seed, so a failure
replays exactly. It does not care whether an order fills or is rejected —
the assertion is that every response is a decision (2xx, or a 4xx the API
documents), never a 5xx and never a hang. The cheapest robustness check
there is, before you point a real strategy at an environment.

Usage: python3 random-walker.py [base-url] [ticker] [orders] [seed]
  base-url defaults to $RYSTIC_ADDR, then http://localhost:8080
  ticker   defaults to the first active market on the twin
  orders   defaults to 40
  seed     defaults to 1337 — rerun with the same seed to replay a failure

Needs only the Python 3 standard library. Exits 0 if the twin coped, so it
runs unchanged as a `rystic grid` row.
"""
import json
import os
import random
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
try:
    ORDERS = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    SEED = int(sys.argv[4]) if len(sys.argv) > 4 else 1337
except ValueError:
    print("usage: python3 random-walker.py [base-url] [ticker] [orders] [seed] "
          "— orders and seed must be integers")
    sys.exit(2)
OK = {200, 201}
DOCUMENTED = {400, 403, 404, 409, 429}


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


def cc(dollars):
    """A 4-dp dollar string as an integer number of centi-cents (dollars *
    1e4 — the exchange's own unit)."""
    return int(round(float(dollars) * 10000))


def price_grid(ticker):
    """The market's DECLARED price grid, as [(start, end, step)] in
    centi-cents.

    Read price_ranges and nothing else: it is the authoritative tick source,
    and a price off it is answered 400 invalid_price. price_level_structure
    is an ADVISORY label — never infer a tick from it — and cents are not a
    safe default. A BTC 15-minute market takes tenths of a cent below $0.10
    and above $0.90 and whole cents between, so a walker that assumed cents
    would never once exercise two thirds of that market's price domain.
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


def on_grid(price_cc, bands):
    """Placeable: strictly inside (0, $1) and on-step within some band."""
    if not 0 < price_cc < 10000:
        return False
    return any(start <= price_cc <= end and step > 0
               and (price_cc - start) % step == 0
               for start, end, step in bands)


def random_price(rng, bands):
    """A price ON the declared grid, uniform over the prices it allows."""
    if not bands:
        return rng.randrange(100, 10000, 100)  # no declaration: 1c, and say so
    points = []
    for start, end, step in bands:
        if step <= 0:
            continue
        # Steps run FROM the band's start, and $0.0000 is not placeable, so a
        # band starting at zero begins one step in.
        first = start if start > 0 else step
        points.extend(range(first, min(end, 9999) + 1, step))
    return rng.choice(points) if points else rng.randrange(100, 10000, 100)


def off_grid_price(rng, bands):
    """A price the declaration REFUSES, or None if every 4-dp price is on it.

    The walker sends one every so often as a positive control: a twin that
    accepted these would be advertising a grid it does not enforce, which is
    worse than a twin that declares none.
    """
    for _ in range(200):
        p = rng.randint(1, 9999)
        if not on_grid(p, bands):
            return p
    return None


if len(sys.argv) > 2:
    ticker = sys.argv[2]
else:
    status, out = req("GET", "markets?status=active")
    markets = (out or {}).get("markets") or []
    if not markets:  # older builds may not support the status filter
        status, out = req("GET", "markets")
        markets = (out or {}).get("markets") or []
    if not markets:
        # Scenarios first, deliberately. Every route this used to offer was a
        # replay route, and replay needs a tape archive a fresh install does
        # not have — so the only way out of this message required something
        # the reader had not got yet. Scenarios are compiled into the binary,
        # so `--list-scenarios` and this POST always work.
        print(f"no markets in the twin's world at {BASE}.\n"
              f"A market exists only once seeded or replayed.\n"
              f"\n"
              f"Quickest — seed a built-in scenario (no tape needed):\n"
              f'  curl -X POST {BASE}/_rystic/scenario -H \'content-type: application/json\' -d \'{{"name":"tight_book"}}\'\n'
              f"  ./kalshi-twin --list-scenarios   (what else ships; SCENARIOS.md describes them)\n"
              f"\n"
              f"Or replay a captured market, if you have a tape archive:\n"
              f"  curl {BASE}/_replay/status   (what tape is loaded, if any)\n"
              f"  curl {BASE}/_replay/markets  (what tapes are available)\n"
              f"then start one from the UI Replay card, or:\n"
              f'  curl -X POST {BASE}/_replay/start -d \'{{"market":"<TICKER>"}}\'')
        sys.exit(1)
    ticker = markets[0]["ticker"]

rng = random.Random(SEED)
bands = price_grid(ticker)
if bands:
    grid = ", ".join(f"{s / 10000:.4f}-{e / 10000:.4f} step {t / 10000:.4f}"
                     for s, e, t in bands)
    print(f"{ticker} declares its grid: {grid}", flush=True)
else:
    print(f"! {ticker} declares no price_ranges — a real market always does. "
          f"Walking the 1c grid, which may miss most of this market.", flush=True)
print(f"{ORDERS} random orders on {ticker} via {BASE} (seed {SEED})", flush=True)

codes, server_errors, undocumented = {}, 0, []
grid_violations = []
for i in range(ORDERS):
    # Every fifth order is deliberately OFF the declared grid. The rest are
    # on it. Both halves matter: the on-grid orders exercise the price domain
    # this market really has (a walker that assumed cents would never place a
    # sub-cent order on a market that takes them), and the off-grid ones are
    # the positive control that the grid is enforced rather than merely
    # advertised.
    want_off = bands and i % 5 == 4
    price_cc = off_grid_price(rng, bands) if want_off else random_price(rng, bands)
    if price_cc is None:
        want_off, price_cc = False, random_price(rng, bands)
    body = {
        "ticker": ticker,
        "side": rng.choice(["bid", "ask"]),
        "count": str(rng.randint(1, 25)),
        "price": f"{price_cc / 10000:.4f}",
        "time_in_force": rng.choice(["immediate_or_cancel",
                                     "good_till_canceled",
                                     "fill_or_kill"]),
        "self_trade_prevention_type": "taker_at_cross",
        "client_order_id": str(uuid.uuid4()),
    }
    status, resp = req("POST", "portfolio/events/orders", body)
    codes[status] = codes.get(status, 0) + 1
    if status >= 500:
        server_errors += 1
        print(f"5xx on {json.dumps(body)}: {json.dumps(resp)[:120]}", flush=True)
    elif status not in OK and status not in DOCUMENTED:
        undocumented.append((status, body))
    if want_off and status < 400:
        grid_violations.append(body["price"])
    time.sleep(0.05)

print(f"{ORDERS} orders -> " +
      ", ".join(f"{k}×{v}" for k, v in sorted(codes.items())), flush=True)

# Whatever it did, the environment must still be readable afterwards.
st_bal, _ = req("GET", "portfolio/balance")
st_book, _ = req("GET", f"markets/{ticker}/orderbook")

failed = []
if grid_violations:
    failed.append(f"{len(grid_violations)} order(s) accepted OFF the declared "
                  f"price grid, e.g. {grid_violations[0]} — the market advertises "
                  f"a tick it does not enforce")
if server_errors:
    failed.append(f"{server_errors} server error(s)")
if undocumented:
    failed.append(f"undocumented status {undocumented[0][0]} "
                  f"on {json.dumps(undocumented[0][1])[:100]}")
if st_bal != 200:
    failed.append(f"balance unreadable after the walk ({st_bal})")
if st_book != 200:
    failed.append(f"book unreadable after the walk ({st_book})")

if failed:
    print("the twin did NOT cope: " + "; ".join(failed), flush=True)
    sys.exit(1)
print("the twin coped: every order answered, account and book still read",
      flush=True)
