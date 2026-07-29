#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "SimLease: $1"
  exit "${2:-74}"
}

test_mode="${SIMLEASE_TEST_MODE:-0}"
if [[ "$test_mode" != 1 ]]; then
  for name in SIMLEASE_TEST_RELEASE_DIR SIMLEASE_TEST_UNAME \
    SIMLEASE_TEST_ARCH SIMLEASE_TEST_MACOS_VERSION \
    SIMLEASE_TEST_SKIP_SECURITY; do
    [[ -z "${(P)name:-}" ]] || fail "$name requires SIMLEASE_TEST_MODE=1" 64
  done
fi

kernel="${SIMLEASE_TEST_UNAME:-$(uname -s)}"
architecture="${SIMLEASE_TEST_ARCH:-$(uname -m)}"
macos_version="${SIMLEASE_TEST_MACOS_VERSION:-$(sw_vers -productVersion)}"
[[ "$kernel" == Darwin ]] || fail "macOS is required" 69
[[ "$architecture" == arm64 ]] || fail "Apple Silicon is required" 69
macos_major="${macos_version%%.*}"
[[ "$macos_major" == <-> && "$macos_major" -ge 15 ]] \
  || fail "macOS 15 or later is required" 69

current_version=""
if (( $# > 0 )); then
  [[ $# == 2 && "$1" == "--current-version" ]] \
    || fail "usage: install-release.sh [--current-version MAJOR.MINOR.PATCH]" 64
  current_version="$2"
  [[ "$current_version" == <->.<->.<-> ]] \
    || fail "invalid current version: $current_version" 64
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/simlease-release.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

release_dir="${SIMLEASE_TEST_RELEASE_DIR:-}"
if [[ -n "$release_dir" ]]; then
  [[ -r "$release_dir/VERSION" ]] || fail "fixture release has no VERSION"
  tag="$(<"$release_dir/VERSION")"
else
  metadata="$work_root/latest.json"
  /usr/bin/curl -fsSL \
    "https://api.github.com/repos/jdelaire/SimLease/releases/latest" \
    -o "$metadata" || fail "latest release is unavailable" 69
  tag="$(/usr/bin/plutil -extract tag_name raw -o - "$metadata" 2>/dev/null)" \
    || fail "latest release metadata is invalid" 69
fi

[[ "$tag" == v<->.<->.<-> ]] || fail "unsupported release tag: $tag" 69
version="${tag#v}"
version_value() {
  local value="$1"
  local major minor patch
  IFS=. read -r major minor patch <<< "$value"
  print -- $(( major * 100000000 + minor * 10000 + patch ))
}

if [[ -n "$current_version" ]] \
  && (( $(version_value "$version") <= $(version_value "$current_version") )); then
  print -- "SimLease $current_version is already current."
  exit 0
fi

asset="SimLease-$version-arm64.zip"
checksum="SimLease-$version-arm64.sha256"
if [[ -n "$release_dir" ]]; then
  /usr/bin/ditto "$release_dir/$asset" "$work_root/$asset"
  /usr/bin/ditto "$release_dir/$checksum" "$work_root/$checksum"
else
  base="https://github.com/jdelaire/SimLease/releases/download/$tag"
  /usr/bin/curl -fsSL "$base/$asset" -o "$work_root/$asset" \
    || fail "release archive download failed" 69
  /usr/bin/curl -fsSL "$base/$checksum" -o "$work_root/$checksum" \
    || fail "release checksum download failed" 69
fi

(cd "$work_root" && /usr/bin/shasum -a 256 -c "$checksum") \
  || fail "release checksum verification failed"

archive_entry=""
while IFS= read -r archive_entry; do
  [[ "$archive_entry" != /* && "$archive_entry" != *"../"* \
    && "$archive_entry" != ".." && "$archive_entry" != *"/.." ]] \
    || fail "release archive contains an unsafe path"
done < <(/usr/bin/unzip -Z1 "$work_root/$asset")

payload="$work_root/payload"
mkdir "$payload"
/usr/bin/ditto -x -k "$work_root/$asset" "$payload" \
  || fail "release archive extraction failed"

[[ -x "$payload/bin/simlease" ]] || fail "release CLI is missing"
[[ -x "$payload/SimLease.app/Contents/MacOS/SimLeaseMenuBar" ]] \
  || fail "release app is missing"
[[ -x "$payload/install.sh" && -x "$payload/install-release.sh" ]] \
  || fail "release installers are missing"
[[ -r "$payload/Resources/com.jdelaire.simlease.plist" ]] \
  || fail "release LaunchAgent is missing"

/usr/bin/file "$payload/bin/simlease" | /usr/bin/grep -q arm64 \
  || fail "release CLI is not arm64"
/usr/bin/file "$payload/SimLease.app/Contents/MacOS/SimLeaseMenuBar" \
  | /usr/bin/grep -q arm64 || fail "release app is not arm64"

if [[ "${SIMLEASE_TEST_SKIP_SECURITY:-0}" != 1 ]]; then
  /usr/bin/codesign --verify --strict "$payload/bin/simlease" \
    || fail "release CLI signature verification failed"
  /usr/bin/codesign --verify --deep --strict "$payload/SimLease.app" \
    || fail "release signature verification failed"
  /usr/sbin/spctl --assess --type execute "$payload/SimLease.app" \
    || fail "release Gatekeeper assessment failed"
fi

SIMLEASE_SOURCE_BINARY="$payload/bin/simlease" \
SIMLEASE_SOURCE_APP="$payload/SimLease.app" \
SIMLEASE_SOURCE_UPDATER="$payload/install-release.sh" \
SIMLEASE_SOURCE_AGENT="$payload/Resources/com.jdelaire.simlease.plist" \
"$payload/install.sh" || fail "installation failed"

print -- "SimLease $version installed."
