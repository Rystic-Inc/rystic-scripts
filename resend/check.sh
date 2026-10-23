#!/bin/bash
# Exercise the archive's binary through email and webhook CRUD.
set -euo pipefail
cd "$(dirname "$0")"
[ -x ./resend-twin ] || { echo "resend-twin executable missing next to check.sh"; exit 1; }

ADDR="${1:-127.0.0.1:8080}"
case "$ADDR" in localhost:*|127.0.0.1:*) ;; *) echo "use localhost:PORT or 127.0.0.1:PORT"; exit 1 ;; esac
PORT="${ADDR##*:}"
case "$PORT" in ''|*[!0-9]*) echo "invalid port"; exit 1 ;; esac
BASE="http://$ADDR"
if curl --connect-timeout 1 --max-time 2 -s -o /dev/null "$BASE/_rystic/version"; then
  echo "something is already serving on $ADDR; choose another port"
  exit 1
fi
LOG=$(mktemp "${TMPDIR:-/tmp}/resend-check.XXXXXX")
TWIN_PID=""
KEEP=0
cleanup() {
  if [ "$KEEP" = 0 ]; then
    [ -z "$TWIN_PID" ] || { kill "$TWIN_PID" 2>/dev/null || true; wait "$TWIN_PID" 2>/dev/null || true; }
    rm -f "$LOG"
  fi
}
trap cleanup EXIT
fail() { echo "FAIL: $1"; tail -10 "$LOG"; exit 1; }
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
RYSTIC_ADDR="127.0.0.1:$PORT" ./resend-twin > "$LOG" 2>&1 &
TWIN_PID=$!
for _ in $(seq 1 150); do
  kill -0 "$TWIN_PID" 2>/dev/null || fail "simulator exited during boot"
  curl -sf --max-time 2 "$BASE/_rystic/version" >/dev/null && break
  sleep 0.2
done
kill -0 "$TWIN_PID" 2>/dev/null || fail "simulator did not start"
curl -sf --max-time 2 "$BASE/_rystic/version" | grep -q model_hash || fail "version handshake failed"
AUTH="Authorization: Bearer re_placeholder"
created=$(curl -sf --max-time 5 "$BASE/emails" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"from":"Acme <onboarding@resend.dev>","to":["delivered@resend.dev"],"subject":"Quickstart","html":"<p>Local test</p>"}') || fail "email create failed"
id=$(printf '%s' "$created" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "email create returned no id"
curl -sf --max-time 5 "$BASE/emails/$id" -H "$AUTH" | grep -q 'Quickstart' || fail "email read-back failed"
curl -sf --max-time 5 "$BASE/emails" -H "$AUTH" | grep -Fq "$id" || fail "created email missing from list"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/emails/ffffffff-ffff-4fff-8fff-ffffffffffff" -H "$AUTH")
[ "$code" = 404 ] || fail "unknown email returned $code instead of 404"
created=$(curl -sf --max-time 5 "$BASE/webhooks" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"endpoint":"https://example.test/resend","events":["email.sent"]}') || fail "webhook create failed"
id=$(printf '%s' "$created" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || fail "webhook create returned no id"
curl -sf --max-time 5 "$BASE/webhooks/$id" -H "$AUTH" | grep -Fq "$id" || fail "webhook read-back failed"
curl -sf --max-time 5 -X DELETE "$BASE/webhooks/$id" -H "$AUTH" >/dev/null || fail "webhook delete failed"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE/webhooks/$id" -H "$AUTH")
[ "$code" = 404 ] || fail "deleted webhook remains readable"
curl -sf --max-time 5 -X POST "$BASE/_rystic/reset" >/dev/null || fail "reset failed"
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  echo "resend-twin checks passed (stopped)"
else
  KEEP=1
  echo "resend-twin checks passed: $BASE (PID $TWIN_PID; log $LOG)"
fi
