#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
release_dir="$test_root/release"
test_home="$test_root/home"
mkdir -p "$release_dir" "$test_home"

SIMLEASE_TEST_MODE=1 \
SIMLEASE_VERSION=0.8.1 \
SIMLEASE_SIGN_IDENTITY=- \
scripts/package-release.sh >/dev/null

print -- "v0.8.1" > "$release_dir/VERSION"
/usr/bin/ditto dist/SimLease-0.8.1-arm64.zip \
  "$release_dir/SimLease-0.8.1-arm64.zip"
/usr/bin/ditto dist/SimLease-0.8.1-arm64.sha256 \
  "$release_dir/SimLease-0.8.1-arm64.sha256"

output="$(
  SIMLEASE_TEST_MODE=1 \
  SIMLEASE_TEST_RELEASE_DIR="$release_dir" \
  SIMLEASE_TEST_SKIP_SECURITY=1 \
  SIMLEASE_INSTALL_HOME="$test_home" \
  scripts/install-release.sh
)"
print -r -- "$output" | /usr/bin/grep -q 'SimLease 0.8.1 installed.' \
  || fail "release install did not complete"
[[ -x "$test_home/.local/lib/simlease/simlease" ]] \
  || fail "release CLI was not installed"
[[ -x "$test_home/.local/lib/simlease/install-release.sh" ]] \
  || fail "release updater was not installed"
[[ "$("$test_home/.local/lib/simlease/simlease" --version)" \
  == "simlease 0.8.1" ]] || fail "installed CLI version is wrong"

output="$(
  SIMLEASE_TEST_MODE=1 \
  SIMLEASE_TEST_RELEASE_DIR="$release_dir" \
  SIMLEASE_TEST_SKIP_SECURITY=1 \
  SIMLEASE_INSTALL_HOME="$test_home" \
  scripts/install-release.sh --current-version 0.8.1
)"
print -r -- "$output" | /usr/bin/grep -q 'already current' \
  || fail "same-version update was not a no-op"

bad_release="$test_root/bad-release"
/usr/bin/ditto "$release_dir" "$bad_release"
print -- "invalid checksum" > "$bad_release/SimLease-0.8.1-arm64.sha256"
set +e
SIMLEASE_TEST_MODE=1 \
SIMLEASE_TEST_RELEASE_DIR="$bad_release" \
SIMLEASE_TEST_SKIP_SECURITY=1 \
SIMLEASE_INSTALL_HOME="$test_home" \
scripts/install-release.sh >/dev/null 2>&1
exit_code=$?
set -e
[[ "$exit_code" == 74 ]] || fail "checksum mismatch did not return 74"

set +e
SIMLEASE_TEST_MODE=1 \
SIMLEASE_TEST_RELEASE_DIR="$release_dir" \
SIMLEASE_TEST_UNAME=Linux \
SIMLEASE_TEST_SKIP_SECURITY=1 \
SIMLEASE_INSTALL_HOME="$test_home" \
scripts/install-release.sh >/dev/null 2>&1
exit_code=$?
set -e
[[ "$exit_code" == 69 ]] || fail "unsupported platform did not return 69"

print -- "install-release: PASS"
