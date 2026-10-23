#!/bin/bash
# Quickstart check — boots the twin, seeds a market, reads it back.
# Run from anywhere: bash check.sh [host:port]
cd "$(dirname "$0")" || exit 1

[ -f ./kalshi-twin ] || { echo "✗ kalshi-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it. Inside the released container image the binary is
# already executable and owned by root while this runs as `rystic`, so an
# unconditional chmod prints "Operation not permitted" on the first line of the
# customer's first command and succeeds anyway — an error that means nothing,
# in the worst possible place to put one.
[ -x ./kalshi-twin ] || chmod +x ./kalshi-twin

fail() {
  echo "✗ $1"
  [ -s /tmp/kalshi-twin.log ] && { echo "--- /tmp/kalshi-twin.log ---"; tail -5 /tmp/kalshi-twin.log; }
  kill $TWIN_PID 2>/dev/null
  exit 1
}

# The credential, resolved the way the CLI resolves it. The Free and Pro build
# serves under an API key: $RYSTIC_TOKEN, then a token file ($RYSTIC_TOKEN_FILE
# or the rystic_token secret), then config.json's token, then the key
# `rystic login rys_…` stored. The Enterprise build reads a license:
# $RYSTIC_LICENSE (a path, or the license itself in a container), then
# ./rystic-license.json, then the CLI's activated copy in $RYSTIC_HOME.
RYSTIC_DIR="${RYSTIC_HOME:-$HOME/.rystic}"
edition=$(./kalshi-twin --version 2> /dev/null | sed -n 's/^edition: //p')
if [ "$edition" = metered ]; then
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
  if [ -z "${RYSTIC_TOKEN:-}" ] && [ -f "$RYSTIC_DIR/config.json" ]; then
    RYSTIC_TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RYSTIC_DIR/config.json" | head -1)
  fi
  if [ -z "${RYSTIC_TOKEN:-}" ] && [ -s "$RYSTIC_DIR/token" ]; then
    RYSTIC_TOKEN=$(tr -d '[:space:]' < "$RYSTIC_DIR/token")
  fi
  [ -n "${RYSTIC_TOKEN:-}" ] || { echo "✗ no API key — run 'rystic login rys_…' with a key from https://www.rystic.ai/account/api-keys, or set RYSTIC_TOKEN"; exit 1; }
  export RYSTIC_TOKEN
else
  if [ -z "${RYSTIC_LICENSE:-}" ]; then
    for candidate in ./rystic-license.json "$RYSTIC_DIR/rystic-license.json"; do
      [ -f "$candidate" ] && { export RYSTIC_LICENSE="$candidate"; break; }
    done
  fi
  [ -n "${RYSTIC_LICENSE:-}" ] || { echo "✗ no license — set RYSTIC_LICENSE to your rystic-license.json (or run 'rystic login <file>' first)"; exit 1; }
fi

# A throwaway signing key for clients that need one; the twin accepts anything,
# so this is a convenience and not part of the check. Skipped where openssl is
# absent or this directory is not writable — both are true inside the released
# image, which carries no openssl and installs read-only.
if [ ! -f twin_key.pem ] && command -v openssl > /dev/null 2>&1 && [ -w . ]; then
  openssl genrsa -out twin_key.pem 2048
fi

# Where to serve. Override to run beside something already on 8080:
#   bash check.sh localhost:18080
ADDR="${1:-localhost:8080}"
PORT="${ADDR##*:}"

# Refuse a port somebody else already holds, rather than testing their
# process. Every twin answers /_rystic/version with a model_hash, so the boot
# check below CANNOT tell one twin from another — run this on a machine
# already serving a Kalshi twin on 8080 and every assertion passes against a
# process this script never started, possibly built from a different commit
# and carrying whatever state its users left in it. A ✓ for a binary that was
# never exercised is the worst answer a release check can give.
if curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$ADDR/_rystic/version" 2>/dev/null; then
  echo "✗ something is already serving on $ADDR — stop it, or pass a free address: bash check.sh localhost:18080"
  exit 1
fi

RYSTIC_ADDR=":$PORT" ./kalshi-twin >/tmp/kalshi-twin.log 2>&1 &
TWIN_PID=$!
for i in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" >/dev/null && break
  kill -0 $TWIN_PID 2>/dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ADDR"/_rystic/seed -d '{
  "state_market_catalog": { "DB-A": {
    "ticker": "DB-A", "status": "active",
    "yes_ask_dollars": "0.40", "no_ask_dollars": "0.55" } } }')
case "$code" in
  2??) curl -sf "$ADDR"/trade-api/v2/markets/DB-A | grep -q '"ticker":"DB-A"' || fail "read-back failed" ;;
  *) fail "seed rejected (HTTP $code)" ;;
esac
curl -sf -X POST "$ADDR"/_rystic/reset || fail "reset failed"

# The twin stays up on purpose: a quickstart whose last act is to kill the
# thing it just told you is ready leaves you nothing to point a client at.
# RYSTIC_CHECK_STOP=1 is for callers that want the assertion and not the
# server, such as a CI job: a twin left behind holds its port.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill $TWIN_PID 2>/dev/null
  echo "✓ kalshi-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ kalshi-twin is good to go on $ADDR (kill $TWIN_PID to stop; next: bash trade-check.sh $ADDR)"
fi
