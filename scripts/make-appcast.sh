#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "SimLease: $1"
  exit 74
}

repository_root="${0:A:h:h}"
version="${SIMLEASE_VERSION:-}"
[[ "$version" == <->.<->.<-> ]] || fail "SIMLEASE_VERSION must be MAJOR.MINOR.PATCH"
app="$repository_root/dist/release/SimLease.app"
[[ -d "$app" ]] || fail "packaged app is missing: $app"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]] \
  || fail "packaged app version does not match $version"
/usr/bin/xcrun stapler validate "$app" >/dev/null || fail "packaged app is not notarized and stapled"
generate_appcast="$repository_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$generate_appcast" ]] || fail "Sparkle tools are missing; run swift package resolve"

feed_root="$(mktemp -d "${TMPDIR:-/tmp}/simlease-appcast.XXXXXX")"
trap 'rm -rf "$feed_root"' EXIT
archive_name="SimLease-$version-arm64-app.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$feed_root/$archive_name"
"$generate_appcast" \
  --download-url-prefix "https://github.com/jdelaire/SimLease/releases/download/v$version/" \
  --link "https://github.com/jdelaire/SimLease/releases/tag/v$version" \
  --maximum-versions 1 \
  "$feed_root"
/usr/bin/grep -q "sparkle:edSignature" "$feed_root/appcast.xml" || fail "appcast has no EdDSA signature"
/usr/bin/ditto "$feed_root/$archive_name" "$repository_root/dist/$archive_name"
/usr/bin/ditto "$feed_root/appcast.xml" "$repository_root/dist/appcast.xml"

print -- "Sparkle feed ready:"
print -- "  $repository_root/dist/$archive_name"
print -- "  $repository_root/dist/appcast.xml"
