#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "SimLease: $1"
  exit 74
}

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
version="${SIMLEASE_VERSION:-}"
identity="${SIMLEASE_SIGN_IDENTITY:-}"
[[ "$version" == <->.<->.<-> ]] || fail "SIMLEASE_VERSION must be MAJOR.MINOR.PATCH"
plist_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
  "$repository_root/Resources/SimLease-Info.plist")"
[[ "$version" == "$plist_version" ]] \
  || fail "release version does not match SimLease-Info.plist"
[[ -n "$identity" ]] || fail "SIMLEASE_SIGN_IDENTITY is required"
[[ "$identity" != - || "${SIMLEASE_TEST_MODE:-0}" == 1 ]] \
  || fail "ad-hoc signing is allowed only in test mode"

cd "$repository_root"
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --arch arm64 --product simlease
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --arch arm64 --product SimLeaseMenuBar
bin_dir="$(swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --arch arm64 --show-bin-path)"

release_root="$repository_root/dist/release"
app="$release_root/SimLease.app"
rm -rf "$release_root"
mkdir -p \
  "$app/Contents/MacOS" \
  "$app/Contents/Resources/bin" \
  "$release_root/bin" \
  "$release_root/Resources"

/usr/bin/install -m 0644 Resources/SimLease-Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_dir/SimLeaseMenuBar" \
  "$app/Contents/MacOS/SimLeaseMenuBar"
/usr/bin/install -m 0755 "$bin_dir/simlease" \
  "$app/Contents/Resources/bin/simlease"
/usr/bin/install -m 0755 "$bin_dir/simlease" \
  "$release_root/bin/simlease"
/usr/bin/install -m 0644 NOTICE "$app/Contents/Resources/NOTICE"
/usr/bin/install -m 0755 scripts/install.sh "$release_root/install.sh"
/usr/bin/install -m 0755 scripts/install-release.sh \
  "$release_root/install-release.sh"
/usr/bin/install -m 0644 Resources/com.jdelaire.simlease.plist \
  "$release_root/Resources/com.jdelaire.simlease.plist"

sign_options=(--force --sign "$identity")
if [[ "$identity" != - ]]; then
  sign_options+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_options[@]}" "$release_root/bin/simlease"
/usr/bin/codesign "${sign_options[@]}" \
  "$app/Contents/Resources/bin/simlease"
/usr/bin/codesign "${sign_options[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

/usr/bin/file "$release_root/bin/simlease" | /usr/bin/grep -q arm64 \
  || fail "packaged CLI is not arm64"
/usr/bin/file "$app/Contents/MacOS/SimLeaseMenuBar" | /usr/bin/grep -q arm64 \
  || fail "packaged app is not arm64"

archive="$repository_root/dist/SimLease-$version-arm64.zip"
checksum="$repository_root/dist/SimLease-$version-arm64.sha256"
rm -f "$archive" "$checksum"
(cd "$release_root" && /usr/bin/zip -qry "$archive" .)
(cd "${archive:h}" && /usr/bin/shasum -a 256 "${archive:t}" > "${checksum:t}")

print -- "SimLease release packaged:"
print -- "  $archive"
print -- "  $checksum"
