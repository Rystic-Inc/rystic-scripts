#!/bin/bash
# The shipped smoke requires only curl and placeholder Jira credentials, so a
# customer can verify the archive without installing a Jira client.
cd "$(dirname "$0")" || exit 1

[ -f ./jira-twin ] || { echo "✗ jira-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./jira-twin ] || chmod +x ./jira-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-twin-check.XXXXXX") || exit 1
LOG="$WORK/jira-twin.log"
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
# token; the Jira routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# A software project, PLAT, mid-sprint: six issues on a scrum board with its
# sprints, comments and worklogs, so the read half needs no seed.
WORLD=jira_sprint_board
RYSTIC_ADDR="$BIND" ./jira-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Jira Cloud takes Basic auth with an email address and an API token; the
# twin accepts any pair. Every request has a deadline, so a twin that stops
# answering fails the check instead of hanging it.
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
AUTH=(-u 'check@example.com:placeholder-token')
api() { # <path> [curl args...]
  local path="$1"; shift
  "${CURL[@]}" "${AUTH[@]}" "$B/rest/api/3$path" "$@"
}
count() { # the number of PLAT issues a search returns
  api /search/jql -G --data-urlencode 'jql=project = PLAT' -d maxResults=50 \
    | grep -o '"id":"[0-9]*"' | wc -l | tr -d ' '
}

epic=$(api '/issue/PLAT-1?fields=summary,issuetype') || fail "reading PLAT-1 was rejected"
echo "$epic" | grep -q '"summary":"Checkout rewrite"' || fail "the seeded epic did not read by its key: ${epic:0:300}"
n=$(count)
[ "$n" = 6 ] || fail "a search of project PLAT returned $n issues, not the six the scenario seeds"

# An issue's key and id are minted by the twin, so they come back out of the
# create: a hardcoded one would only ever test the not-found path.
created=$(api /issue -H 'Content-Type: application/json' \
  -d '{"fields":{"project":{"key":"PLAT"},"issuetype":{"name":"Task"},"summary":"Retry failed webhooks"}}') \
  || fail "creating an issue was rejected"
KEY=$(printf '%s' "$created" | sed -n 's/.*"key":"\(PLAT-[0-9]*\)".*/\1/p')
[ -n "$KEY" ] || fail "creating an issue returned no key: ${created:0:300}"
read_back=$(api "/issue/$KEY?fields=summary,status") || fail "reading $KEY back was rejected"
echo "$read_back" | grep -q '"summary":"Retry failed webhooks"' || fail "$KEY did not read back its summary: ${read_back:0:300}"
# The status's own name, not its category's, which shares the same words.
status=$(printf '%s' "$read_back" | sed -n 's/.*"status":{[^{]*"name":"\([^"]*\)".*/\1/p')
[ "$status" = "To Do" ] || fail "$KEY did not start in To Do: ${read_back:0:300}"
n=$(count)
[ "$n" = 7 ] || fail "a search of project PLAT returned $n issues after the create, not seven"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(api /issue/PLAT-999 -w ' %{http_code}')
case "$missing" in
  *'"errorMessages":["Issue does not exist or you do not have permission to see it."]'*' 404') ;;
  *) fail "an unknown issue did not answer 404: ${missing:0:300}" ;;
esac
anon=$("${CURL[@]}" "$B/rest/api/3/myself" -w ' %{http_code}')
case "$anon" in
  *' 401') ;;
  *) fail "reading the current user with no credential was not refused with 401: ${anon:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
# Reset empties the site, so the scenario is loaded again for the client the
# twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
gone=$(api "/issue/$KEY" -o /dev/null -w '%{http_code}')
[ "$gone" = 404 ] || fail "$KEY survived the reset (answered $gone)"
n=$(count)
[ "$n" = 6 ] || fail "the scenario did not load again after reset: a search returned $n issues"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ jira-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ jira-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
