#!/bin/bash
# Quickstart check — boots the twin into its static-site world, lists the
# buckets, reads a shipped object, creates a bucket of its own, puts an object
# under a key with a slash, reads it back, lists it, deletes both, and asserts
# a missing key is refused the way S3 refuses it.
# Run from anywhere: bash check.sh [host:port]
#
# Plain HTTP and curl 7.75 or later only: curl's --aws-sigv4 signs each
# request, and the twin checks the signature's shape and freshness, never its
# key, so the machine needs no AWS SDK. (RYS-1372)
cd "$(dirname "$0")" || exit 1

[ -f ./s3-twin ] || { echo "✗ s3-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it: inside the released image the binary is already
# executable and owned by root while this runs as `rystic`. (RYS-1548)
[ -x ./s3-twin ] || chmod +x ./s3-twin
curl --help all 2>/dev/null | grep -q -- '--aws-sigv4' \
  || { echo "✗ curl 7.75 or later is needed: check.sh signs with --aws-sigv4"; exit 1; }

# The twin's log lives in a private directory, never at a fixed path a
# shared host could have planted a symlink at; the trap removes it. (RYS-1548)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s3-twin-check.XXXXXX") || exit 1
LOG="$WORK/s3-twin.log"
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
# does, and export both builds' variables since each ignores the other's (RYS-1204).
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
# A note, not a failure: an unstamped snapshot boots with neither. (RYS-1204)
[ -n "${RYSTIC_TOKEN:-}${RYSTIC_LICENSE:-}" ] || echo "note: no API key or license found — fine for an unstamped build; a released build refuses to boot without one (rystic login rys_…)"

# Where to serve: the address given, else a loopback port the kernel hands
# out. Either way readiness is held to the twin this script started — its
# banner names the address it bound and its model hash, its pid must be
# alive, and /_rystic/version there must report that hash — so a port some
# other server holds can never pass as this twin (RYS-1444).
#   bash check.sh                   # a free port, printed at the end
#   bash check.sh localhost:18080   # serve there instead
BIND="${1:-127.0.0.1:0}"

# The static-site world: a website bucket with seven keys beside its log
# bucket, so the read half needs no seed. It is also the world a Free key
# boots, so the name is accepted on every plan. (RYS-1548)
RYSTIC_ADDR="$BIND" ./s3-twin --scenario s3_static_site > "$LOG" 2>&1 &
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

# The twin holds no AWS key, so AWS's documented example pair signs every
# request; a static Authorization header would go stale. (RYS-1372)
s3() { # <method> <path> [curl args...]
  local method="$1" path="$2"
  shift 2
  curl -s --noproxy '*' -X "$method" "http://$ADDR$path" \
    --aws-sigv4 'aws:amz:us-east-1:s3' --user 'AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' "$@"
}

buckets=$(s3 GET /) || fail "ListBuckets rejected"
echo "$buckets" | grep -q '<Name>acme-demo-site</Name>' || fail "the static-site world did not list its bucket: ${buckets:0:200}"
page=$(s3 GET /acme-demo-site/index.html) || fail "GetObject on the shipped index.html rejected"
echo "$page" | grep -q '<title>Acme Demo</title>' || fail "the shipped index.html did not read back: ${page:0:200}"

BUCKET=release-check
KEY=hello/world.txt
BODY='hello from check.sh'
code=$(s3 PUT "/$BUCKET" -o /dev/null -w '%{http_code}')
[ "$code" = 200 ] || fail "CreateBucket answered $code"
code=$(s3 PUT "/$BUCKET/$KEY" -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' --data "$BODY")
[ "$code" = 200 ] || fail "PutObject answered $code"
got=$(s3 GET "/$BUCKET/$KEY") || fail "GetObject rejected"
[ "$got" = "$BODY" ] || fail "read-back differs: $got"
listing=$(s3 GET "/$BUCKET?list-type=2") || fail "ListObjectsV2 rejected"
echo "$listing" | grep -q "<Key>$KEY</Key>" || fail "ListObjectsV2 did not list $KEY: ${listing:0:200}"

# A twin that invents an object on read is worse than one missing it: the
# caller's not-found branch would never run.
missing=$(s3 GET "/$BUCKET/missing.txt" -w ' %{http_code}')
case "$missing" in *'<Code>NoSuchKey</Code>'*' 404') ;; *) fail "a missing key was not refused with NoSuchKey: ${missing:0:300}" ;; esac

code=$(s3 DELETE "/$BUCKET/$KEY" -o /dev/null -w '%{http_code}')
[ "$code" = 204 ] || fail "DeleteObject answered $code"
code=$(s3 DELETE "/$BUCKET" -o /dev/null -w '%{http_code}')
[ "$code" = 204 ] || fail "DeleteBucket answered $code"

curl -sf --noproxy '*' -X POST "http://$ADDR/_rystic/reset" > /dev/null || fail "reset failed"

# The twin stays up on purpose, so there is something to point a client at.
# RYSTIC_CHECK_STOP=1 stops it, for callers such as `release build -smoke`
# that run this unattended.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill "$TWIN_PID" 2>/dev/null
  wait "$TWIN_PID" 2>/dev/null
  echo "✓ s3-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ s3-twin is good to go on http://$ADDR (kill $TWIN_PID to stop)"
fi
