#!/bin/bash
# Quickstart check — boots the twin, creates a channel, posts a message, reads
# both back, and asserts an unknown channel is refused the way Slack refuses it.
# Run from anywhere: bash check.sh
#
# The Kalshi twin's pair is check.sh + trade-check.sh, because an exchange's
# second claim is that money moves correctly. A messaging twin's surface is
# channel and message CRUD, so the round trip below IS the check and there is
# no second script. A stub that asserted nothing would read as coverage; its
# absence reads as what it is.
cd "$(dirname "$0")" || exit 1

[ -f ./slack-twin ] || { echo "✗ slack-twin binary not found next to check.sh"; exit 1; }
# Only if it needs it — inside the released image the binary is already
# executable and owned by root while this runs as `rystic`, so an
# unconditional chmod prints a meaningless permission error on the first line
# of the customer's first command and then succeeds anyway.
[ -x ./slack-twin ] || chmod +x ./slack-twin

fail() {
  echo "✗ $1"
  [ -s /tmp/slack-twin.log ] && { echo "--- /tmp/slack-twin.log ---"; tail -5 /tmp/slack-twin.log; }
  kill $TWIN_PID 2>/dev/null
  exit 1
}

# The credential, resolved the way the CLI resolves it. The Free and Pro build
# serves under an API key: $RYSTIC_TOKEN, then a token file ($RYSTIC_TOKEN_FILE
# or the rystic_token secret), then config.json's token, then the key
# `rystic login rys_…` stored. The Enterprise build reads a license:
# $RYSTIC_LICENSE (a path, or the license itself in a container), then
# ./rystic-license.json, then the CLI's activated copy in $RYSTIC_HOME.
RYSTIC_DIR="${RYSTIC_HOME:-$HOME/.rystic}"
edition=$(./slack-twin --version 2> /dev/null | sed -n 's/^edition: //p')
if [ "$edition" = metered ]; then
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

RYSTIC_ADDR=":$PORT" ./slack-twin > /tmp/slack-twin.log 2>&1 &
TWIN_PID=$!
for i in $(seq 1 150); do
  curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" > /dev/null && break
  kill -0 $TWIN_PID 2> /dev/null || fail "twin exited during boot"
  sleep 0.2
done

curl -sf --connect-timeout 1 --max-time 2 "$ADDR/_rystic/version" | grep -q model_hash || fail "twin not responding on $ADDR"

# No Slack app is needed or wanted: no method checks a token's value. The
# prefix matters — the twin reads the credential kind off it, the way Slack
# does — so the check sends the shape a real client would. Every plan boots
# an empty workspace, and the round trip works in it.
AUTH="Authorization: Bearer xoxb-placeholder"

created=$(curl -sf -X POST "$ADDR"/conversations.create -H "$AUTH" -d "name=quickstart") \
  || fail "conversations.create rejected"
echo "$created" | grep -q '"ok": *true' || fail "conversations.create did not answer ok:true: ${created:0:200}"

# The id has to come back out of the create response — it is minted by the
# twin, so a hardcoded one would only ever test the not-found path.
cid=$(printf '%s' "$created" | sed -n 's/.*"id": *"\(C[A-Z0-9]*\)".*/\1/p' | head -1)
[ -n "$cid" ] || fail "conversations.create returned no channel id: ${created:0:200}"

curl -sf "$ADDR/conversations.info?channel=$cid" -H "$AUTH" | grep -q "\"$cid\"" \
  || fail "conversations.info read-back failed for $cid"

posted=$(curl -sf -X POST "$ADDR"/chat.postMessage -H "$AUTH" -d "channel=$cid" -d "text=hello from check.sh") \
  || fail "chat.postMessage rejected"
echo "$posted" | grep -q '"ok": *true' || fail "chat.postMessage did not answer ok:true: ${posted:0:200}"

curl -sf "$ADDR/conversations.history?channel=$cid" -H "$AUTH" | grep -q 'hello from check.sh' \
  || fail "conversations.history did not return the posted message"

# Slack refuses at HTTP 200 with ok:false and an error code — never a 404.
# A twin that invents a channel on read, or that answers 404, would leave the
# caller's error branch unexercised in every test they ever write.
missing=$(curl -s "$ADDR/conversations.info?channel=C0NEVERMADE" -H "$AUTH")
echo "$missing" | grep -q '"error": *"channel_not_found"' \
  || fail "an unknown channel answered ${missing:0:120}, want ok:false channel_not_found"

curl -sf -X POST "$ADDR"/_rystic/reset > /dev/null || fail "reset failed"

# The twin stays up on purpose: a quickstart whose last act is to kill the
# thing it just told you is ready leaves you nothing to point a client at.
# RYSTIC_CHECK_STOP=1 is for callers that want the assertion and not the
# server.
if [ "${RYSTIC_CHECK_STOP:-0}" = 1 ]; then
  kill $TWIN_PID 2> /dev/null
  echo "✓ slack-twin passed its checks on $ADDR (stopped)"
else
  echo "✓ slack-twin is good to go on $ADDR (kill $TWIN_PID to stop)"
fi
