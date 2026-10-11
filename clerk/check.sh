#!/bin/bash
# The shipped smoke requires only curl and a placeholder secret key, so a
# customer can verify the archive without installing an SDK. With openssl on
# PATH it also boots the browser companion on a throwaway signing key.
cd "$(dirname "$0")" || exit 1

[ -f ./clerk-twin ] || { echo "✗ clerk-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./clerk-twin ] || chmod +x ./clerk-twin

# The twin's log and any throwaway key live in a private directory, never at
# a fixed path a shared host could have planted a symlink at; the trap
# removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/clerk-twin-check.XXXXXX") || exit 1
LOG="$WORK/clerk-twin.log"
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

# The browser companion needs an RSA signing key and the twin's own origin.
# A key file you name is used as it is; otherwise openssl makes a throwaway
# one, and without openssl the companion stays off and only its static
# bundle is checked. Clerk SDKs refuse an issuer host with no dot, so
# localhost becomes 127.0.0.1.
COMPANION=0
THROWAWAY=0
if [ -n "${CLERK_TWIN_PRIVATE_KEY_FILE:-}" ]; then
  COMPANION=1
elif command -v openssl > /dev/null 2>&1; then
  KEY="$WORK/signing-key.pem"
  if (umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY") > /dev/null 2>&1; then
    export CLERK_TWIN_PRIVATE_KEY_FILE="$KEY"
    COMPANION=1
    THROWAWAY=1
  fi
fi
DERIVED=0
if [ "$COMPANION" = 1 ] && [ -z "${CLERK_TWIN_ISSUER:-}" ]; then
  DERIVED=1
fi
[ "$COMPANION" = 1 ] || echo "note: no openssl and no CLERK_TWIN_PRIVATE_KEY_FILE — the browser companion's sign-in routes are not checked"

# Acme Robotics: five users in one organization with three live sessions, so
# the read half needs no seed. start_twin fails only when the twin exits
# before its banner, such as on a port another process holds.
start_twin() { # <addr>
  RYSTIC_ADDR="$1" ./clerk-twin --scenario clerk_acme_tenant > "$LOG" 2>&1 &
  TWIN_PID=$!
  line=""
  for _ in $(seq 1 150); do
    line=$(grep -o -m 1 'listening on [^ ]* (model [^)]*)' "$LOG" 2>/dev/null) && return 0
    kill -0 "$TWIN_PID" 2>/dev/null || { TWIN_PID=""; return 1; }
    sleep 0.2
  done
  fail "twin printed no listening banner"
}

# The issuer names the port the twin serves on, so a port 0 bind picks one
# first; a port that turns out taken is retried on another.
HOST=${BIND%:*}
PORT=${BIND##*:}
if [ "$DERIVED" = 1 ] && [ "$PORT" = 0 ]; then
  booted=0
  for _ in 1 2 3 4 5; do
    PORT=$((20000 + RANDOM % 40000))
    export CLERK_TWIN_ISSUER="http://127.0.0.1:$PORT"
    start_twin "$HOST:$PORT" && { booted=1; break; }
  done
  [ "$booted" = 1 ] || fail "twin exited during boot on five ports"
else
  [ "$DERIVED" = 1 ] && export CLERK_TWIN_ISSUER="http://127.0.0.1:$PORT"
  start_twin "$BIND" || fail "twin exited during boot (is $BIND free?)"
fi
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

# Any bearer value that starts with sk_ is accepted; no Clerk instance is involved.
clerk() { # <method> <path> [curl args...]
  local method="$1" path="$2"
  shift 2
  curl -s --noproxy '*' -X "$method" "http://$ADDR$path" \
    -H 'Authorization: Bearer sk_test_placeholder' -H 'Content-Type: application/json' "$@"
}

# The lookalike bundle @clerk/nextjs loads, served with or without a key.
for asset in clerk.js clerk-ui.js clerk.css; do
  served=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{content_type}' "http://$ADDR/$asset")
  case "$asset $served" in
    *.js' 200 application/javascript'*|*.css' 200 text/css'*) ;;
    *) fail "/$asset was not served: $served" ;;
  esac
done

users=$(clerk GET '/v1/users?email_address=dana.okafor@acme-robotics.test') || fail "listing users rejected"
echo "$users" | grep -q '"first_name":"Dana"' || fail "the Acme world's admin did not list: ${users:0:200}"

created=$(clerk POST /v1/users \
  -d '{"email_address":["Release.Check@Example.com"],"first_name":"Release","skip_password_requirement":true,"legal_accepted_at":"2026-01-01T00:00:00Z"}') \
  || fail "creating a user rejected"
echo "$created" | grep -q '"email_address":"release.check@example.com"' || fail "creating a user answered: ${created:0:300}"
USER=$(echo "$created" | grep -o '"id":"user_[A-Za-z0-9]*"' | head -n 1 | sed 's/"id":"\(.*\)"/\1/')
[ -n "$USER" ] || fail "the created user carried no id: ${created:0:300}"

org=$(clerk POST /v1/organizations -d "{\"name\":\"Release Check\",\"created_by\":\"$USER\"}") \
  || fail "creating an organization rejected"
ORG=$(echo "$org" | grep -o '"id":"org_[A-Za-z0-9_]*"' | head -n 1 | sed 's/"id":"\(.*\)"/\1/')
[ -n "$ORG" ] || fail "creating an organization answered: ${org:0:300}"
members=$(clerk GET "/v1/organizations/$ORG/memberships") || fail "listing the organization's members rejected"
case "$members" in
  *'"role":"org:admin"'*"\"user_id\":\"$USER\""*|*"\"user_id\":\"$USER\""*'"role":"org:admin"'*) ;;
  *) fail "the organization's creator was not listed as its admin: ${members:0:300}" ;;
esac

meta=$(clerk PATCH "/v1/users/$USER/metadata" -d '{"public_metadata":{"plan":"pro"}}') || fail "merging user metadata rejected"
echo "$meta" | grep -q '"plan":"pro"' || fail "merged public metadata did not read back: ${meta:0:300}"

# A twin that invents a user on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(clerk GET /v1/users/user_missing -w ' %{http_code}')
case "$missing" in *'"code":"resource_not_found"'*' 404') ;; *) fail "a missing user was not refused with resource_not_found: ${missing:0:300}" ;; esac
unauthed=$(curl -s --noproxy '*' "http://$ADDR/v1/users" -w ' %{http_code}')
case "$unauthed" in *'"code":"authentication_invalid"'*' 401') ;; *) fail "a request with no secret key was not refused with authentication_invalid: ${unauthed:0:300}" ;; esac

if [ "$COMPANION" = 1 ]; then
  config=$(curl -s --noproxy '*' "http://$ADDR/_twin/config") || fail "/_twin/config rejected"
  case "$config" in *'"publishable_key":"pk_live_'*'"jwt_key":"-----BEGIN PUBLIC KEY-----'*|*'"jwt_key":"-----BEGIN PUBLIC KEY-----'*'"publishable_key":"pk_live_'*) ;; *) fail "/_twin/config carried no publishable key and public PEM: ${config:0:300}" ;; esac
  case "$config" in *"\"issuer\":\"$CLERK_TWIN_ISSUER\""*) ;; *) fail "/_twin/config does not name the issuer $CLERK_TWIN_ISSUER: ${config:0:300}" ;; esac
  [ "$DERIVED" = 0 ] || [ "${ADDR##*:}" = "$PORT" ] || fail "the twin serves on $ADDR, not the port $PORT its issuer names"
  jwks=$(curl -s --noproxy '*' "http://$ADDR/.well-known/jwks.json") || fail "the JWKS rejected"
  echo "$jwks" | grep -q '"alg":"RS256"' || fail "the JWKS carried no RS256 key: ${jwks:0:300}"
  signin=$(curl -s --noproxy '*' -X POST "http://$ADDR/_twin/sign-in" -H 'Content-Type: application/json' \
    -d '{"email":"dana.okafor@acme-robotics.test"}') || fail "signing in through the companion rejected"
  TOKEN=$(echo "$signin" | sed -n 's/.*"token":"\([A-Za-z0-9_.-]*\)".*/\1/p')
  [ -n "$TOKEN" ] || fail "signing in answered no session token: ${signin:0:300}"
  session=$(curl -s --noproxy '*' "http://$ADDR/_twin/session" -H "Authorization: Bearer $TOKEN" -w ' %{http_code}')
  case "$session" in *'"first_name":"Dana"'*' 200') ;; *) fail "the signed-in session did not read back: ${session:0:200}" ;; esac
fi

curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/reset" > /dev/null || fail "reset failed"
# Reset wipes to empty on every plan, so the Acme world is loaded again for
# the client the twin stays up for.
curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/scenario" \
  -H 'Content-Type: application/json' -d '{"name":"clerk_acme_tenant"}' > /dev/null \
  || fail "reloading the Acme world after reset failed"
count=$(clerk GET /v1/users/count -w ' %{http_code}') || fail "counting users after reload rejected"
case "$count" in
  *'"total_count":5'*' 200') ;;
  *) fail "the Acme world's five users did not come back after reload: ${count:0:200}" ;;
esac

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ clerk-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ clerk-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
  [ "$THROWAWAY" = 0 ] \
    || echo "note: its browser companion signs with a throwaway key; restart the twin with your own (HOWTO.md, \"The browser companion\") before pointing a site at it"
fi
