#!/bin/bash
# Exercise the installed directory surface and leave a clean running twin. (RYS-1384)
set -eu
cd "$(dirname "$0")"
ADDR="${1:-localhost:8080}"
BASE="http://$ADDR"
AUTH='Authorization: SSWS offline-placeholder'
LOG=$(mktemp)
PID=""
fail() { echo "FAIL: $1"; tail -10 "$LOG"; exit 1; }
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; rm -f "$LOG"; }
trap cleanup EXIT
BIN=./okta-twin
[ -f "$BIN" ] || BIN=./okta-twin.exe
[ -x "$BIN" ] || fail "okta-twin executable must be beside check.sh"
# A released build refuses to boot without a credential. Resolve it the way
# the CLI does: an API-key build reads $RYSTIC_TOKEN, else config.json's
# token, else the key `rystic login rys_…` stored; an Enterprise build reads
# $RYSTIC_LICENSE (a path, or the base64 license itself in a container), else
# ./rystic-license.json, else the CLI's activated copy. Each build ignores
# the other's variable, so both are exported when found (RYS-1204).
RHOME="${RYSTIC_HOME:-$HOME/.rystic}"
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
if curl -sf -o /dev/null "$BASE/_rystic/version"; then fail "$ADDR is already serving; choose another port"; fi
RYSTIC_ADDR="$ADDR" "$BIN" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 150); do
  curl -sf -o /dev/null "$BASE/_rystic/version" && break
  kill -0 "$PID" 2>/dev/null || fail "twin exited during startup"
  sleep 0.2
done
curl -sf "$BASE/_rystic/version" | grep -q 'model_hash' || fail "version handshake failed"
user=$(curl -fsS "$BASE/api/v1/users?activate=false" -H "$AUTH" -H 'Content-Type: application/json' \
  --data '{"profile":{"firstName":"Release","lastName":"Check","email":"release.check@example.com","login":"release.check@example.com"}}') \
  || fail "create user failed"
uid=$(printf '%s' "$user" | grep -o '"id" *: *"00u[A-Za-z0-9]*"' | head -n 1 | sed 's/.*"\(00u[A-Za-z0-9]*\)"/\1/')
[ -n "$uid" ] || fail "create user returned no id"
printf '%s' "$user" | grep -q '"status" *: *"STAGED"' || fail "a user created with activate=false is not STAGED"
curl -fsS -H "$AUTH" "$BASE/api/v1/users/$uid" | grep -q "$uid" || fail "user read-back failed"
group=$(curl -fsS "$BASE/api/v1/groups" -H "$AUTH" -H 'Content-Type: application/json' \
  --data '{"profile":{"name":"Release Check","description":"check.sh"}}') || fail "create group failed"
gid=$(printf '%s' "$group" | grep -o '"id" *: *"00g[A-Za-z0-9]*"' | head -n 1 | sed 's/.*"\(00g[A-Za-z0-9]*\)"/\1/')
[ -n "$gid" ] || fail "create group returned no id"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$AUTH" "$BASE/api/v1/groups/$gid/users/$uid")
[ "$code" = 204 ] || fail "adding the member answered $code"
curl -fsS -H "$AUTH" "$BASE/api/v1/groups/$gid/users" | grep -q "$uid" || fail "the member is not in the group"
missing=$(curl -sS -w ' %{http_code}' -H "$AUTH" "$BASE/api/v1/users/00u99999999999999999")
case "$missing" in *E0000007*" 404") ;; *) fail "unknown user answered: $missing" ;; esac
curl -fsS -X POST "$BASE/_rystic/reset" > /dev/null || fail "reset failed"
if [ "${RYSTIC_CHECK_STOP:-0}" != 1 ]; then
  echo "PASS: okta-twin is ready on $ADDR (kill $PID to stop)"
  PID=""
else
  echo "PASS: okta-twin checks complete (stopped)"
fi
