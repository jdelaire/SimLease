#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

scripts/package-app.sh

app="$PWD/dist/SimLease.app"
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || fail "missing Info.plist"
/usr/bin/plutil -lint "$plist" >/dev/null || fail "invalid Info.plist"
[[ -x "$app/Contents/MacOS/SimLeaseMenuBar" ]] || fail "missing menu executable"
[[ -x "$app/Contents/Resources/bin/simlease" ]] || fail "missing bundled CLI"
/usr/bin/codesign --verify --deep --strict "$app" || fail "invalid app signature"

usage_file="$(mktemp)"
if "$app/Contents/Resources/bin/simlease" clean 2>"$usage_file"; then
  rm "$usage_file"
  fail "incomplete clean command unexpectedly succeeded"
fi
grep -qF 'status|measure|history|config|name|hold|clean' "$usage_file" \
  || fail "bundled CLI usage omits clean"
rm "$usage_file"

print -- "package-app: PASS"
