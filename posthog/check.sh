#!/bin/bash
# The shipped smoke requires only curl and a placeholder project token, so a
# customer can verify the archive without installing a PostHog library.
cd "$(dirname "$0")" || exit 1

[ -f ./posthog-twin ] || { echo "✗ posthog-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./posthog-twin ] || chmod +x ./posthog-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/posthog-twin-check.XXXXXX") || exit 1
LOG="$WORK/posthog-twin.log"
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
# token; the capture route and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# One captured signup event, so the read half needs no seed.
WORLD=posthog_first_event
RYSTIC_ADDR="$BIND" ./posthog-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# PostHog's capture route takes the project token in the JSON body, not in a
# header; the twin accepts any non-empty token. Every request has a deadline,
# so a twin that stops answering fails the check instead of hanging it.
B="http://$ADDR"
TOKEN=phc_rysticexampletoken0000000000000000000000
CURL=(curl -s --noproxy '*' --max-time 30)
capture() { # <json body> [curl args...]
  local body="$1"; shift
  "${CURL[@]}" -X POST -H 'Content-Type: application/json' "$B/i/v0/e/" -d "$body" "$@"
}
state() { "${CURL[@]}" -f ${ADMIN[@]+"${ADMIN[@]}"} "$B/_rystic/inspect"; }

seeded=$(state) || fail "reading the simulator's state was rejected"
echo "$seeded" | grep -q '"event":"user_signed_up"' || fail "the scenario's signup event did not read back: ${seeded:0:300}"

sent=$(capture "{\"api_key\":\"$TOKEN\",\"event\":\"archive_checked\",\"distinct_id\":\"check-user\",\"properties\":{\"step\":\"smoke\"}}" -w ' %{http_code}')
case "$sent" in
  *'{"status":"Ok"}'*' 200') ;;
  *) fail "capturing an event did not answer 200 {\"status\":\"Ok\"}: ${sent:0:300}" ;;
esac
read_back=$(state) || fail "reading the state back was rejected"
echo "$read_back" | grep -q '"distinct_id":"check-user","event":"archive_checked"' \
  || fail "the captured event did not read back: ${read_back:0:300}"

# A twin that takes an event with no token would hide a client that forgot
# it. PostHog refuses one with 401 and a plain-text reason.
anon=$(capture '{"event":"archive_checked","distinct_id":"check-user"}' -w ' %{http_code}')
case "$anon" in
  *'event submitted without an api_key'*' 401') ;;
  *) fail "an event with no api_key was not refused with 401: ${anon:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
gone=$(state) || fail "reading the state after the reset was rejected"
case "$gone" in
  *archive_checked*) fail "the captured event survived the reset: ${gone:0:300}" ;;
  '{'*) ;;
  *) fail "the state after the reset was not a JSON object: ${gone:0:300}" ;;
esac
# Reset empties the project, so the scenario is loaded again for the client
# the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
again=$(state) || fail "reading the state after the reload was rejected"
echo "$again" | grep -q '"event":"user_signed_up"' || fail "the scenario did not load again after reset: ${again:0:300}"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ posthog-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ posthog-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
