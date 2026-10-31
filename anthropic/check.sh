#!/bin/bash
# The shipped smoke requires only curl and a placeholder API key, so a
# customer can verify the archive without installing an SDK.
cd "$(dirname "$0")" || exit 1

[ -f ./anthropic-twin ] || { echo "✗ anthropic-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./anthropic-twin ] || chmod +x ./anthropic-twin

# The twin's log and the skill upload live in a private directory, never at a
# fixed path a shared host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/anthropic-twin-check.XXXXXX") || exit 1
LOG="$WORK/anthropic-twin.log"
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
# alive and /_rystic/version there must report that hash — so a port some
# other server holds can never pass as this twin.
#   bash check.sh                   # a free port, printed at the end
#   bash check.sh localhost:18080   # serve there instead
BIND="${1:-127.0.0.1:0}"

# A twin booted with RYSTIC_ADMIN_TOKEN gates its control routes on that
# token; the Anthropic routes and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Three skills with six versions between them, beside the model table, so the
# read half needs no seed.
WORLD=anthropic_skill_library
RYSTIC_ADDR="$BIND" ./anthropic-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Any API key works; the twin reads it from x-api-key. No Anthropic account
# or key is involved, nothing reaches Anthropic and every request has a
# deadline, so a twin that stops answering fails the check instead of hanging it.
B="http://$ADDR"
CURL=(curl -s --noproxy '*' --max-time 30)
api() { # <method> <path> [curl args...]
  local method="$1" path="$2"
  shift 2
  "${CURL[@]}" -X "$method" "$B$path" -H 'x-api-key: sk-ant-placeholder' -H 'anthropic-version: 2023-06-01' "$@"
}
count_skills() { grep -o '"type":"skill"' | wc -l | tr -d ' '; }

invoice=$(api GET /v1/skills/skill_01InvoiceParser00001) || fail "skills.retrieve was rejected"
echo "$invoice" | grep -q '"display_name":"Invoice Parser"' || fail "a seeded skill did not read back: ${invoice:0:300}"
listed=$(api GET /v1/skills) || fail "skills.list was rejected"
[ "$(printf '%s' "$listed" | count_skills)" = 3 ] || fail "the world did not list its three skills: ${listed:0:300}"
reply=$(api POST /v1/messages -H 'Content-Type: application/json' \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":64,"messages":[{"role":"user","content":"Say hello"}]}') \
  || fail "messages.create was rejected"
echo "$reply" | grep -q '"role":"assistant"' || fail "messages.create did not answer an assistant message: ${reply:0:300}"

# A skill's id is minted by the twin, so it comes back out of the create: a
# hardcoded one would only ever test the not-found path.
mkdir "$WORK/rystic-check"
printf -- '---\nname: rystic-check\ndescription: A skill the shipped check creates.\n---\nSay hello.\n' \
  > "$WORK/rystic-check/SKILL.md"
created=$(api POST /v1/skills -F 'display_title=Rystic Check' \
  -F "files[]=@$WORK/rystic-check/SKILL.md;filename=rystic-check/SKILL.md;type=text/markdown") \
  || fail "skills.create was rejected"
ID=$(printf '%s' "$created" | sed -n 's/.*"id":"\(skill_[^"]*\)".*/\1/p')
[ -n "$ID" ] || fail "skills.create returned no id: ${created:0:300}"
read_back=$(api GET "/v1/skills/$ID") || fail "reading the skill back was rejected"
echo "$read_back" | grep -q '"display_name":"Rystic Check"' || fail "the created skill did not read back its display_name: ${read_back:0:300}"
versions=$(api GET "/v1/skills/$ID/versions") || fail "skills.versions.list was rejected"
echo "$versions" | grep -q '"name":"rystic-check"' || fail "the created skill's version did not take its SKILL.md name: ${versions:0:300}"
listed=$(api GET /v1/skills)
[ "$(printf '%s' "$listed" | count_skills)" = 4 ] || fail "skills.list did not count the created skill: ${listed:0:300}"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(api GET /v1/skills/skill_01NoSuchSkill000000 -w ' %{http_code}')
case "$missing" in
  *'"type":"not_found_error"'*' 404') ;;
  *) fail "an unknown skill did not answer 404 not_found_error: ${missing:0:300}" ;;
esac
# The API refuses a request with no key before any lookup.
anonymous=$("${CURL[@]}" "$B/v1/skills" -H 'anthropic-version: 2023-06-01' -w ' %{http_code}')
case "$anonymous" in
  *'"type":"authentication_error"'*' 401') ;;
  *) fail "a request with no API key was not refused with 401: ${anonymous:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
# Reset empties the account, the world's skills included; loading the world
# resets too, so this is checked before the reload.
for gone_id in "$ID" skill_01InvoiceParser00001; do
  gone=$(api GET "/v1/skills/$gone_id" -w ' %{http_code}')
  case "$gone" in *' 404') ;; *) fail "skill $gone_id survived the reset: ${gone:0:300}" ;; esac
done
# The world is loaded again for the client the twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the world after reset failed"
listed=$(api GET /v1/skills)
[ "$(printf '%s' "$listed" | count_skills)" = 3 ] || fail "the world did not load again after reset: ${listed:0:300}"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ anthropic-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ anthropic-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
