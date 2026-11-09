#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

SIMLEASE_TEST_MODE=1 \
SIMLEASE_VERSION=0.8.2 \
SIMLEASE_SIGN_IDENTITY=- \
scripts/package-release.sh

archive="$PWD/dist/SimLease-0.8.2-arm64.zip"
checksum="$PWD/dist/SimLease-0.8.2-arm64.sha256"
[[ -f "$archive" ]] || fail "release archive missing"
[[ -f "$checksum" ]] || fail "release checksum missing"
(cd "$PWD/dist" && /usr/bin/shasum -a 256 -c "${checksum:t}") \
  || fail "release checksum invalid"

entries="$(/usr/bin/unzip -Z1 "$archive")"
for expected in \
  SimLease.app/Contents/MacOS/SimLeaseMenuBar \
  SimLease.app/Contents/Resources/AppIcon.icns \
  SimLease.app/Contents/Resources/Assets.car \
  SimLease.app/Contents/Resources/bin/simlease \
  SimLease.app/Contents/Resources/install-release.sh \
  SimLease.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle \
  SimLease.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
  bin/simlease \
  install.sh \
  install-release.sh \
  Resources/com.jdelaire.simlease.plist; do
  print -r -- "$entries" | /usr/bin/grep -q "^$expected$" \
    || fail "archive missing $expected"
done

/usr/bin/file dist/release/bin/simlease | /usr/bin/grep -q arm64 \
  || fail "CLI is not arm64"
/usr/bin/file dist/release/SimLease.app/Contents/MacOS/SimLeaseMenuBar \
  | /usr/bin/grep -q arm64 || fail "app is not arm64"
/usr/bin/codesign --verify --deep --strict dist/release/SimLease.app \
  || fail "app signature is invalid"

print -r -- "$entries" | /usr/bin/grep -q "XPCServices" \
  && fail "archive contains unused Sparkle XPC services"
/usr/bin/otool -l dist/release/SimLease.app/Contents/MacOS/SimLeaseMenuBar \
  | /usr/bin/grep -q "@executable_path/../Frameworks" \
  || fail "app cannot load embedded Sparkle"

print -- "package-release: PASS"
