#!/bin/bash
# Quickstart check — boots the twin, creates a customer, reads it back.
# Run from anywhere: bash check.sh
#
# The Kalshi twin's pair is check.sh + trade-check.sh, because an exchange's
# second claim is that money moves correctly. A payments twin's surface is
# resource CRUD, so the round trip below IS the second claim and there is no
# trade-check.sh to follow it. A stub that asserted nothing would read as
# coverage; its absence reads as what it is.
cd "$(dirname "$0")" || exit 1

[ -f ./stripe-twin ] || { echo "✗ stripe-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it — inside the released image the binary is already
# executable and owned by root while this runs as `rystic`, so an
# unconditional chmod prints a meaningless permission error on the first line
# of the customer's first command and then succeeds anyway.
[ -x ./stripe-twin ] || chmod +x ./stripe-twin

# The twin's log lives in a directory of this run's own, never at a fixed path
# another run on the host truncates. The trap removes it unless the twin is
# left running, whose log stays where the last line says.
TMP_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${TMP_ROOT%/}/stripe-twin-check.XXXXXX") || exit 1
LOG="$WORK/stripe-twin.log"
TWIN_PID=""
KEEP_LOG=0
cleanup() { [ "$KEEP_LOG" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  echo "✗ $1"
  [ -s "$LOG" ] && { echo "--- twin log ---"; tail -5 "$LOG"; }
  [ -z "$TWIN_PID" ] || kill "$TWIN_PID" 2>/dev/null
  exit 1
}

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
# A note, not a failure: an unstamped snapshot boots with neither. A released
# build that needs one refuses at startup and says so, and the boot loop
# surfaces the log.
[ -n "${RYSTIC_TOKEN:-}${RYSTIC_LICENSE:-}" ] || echo "note: no API key or license found — fine for an unstamped build; a released build refuses to boot without one (rystic login rys_…)"

# Where to serve. Override to run beside something already on 8080:
#   bash check.sh localhost:18080
ADDR="${1:-localhost:8080}"
PORT="${ADDR##*:}"

# Refuse a port somebody else already holds, rather than testing their
# process. Every twin answers /_rystic/version with a model_hash, so the boot
# check below CANNOT tell one twin from another — point this at a machine
# already running a Kalshi twin on 8080 and it goes green through boot and
# then fails on a Stripe route, reporting "create rejected" for a twin that
# never started. Checking first turns that into one legible line.
if curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$ADDR/_rystic/version" 2> /dev/null; then
  echo "✗ something is already serving on $ADDR — stop it, or pass a free address: bash check.sh localhost:18080"
  exit 1
fi

RYSTIC_ADDR=":$PORT" ./stripe-twin > "$LOG" 2>&1 &
TWIN_PID=$!
for _ in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" > /dev/null && break
  kill -0 $TWIN_PID 2> /dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"

# No Stripe key is needed or wanted: the twin is offline and accepts any
# Authorization header. A real SDK would put a key here, so the check sends
# the shape one would rather than omitting the header and testing a path no
# customer takes.
AUTH="Authorization: Bearer sk_test_placeholder"

created=$(curl -sf -X POST "$ADDR"/v1/customers -H "$AUTH" \
  -d "email=quickstart@example.test" -d "name=Quickstart") \
  || fail "create customer rejected"
echo "$created" | grep -q '"object": *"customer"' || fail "create did not answer with a customer: $created"

# The id has to come back out of the create response — it is minted by the
# twin, so a hardcoded one would only ever test the 404 path.
cid=$(printf '%s' "$created" | sed -n 's/.*"id" *: *"\(cus_[^"]*\)".*/\1/p')
[ -n "$cid" ] || fail "create returned no cus_ id: $created"

curl -sf "$ADDR"/v1/customers/"$cid" -H "$AUTH" | grep -q "$cid" \
  || fail "read-back failed for $cid"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run, in any test they ever write.
code=$(curl -s -o /dev/null -w '%{http_code}' "$ADDR"/v1/customers/cus_never_created -H "$AUTH")
[ "$code" = "404" ] || fail "an unknown customer id answered $code, want 404"

curl -sf -X POST "$ADDR"/_rystic/reset > /dev/null || fail "reset failed"

# The twin stays up on purpose: a quickstart whose last act is to kill the
# thing it just told you is ready leaves you nothing to point a client at.
# RYSTIC_CHECK_STOP=1 is for callers that want the assertion and not the
# server, such as a CI job: a twin left behind holds its port.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  { kill $TWIN_PID && wait $TWIN_PID; } 2> /dev/null
  echo "✓ stripe-twin passed its checks on $ADDR (stopped)"
else
  KEEP_LOG=1
  echo "✓ stripe-twin is good to go on $ADDR (kill $TWIN_PID to stop; its log is $LOG)"
fi
