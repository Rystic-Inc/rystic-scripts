#!/bin/bash
# The shipped smoke requires only curl and a placeholder bearer token, so a
# customer can verify the archive without installing an SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./dropbox-twin ] || { echo "✗ dropbox-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./dropbox-twin ] || chmod +x ./dropbox-twin

# The twin's log lives in a private directory, never at a fixed path a
# shared host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dropbox-twin-check.XXXXXX") || exit 1
LOG="$WORK/dropbox-twin.log"
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
# token; the Dropbox routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Ada Sealy's personal archive: one Pro account and a nine-entry tree, so the
# read half needs no seed.
RYSTIC_ADDR="$BIND" ./dropbox-twin --scenario dropbox_personal_archive > "$LOG" 2>&1 &
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

# Any bearer value is the world's account; no Dropbox app or token is
# involved. RPC routes take their argument as a JSON body; the content
# routes (upload, download) take it in the Dropbox-API-Arg header beside
# the file's bytes, and the twin serves both hosts' routes on one port.
dbx() { # <route> <json body> [curl args...]
  local route="$1" body="$2"
  shift 2
  curl -s --noproxy '*' -X POST "http://$ADDR/2/$route" \
    -H 'Authorization: Bearer sl.placeholder' -H 'Content-Type: application/json' -d "$body" "$@"
}
content() { # <route> <Dropbox-API-Arg json> [curl args...]
  local route="$1" arg="$2"
  shift 2
  curl -s --noproxy '*' -X POST "http://$ADDR/2/$route" \
    -H 'Authorization: Bearer sl.placeholder' -H 'Content-Type: application/octet-stream' \
    -H "Dropbox-API-Arg: $arg" "$@"
}

me=$(dbx users/get_current_account null) || fail "users/get_current_account rejected"
echo "$me" | grep -q '"email":"ada.sealy@example.test"' || fail "the archive's owner did not answer get_current_account: ${me:0:200}"
root=$(dbx files/list_folder '{"path":""}') || fail "listing the root folder rejected"
echo "$root" | grep -q '"path_display":"/notes.md"' || fail "the seeded tree did not list: ${root:0:300}"

folder=$(dbx files/create_folder_v2 '{"path":"/Release Check","autorename":false}') || fail "creating a folder rejected"
echo "$folder" | grep -q '"path_lower":"/release check"' || fail "creating a folder answered: ${folder:0:300}"
FOLDER=$(echo "$folder" | grep -o '"id":"id:[A-Za-z0-9_-]*"' | head -n 1 | sed 's/"id":"\(.*\)"/\1/')
[ -n "$FOLDER" ] || fail "the created folder carried no id: ${folder:0:300}"
meta=$(dbx files/get_metadata '{"path":"/Release Check"}') || fail "reading the folder back rejected"
case "$meta" in
  *'".tag":"folder"'*"\"id\":\"$FOLDER\""*) ;;
  *) fail "the created folder did not read back by path: ${meta:0:300}" ;;
esac

BODY='hello from check.sh'
uploaded=$(content files/upload '{"path":"/Release Check/hello.txt","mode":"add","autorename":false,"mute":false}' --data-binary "$BODY") \
  || fail "uploading a file rejected"
echo "$uploaded" | grep -q '"path_display":"/Release Check/hello.txt"' || fail "uploading a file answered: ${uploaded:0:300}"
downloaded=$(content files/download '{"path":"/Release Check/hello.txt"}') || fail "downloading the file rejected"
[ "$downloaded" = "$BODY" ] || fail "the uploaded bytes did not download back: ${downloaded:0:200}"
listed=$(dbx files/list_folder '{"path":"/Release Check"}') || fail "listing the new folder rejected"
echo "$listed" | grep -q '"name":"hello.txt"' || fail "the uploaded file was not listed in its folder: ${listed:0:300}"

# A twin that invents an entry on read is worse than one missing it: the
# caller's not-found branch would never run. Dropbox answers both of these
# with 409 and a tagged error, never 404 or 400.
duplicate=$(dbx files/create_folder_v2 '{"path":"/Release Check","autorename":false}' -w ' %{http_code}')
case "$duplicate" in *'"conflict"'*' 409') ;; *) fail "creating a folder over an existing one was not refused with path/conflict: ${duplicate:0:300}" ;; esac
missing=$(dbx files/get_metadata '{"path":"/missing.txt"}' -w ' %{http_code}')
case "$missing" in *'"path":{".tag":"not_found"}'*' 409') ;; *) fail "a missing path was not refused with path/not_found: ${missing:0:300}" ;; esac
unauthed=$(curl -s --noproxy '*' -X POST "http://$ADDR/2/users/get_current_account" -H 'Content-Type: application/json' -d null -o /dev/null -w '%{http_code}')
[ "$unauthed" = 400 ] || fail "a request with no bearer token was not refused with 400: $unauthed"

deleted=$(dbx files/delete_v2 '{"path":"/Release Check"}') || fail "deleting the folder rejected"
echo "$deleted" | grep -q '"path_lower":"/release check"' || fail "deleting the folder answered: ${deleted:0:300}"
gone=$(dbx files/get_metadata '{"path":"/Release Check"}' -w ' %{http_code}')
case "$gone" in *'"not_found"'*' 409') ;; *) fail "the deleted folder still read back: ${gone:0:300}" ;; esac

curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
# Reset empties the Dropbox on every plan, so the archive is loaded again for
# the client the twin stays up for.
curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d '{"name":"dropbox_personal_archive"}' > /dev/null \
  || fail "reloading the archive after reset failed"
restored=$(dbx users/get_current_account null -w ' %{http_code}') || fail "get_current_account after reload rejected"
case "$restored" in
  *'"email":"ada.sealy@example.test"'*' 200') ;;
  *) fail "the archive's owner did not answer after reload: ${restored:0:200}" ;;
esac

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ dropbox-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ dropbox-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
