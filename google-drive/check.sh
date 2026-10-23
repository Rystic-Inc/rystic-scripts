#!/bin/bash
# The shipped smoke requires only curl and a placeholder bearer token, so a
# customer can verify the archive without installing an SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./google-drive-twin ] || { echo "✗ google-drive-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./google-drive-twin ] || chmod +x ./google-drive-twin

# The twin's log and the upload body live in a private directory, never at a
# fixed path a shared host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/google-drive-twin-check.XXXXXX") || exit 1
LOG="$WORK/google-drive-twin.log"
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
# token; the Drive routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Juno Park's media vault: her own folders and files, two of them shared with
# a collaborator, so the read half needs no seed.
WORLD=google-drive_media_vault
RYSTIC_ADDR="$BIND" ./google-drive-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Any bearer value that starts ya29. is the world's own user; no Google
# project, OAuth client or token is involved. Metadata routes live under
# /drive/v3, uploads under /upload/drive/v3, both on the one port. Every
# request has a deadline, so a twin that stops answering fails the check
# instead of hanging it.
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
drive() { # <method> <path?query> [curl args...]
  local method="$1" path="$2"
  shift 2
  "${CURL[@]}" -X "$method" "$B$path" -H 'Authorization: Bearer ya29.placeholder' "$@"
}
id_of() { sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -n 1; }

me=$(drive GET '/drive/v3/about?fields=user') || fail "about.get rejected"
echo "$me" | grep -q '"emailAddress":"juno.park@studio.example"' || fail "the vault's owner did not answer about.get: ${me:0:200}"
listed=$(drive GET '/drive/v3/files?q=trashed%3Dfalse&fields=files(id,name)') || fail "files.list rejected"
echo "$listed" | grep -q '"name":"beach-sunrise.jpg"' || fail "the seeded vault did not list: ${listed:0:300}"

folder=$(drive POST '/drive/v3/files?fields=id,name,mimeType' -H 'Content-Type: application/json' \
  -d '{"name":"Release Check","mimeType":"application/vnd.google-apps.folder"}') || fail "creating a folder rejected"
FOLDER=$(echo "$folder" | id_of)
[ -n "$FOLDER" ] || fail "the created folder carried no id: ${folder:0:300}"
meta=$(drive GET "/drive/v3/files/$FOLDER?fields=id,name,mimeType") || fail "reading the folder back rejected"
case "$meta" in
  *'"mimeType":"application/vnd.google-apps.folder"'*'"name":"Release Check"'*) ;;
  *) fail "the created folder did not read back: ${meta:0:300}" ;;
esac

# A multipart upload: the file's metadata as JSON, then its bytes, in one
# multipart/related body, as the official clients send it.
BODY='hello from check.sh'
{
  printf -- '--check\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
  printf '{"name":"hello.txt","mimeType":"text/plain","parents":["%s"]}\r\n' "$FOLDER"
  printf -- '--check\r\nContent-Type: text/plain\r\n\r\n%s\r\n--check--\r\n' "$BODY"
} > "$WORK/upload.body"
uploaded=$(drive POST '/upload/drive/v3/files?uploadType=multipart&fields=id,name,parents,size' \
  -H 'Content-Type: multipart/related; boundary=check' --data-binary "@$WORK/upload.body") || fail "uploading a file rejected"
FILE=$(echo "$uploaded" | id_of)
case "$uploaded" in
  *"\"name\":\"hello.txt\""*"\"$FOLDER\""*) ;;
  *) fail "uploading a file into the folder answered: ${uploaded:0:300}" ;;
esac
downloaded=$(drive GET "/drive/v3/files/$FILE?alt=media") || fail "downloading the file rejected"
[ "$downloaded" = "$BODY" ] || fail "the uploaded bytes did not download back: ${downloaded:0:200}"
inside=$(drive GET "/drive/v3/files?q=%27$FOLDER%27+in+parents&fields=files(id,name)") || fail "listing the folder rejected"
echo "$inside" | grep -q '"name":"hello.txt"' || fail "the uploaded file was not listed in its folder: ${inside:0:300}"

# A twin that invents a file on read is worse than one missing it: the
# caller's not-found branch would never run. Drive answers both of these with
# its JSON error envelope.
missing=$(drive GET '/drive/v3/files/no-such-file' -w ' %{http_code}')
case "$missing" in *'"reason":"notFound"'*' 404') ;; *) fail "a missing file was not refused with 404 notFound: ${missing:0:300}" ;; esac
unauthed=$("${CURL[@]}" "$B/drive/v3/files/$FILE" -o /dev/null -w '%{http_code}')
case "$unauthed" in 401|403) ;; *) fail "a request with no bearer token was not refused: $unauthed" ;; esac

deleted=$(drive DELETE "/drive/v3/files/$FILE" -o /dev/null -w '%{http_code}')
[ "$deleted" = 204 ] || fail "deleting the file answered $deleted, not 204"
gone=$(drive GET "/drive/v3/files/$FILE" -w ' %{http_code}')
case "$gone" in *'"reason":"notFound"'*' 404') ;; *) fail "the deleted file still read back: ${gone:0:300}" ;; esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
# Reset empties the Drive, so the vault is loaded again for the client the
# twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the vault after reset failed"
restored=$(drive GET '/drive/v3/about?fields=user' -w ' %{http_code}') || fail "about.get after reload rejected"
case "$restored" in
  *'"emailAddress":"juno.park@studio.example"'*' 200') ;;
  *) fail "the vault's owner did not answer after reload: ${restored:0:200}" ;;
esac

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ google-drive-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ google-drive-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
