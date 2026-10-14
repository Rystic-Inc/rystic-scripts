#!/bin/bash
# The shipped smoke requires only curl: it speaks the raw Office.js batches
# office.js sends, so a customer can verify the archive without Node or an
# add-in.
cd "$(dirname "$0")" || exit 1

[ -f ./word-twin ] || { echo "✗ word-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./word-twin ] || chmod +x ./word-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/word-twin-check.XXXXXX") || exit 1
LOG="$WORK/word-twin.log"
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
# token; the Office.js routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# A mutual NDA mid-negotiation: two authors' tracked changes and a comment
# thread, so the read half needs no seed.
WORLD=word_contract_redlined
RYSTIC_ADDR="$BIND" ./word-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Each request is one context.sync(): the batch office.js posts, ObjectPaths
# naming the objects and Actions reading or changing them. Every request has
# a deadline, so a twin that stops answering fails the check instead of
# hanging it.
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
batch() { # <batch json>
  "${CURL[@]}" -X POST "$B/officejs/ProcessQuery" -H 'Content-Type: application/json' -d "$1"
}
ROOT='"1":{"Id":1,"ObjectPathType":1,"Name":""},"2":{"Id":2,"ObjectPathType":4,"Name":"Body","ParentObjectPathId":1}'

# The add-in's side: the harness package and the host page that frames it.
harness=$("${CURL[@]}" "$B/officejs/harness.tgz" -o /dev/null -w '%{http_code} %{content_type}')
[ "$harness" = "200 application/gzip" ] || fail "the harness package was not served: $harness"
host=$("${CURL[@]}" "$B/officejs/host?addin=https%3A%2F%2Flocalhost%3A3000%2Ftaskpane.html" -o /dev/null -w '%{http_code}')
[ "$host" = 200 ] || fail "the host page answered $host"

# body.paragraphs, body.getTrackedChanges() and body.getComments(), loaded.
read=$(batch '{"Actions":[{"Id":1,"ActionType":2,"Name":"","ObjectPathId":3,"QueryInfo":{"Select":["text"]}},{"Id":2,"ActionType":2,"Name":"","ObjectPathId":4,"QueryInfo":{"Select":["type","author","text"]}},{"Id":3,"ActionType":2,"Name":"","ObjectPathId":5,"QueryInfo":{"Select":["content","authorName","resolved"]}}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":4,"Name":"Paragraphs","ParentObjectPathId":2},"4":{"Id":4,"ObjectPathType":3,"Name":"GetTrackedChanges","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":[]}},"5":{"Id":5,"ObjectPathType":3,"Name":"GetComments","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":[]}}}}') \
  || fail "reading the contract rejected"
case "$read" in
  *'"Text":"Mutual Non-Disclosure Agreement"'*'"Author":"Bob","Text":"Delaware","Type":"Added"'*'"Content":"Is Beta LLC the right legal entity?"'*) ;;
  *) fail "the redlined contract did not read back its paragraphs, Bob's tracked insertion and Alice's comment: ${read:0:300}" ;;
esac

# Tracking on, then a clause appended: the edit is a tracked insertion, and
# the reviewed text shows it in the current view and not in the original.
edit=$(batch '{"Actions":[{"Id":1,"ActionType":4,"Name":"ChangeTrackingMode","ObjectPathId":1,"ArgumentInfo":{"Arguments":["TrackAll"]}},{"Id":2,"ActionType":1,"Name":"","ObjectPathId":3}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":3,"Name":"InsertText","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":[" Signed by both parties.","End"]}}}}') \
  || fail "inserting text rejected"
case "$edit" in *'"Error"'*) fail "inserting text with tracking on answered an error: ${edit:0:300}" ;; esac
changes=$(batch '{"Actions":[{"Id":1,"ActionType":2,"Name":"","ObjectPathId":3,"QueryInfo":{"Select":["type","text"]}}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":3,"Name":"GetTrackedChanges","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":[]}}}}') \
  || fail "reading the tracked changes rejected"
echo "$changes" | grep -q '"Text":" Signed by both parties.","Type":"Added"' || fail "the insertion was not tracked: ${changes:0:300}"
reviewed=$(batch '{"Actions":[{"Id":1,"ActionType":3,"Name":"GetReviewedText","ObjectPathId":3,"ArgumentInfo":{"Arguments":["Current"]}},{"Id":2,"ActionType":3,"Name":"GetReviewedText","ObjectPathId":3,"ArgumentInfo":{"Arguments":["Original"]}}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":3,"Name":"GetRange","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":["Whole"]}}}}') \
  || fail "reading the reviewed text rejected"
case "$reviewed" in
  *'"ActionId":1,"Value":"'*'costs. Signed by both parties.'*'"ActionId":2,"Value":"'*'costs and expenses.'*) ;;
  *) fail "the reviewed text did not show the insertion as current and the original without it: ${reviewed:0:400}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"

# A twin that invents a comment on read is worse than one missing it: the
# add-in's not-found branch would never run. A blank document has none, and
# office.js raises Word's ItemNotFound from the batch's Error.
missing=$(batch '{"Actions":[{"Id":1,"ActionType":2,"Name":"","ObjectPathId":4,"QueryInfo":{"Select":["content"]}}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":3,"Name":"GetComments","ParentObjectPathId":2,"ArgumentInfo":{"Arguments":[]}},"4":{"Id":4,"ObjectPathType":3,"Name":"GetFirst","ParentObjectPathId":3,"ArgumentInfo":{"Arguments":[]}}}}')
case "$missing" in *'"Code":"ItemNotFound"'*) ;; *) fail "the first comment of a blank document was not refused with ItemNotFound: ${missing:0:300}" ;; esac

# Reset leaves a blank document, so the contract is loaded again for the
# add-in the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the contract after reset failed"
restored=$(batch '{"Actions":[{"Id":1,"ActionType":2,"Name":"","ObjectPathId":3,"QueryInfo":{"Select":["text"]}}],"ObjectPaths":{'"$ROOT"',"3":{"Id":3,"ObjectPathType":4,"Name":"Paragraphs","ParentObjectPathId":2}}}') \
  || fail "reading the contract after reload rejected"
case "$restored" in
  *'"Text":"Mutual Non-Disclosure Agreement"'*) ;;
  *) fail "the contract did not read back after reload: ${restored:0:200}" ;;
esac

# The twin stays up on purpose, so there is something to point an add-in at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ word-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ word-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
