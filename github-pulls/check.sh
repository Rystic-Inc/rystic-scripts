#!/bin/bash
# Quickstart check — boots the twin into its open-queue world, lists the pull
# requests, reads one back, and asserts an unknown one is refused.
# Run from anywhere: bash check.sh
#
# The Kalshi twin's pair is check.sh + trade-check.sh, because an exchange's
# second claim is that money moves correctly. A review-surface twin's claims
# are resource reads and the review state machine, so the round trip below IS
# the check and there is no second script. A stub that asserted nothing would
# read as coverage; its absence reads as what it is.
cd "$(dirname "$0")" || exit 1

[ -f ./github-pulls-twin ] || { echo "✗ github-pulls-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it — inside the released image the binary is already
# executable and owned by root while this runs as `rystic`, so an
# unconditional chmod prints a meaningless permission error on the first line
# of the customer's first command and then succeeds anyway.
[ -x ./github-pulls-twin ] || chmod +x ./github-pulls-twin

fail() {
  echo "✗ $1"
  [ -s /tmp/github-pulls-twin.log ] && { echo "--- /tmp/github-pulls-twin.log ---"; tail -5 /tmp/github-pulls-twin.log; }
  kill $TWIN_PID 2>/dev/null
  exit 1
}

# The credential, resolved the way the CLI resolves it. The Free and Pro build
# serves under an API key: $RYSTIC_TOKEN, then config.json's token, then the
# key `rystic login rys_…` stored. The Enterprise build reads a license:
# $RYSTIC_LICENSE (a path, or the license itself in a container), then
# ./rystic-license.json, then the CLI's activated copy in $RYSTIC_HOME.
RYSTIC_DIR="${RYSTIC_HOME:-$HOME/.rystic}"
edition=$(./github-pulls-twin --version 2> /dev/null | sed -n 's/^edition: //p')
if [ "$edition" = metered ]; then
  if [ -z "${RYSTIC_TOKEN:-}" ] && [ -f "$RYSTIC_DIR/config.json" ]; then
    RYSTIC_TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RYSTIC_DIR/config.json" | head -1)
  fi
  if [ -z "${RYSTIC_TOKEN:-}" ] && [ -s "$RYSTIC_DIR/token" ]; then
    RYSTIC_TOKEN=$(tr -d '[:space:]' < "$RYSTIC_DIR/token")
  fi
  [ -n "${RYSTIC_TOKEN:-}" ] || { echo "✗ no API key — run 'rystic login rys_…' with a key from https://www.rystic.ai/account/api-keys, or set RYSTIC_TOKEN"; exit 1; }
  export RYSTIC_TOKEN
else
  if [ -z "${RYSTIC_LICENSE:-}" ]; then
    for candidate in ./rystic-license.json "$RYSTIC_DIR/rystic-license.json"; do
      [ -f "$candidate" ] && { export RYSTIC_LICENSE="$candidate"; break; }
    done
  fi
  # A warning, not a failure: an unstamped snapshot boots with no license at
  # all. A stamped build refuses at startup and says so, and the boot loop
  # below surfaces that message.
  [ -n "${RYSTIC_LICENSE:-}" ] || echo "note: no license found — fine for an unstamped build; an Enterprise build will refuse to boot without one"
fi

# Where to serve. Override to run beside something already on 8080:
#   bash check.sh localhost:18080
ADDR="${1:-localhost:8080}"
PORT="${ADDR##*:}"

# Refuse a port somebody else already holds, rather than testing their
# process. Every twin answers /_rystic/version with a model_hash, so the boot
# check below CANNOT tell one twin from another. Checking first turns that
# into one legible line.
if curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "$ADDR/_rystic/version" 2> /dev/null; then
  echo "✗ something is already serving on $ADDR — stop it, or pass a free address: bash check.sh localhost:18080"
  exit 1
fi

# The open-queue world: one repository, tb-owner/tb-repo, with four open pull
# requests. Booting into it means the list below has something to return
# without a seed step, which is what a customer's first command should do.
RYSTIC_ADDR=":$PORT" ./github-pulls-twin --scenario github-pulls_open_queue > /tmp/github-pulls-twin.log 2>&1 &
TWIN_PID=$!
for i in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" > /dev/null && break
  kill -0 $TWIN_PID 2> /dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"

# No GitHub token is needed or wanted: no route checks a token's value. A
# real client would put a token here, so the check sends the shape one would
# rather than omitting the header.
AUTH="Authorization: Bearer ghp_placeholder"

listed=$(curl -sf "$ADDR"/repos/tb-owner/tb-repo/pulls -H "$AUTH") \
  || fail "list pulls rejected"
echo "$listed" | grep -q '"number": *4[1-4]' || fail "the open-queue world did not list its pull requests: ${listed:0:200}"

# The number has to come back out of the list — it is the world's, so a
# hardcoded one would only ever test the 404 path.
num=$(printf '%s' "$listed" | sed -n 's/.*"number": *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$num" ] || fail "list returned no pull number: ${listed:0:200}"

curl -sf "$ADDR"/repos/tb-owner/tb-repo/pulls/"$num" -H "$AUTH" | grep -q "\"number\": *$num" \
  || fail "read-back failed for pull #$num"

# A twin that invents a record on read is worse than one missing it: the
# caller's not-found branch would never run, in any test they ever write.
code=$(curl -s -o /dev/null -w '%{http_code}' "$ADDR"/repos/tb-owner/tb-repo/pulls/999999 -H "$AUTH")
[ "$code" = "404" ] || fail "an unknown pull number answered $code, want 404"

curl -sf -X POST "$ADDR"/_rystic/reset > /dev/null || fail "reset failed"

# The twin stays up on purpose: a quickstart whose last act is to kill the
# thing it just told you is ready leaves you nothing to point a client at.
# RYSTIC_CHECK_STOP=1 is for callers that want the assertion and not the
# server.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill $TWIN_PID 2> /dev/null
  echo "✓ github-pulls-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ github-pulls-twin is good to go on $ADDR (kill $TWIN_PID to stop)"
fi
