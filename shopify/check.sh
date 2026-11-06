#!/bin/bash
# The shipped smoke requires only curl and a placeholder Admin API token, so a
# customer can verify the archive without installing a Shopify library.
cd "$(dirname "$0")" || exit 1

[ -f ./shopify-twin ] || { echo "✗ shopify-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`.
[ -x ./shopify-twin ] || chmod +x ./shopify-twin

# The twin's log lives in a private directory, never at a fixed path a shared
# host could have planted a symlink at; the trap removes it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/shopify-twin-check.XXXXXX") || exit 1
LOG="$WORK/shopify-twin.log"
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
# token; the Admin API endpoint and /_rystic/version stay open.
ADMIN=()
[ -z "${RYSTIC_ADMIN_TOKEN:-}" ] || ADMIN=(-H "X-Rystic-Admin-Token: $RYSTIC_ADMIN_TOKEN")

# Acme Apparel: three products with their variants, two collections, three
# customers and three orders, so the read half needs no seed.
WORLD=shopify_apparel_storefront
RYSTIC_ADDR="$BIND" ./shopify-twin --scenario "$WORLD" > "$LOG" 2>&1 &
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

# Every query and mutation is a POST of JSON to the one versioned Admin
# endpoint, with any token value in the access token header; no Shopify store,
# app or token is involved. Every request has a deadline, so a twin that stops
# answering fails the check instead of hanging it.
B="http://$ADDR"
GQL="$B/admin/api/2026-10/graphql.json"
CURL=(curl -s --noproxy '*' --max-time 30)
gql() { # <json body>
  "${CURL[@]}" "$GQL" -H 'X-Shopify-Access-Token: shpat_placeholder' \
    -H 'Content-Type: application/json' -d "$1"
}
count() { # the number of products the store holds
  gql '{"query":"{ productsCount { count } }"}' | sed -n 's/.*"count":\([0-9]*\).*/\1/p'
}

shop=$(gql '{"query":"{ shop { name } }"}') || fail "the shop query was rejected"
echo "$shop" | grep -q '"name":"Acme Apparel"' || fail "the scenario's shop did not answer: ${shop:0:200}"
shell=$(gql '{"query":"{ product(id: \"gid://shopify/Product/1030\") { title } }"}') \
  || fail "the product query was rejected"
echo "$shell" | grep -q '"title":"Cedar Rain Shell"' || fail "the seeded product did not read by its id: ${shell:0:300}"
n=$(count)
[ "$n" = 3 ] || fail "productsCount returned $n, not the three products the scenario seeds"

# A product's id is minted by the twin, so it comes back out of the create: a
# hardcoded one would only ever test the not-found path.
created=$(gql '{"query":"mutation { productCreate(product: {title: \"Ridge Wool Socks\"}) { product { id title } userErrors { field message } } }"}') \
  || fail "productCreate was rejected"
PRODUCT=$(printf '%s' "$created" | sed -n 's/.*"id":"\(gid:\/\/shopify\/Product\/[0-9]*\)".*/\1/p')
[ -n "$PRODUCT" ] || fail "productCreate returned no product id: ${created:0:300}"
echo "$created" | grep -q '"userErrors":\[\]' || fail "productCreate answered userErrors: ${created:0:300}"
read_back=$(gql '{"query":"{ product(id: \"'"$PRODUCT"'\") { title handle } }"}') \
  || fail "reading $PRODUCT back was rejected"
echo "$read_back" | grep -q '"title":"Ridge Wool Socks"' || fail "$PRODUCT did not read back its title: ${read_back:0:300}"
# Shopify derives a product's handle from its title when none is sent.
echo "$read_back" | grep -q '"handle":"ridge-wool-socks"' || fail "$PRODUCT did not read back the handle its title makes: ${read_back:0:300}"
n=$(count)
[ "$n" = 4 ] || fail "productsCount returned $n after the create, not four"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run. Shopify answers an unknown id in
# a query as a null field, not an error.
missing=$(gql '{"query":"{ product(id: \"gid://shopify/Product/999999\") { id } }"}')
case "$missing" in
  *'"errors"'*) fail "an unknown product answered an error, not null: ${missing:0:300}" ;;
  *'"product":null'*) ;;
  *) fail "an unknown product did not answer null: ${missing:0:300}" ;;
esac
anon=$("${CURL[@]}" "$GQL" -H 'Content-Type: application/json' -d '{"query":"{ shop { name } }"}' -w ' %{http_code}')
case "$anon" in
  *'Invalid API key or access token'*' 401') ;;
  *) fail "a request with no access token was not refused with 401: ${anon:0:300}" ;;
esac

"${CURL[@]}" -f -X POST "$B/_rystic/reset" ${ADMIN[@]+"${ADMIN[@]}"} > /dev/null || fail "reset failed"
gone=$(gql '{"query":"{ product(id: \"'"$PRODUCT"'\") { id } }"}') \
  || fail "reading $PRODUCT after the reset was rejected"
case "$gone" in
  *'"errors"'*) fail "reading $PRODUCT after the reset returned an error: ${gone:0:300}" ;;
  *'"product":null'*) ;;
  *'"product":{'*) fail "$PRODUCT survived the reset: ${gone:0:300}" ;;
  *) fail "reading $PRODUCT after the reset did not answer null: ${gone:0:300}" ;;
esac
# Reset empties the store, so the scenario is loaded again for the client the
# twin stays up for.
"${CURL[@]}" -f -X POST "$B/_rystic/scenario" ${ADMIN[@]+"${ADMIN[@]}"} \
  -H 'Content-Type: application/json' -d "{\"name\":\"$WORLD\"}" > /dev/null \
  || fail "reloading the scenario after reset failed"
n=$(count)
[ "$n" = 3 ] || fail "the scenario did not load again after reset: productsCount returned $n"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers that run this unattended, such
# as CI.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ shopify-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ shopify-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
