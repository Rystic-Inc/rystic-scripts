#!/bin/bash
# Exercise the installed checkout surface and leave a clean running twin.
set -eu
cd "$(dirname "$0")"
ADDR="${1:-localhost:8080}"
BASE="http://$ADDR"
LOG=$(mktemp)
PID=""
fail() { echo "FAIL: $1"; tail -10 "$LOG"; exit 1; }
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; rm -f "$LOG"; }
trap cleanup EXIT
BIN=./paypal-twin
[ -f "$BIN" ] || BIN=./paypal-twin.exe
[ -x "$BIN" ] || fail "paypal-twin executable must be beside check.sh"
# A released build refuses to boot without a credential. Resolve it the way
# the CLI does: an API-key build reads $RYSTIC_TOKEN, else a token
# file ($RYSTIC_TOKEN_FILE or the rystic_token secret), else config.json's
# token, else the key `rystic login rys_…` stored; an Enterprise build reads
# $RYSTIC_LICENSE (a path, or the base64 license itself in a container), else
# ./rystic-license.json, else the CLI's activated copy. Each build ignores
# the other's variable, so both are exported when found.
RHOME="${RYSTIC_HOME:-$HOME/.rystic}"
# A token file a deployment names or mounts comes before the saved login, and
# one named or mounted but unusable stops the check rather than falling through.
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
token_from() { # <path> <where it came from>
  { [ ! -d "$1" ] && [ -r "$1" ]; } || fail "$2 ($1) is not a readable file"
  RYSTIC_TOKEN=$(trim "$(cat "$1")")
  [ -n "$RYSTIC_TOKEN" ] || fail "$2 ($1) is empty — it should hold the API key (rys_…)"
}
RYSTIC_TOKEN=$(trim "${RYSTIC_TOKEN:-}")
TOKEN_FILE=$(trim "${RYSTIC_TOKEN_FILE:-}")
SECRET=/run/secrets/rystic_token
if [ -z "$RYSTIC_TOKEN" ] && [ -n "$TOKEN_FILE" ]; then
  token_from "$TOKEN_FILE" '$RYSTIC_TOKEN_FILE'
elif [ -z "$RYSTIC_TOKEN" ] && { [ -e "$SECRET" ] || [ -L "$SECRET" ]; }; then
  token_from "$SECRET" 'the rystic_token secret'
fi
if [ -z "${RYSTIC_TOKEN:-}" ] && [ -f "$RHOME/config.json" ]; then
  RYSTIC_TOKEN=$(sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p' "$RHOME/config.json" | head -n 1)
fi
if [ -z "${RYSTIC_TOKEN:-}" ] && [ -s "$RHOME/token" ]; then
  RYSTIC_TOKEN=$(tr -d ' \t\r\n' < "$RHOME/token")
fi
[ -z "${RYSTIC_TOKEN:-}" ] || export RYSTIC_TOKEN
if [ -z "${RYSTIC_LICENSE:-}" ]; then
  for candidate in ./rystic-license.json "$RHOME/rystic-license.json"; do
    [ -f "$candidate" ] && { export RYSTIC_LICENSE="$candidate"; break; }
  done
fi
if curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$BASE/_rystic/version"; then fail "$ADDR is already serving; choose another port"; fi
RYSTIC_ADDR="$ADDR" "$BIN" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$BASE/_rystic/version" && break
  kill -0 "$PID" 2>/dev/null || fail "twin exited during startup"
  sleep 0.2
done
curl -sf --connect-timeout 1 --max-time 2 "$BASE/_rystic/version" | grep -q 'model_hash' || fail "version handshake failed"
order=$(curl -fsS "$BASE/v2/checkout/orders" -H 'Authorization: Bearer offline-test' -H 'Content-Type: application/json' -H 'PayPal-Request-Id: release-smoke-order' --data '{"intent":"CAPTURE","purchase_units":[{"amount":{"currency_code":"USD","value":"10.00"}}]}') || fail "create order failed"
id=$(printf '%s' "$order" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "create returned no id"
printf '%s' "$order" | grep -q '"status": *"CREATED"' || fail "wallet order is not CREATED"
curl -fsS -H 'Authorization: Bearer offline-test' "$BASE/v2/checkout/orders/$id" | grep -q "$id" || fail "order read-back failed"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$BASE/v2/checkout/orders/$id" -H 'Authorization: Bearer offline-test' -H 'Content-Type: application/json' --data '[{"op":"add","path":"/purchase_units/@reference_id=='"'"'default'"'"'/description","value":"release-check"}]')
[ "$code" = 204 ] || fail "PATCH answered $code"
curl -fsS -H 'Authorization: Bearer offline-test' "$BASE/v2/checkout/orders/$id" | grep -q 'release-check' || fail "PATCH did not persist"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer offline-test' "$BASE/v2/payments/captures/9ZZ99999ZZ999999Z")
[ "$code" = 404 ] || fail "unknown capture answered $code"
curl -fsS -X POST "$BASE/_rystic/reset" > /dev/null || fail "reset failed"
if [ "${RYSTIC_CHECK_STOP:-0}" != 1 ]; then
  echo "PASS: paypal-twin is ready on $ADDR (kill $PID to stop)"
  PID=""
else
  echo "PASS: paypal-twin checks complete (stopped)"
fi
