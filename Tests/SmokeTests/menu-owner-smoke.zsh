#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

test_root="$(mktemp -d)"
owner_pid=""
waiter_pid=""
cleanup() {
  [[ -n "$owner_pid" ]] && kill "$owner_pid" >/dev/null 2>&1 || true
  [[ -n "$waiter_pid" ]] && kill "$waiter_pid" >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

cache="$test_root/cache"
shims="$test_root/shims"
tools="$test_root/tools"
gate="$test_root/release-owner"
cli="$PWD/.build/debug/simlease"
mkdir -p "$shims" "$tools"

fake_xcrun="$tools/xcrun"
{
  print -- '#!/bin/zsh'
  print -- 'set -euo pipefail'
  print -- 'if [[ -n "${SIMLEASE_FAKE_GATE:-}" ]]; then'
  print -- '  while [[ ! -e "$SIMLEASE_FAKE_GATE" ]]; do sleep 0.02; done'
  print -- 'fi'
} > "$fake_xcrun"
chmod +x "$fake_xcrun"
ln -s "$cli" "$shims/xcrun"

status_json() {
  SIMLEASE_CACHE_ROOT="$cache" "$cli" status --json
}

wait_for_status() {
  local expression="$1"
  local attempt
  for attempt in {1..250}; do
    if status_json | jq -e "$expression" >/dev/null; then
      return 0
    fi
    sleep 0.02
  done
  status_json >&2
  fail "status did not satisfy: $expression"
}

owner_id="019faaef-c552-7933"
waiter_id="019fbb00-c552-7933"
CODEX_THREAD_ID="$owner_id" SIMLEASE_CACHE_ROOT="$cache" \
  "$cli" name "[SimLease] Owner smoke"

PATH="$shims:$tools:/usr/bin:/bin" \
CODEX_THREAD_ID="$owner_id" \
SIMLEASE_CACHE_ROOT="$cache" \
SIMLEASE_FAKE_GATE="$gate" \
  "$shims/xcrun" simctl list &
owner_pid=$!

wait_for_status '.state == "leased" and .owner.threadTitle == "[SimLease] Owner smoke"'

PATH="$shims:$tools:/usr/bin:/bin" \
CODEX_THREAD_ID="$waiter_id" \
SIMLEASE_CACHE_ROOT="$cache" \
  "$shims/xcrun" simctl list &
waiter_pid=$!

wait_for_status '.waiters | length == 1'
snapshot="$(status_json)"
[[ "$(jq -r '.owner.threadID' <<< "$snapshot")" == "$owner_id" ]] \
  || fail "wrong owner thread ID"
[[ "$(jq -r '.waiters[0].threadID' <<< "$snapshot")" == "$waiter_id" ]] \
  || fail "wrong waiter ordering"
[[ "$(jq -r '.waiters[0].threadTitle' <<< "$snapshot")" == null ]] \
  || fail "waiter should exercise ID fallback"

touch "$gate"
wait "$owner_pid" || fail "owner command failed"
owner_pid=""
wait "$waiter_pid" || fail "waiter command failed"
waiter_pid=""
wait_for_status '.state == "free" and (.waiters | length == 0)'

print -- "menu-owner-smoke: PASS"
