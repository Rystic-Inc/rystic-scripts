#!/bin/bash
# Quickstart check — boots the twin, saves an address, sends a postcard to it,
# reads both back, and asserts an unknown postcard is refused the way Lob
# refuses it. Run from anywhere: bash check.sh
#
# The Kalshi twin's pair is check.sh + trade-check.sh, because an exchange's
# second claim is that money moves correctly. A mail twin's surface is
# address and postcard CRUD, so the round trip below IS the check and there is
# no second script. A stub that asserted nothing would read as coverage; its
# absence reads as what it is.
cd "$(dirname "$0")" || exit 1

[ -f ./lob-twin ] || { echo "✗ lob-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it — inside the released image the binary is already
# executable and owned by root while this runs as `rystic`, so an
# unconditional chmod prints a meaningless permission error on the first line
# of the customer's first command and then succeeds anyway.
[ -x ./lob-twin ] || chmod +x ./lob-twin

fail() {
  echo "✗ $1"
  [ -s /tmp/lob-twin.log ] && { echo "--- /tmp/lob-twin.log ---"; tail -5 /tmp/lob-twin.log; }
  kill $TWIN_PID 2>/dev/null
  exit 1
}

# A released build refuses to boot without a credential. Resolve it the way
# the CLI does: an API-key build reads $RYSTIC_TOKEN, else config.json's
# token, else the key `rystic login rys_…` stored; an Enterprise build reads
# $RYSTIC_LICENSE (a path, or the base64 license itself in a container), else
# ./rystic-license.json, else the CLI's activated copy. Each build ignores
# the other's variable, so both are exported when found.
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
# then fails on a Lob route, reporting "create rejected" for a twin that
# never started. Checking first turns that into one legible line.
if curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$ADDR/_rystic/version" 2> /dev/null; then
  echo "✗ something is already serving on $ADDR — stop it, or pass a free address: bash check.sh localhost:18080"
  exit 1
fi

RYSTIC_ADDR=":$PORT" ./lob-twin > /tmp/lob-twin.log 2>&1 &
TWIN_PID=$!
for _ in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" > /dev/null && break
  kill -0 $TWIN_PID 2> /dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"

# No Lob key is needed: the twin accepts any non-empty key as the Basic
# username. A real SDK sends the key that way with an empty password, so the
# check sends that shape rather than a path no customer takes.
AUTH="test_placeholder:"

adr=$(curl -sf -u "$AUTH" -X POST "$ADDR"/addresses \
  -d "name=Quickstart" -d "address_line1=210 King St" -d "address_city=San Francisco" \
  -d "address_state=CA" -d "address_zip=94107" -d "address_country=US") \
  || fail "create address rejected"
echo "$adr" | grep -q '"object": *"address"' || fail "create did not answer with an address: $adr"

# Ids have to come back out of the create responses — they are minted by the
# twin, so a hardcoded one would only ever test the 404 path.
aid=$(printf '%s' "$adr" | sed -n 's/.*"id" *: *"\(adr_[^"]*\)".*/\1/p')
[ -n "$aid" ] || fail "create returned no adr_ id: $adr"

psc=$(curl -sf -u "$AUTH" -X POST "$ADDR"/postcards \
  -d "to=$aid" -d "from=$aid" -d "use_type=operational" \
  --data-urlencode "front=<html>front</html>" --data-urlencode "back=<html>back</html>") \
  || fail "send postcard rejected"
echo "$psc" | grep -q '"object": *"postcard"' || fail "send did not answer with a postcard: $psc"
pid=$(printf '%s' "$psc" | sed -n 's/.*"id" *: *"\(psc_[^"]*\)".*/\1/p')
[ -n "$pid" ] || fail "send returned no psc_ id: $psc"

curl -sf -u "$AUTH" "$ADDR"/postcards/"$pid" | grep -q "$pid" \
  || fail "read-back failed for $pid"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run, in any test they ever write.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$ADDR"/postcards/psc_never_created)
[ "$code" = "404" ] || fail "an unknown postcard id answered $code, want 404"

curl -sf -X POST "$ADDR"/_rystic/reset > /dev/null || fail "reset failed"

# The twin stays up on purpose: a quickstart whose last act is to kill the
# thing it just told you is ready leaves you nothing to point a client at.
# RYSTIC_CHECK_STOP=1 is for callers that want the assertion and not the
# server, such as a CI job: a twin left behind holds its port.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill $TWIN_PID 2> /dev/null
  echo "✓ lob-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ lob-twin is good to go on $ADDR (kill $TWIN_PID to stop)"
fi
