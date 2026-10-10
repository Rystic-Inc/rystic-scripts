#!/bin/bash
# Trade smoke test — run with the twin already running (bash check.sh first).
# Seeds a resting book, crosses it with a fill-or-kill order, asserts the
# fill, position, book depletion, and WS egress. Needs Pro or Enterprise: it
# seeds and reads the egress log (RYS-1204). Usage: bash trade-check.sh [host:port]
BASE=${1:-localhost:8080}
fail() { echo "✗ $1"; exit 1; }
j() { curl -sf -H "Content-Type: application/json" "$@"; }

j -X POST $BASE/_rystic/reset >/dev/null || fail "reset failed — is the twin running on $BASE? (bash check.sh first)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" -X POST "$BASE"/_rystic/seed -d '{
  "state_market_catalog": { "DB-A": { "ticker": "DB-A", "status": "active",
    "yes_ask_dollars": "0.40", "no_ask_dollars": "0.55" } },
  "state_orderbook": { "DB-A": { "ticker": "DB-A", "bids": [],
    "asks": [ { "price_dollars": "0.40",
      "resting": [ { "order_id": "seed-maker-1", "remaining_count_fp": "25", "seq": 1 } ] } ] } }
}')
[ "$code" = 403 ] && fail "this plan cannot seed (HTTP 403) — trade-check.sh seeds its own book and reads /_rystic/egress, which need Pro or Enterprise; check.sh covers Free"
case "$code" in 2??) ;; *) fail "seed rejected (HTTP $code)" ;; esac

RESP=$(j -X POST $BASE/trade-api/v2/portfolio/events/orders -d '{
  "ticker": "DB-A", "side": "bid", "price": "0.40", "count": "10",
  "time_in_force": "fill_or_kill", "self_trade_prevention_type": "taker_at_cross",
  "client_order_id": "11111111-1111-1111-1111-111111111111"
}') || fail "order rejected"
echo "$RESP" | grep -q '"fill_count":"10.00"' || fail "expected fill_count 10.00, got: $RESP"

j $BASE/trade-api/v2/portfolio/fills      | grep -q '"is_taker":true'        || fail "no taker fill recorded"
j $BASE/trade-api/v2/portfolio/positions  | grep -q '"position_fp":"10.00"'  || fail "position is not 10"
j $BASE/trade-api/v2/markets/DB-A/orderbook | grep -q '"15.00"'              || fail "book not depleted 25→15"
j $BASE/_rystic/egress                    | grep -q '"type":"fill"'          || fail "no WS fill egress recorded"

echo "✓ trade check passed: FOK bid 10 @ 0.40 crossed the book — fill, position, book depletion, and WS egress all correct"
