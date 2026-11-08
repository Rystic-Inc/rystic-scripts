#!/bin/bash
# The shipped smoke requires only curl and a placeholder OAuth token, so a
# customer can verify the archive without installing a QuickBooks SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./quickbooks-twin ] || { echo "✗ quickbooks-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./quickbooks-twin ] || chmod +x ./quickbooks-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/quickbooks-twin-check.XXXXXX") || exit 1
LOG="$WORK/quickbooks-twin.log"
TWIN_PID=""
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() {
  echo "✗ $1"
  [ -s "$LOG" ] && { echo "--- twin log ---"; tail -5 "$LOG"; }
  [ -z "$TWIN_PID" ] || kill "$TWIN_PID" 2>/dev/null
  exit 1
}

# A released build refuses to boot without a credential: resolve it as the CLI
# does, and export both builds' variables since each ignores the other's.
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
# A note, not a failure: an unstamped snapshot boots with neither.
[ -n "${RYSTIC_TOKEN:-}${RYSTIC_LICENSE:-}" ] || echo "note: no API key or license found — fine for an unstamped build; a released build refuses to boot without one (rystic login rys_…)"

# Where to serve: the address given, else a loopback port the kernel hands
# out. Either way readiness is held to the twin this script started — its
# banner names the address it bound and its model hash, its pid must be
# alive, and /_rystic/version there must report that hash — so a port some
# other server holds can never pass as this twin.
#   bash check.sh                   # a free port, printed at the end
#   bash check.sh localhost:18080   # serve there instead
BIND="${1:-127.0.0.1:0}"

# A twin booted with RYSTIC_ADMIN_TOKEN gates its control routes on that
# token; the QuickBooks routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Blue Heron Bakery: eight customers, most with open balances, and the
# company's own record, so the read half needs no seed.
WORLD=quickbooks_customer_ledger
RYSTIC_ADDR="$BIND" ./quickbooks-twin --scenario "$WORLD" > "$LOG" 2>&1 &
TWIN_PID=$!
line=""
for _ in $(seq 1 150); do
  line=$(grep -o -m 1 'listening on [^ ]* (model [^)]*)' "$LOG" 2>/dev/null) && break
  kill -0 "$TWIN_PID" 2>/dev/null || fail "twin exited during boot (is $BIND free?)"
  sleep 0.2
done
[ -n "$line" ] || fail "twin printed no listening banner"
ADDR=${line#listening on }
ADDR=${ADDR%% *}
HASH=${line##*(model }
HASH=${HASH%)}
case "$ADDR" in
  :*) ADDR="127.0.0.1$ADDR" ;;   # a bare :port binds every interface; reach it on loopback
esac

got=""
for _ in $(seq 1 150); do
  kill -0 "$TWIN_PID" 2>/dev/null || fail "twin announced $ADDR and then exited"
  got=$(curl -sf --noproxy '*' --max-time 5 "http://$ADDR/_rystic/version" 2>/dev/null \
    | sed -n 's/.*"model_hash": *"\([^"]*\)".*/\1/p')
  [ -z "$got" ] || break
  sleep 0.2
done
[ -n "$got" ] || fail "/_rystic/version on $ADDR reported no model hash"
[ "$got" = "$HASH" ] || fail "$ADDR answered model $got, not the $HASH its own banner names — that port is not this twin's"

# QuickBooks Online takes an OAuth 2.0 bearer token and a company (realm) id
# in the path; the twin accepts any token. Every request has a deadline, so a
# twin that stops answering fails the check instead of hanging it.
B="http://$ADDR"
REALM=4620816365320737870
CURL=(curl -s --noproxy '*' --max-time 30)
api() { # <path> [curl args...]
  local path="$1"; shift
  "${CURL[@]}" -H 'Authorization: Bearer placeholder-token' -H 'Accept: application/json' \
    "$B/v3/company/$REALM$path" "$@"
}

company=$(api "/companyinfo/$REALM") || fail "reading CompanyInfo was rejected"
echo "$company" | grep -q '"CompanyName":"Blue Heron Bakery"' || fail "the scenario's company did not answer: ${company:0:300}"
amy=$(api /customer/1) || fail "reading customer 1 was rejected"
echo "$amy" | grep -q '"DisplayName":"Amy'"'"'s Bird Sanctuary"' || fail "the seeded customer did not read by its Id: ${amy:0:300}"
echo "$amy" | grep -q '"Balance":239,' || fail "the seeded customer did not read its open balance: ${amy:0:300}"

# A vendor's Id is minted by the twin, so it comes back out of the create: a
# hardcoded one would only ever test the not-found path.
created=$(api /vendor -H 'Content-Type: application/json' -d '{"DisplayName":"Harbor Flour Mill"}') \
  || fail "creating a vendor was rejected"
VENDOR=$(printf '%s' "$created" | sed -n 's/.*"DisplayName":"Harbor Flour Mill","Id":"\([0-9]*\)".*/\1/p')
[ -n "$VENDOR" ] || fail "creating a vendor returned no Id: ${created:0:300}"
read_back=$(api "/vendor/$VENDOR") || fail "reading vendor $VENDOR back was rejected"
echo "$read_back" | grep -q '"DisplayName":"Harbor Flour Mill"' || fail "vendor $VENDOR did not read back its name: ${read_back:0:300}"
# QuickBooks starts every record's SyncToken at 0 and bumps it on each update.
echo "$read_back" | grep -q '"SyncToken":"0"' || fail "vendor $VENDOR did not start at SyncToken 0: ${read_back:0:300}"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run. QuickBooks answers an unknown Id
# with a 400 validation fault, code 610.
missing=$(api /customer/999 -w ' %{http_code}')
case "$missing" in
  *'"code":"610"'*' 400') ;;
  *) fail "an unknown customer did not answer 400 with fault 610: ${missing:0:300}" ;;
esac
anon=$("${CURL[@]}" -H 'Accept: application/json' "$B/v3/company/$REALM/customer/1" -w ' %{http_code}')
case "$anon" in
  *'AuthenticationFailed'*' 401') ;;
  *) fail "a request with no token was not refused with 401: ${anon:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
gone=$(api "/vendor/$VENDOR" -w ' %{http_code}')
case "$gone" in
  *'"code":"610"'*' 400') ;;
  *'"Vendor":{'*) fail "vendor $VENDOR survived the reset: ${gone:0:300}" ;;
  *) fail "reading vendor $VENDOR after the reset did not answer 400 with fault 610: ${gone:0:300}" ;;
esac
# Reset empties the company, so the scenario is loaded again for the client
# the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
amy=$(api /customer/1) || fail "reading customer 1 after the reload was rejected"
echo "$amy" | grep -q '"DisplayName":"Amy'"'"'s Bird Sanctuary"' || fail "the scenario did not load again after reset: ${amy:0:300}"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ quickbooks-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ quickbooks-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
