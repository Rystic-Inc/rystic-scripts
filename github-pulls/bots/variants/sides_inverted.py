#!/usr/bin/env python3
"""A small two-sided market maker for one Kalshi market (Trade API v2).

Rests a bid and an ask within QUOTE_OFFSET_CENTS of the touch, re-quotes as the
book moves, never crosses the spread (post_only, and a bid is always priced
below the ask), keeps the position within MAX_INVENTORY contracts, and cancels
everything on the way out — at SESSION_SECONDS or on SIGTERM.

Configured only through the environment, so the same file runs against the
Rystic twin (no auth) or the exchange:

    KALSHI_BASE_URL     http://localhost:8080          scheme + host, no path
    KALSHI_HEADERS      {}                             JSON object of extra headers
    TICKER              KXDEMO-26-A                    the market to make
    SESSION_SECONDS     30                             run for this long, then flatten
    QUOTE_OFFSET_CENTS  1                              how far behind the touch to rest
    QUOTE_SIZE          2                              contracts per side
    MAX_INVENTORY       10                             |position| beyond which a side stops
    POLL_SECONDS        1                              book read cadence

Prices are YES-axis dollar strings ("0.40"); side "bid" buys YES, "ask" sells
YES. The book's no_dollars stack is the ask side quoted as NO bids, so a YES
ask is 1.00 minus the NO price.
"""
import json
import os
import signal
import sys
import time
import uuid

import requests

BASE_URL = os.environ.get("KALSHI_BASE_URL", "http://localhost:8080").rstrip("/")
HEADERS = json.loads(os.environ.get("KALSHI_HEADERS", "{}"))
TICKER = os.environ.get("TICKER", "KXDEMO-26-A")
SESSION_SECONDS = float(os.environ.get("SESSION_SECONDS", "30"))
QUOTE_OFFSET_CENTS = int(os.environ.get("QUOTE_OFFSET_CENTS", "1"))
QUOTE_SIZE = int(os.environ.get("QUOTE_SIZE", "2"))
MAX_INVENTORY = int(os.environ.get("MAX_INVENTORY", "10"))
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "1"))

V2 = "/trade-api/v2"
ORDERS = V2 + "/portfolio/events/orders"


def auth_headers(method, path, body):
    """The signing seam. The twin needs nothing; a real-Kalshi run would return
    the KALSHI-ACCESS-KEY / -TIMESTAMP / -SIGNATURE headers here."""
    return {}


def call(method, path, body=None, params=None):
    headers = {"Accept": "application/json", **HEADERS}
    headers.update(auth_headers(method, path, body))
    resp = requests.request(method, BASE_URL + path, params=params, json=body,
                            headers=headers, timeout=10)
    if resp.status_code >= 400:
        raise RuntimeError(f"{method} {path} -> {resp.status_code} {resp.text[:200]}")
    return resp.json() if resp.content else {}


def cents(dollars):
    return int(round(float(dollars) * 100))


def dollars(c):
    return f"{c / 100:.2f}"


class MarketMaker:
    def __init__(self):
        self.resting = {}  # side -> {"order_id", "price_cents"}

    # --- reads ---------------------------------------------------------
    def touch(self):
        """Best bid and best ask in cents, with our own resting quotes removed.
        Levels are ascending, so the best of each stack is the last element."""
        book = call("GET", f"{V2}/markets/{TICKER}/orderbook")["orderbook_fp"]
        own = {q["price_cents"]: QUOTE_SIZE for q in self.resting.values()}
        bids = [(cents(p), float(n)) for p, n in book.get("yes_dollars", [])]
        asks = [(100 - cents(p), float(n)) for p, n in book.get("no_dollars", [])]
        bids = [p for p, n in bids if n - own.get(p, 0) > 0]
        asks = [p for p, n in asks if n - own.get(p, 0) > 0]
        return (max(bids) if bids else None), (min(asks) if asks else None)

    def position(self):
        data = call("GET", f"{V2}/portfolio/positions", params={"ticker": TICKER})
        for pos in data.get("market_positions", []):
            if pos.get("ticker") == TICKER:
                return float(pos.get("position_fp") or pos.get("position") or 0)
        return 0.0

    # --- writes --------------------------------------------------------
    def place(self, side, price_cents):
        body = {
            "ticker": TICKER,
            "side": side,
            "count": str(QUOTE_SIZE),
            "price": dollars(price_cents),
            "time_in_force": "good_till_canceled",
            "post_only": True,
            "self_trade_prevention_type": "taker_at_cross",
            "client_order_id": str(uuid.uuid4()),
        }
        order = call("POST", ORDERS, body)
        self.resting[side] = {"order_id": order["order_id"], "price_cents": price_cents}
        print(f"rest {side} {QUOTE_SIZE}@{dollars(price_cents)} {order['order_id']}", flush=True)

    def cancel(self, side):
        quote = self.resting.pop(side, None)
        if quote:
            call("DELETE", f"{ORDERS}/{quote['order_id']}")
            print(f"cancel {side} {quote['order_id']}", flush=True)

    def cancel_all(self):
        for side in list(self.resting):
            try:
                self.cancel(side)
            except RuntimeError as err:
                print(f"cancel {side} failed: {err}", file=sys.stderr, flush=True)

    # --- the loop ------------------------------------------------------
    def requote(self):
        best_bid, best_ask = self.touch()
        if best_bid is None or best_ask is None:
            return  # a one-sided or empty book has no touch to lean on
        bid = best_bid - QUOTE_OFFSET_CENTS
        ask = best_ask + QUOTE_OFFSET_CENTS
        if not (1 <= bid < ask <= 99):
            return
        pos = self.position()
        wanted = {}
        if pos < MAX_INVENTORY:
            wanted["bid"] = bid
        if pos > -MAX_INVENTORY:
            wanted["ask"] = ask
        for side in ("bid", "ask"):
            have = self.resting.get(side)
            if have and have["price_cents"] != wanted.get(side):
                self.cancel(side)
            if side in wanted and side not in self.resting:
                self.place("ask" if side == "bid" else "bid", wanted[side])

    def run(self):
        deadline = time.monotonic() + SESSION_SECONDS
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            while time.monotonic() < deadline:
                self.requote()
                time.sleep(min(POLL_SECONDS, max(0.0, deadline - time.monotonic())))
        finally:
            self.cancel_all()
            print("flat, exiting", flush=True)


if __name__ == "__main__":
    MarketMaker().run()
