#!/bin/bash
# The shipped smoke requires only curl and a placeholder personal access token,
# so a customer can verify the archive without installing an Airtable library.
cd "$(dirname "$0")" || exit 1

[ -f ./airtable-twin ] || { echo "✗ airtable-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./airtable-twin ] || chmod +x ./airtable-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/airtable-twin-check.XXXXXX") || exit 1
LOG="$WORK/airtable-twin.log"
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
# token; the Airtable routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# A launch tracker base with eight records, so the read half needs no seed.
WORLD=airtable_launch_tracker
RYSTIC_ADDR="$BIND" ./airtable-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Airtable takes the token as a bearer header; the twin accepts any non-empty
# one. Every request has a deadline, so a twin that stops answering fails the
# check instead of hanging it.
B="http://$ADDR"
BASE=appLnch0000000001
AUTH='Authorization: Bearer patRysticExample.placeholder'
CURL=(curl -s --noproxy '*' --max-time 30)
api() { "${CURL[@]}" -H "$AUTH" "$@"; }

seeded=$(api -w ' %{http_code}' "$B/v0/$BASE/Tasks/recLnch0000000011")
case "$seeded" in
  *'"Name":"Finalize pricing page"'*' 200') ;;
  *) fail "the scenario's first task did not read back: ${seeded:0:300}" ;;
esac

made=$(api -X POST -H 'Content-Type: application/json' "$B/v0/$BASE/Tasks" \
  -d '{"fields":{"Name":"Archive checked","Status":"Todo"}}' -w ' %{http_code}')
case "$made" in
  *'"Name":"Archive checked"'*' 200') ;;
  *) fail "creating a record did not answer 200: ${made:0:300}" ;;
esac
ID=$(printf '%s' "$made" | sed -n 's/.*"id":"\(rec[A-Za-z0-9]*\)".*/\1/p')
[ -n "$ID" ] || fail "the created record carried no id: ${made:0:300}"
read_back=$(api -w ' %{http_code}' "$B/v0/$BASE/Tasks/$ID")
case "$read_back" in
  *'"Name":"Archive checked"'*'"Status":"Todo"'*' 200') ;;
  *) fail "the created record did not read back: ${read_back:0:300}" ;;
esac

# A malformed record id is not found, as on Airtable.
missing=$(api -w ' %{http_code}' "$B/v0/$BASE/Tasks/notarecordid")
case "$missing" in
  *'{"error":"NOT_FOUND"}'*' 404') ;;
  *) fail "a malformed record id did not answer 404 NOT_FOUND: ${missing:0:300}" ;;
esac

# A request with no token would hide a client that forgot it.
anon=$("${CURL[@]}" -w ' %{http_code}' "$B/v0/meta/bases")
case "$anon" in
  *'AUTHENTICATION_REQUIRED'*' 401') ;;
  *) fail "a request with no token was not refused with 401: ${anon:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
gone=$(api -w ' %{http_code}' "$B/v0/meta/bases")
case "$gone" in
  *'{"bases":[]}'*' 200') ;;
  *) fail "the base survived the reset: ${gone:0:300}" ;;
esac
# Reset empties the workspace, so the scenario is loaded again for the client
# the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
again=$(api -w ' %{http_code}' "$B/v0/$BASE/Tasks/recLnch0000000011")
case "$again" in
  *'"Name":"Finalize pricing page"'*' 200') ;;
  *) fail "the scenario did not load again after reset: ${again:0:300}" ;;
esac
again_made=$(api -w ' %{http_code}' "$B/v0/$BASE/Tasks/$ID")
case "$again_made" in
  *'INVALID_PERMISSIONS_OR_MODEL_NOT_FOUND'*' 403') ;;
  *'"Archive checked"'*) fail "the created record survived the reset: ${again_made:0:300}" ;;
  *) fail "reading the reset record did not answer 403 INVALID_PERMISSIONS_OR_MODEL_NOT_FOUND: ${again_made:0:300}" ;;
esac

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ airtable-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ airtable-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
