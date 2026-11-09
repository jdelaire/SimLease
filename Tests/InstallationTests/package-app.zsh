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
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "missing icon"
[[ -f "$app/Contents/Resources/Assets.car" ]] || fail "missing asset catalog"
[[ "$(/usr/bin/plutil -extract CFBundleIconName raw "$plist")" == AppIcon ]] || fail "missing icon name"
[[ -x "$app/Contents/MacOS/SimLeaseMenuBar" ]] || fail "missing menu executable"
[[ -x "$app/Contents/Resources/bin/simlease" ]] || fail "missing bundled CLI"
[[ -x "$app/Contents/Resources/install-release.sh" ]] || fail "missing bundled release installer"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "missing Sparkle framework"
[[ "$(/usr/bin/plutil -extract SUFeedURL raw "$plist")" == https://github.com/jdelaire/SimLease/releases/latest/download/appcast.xml ]] \
  || fail "wrong Sparkle feed"
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
