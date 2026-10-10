#!/usr/bin/env python3
"""api-check.py — exercises every route on the kalshi-twin's Trade API v2
surface (88 routes) against a running twin and reports pass/fail per route.

Usage: python3 api-check.py [base-url]      # default http://localhost:8080

Needs only the Python 3 standard library. Resets the twin's state, seeds a
known world via /_rystic/seed, then walks the whole surface: catalog reads,
the full order lifecycle (create/amend/decrease/cancel/batch/fill), RFQs and
quotes, order groups, subaccounts, api keys, and every read family.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080").rstrip("/")
V2 = BASE + "/trade-api/v2/"

results = []  # (name, ok, detail)


def req(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method,
                               headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"✗ cannot reach twin at {BASE} ({e.reason}) — is it running?")
        sys.exit(1)


def check(name, method, path, body=None, expect=(200,)):
    """Hit METHOD /trade-api/v2/<path>, record pass/fail, return parsed body."""
    status, out = req(method, V2 + path, body)
    ok = status in expect
    results.append((name, ok, f"{method} {path} -> {status} (want {'/'.join(map(str, expect))})"
                    + ("" if ok else f" body: {json.dumps(out)[:200]}")))
    return out


def ctl(method, path, body=None):
    status, out = req(method, BASE + path, body)
    if status >= 400:
        print(f"✗ control-plane {path} failed ({status}): {json.dumps(out)[:400]}")
        sys.exit(1)
    return out


# ---------------------------------------------------------------- seed world
ctl("GET", "/_rystic/version")
ctl("POST", "/_rystic/reset")
ctl("POST", "/_rystic/clock", {"time": "2026-08-10T12:00:00Z"})
ctl("POST", "/_rystic/seed-rng", {"seed": 42})

def market(ticker, event, bid, ask):
    """A COMPLETE market record — every field live serves on every read.

    This script seeds the world it then checks, so the world it seeds is also
    an example of one. It used to seed five fields, which is the shape that
    shipped in 0.0.11 and killed a customer's bot one KeyError at a time
    (FINDINGS #29/#37): a firm's stack indexes the documented market before it
    prices, and absent is the one answer the real API never gives.

    Prices are 4-dp FixedPointDollars, and price_ranges declares the tick the
    order-price guard enforces — read it before you price anything.
    """
    return {
        "ticker": ticker, "event_ticker": event,
        "market_type": "binary", "status": "active",
        "open_time": "2026-08-01T00:00:00Z", "close_time": "2026-12-31T00:00:00Z",
        "created_time": "2026-08-01T00:00:00Z", "updated_time": "2026-08-10T12:00:00Z",
        "latest_expiration_time": "2026-12-31T00:00:00Z",
        "expected_expiration_time": "2026-12-31T00:00:00Z",
        "expiration_time": "2026-12-31T00:00:00Z",
        "title": ticker, "liquidity_dollars": "0.0000", "exchange_index": 0,
        "price_level_structure": "linear_cent",
        "price_ranges": [{"start": "0.0000", "end": "1.0000", "step": "0.0100"}],
        "yes_sub_title": "Yes", "no_sub_title": "No",
        "rules_primary": "Smoke-check market.", "rules_secondary": "",
        "notional_value_dollars": "1.0000",
        "can_close_early": False, "settlement_timer_seconds": 0,
        "result": "", "expiration_value": "",
        "yes_bid_dollars": bid, "yes_ask_dollars": ask,
        "no_bid_dollars": f"{1 - float(ask):.4f}",
        "no_ask_dollars": f"{1 - float(bid):.4f}",
        "yes_bid_size_fp": "0.00", "yes_ask_size_fp": "100.00",
        "last_price_dollars": ask, "previous_price_dollars": ask,
        "previous_yes_bid_dollars": bid, "previous_yes_ask_dollars": ask,
        "volume_fp": "0.00", "volume_24h_fp": "0.00", "open_interest_fp": "0.00",
    }


MKT = market("DB-A", "EVT-1", "0.3500", "0.4000")
MKT2 = market("DB-B", "EVT-1", "0.3500", "0.4000")
BOOK = {"ticker": "DB-A", "bids": [],
        "asks": [{"price_dollars": "0.4000",
                  "resting": [{"order_id": "seed-maker-1",
                               "remaining_count_fp": "100", "seq": 1}]}]}
ctl("POST", "/_rystic/seed", {
    "state_market_catalog": {"DB-A": MKT, "DB-B": MKT2},
    "state_orderbook": {"DB-A": BOOK},
    "state_balance": {"member": {"balance_dollars": "10000.00"}},
    # Complete too: the model marks eight event fields required, and
    # event-scoped discovery is how a firm's bot finds markets at all.
    "state_event": {"EVT-1": {
        "event_ticker": "EVT-1", "series_ticker": "SER-1",
        "title": "Test event", "sub_title": "Smoke-check event",
        "collateral_return_type": "binary", "mutually_exclusive": False,
        "available_on_brokers": False, "settlement_sources": [],
        "strike_date": "2026-12-31T00:00:00Z", "strike_period": "",
        "fee_type_override": "", "fee_multiplier_override": 0,
        "last_updated_ts": "2026-08-10T12:00:00Z", "product_metadata": {},
    }},
    "state_event_metadata": {"EVT-1": {"event_ticker": "EVT-1"}},
    "state_series": {"SER-1": {"ticker": "SER-1", "title": "Test series"}},
    "state_milestone": {"mi-1": {"id": "mi-1", "title": "Test milestone"}},
    "state_structured_target": {"st-1": {"id": "st-1", "name": "Test target"}},
    "state_multivariate_collection": {"MVC-1": {"collection_ticker": "MVC-1",
                                                "title": "Test collection"}},
    "state_historical_market": {"DB-A": {"ticker": "DB-A"}},
    "state_historical_candlestick": {"cs-1": {"ticker": "DB-A", "period_interval": 1,
                                              "end_period_ts": 1754810000}},
    "state_live_data": {"mi-1": {"id": "mi-1", "type": "milestone"}},
})

# ------------------------------------------------------------------- account
check("account.volume_progress", "GET", "account/api_usage_level/volume_progress")
check("account.endpoint_costs", "GET", "account/endpoint_costs")
check("account.limits", "GET", "account/limits")

# ------------------------------------------------------------------ api_keys
check("api_keys.list", "GET", "api_keys")
gen = check("api_keys.generate", "POST", "api_keys/generate",
            {"name": "smoke-generated"}, expect=(201,))
pub = subprocess.run(["openssl", "rsa", "-pubout"], capture_output=True, text=True,
                     input=subprocess.run(["openssl", "genrsa", "2048"],
                                          capture_output=True, text=True).stdout).stdout
created = check("api_keys.create", "POST", "api_keys",
                {"name": "smoke-created", "public_key": pub}, expect=(201,))
del_id = (created or {}).get("api_key_id") or (gen or {}).get("api_key_id")
check("api_keys.delete", "DELETE", f"api_keys/{del_id}", expect=(204,))

# ------------------------------------------------------------ communications
check("comms.id", "GET", "communications/id")
check("comms.btp.list", "GET", "communications/block-trade-proposals")
btp = check("comms.btp.create", "POST", "communications/block-trade-proposals",
            {"buyer_user_id": "twin-buyer", "seller_user_id": "twin-seller",
             "market_ticker": "DB-A", "maker_side": "yes",
             "price_centi_cents": 4000, "centicount": 10000000,
             "expiration_ts": "2026-08-10T13:00:00Z"}, expect=(201,))
btp_id = (btp or {}).get("block_trade_proposal_id", "missing")
check("comms.btp.accept", "POST",
      f"communications/block-trade-proposals/{btp_id}/accept", {}, expect=(204,))


def make_rfq(n):
    out = check(f"comms.rfq.create[{n}]", "POST", "communications/rfqs",
                {"market_ticker": "DB-A", "contracts": 10, "rest_remainder": False},
                expect=(201,))
    return (out or {}).get("id", "missing")


def make_quote(n, rfq_id):
    out = check(f"comms.quote.create[{n}]", "POST", "communications/quotes",
                {"rfq_id": rfq_id, "yes_bid": "0.35", "no_bid": "0.60",
                 "rest_remainder": False}, expect=(201,))
    return (out or {}).get("id", "missing")


rfq1 = make_rfq(1)
check("comms.rfq.list", "GET", "communications/rfqs")
check("comms.rfq.get", "GET", f"communications/rfqs/{rfq1}")
q1 = make_quote(1, rfq1)
check("comms.quote.list", "GET", "communications/quotes?creator_user_id=member")
check("comms.quote.get", "GET", f"communications/quotes/{q1}")
check("comms.quote.accept", "PUT", f"communications/quotes/{q1}/accept",
      {"accepted_side": "yes"}, expect=(204,))
check("comms.quote.confirm", "PUT", f"communications/quotes/{q1}/confirm", {},
      expect=(204,))
rfq2 = make_rfq(2)
q2 = make_quote(2, rfq2)
check("comms.quote.delete", "DELETE", f"communications/quotes/{q2}", expect=(204,))
check("comms.rfq.delete", "DELETE", f"communications/rfqs/{rfq2}", expect=(204,))

# -------------------------------------------------------------------- events
check("events.list", "GET", "events")
check("events.fee_changes", "GET", "events/fee_changes")
check("events.multivariate", "GET", "events/multivariate")
check("events.get", "GET", "events/EVT-1")
check("events.metadata", "GET", "events/EVT-1/metadata")

# ------------------------------------------------------------------ exchange
check("exchange.schedule", "GET", "exchange/schedule")
check("exchange.status", "GET", "exchange/status")
check("exchange.user_data_timestamp", "GET", "exchange/user_data_timestamp")

# ----------------------------------------------------------------------- fcm
check("fcm.orders", "GET", "fcm/orders?subtrader_id=st-1")
check("fcm.positions", "GET", "fcm/positions?subtrader_id=st-1")

# ---------------------------------------------------------------- historical
check("historical.cutoff", "GET", "historical/cutoff")
check("historical.fills", "GET", "historical/fills")
check("historical.markets", "GET", "historical/markets")
check("historical.market.get", "GET", "historical/markets/DB-A")
check("historical.candlesticks", "GET",
      "historical/markets/DB-A/candlesticks"
      "?start_ts=1754800000&end_ts=1754830000&period_interval=1")
check("historical.orders", "GET", "historical/orders")
check("historical.trades", "GET", "historical/trades")

# ---------------------------------------------------- incentives / live data
check("incentive_programs.list", "GET", "incentive_programs")
check("live_data.batch", "GET", "live_data/batch?ids=mi-1")
check("live_data.milestone", "GET", "live_data/milestone/mi-1")

# ------------------------------------------------------------------- markets
check("markets.list", "GET", "markets")
check("markets.orderbooks", "GET", "markets/orderbooks?tickers=DB-A")
check("markets.trades", "GET", "markets/trades")
check("markets.get", "GET", "markets/DB-A")
check("markets.orderbook", "GET", "markets/DB-A/orderbook")

# ---------------------------------------------------------------- milestones
check("milestones.list", "GET", "milestones")
check("milestones.get", "GET", "milestones/mi-1")

# ------------------------------------------- multivariate event collections
check("mvec.list", "GET", "multivariate_event_collections")
check("mvec.get", "GET", "multivariate_event_collections/MVC-1")
check("mvec.lookup", "POST", "multivariate_event_collections/MVC-1",
      {"selected_markets": [{"event_ticker": "EVT-1", "market_ticker": "DB-A",
                             "side": "yes"}]}, expect=(200, 400))

# ----------------------------------------------------------------- portfolio
check("portfolio.balance", "GET", "portfolio/balance")
check("portfolio.deposits", "GET", "portfolio/deposits")
check("portfolio.withdrawals", "GET", "portfolio/withdrawals")


def place(n, price="0.30", count="10", tif="good_till_canceled", coid=None):
    body = {"ticker": "DB-A", "side": "bid", "price": price, "count": count,
            "time_in_force": tif,
            "self_trade_prevention_type": "taker_at_cross",
            "client_order_id": coid or f"00000000-0000-0000-0000-0000000000{n:02d}"}
    out = check(f"portfolio.orders.create[{n}]", "POST", "portfolio/events/orders",
                body, expect=(201,))
    return (out or {}).get("order_id", "missing")


o_rest = place(1)                       # rests at 0.30 under the 0.40 ask
o_amend = place(2)
o_cancel = place(3)
place(4, price="0.40", count="5", tif="fill_or_kill")   # crosses seeded ask -> fill

check("portfolio.orders.list", "GET", "portfolio/orders")
check("portfolio.orders.get", "GET", f"portfolio/orders/{o_rest}")
check("portfolio.orders.queue_positions", "GET", "portfolio/orders/queue_positions")
check("portfolio.orders.queue_position", "GET",
      f"portfolio/orders/{o_rest}/queue_position")
check("portfolio.orders.amend", "POST", f"portfolio/events/orders/{o_amend}/amend",
      {"ticker": "DB-A", "side": "bid", "price": "0.31", "count": "10",
       "updated_client_order_id": "00000000-0000-0000-0000-000000000099"})
check("portfolio.orders.decrease", "POST",
      f"portfolio/events/orders/{o_rest}/decrease", {"reduce_by": "2"})
check("portfolio.orders.cancel", "DELETE", f"portfolio/events/orders/{o_cancel}")
batch = check("portfolio.orders.batch_create", "POST",
              "portfolio/events/orders/batched",
              {"orders": [{"ticker": "DB-A", "side": "bid", "price": "0.20",
                           "count": "5", "time_in_force": "good_till_canceled",
                           "self_trade_prevention_type": "taker_at_cross",
                           "client_order_id": "00000000-0000-0000-0000-000000000021"},
                          {"ticker": "DB-A", "side": "bid", "price": "0.21",
                           "count": "5", "time_in_force": "good_till_canceled",
                           "self_trade_prevention_type": "taker_at_cross",
                           "client_order_id": "00000000-0000-0000-0000-000000000022"}]},
              expect=(201,))
batch_ids = [(o.get("order_id") or (o.get("order") or {}).get("order_id"))
             for o in (batch or {}).get("orders", []) if isinstance(o, dict)]
check("portfolio.orders.batch_cancel", "DELETE", "portfolio/events/orders/batched",
      {"orders": [{"order_id": i, "market_ticker": "DB-A"}
                  for i in batch_ids if i]})
check("portfolio.fills", "GET", "portfolio/fills")
check("portfolio.positions", "GET", "portfolio/positions")
check("portfolio.settlements", "GET", "portfolio/settlements")
check("portfolio.summary.resting_value", "GET",
      "portfolio/summary/total_resting_order_value")

og = check("portfolio.order_groups.create", "POST", "portfolio/order_groups/create",
           {"contracts_limit_fp": "100"}, expect=(201,))
og_id = (og or {}).get("order_group_id", "missing")
check("portfolio.order_groups.list", "GET", "portfolio/order_groups")
check("portfolio.order_groups.get", "GET", f"portfolio/order_groups/{og_id}")
check("portfolio.order_groups.limit", "PUT", f"portfolio/order_groups/{og_id}/limit",
      {"contracts_limit_fp": "50"})
check("portfolio.order_groups.reset", "PUT", f"portfolio/order_groups/{og_id}/reset", {})
check("portfolio.order_groups.trigger", "PUT",
      f"portfolio/order_groups/{og_id}/trigger", {})
check("portfolio.order_groups.delete", "DELETE", f"portfolio/order_groups/{og_id}")

sub = check("portfolio.subaccounts.create", "POST", "portfolio/subaccounts", {},
            expect=(201,))
sub_id = (sub or {}).get("subaccount") or 1
check("portfolio.subaccounts.balances", "GET", "portfolio/subaccounts/balances")
check("portfolio.subaccounts.netting.get", "GET", "portfolio/subaccounts/netting")
check("portfolio.subaccounts.netting.put", "PUT", "portfolio/subaccounts/netting",
      {"subaccount_number": 0, "enabled": True})
check("portfolio.subaccounts.transfer", "POST", "portfolio/subaccounts/transfer",
      {"from_subaccount": 0, "to_subaccount": sub_id, "amount_cents": 100,
       "client_transfer_id": "00000000-0000-0000-0000-000000000031"})
check("portfolio.subaccounts.transfers", "GET", "portfolio/subaccounts/transfers")
check("portfolio.subaccounts.positions_transfer", "POST",
      "portfolio/subaccounts/positions/transfer",
      {"from_subaccount": 0, "to_subaccount": sub_id, "ticker": "DB-A",
       "quantity": 1}, expect=(200, 403))

# ------------------------------------------------------------ search / series
check("search.filters_by_sport", "GET", "search/filters_by_sport")
check("search.tags_by_categories", "GET", "search/tags_by_categories")
check("series.list", "GET", "series?series_ticker=SER-1")
check("series.fee_changes", "GET", "series/fee_changes")

# ---------------------------------------------------------- structured targets
check("structured_targets.list", "GET", "structured_targets")
check("structured_targets.get", "GET", "structured_targets/st-1")

# -------------------------------------------------------------------- report
failed = [r for r in results if not r[1]]
for name, ok, detail in results:
    print(f"{'✓' if ok else '✗'} {name}: {detail}")
print(f"\n{len(results) - len(failed)}/{len(results)} checks passed "
      f"({len(set(r[0].split('[')[0] for r in results))} route families)")
sys.exit(1 if failed else 0)
