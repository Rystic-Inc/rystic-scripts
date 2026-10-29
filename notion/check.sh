#!/bin/bash
# The shipped smoke requires only curl and a placeholder bearer token, so a
# customer can verify the archive without installing an SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./notion-twin ] || { echo "✗ notion-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./notion-twin ] || chmod +x ./notion-twin

# The twin's log lives in a private directory, never at a fixed path a
# shared host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/notion-twin-check.XXXXXX") || exit 1
LOG="$WORK/notion-twin.log"
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

# The team wiki: a root page with three child pages and a Meeting Notes
# database, so the read half needs no seed.
RYSTIC_ADDR="$BIND" ./notion-twin --scenario notion_team_wiki > "$LOG" 2>&1 &
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

# Any non-empty bearer token is the world's bot; the twin answers Notion-Version
# 2026-03-11 and 2025-09-03, and a request must carry a Notion-Version header.
notion() { # <method> <path> [curl args...]
  local method="$1" path="$2"
  shift 2
  curl -s --noproxy '*' -X "$method" "http://$ADDR$path" \
    -H 'Authorization: Bearer secret_placeholder' -H 'Notion-Version: 2026-03-11' \
    -H 'Content-Type: application/json' "$@"
}

ROOT=a1000000-0000-4000-8000-000000000101
me=$(notion GET /v1/users/me) || fail "users/me rejected"
echo "$me" | grep -q '"name":"Wiki Reader"' || fail "the team wiki's bot did not answer users/me: ${me:0:200}"
BOT=$(echo "$me" | sed -n 's/.*"id":"\([0-9a-f-]*\)","name":"Wiki Reader".*/\1/p')
[ -n "$BOT" ] || fail "users/me carried no bot id: ${me:0:200}"
root=$(notion GET "/v1/pages/$ROOT") || fail "retrieving the wiki's root page rejected"
echo "$root" | grep -q 'Acme Team Wiki' || fail "the wiki's root page did not read back: ${root:0:200}"

page=$(notion POST /v1/pages \
  -d "{\"parent\":{\"page_id\":\"$ROOT\"},\"properties\":{\"title\":{\"title\":[{\"text\":{\"content\":\"Release check\"}}]}}}") \
  || fail "creating a page rejected"
echo "$page" | grep -q '"object":"page"' || fail "creating a page answered: ${page:0:300}"
# The page's own id: every id in the answer but the bot's (created_by,
# last_edited_by); the parent is carried as page_id, not id.
PAGE=$(echo "$page" | grep -o '"id":"[0-9a-f-]*"' | grep -v "$BOT" | head -n 1 | sed 's/"id":"\(.*\)"/\1/')
[ -n "$PAGE" ] || fail "the created page carried no id of its own: ${page:0:300}"

BODY='hello from check.sh'
added=$(notion PATCH "/v1/blocks/$PAGE/children" \
  -d "{\"children\":[{\"object\":\"block\",\"type\":\"paragraph\",\"paragraph\":{\"rich_text\":[{\"type\":\"text\",\"text\":{\"content\":\"$BODY\"}}]}}]}") \
  || fail "appending a paragraph rejected"
echo "$added" | grep -q '"type":"paragraph"' || fail "appending a paragraph answered: ${added:0:300}"
children=$(notion GET "/v1/blocks/$PAGE/children") || fail "listing the page's children rejected"
echo "$children" | grep -q "$BODY" || fail "the paragraph did not read back: ${children:0:300}"

# A twin that invents a page on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(notion GET /v1/pages/a1000000-0000-4000-8000-000000009999 -w ' %{http_code}')
case "$missing" in *'"code":"object_not_found"'*' 404') ;; *) fail "a missing page was not refused with object_not_found: ${missing:0:300}" ;; esac
unversioned=$(curl -s --noproxy '*' "http://$ADDR/v1/users/me" -H 'Authorization: Bearer secret_placeholder' -w ' %{http_code}')
case "$unversioned" in *'"code":"missing_version"'*' 400') ;; *) fail "a request with no Notion-Version was not refused with missing_version: ${unversioned:0:300}" ;; esac

# Notion deletes nothing: DELETE /v1/blocks/{id} on a page moves it to the trash.
trashed=$(notion DELETE "/v1/blocks/$PAGE") || fail "trashing the page rejected"
echo "$trashed" | grep -q '"in_trash":true' || fail "trashing the page answered: ${trashed:0:300}"

curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/reset" > /dev/null || fail "reset failed"
# Reset wipes to empty on every plan, so the wiki is loaded again for the
# client the twin stays up for.
curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/scenario" \
  -H 'Content-Type: application/json' -d '{"name":"notion_team_wiki"}' > /dev/null \
  || fail "reloading the team wiki after reset failed"
restored=$(notion GET /v1/users/me -w ' %{http_code}') || fail "users/me after reload rejected"
case "$restored" in
  *'"name":"Wiki Reader"'*' 200') ;;
  *) fail "the team wiki's bot did not answer after reload: ${restored:0:200}" ;;
esac

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ notion-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ notion-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
