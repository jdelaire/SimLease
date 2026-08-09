#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

smoke_root="$(mktemp -d)"
jobs=()
cleanup() {
  for pid in $jobs; do kill "$pid" >/dev/null 2>&1 || true; done
  rm -rf "$smoke_root"
}
trap cleanup EXIT

cache="$smoke_root/cache"
shims="$smoke_root/shims"
tools="$smoke_root/tools"
fake_xcrun="$tools/xcrun"
fake_axe="$tools/axe"
cli="$PWD/.build/debug/simlease"
mkdir -p "$shims" "$tools"

[[ -x "$cli" ]] || fail "build debug simlease before smoke"

/bin/cp "$PWD/Tests/SmokeTests/lane-fake-xcrun.py" "$fake_xcrun"
/bin/cp "$PWD/Tests/SmokeTests/lane-fake-axe.py" "$fake_axe"
chmod 0755 "$fake_xcrun" "$fake_axe"

ln -s "$cli" "$shims/xcrun"
ln -s "$cli" "$shims/axe"

export SIMLEASE_CACHE_ROOT="$cache"
export SIMLEASE_XCRUN_PATH="$fake_xcrun"
export SIMLEASE_FAKE_ROOT="$smoke_root"
export PATH="$shims:$tools:/usr/bin:/bin"

json_value() {
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))'"$1"')' "$2"
}

acquire() {
  local project="$1"
  local output="$2"
  "$cli" lane acquire \
    --project "$project" \
    --device-type "iPhone 17 Pro" \
    --runtime latest \
    --json >"$output"
}

lane1="$smoke_root/lane1.json"
lane2="$smoke_root/lane2.json"
acquire "ProjectOne" "$lane1"
acquire "ProjectTwo" "$lane2"

udid1="$(json_value '["lane"]["udid"]' "$lane1")"
udid2="$(json_value '["lane"]["udid"]' "$lane2")"
descriptor1="$(json_value '["environment"]["SIMLEASE_LANE_FILE"]' "$lane1")"
descriptor2="$(json_value '["environment"]["SIMLEASE_LANE_FILE"]' "$lane2")"
derived1="$(json_value '["derivedDataPath"]' "$lane1")"
derived2="$(json_value '["derivedDataPath"]' "$lane2")"

[[ "$udid1" != "$udid2" ]] || fail "lanes share one simulator"
[[ "$derived1" != "$derived2" ]] || fail "lanes share DerivedData"

if acquire "ProjectThree" "$smoke_root/lane3.json" 2>/dev/null; then
  fail "third acquire exceeded capacity"
else
  [[ "$?" == 75 ]] || fail "third acquire did not return 75"
fi

SIMLEASE_FAKE_AXE_MODE=pair SIMLEASE_EXPECT_A="$udid1" SIMLEASE_EXPECT_B="$udid2" \
SIMLEASE_LANE_FILE="$descriptor1" "$shims/axe" tap --udid "$udid1" &
jobs+=($!)
SIMLEASE_FAKE_AXE_MODE=pair SIMLEASE_EXPECT_A="$udid1" SIMLEASE_EXPECT_B="$udid2" \
SIMLEASE_LANE_FILE="$descriptor2" "$shims/axe" tap --udid "$udid2" &
jobs+=($!)
wait "$jobs[1]" || fail "lane 1 overlap command failed"
wait "$jobs[2]" || fail "lane 2 overlap command failed"
jobs=()

SIMLEASE_FAKE_AXE_MODE=same SIMLEASE_LANE_FILE="$descriptor1" \
  "$shims/axe" tap --udid "$udid1" &
jobs+=($!)
SIMLEASE_FAKE_AXE_MODE=same SIMLEASE_LANE_FILE="$descriptor1" \
  "$shims/axe" tap --udid "$udid1" &
jobs+=($!)
wait "$jobs[1]" || fail "first same-lane command failed"
wait "$jobs[2]" || fail "second same-lane command failed"
jobs=()
[[ ! -f "$smoke_root/axe-overlap" ]] || fail "same-lane children overlapped"

SIMLEASE_LANE_FILE="$descriptor1" "$cli" lane release --json >/dev/null
SIMLEASE_LANE_FILE="$descriptor2" "$cli" lane release --json >/dev/null

reused="$smoke_root/reused.json"
acquire "ProjectOne" "$reused"
reused_udid="$(json_value '["lane"]["udid"]' "$reused")"
reused_descriptor="$(json_value '["environment"]["SIMLEASE_LANE_FILE"]' "$reused")"
[[ "$reused_udid" == "$udid1" ]] || fail "compatible idle simulator was not reused"

if "$cli" lane recover plan lane-1 --json >/dev/null 2>&1; then
  fail "fresh lane recovery plan unexpectedly succeeded"
else
  [[ "$?" == 76 ]] || fail "fresh recovery refusal did not return 76"
fi
SIMLEASE_LANE_FILE="$reused_descriptor" "$cli" lane release --json >/dev/null

dispose1="$smoke_root/dispose1.json"
"$cli" lane dispose plan "$reused_udid" --json >"$dispose1"
dispose_id1="$(json_value '["id"]' "$dispose1")"
"$fake_xcrun" simctl boot "$reused_udid"
if "$cli" lane dispose apply "$dispose_id1" --target "$reused_udid" --json >/dev/null 2>&1; then
  fail "changed disposal target unexpectedly deleted"
else
  [[ "$?" == 74 ]] || fail "changed disposal refusal did not return 74"
fi

"$fake_xcrun" simctl shutdown "$reused_udid"
dispose2="$smoke_root/dispose2.json"
"$cli" lane dispose plan "$reused_udid" --json >"$dispose2"
dispose_id2="$(json_value '["id"]' "$dispose2")"
"$cli" lane dispose apply "$dispose_id2" --target "$reused_udid" --json >/dev/null

grep -qx "delete $reused_udid" "$smoke_root/delete.log" \
  || fail "exact managed delete missing"
grep -q "FOREIGN" "$smoke_root/delete.log" \
  && fail "foreign simulator delete attempted"

print -- "lane-smoke: PASS"
