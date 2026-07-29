#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

smoke_root="$(mktemp -d)"
trap 'rm -rf "$smoke_root"' EXIT
fake_xcrun="$smoke_root/xcrun"
fake_ps="$smoke_root/ps"
cache="$smoke_root/cache"
state="$smoke_root/state"
mkdir -p "$state"
touch "$state/device-stale" "$state/device-booted" \
  "$state/device-recent" "$state/runtime-outdated"

cat >"$fake_xcrun" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail

state="$SIMLEASE_FAKE_ROOT/state"
log="$state/delete.log"

case "$*" in
  "simctl list devices -j")
    stale=""
    runtime=""
    [[ -f "$state/device-stale" ]] && stale='
      {
        "dataPath": "'"$SIMLEASE_CLEANUP_HOME"'/Library/Developer/CoreSimulator/Devices/DEVICE-STALE/data",
        "dataPathSize": 4000,
        "udid": "DEVICE-STALE",
        "lastUsedAt": "2000-01-01T00:00:00Z",
        "isAvailable": true,
        "state": "Shutdown",
        "name": "Stale iPhone"
      },'
    [[ -f "$state/runtime-outdated" ]] && runtime='
      "com.apple.CoreSimulator.SimRuntime.watchOS-26-4": []'
    cat <<JSON
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      $stale
      {
        "dataPath": "$SIMLEASE_CLEANUP_HOME/Library/Developer/CoreSimulator/Devices/DEVICE-BOOTED/data",
        "dataPathSize": 5000,
        "udid": "DEVICE-BOOTED",
        "lastUsedAt": "2000-01-01T00:00:00Z",
        "isAvailable": true,
        "state": "Booted",
        "name": "Booted iPhone"
      },
      {
        "dataPath": "$SIMLEASE_CLEANUP_HOME/Library/Developer/CoreSimulator/Devices/DEVICE-RECENT/data",
        "dataPathSize": 6000,
        "udid": "DEVICE-RECENT",
        "lastUsedAt": "2099-01-01T00:00:00Z",
        "isAvailable": true,
        "state": "Shutdown",
        "name": "Recent iPhone"
      }
    ]${runtime:+,$runtime}
  }
}
JSON
    ;;
  "simctl runtime list -j")
    if [[ -f "$state/runtime-outdated" ]]; then
      cat <<JSON
{
  "RUNTIME-OUTDATED": {
    "build": "23T239",
    "deletable": true,
    "identifier": "RUNTIME-OUTDATED",
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-4",
    "sizeBytes": 7000,
    "version": "26.4"
  }
}
JSON
    else
      print -- '{}'
    fi
    ;;
  "simctl runtime delete --outdated --dry-run")
    if [[ -f "$state/runtime-outdated" ]]; then
      print -- "Would delete RUNTIME-OUTDATED"
    else
      print -- "No matching images found to delete"
    fi
    ;;
  "simctl delete DEVICE-STALE")
    [[ -f "$state/device-stale" ]] || {
      print -u2 -- "Invalid device: DEVICE-STALE"
      exit 148
    }
    print -- "simctl delete DEVICE-STALE" >>"$log"
    rm "$state/device-stale"
    ;;
  "simctl runtime delete RUNTIME-OUTDATED")
    [[ -f "$state/runtime-outdated" ]] || exit 148
    print -- "simctl runtime delete RUNTIME-OUTDATED" >>"$log"
    rm "$state/runtime-outdated"
    ;;
  "simctl delete all"|"simctl delete unavailable"|\
  "simctl runtime delete --outdated"|"simctl runtime delete --unusable")
    print -u2 -- "unsafe broad deletion: $*"
    exit 99
    ;;
  *)
    print -u2 -- "unexpected xcrun command: $*"
    exit 98
    ;;
esac
SCRIPT

cat >"$fake_ps" <<'SCRIPT'
#!/bin/zsh
[[ "$*" == "-axo command=" ]] || exit 97
exit 0
SCRIPT
chmod 0755 "$fake_xcrun" "$fake_ps"

export SIMLEASE_CACHE_ROOT="$cache"
export SIMLEASE_XCRUN_PATH="$fake_xcrun"
export SIMLEASE_PS_PATH="$fake_ps"
export SIMLEASE_FAKE_ROOT="$smoke_root"
export SIMLEASE_CLEANUP_HOME="$smoke_root/home"
export SIMLEASE_CLEANUP_TMP="$smoke_root/tmp"
mkdir -p "$SIMLEASE_CLEANUP_HOME" "$SIMLEASE_CLEANUP_TMP"
simlease="$PWD/.build/debug/simlease"
plan_json="$smoke_root/plan.json"
result_json="$smoke_root/result.json"

"$simlease" clean plan --json >"$plan_json"
/usr/bin/python3 - "$plan_json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
plan = p["plan"]
assert [x["identifier"] for x in plan["devices"]] == ["DEVICE-STALE"]
assert [x["identifier"] for x in plan["runtimes"]] == ["RUNTIME-OUTDATED"]
reasons = {x["target"]["identifier"]: x["reason"] for x in p["protected"]}
assert reasons["DEVICE-BOOTED"] == "booted"
assert reasons["DEVICE-RECENT"] == "notOldEnough"
PY

plan_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan"]["id"])' "$plan_json")"
wrong_id="ZZZZZZ"
[[ "$plan_id" != "$wrong_id" ]] || wrong_id="YYYYYY"
if "$simlease" clean apply "$wrong_id" \
  --target DEVICE-STALE --json >/dev/null 2>&1; then
  fail "wrong plan ID unexpectedly applied"
else
  [[ "$?" == 73 ]] || fail "wrong plan ID did not return 73"
fi
[[ ! -f "$state/delete.log" ]] || fail "wrong plan ID deleted state"

"$simlease" clean apply "$plan_id" \
  --target DEVICE-STALE \
  --target RUNTIME-OUTDATED \
  --json >"$result_json"
expected="$smoke_root/expected.log"
print -- "simctl delete DEVICE-STALE" >"$expected"
print -- "simctl runtime delete RUNTIME-OUTDATED" >>"$expected"
cmp -s "$expected" "$state/delete.log" || fail "delete order changed"

if "$simlease" clean apply "$plan_id" \
  --target DEVICE-STALE --json >/dev/null 2>&1; then
  fail "plan applied twice"
else
  [[ "$?" == 73 ]] || fail "second apply did not return 73"
fi

/usr/bin/python3 - "$result_json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
groups = {"deleted": [], "skipped": [], "failed": []}
for item in r["items"]:
    groups[item["outcome"]].append(item["target"]["identifier"])
assert groups["deleted"] == ["DEVICE-STALE", "RUNTIME-OUTDATED"]
assert groups["skipped"] == []
assert groups["failed"] == []
PY

[[ ! -f "$state/device-stale" ]] || fail "stale device state remained"
[[ ! -f "$state/runtime-outdated" ]] || fail "outdated runtime state remained"
[[ -f "$state/device-booted" ]] || fail "booted device state changed"
[[ -f "$state/device-recent" ]] || fail "recent device state changed"

print -- "cleanup-smoke: PASS"
