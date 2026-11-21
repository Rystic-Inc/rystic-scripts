#!/bin/bash
# The shipped smoke requires only curl, built with HTTP/2, and a placeholder
# token, so a customer can verify the archive without installing Modal's SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./modal-twin ] || { echo "✗ modal-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./modal-twin ] || chmod +x ./modal-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/modal-twin-check.XXXXXX") || exit 1
LOG="$WORK/modal-twin.log"
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
# token; the gRPC methods and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Six apps across the app lifecycle, so the read half needs no seed.
WORLD=modal_app_states
RYSTIC_ADDR="$BIND" ./modal-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Modal's SDK speaks gRPC over HTTP/2, on the same port as the control plane.
# Each call below is one unary gRPC call sent with curl: a five-byte frame
# header, then the request message encoded by hand. Every request has a
# deadline, so a twin that stops answering fails the check instead of hanging.
curl --version | grep -qw HTTP2 || fail "this curl has no HTTP/2 support, which Modal's gRPC API needs"
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
state() { "${CURL[@]}" -f ${ADMIN[@]+"${ADMIN[@]}"} "$B/_rystic/inspect"; }

byte() { printf "\\$(printf '%03o' "$1")"; }
# A string field of a request message: its tag, its length, its text. Every
# name sent here is shorter than 128 bytes, so each length is one byte.
field() { byte "$1"; byte "${#2}"; printf '%s' "$2"; }
# grpc <Method> <message file>: the reply's bytes land in $WORK/reply and its
# status in GRPC_STATUS. gRPC reports its status in a trailer, or in the
# headers when the reply has no message.
grpc() {
  local size
  size=$(wc -c < "$2" | tr -d ' ')
  [ "$size" -lt 256 ] || fail "a request message of $size bytes does not fit this script's one-byte frame length"
  { printf '\000\000\000\000'; byte "$size"; cat "$2"; } > "$WORK/frame"
  "${CURL[@]}" --http2-prior-knowledge -X POST \
    -H 'Content-Type: application/grpc' -H 'TE: trailers' \
    -H 'x-modal-client-type: 1' -H 'x-modal-client-version: 1.6.3' \
    -H 'x-modal-token-id: ak-rysticcheck00000000000' -H 'x-modal-token-secret: as-rysticcheck00000000000' \
    --data-binary "@$WORK/frame" -D "$WORK/headers" -o "$WORK/reply" \
    "$B/modal.client.ModalClient/$1" || fail "$1 got no answer over HTTP/2"
  GRPC_STATUS=$(tr -d '\r' < "$WORK/headers" | sed -n 's/^[Gg]rpc-[Ss]tatus: *//p' | tail -n 1)
  [ -n "$GRPC_STATUS" ] || fail "$1 answered without a grpc-status: $(head -c 300 "$WORK/headers")"
}
# The first app id in the last reply. Ids are plain text inside the message.
app_id() { LC_ALL=C grep -ao 'ap-[A-Za-z0-9]*' "$WORK/reply" | head -n 1; }

seeded=$(state) || fail "reading the simulator's state was rejected"
echo "$seeded" | grep -q '"billing-api"' || fail "the scenario's deployed app did not read back: ${seeded:0:300}"

# The handshake the SDK opens every session with: an empty message.
: > "$WORK/hello"
grpc ClientHello "$WORK/hello"
[ "$GRPC_STATUS" = 0 ] || fail "ClientHello answered grpc-status $GRPC_STATUS, not 0"

# A read: the scenario's deployed app, looked up by its name as
# modal.App.lookup(name) does.
field 10 billing-api > "$WORK/msg"
grpc AppGetOrCreate "$WORK/msg"
[ "$GRPC_STATUS" = 0 ] || fail "looking up the app billing-api answered grpc-status $GRPC_STATUS, not 0"
[ "$(app_id)" = ap-Life000000000000000004 ] || fail "the deployed app billing-api did not read back by name: $(app_id)"

# A create and its read-back: the app modal.App.lookup(name,
# create_if_missing=True) makes, then the same name looked up again.
{ field 10 archive-checked; byte 24; byte 1; } > "$WORK/msg"
grpc AppGetOrCreate "$WORK/msg"
[ "$GRPC_STATUS" = 0 ] || fail "AppGetOrCreate answered grpc-status $GRPC_STATUS, not 0"
created=$(app_id)
[ -n "$created" ] || fail "AppGetOrCreate answered no app id"
grpc AppGetOrCreate "$WORK/msg"
[ "$(app_id)" = "$created" ] || fail "the created app did not read back under its id $created: $(app_id)"
read_back=$(state) || fail "reading the state back was rejected"
echo "$read_back" | grep -q '"archive-checked"' || fail "the created app is not in the simulator's state: ${read_back:0:300}"

# A twin that finds a function no app holds would hide a typo in a lookup.
# Modal refuses one with NOT_FOUND, gRPC status 5.
{ field 10 billing-api; field 18 no_such_function; } > "$WORK/msg"
grpc FunctionGet "$WORK/msg"
[ "$GRPC_STATUS" = 5 ] || fail "a function the app does not hold answered grpc-status $GRPC_STATUS, not 5 (NOT_FOUND)"

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
gone=$(state) || fail "reading the state after the reset was rejected"
case "$gone" in
  *archive-checked*) fail "the created app survived the reset: ${gone:0:300}" ;;
  '{'*) ;;
  *) fail "the state after the reset was not a JSON object: ${gone:0:300}" ;;
esac
# Reset empties the workspace, so the scenario is loaded again for the client
# the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
again=$(state) || fail "reading the state after the reload was rejected"
echo "$again" | grep -q '"billing-api"' || fail "the scenario did not load again after reset: ${again:0:300}"

# The twin stays up on purpose, so there is something to point the SDK at:
# MODAL_SERVER_URL=http://<address> with any MODAL_TOKEN_ID and
# MODAL_TOKEN_SECRET. RYSTIC_CHECK_STOP=1 stops it, for callers that run this
# unattended, such as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ modal-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ modal-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
