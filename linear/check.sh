#!/bin/bash
# Quickstart check — boots the twin into its sprint-board world, asks who it is
# talking to, lists the board, files an issue in the world's team, reads it
# back, and asserts an unknown issue is refused the way Linear refuses it.
# Run from anywhere: bash check.sh
#
# One script, no second one: a workspace twin's surface is issue CRUD over one
# GraphQL endpoint, so the round trip below IS the check.
cd "$(dirname "$0")" || exit 1

[ -f ./linear-twin ] || { echo "✗ linear-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./linear-twin ] || chmod +x ./linear-twin

fail() {
  echo "✗ $1"
  [ -s /tmp/linear-twin.log ] && { echo "--- /tmp/linear-twin.log ---"; tail -5 /tmp/linear-twin.log; }
  kill $TWIN_PID 2>/dev/null
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

# Where to serve. Override to run beside something already on 8080:
#   bash check.sh localhost:18080
ADDR="${1:-localhost:8080}"
PORT="${ADDR##*:}"

# Refuse a port somebody else already holds: every twin answers
# /_rystic/version, so the boot check cannot tell one twin from another.
if curl -sf -o /dev/null "$ADDR/_rystic/version" 2> /dev/null; then
  echo "✗ something is already serving on $ADDR — stop it, or pass a free address: bash check.sh localhost:18080"
  exit 1
fi

# The sprint-board world: one team, ENG, with six people, six workflow states
# and eight issues, so the check needs no seed.
RYSTIC_ADDR="$ADDR" ./linear-twin --scenario linear_sprint_board > /tmp/linear-twin.log 2>&1 &
TWIN_PID=$!
for _ in $(seq 1 150); do
  curl -sf "$ADDR/_rystic/version" > /dev/null && break
  kill -0 $TWIN_PID 2> /dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"

# The twin needs no Linear key but refuses a request with no Authorization, so
# the check sends a placeholder, bare, as Linear takes a personal API key.
gql() {
  curl -s "$ADDR"/graphql -H 'Authorization: lin_placeholder' -H 'Content-Type: application/json' -d "$1"
}

me=$(gql '{"query":"query Me { viewer { id name } }","operationName":"Me"}') || fail "viewer query rejected"
echo "$me" | grep -q '"name": *"Mira Okafor"' || fail "viewer did not answer the world's admin: $me"

board=$(gql '{"query":"{ issues { nodes { identifier title } } }"}')
echo "$board" | grep -q '"identifier": *"ENG-103"' || fail "the sprint-board world did not list its issues: ${board:0:200}"

# The team and its Todo state are the world's, so their ids are fixed. The
# issue's id is minted by the twin, so it comes back out of the create: a
# hardcoded one would only ever test the not-found path.
TEAM_ID=5b0a4d00-7ea0-4a00-8b00-000000000001
TODO_ID=5b0a4d00-57a7-4a00-8b00-000000000002
created=$(gql "{\"query\":\"mutation { issueCreate(input: {teamId: \\\"$TEAM_ID\\\", stateId: \\\"$TODO_ID\\\", title: \\\"Quickstart\\\"}) { success issue { id identifier state { name } } } }\"}")
echo "$created" | grep -q '"success": *true' || fail "issueCreate did not succeed: $created"
echo "$created" | grep -q '"identifier": *"ENG-[0-9]*"' || fail "issueCreate did not number the issue in ENG: $created"
echo "$created" | grep -q '"name": *"Todo"' || fail "issueCreate did not file the issue in Todo: $created"
iid=$(printf '%s' "$created" | sed -n 's/.*"issue": *{"id": *"\([0-9a-f-]*\)".*/\1/p')
[ -n "$iid" ] || fail "issueCreate returned no id: $created"
got=$(gql "{\"query\":\"{ issue(id: \\\"$iid\\\") { id title } }\"}")
echo "$got" | grep -q '"title": *"Quickstart"' || fail "read-back failed for $iid: $got"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(gql '{"query":"{ issue(id: \"00000000-0000-4000-8000-00000000dead\") { id } }"}')
echo "$missing" | grep -q '"code": *"INPUT_ERROR"' || fail "an unknown issue id was not refused with INPUT_ERROR: $missing"

curl -sf -X POST "$ADDR"/_rystic/reset > /dev/null || fail "reset failed"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this on a fixed port,
# such as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill $TWIN_PID 2> /dev/null
  echo "✓ linear-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ linear-twin is good to go on $ADDR (kill $TWIN_PID to stop)"
fi
