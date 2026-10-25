#!/bin/bash
# The shipped smoke requires only curl and a placeholder bearer token, so a
# customer can verify the archive without installing an SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./gmail-twin ] || { echo "✗ gmail-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./gmail-twin ] || chmod +x ./gmail-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gmail-twin-check.XXXXXX") || exit 1
LOG="$WORK/gmail-twin.log"
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
# token; the Gmail routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Ada Lovelace's inbox: nine messages in six threads under system and user
# labels, so the read half needs no seed.
WORLD=gmail_busy_inbox
RYSTIC_ADDR="$BIND" ./gmail-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Any bearer token speaks as the mailbox's own user; no Google project, OAuth
# client or token is involved, and no message is delivered anywhere. Every
# request has a deadline, so a twin that stops answering fails the check
# instead of hanging it.
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
gmail() { # <method> <path under /gmail/v1/users/me> [curl args...]
  local method="$1" path="$2"
  shift 2
  "${CURL[@]}" -X "$method" "$B/gmail/v1/users/me$path" -H 'Authorization: Bearer ya29.placeholder' "$@"
}

flight=$(gmail GET '/messages/19a4c0d1e2f31004?format=metadata&metadataHeaders=Subject') \
  || fail "messages.get was rejected"
echo "$flight" | grep -q '"value":"Flight confirmation ZX4821"' || fail "a seeded message did not read back: ${flight:0:300}"
inbox=$(gmail GET /labels/INBOX) || fail "labels.get was rejected"
echo "$inbox" | grep -q '"messagesTotal":6' || fail "INBOX did not count the world's six messages: ${inbox:0:300}"

# A message's id is minted by the twin, so it comes back out of the insert: a
# hardcoded one would only ever test the not-found path. raw is the RFC 5322
# message below, base64url-encoded:
#   From: check@example.com / To: ada.lovelace@example.com
#   Subject: rystic check / Message-ID: <check-1@example.com>
#   Inserted by check.sh.
RAW=RnJvbTogY2hlY2tAZXhhbXBsZS5jb20NClRvOiBhZGEubG92ZWxhY2VAZXhhbXBsZS5jb20NClN1YmplY3Q6IHJ5c3RpYyBjaGVjaw0KTWVzc2FnZS1JRDogPGNoZWNrLTFAZXhhbXBsZS5jb20-DQoNCkluc2VydGVkIGJ5IGNoZWNrLnNoLg0K
created=$(gmail POST /messages -H 'Content-Type: application/json' \
  -d "{\"raw\":\"$RAW\",\"labelIds\":[\"INBOX\",\"UNREAD\"]}") || fail "messages.insert was rejected"
ID=$(printf '%s' "$created" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
[ -n "$ID" ] || fail "messages.insert returned no id: ${created:0:300}"
read_back=$(gmail GET "/messages/$ID?format=metadata&metadataHeaders=Subject") || fail "reading the message back was rejected"
echo "$read_back" | grep -q '"value":"rystic check"' || fail "the inserted message did not read back its Subject: ${read_back:0:300}"
echo "$read_back" | grep -q '"labelIds":\["INBOX","UNREAD"\]' || fail "the inserted message did not keep its labels: ${read_back:0:300}"
newest=$(gmail GET '/messages?labelIds=INBOX&maxResults=1') || fail "messages.list was rejected"
echo "$newest" | grep -q "\"id\":\"$ID\"" || fail "INBOX did not list the inserted message first: ${newest:0:300}"
inbox=$(gmail GET /labels/INBOX) || fail "labels.get was rejected"
echo "$inbox" | grep -q '"messagesTotal":7' || fail "INBOX did not count the inserted message: ${inbox:0:300}"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(gmail GET /messages/0123456789abcdef -w ' %{http_code}')
case "$missing" in
  *'"reason":"notFound"'*' 404') ;;
  *) fail "an unknown message did not answer 404 notFound: ${missing:0:300}" ;;
esac
# Gmail refuses a request with no credential before any lookup.
anonymous=$("${CURL[@]}" "$B/gmail/v1/users/me/labels" -w ' %{http_code}')
case "$anonymous" in
  *'Login Required.'*' 401') ;;
  *) fail "a request with no bearer token was not refused with 401: ${anonymous:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
# Reset empties the mailbox, the world's own mail included; loading the world
# resets too, so this is checked before the reload.
for gone_id in "$ID" 19a4c0d1e2f31004; do
  gone=$(gmail GET "/messages/$gone_id" -w ' %{http_code}')
  case "$gone" in *' 404') ;; *) fail "message $gone_id survived the reset: ${gone:0:300}" ;; esac
done
# The world is loaded again for the client the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the world after reset failed"
inbox=$(gmail GET /labels/INBOX)
echo "$inbox" | grep -q '"messagesTotal":6' || fail "the world did not load again after reset: ${inbox:0:300}"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ gmail-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ gmail-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
