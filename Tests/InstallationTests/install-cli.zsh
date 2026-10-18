#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_symlink_target() {
  [[ -L "$1" ]] || fail "missing symlink: $1"
  [[ "${1:A}" == "${2:A}" ]] || fail "wrong target: $1"
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
test_home="$test_root/home"
mkdir -p "$test_home/.local/bin"
print -r -- 'export KEEP_ME=1' > "$test_home/.zprofile"
print -r -- 'unrelated' > "$test_home/.local/bin/keep-tool"
custom_axe="$test_root/custom-axe"
source_app="$test_root/SimLease.app"
mkdir -p "$source_app/Contents/MacOS"
bin_dir="${SIMLEASE_TEST_BIN_DIR:-$(swift build -c release --show-bin-path)}"
print -r -- '#!/bin/sh' > "$source_app/Contents/MacOS/SimLeaseMenuBar"
chmod +x "$source_app/Contents/MacOS/SimLeaseMenuBar"
/usr/bin/install -m 0644 Resources/SimLease-Info.plist \
  "$source_app/Contents/Info.plist"
{
  print -- '#!/bin/sh'
  print -- 'echo custom-d45fd82'
} > "$custom_axe"
chmod +x "$custom_axe"
ln -s "$custom_axe" "$test_home/.local/bin/axe"

SIMLEASE_INSTALL_HOME="$test_home" \
SIMLEASE_SOURCE_BINARY="$bin_dir/simlease" \
SIMLEASE_SOURCE_APP="$source_app" \
scripts/install.sh

installed="$test_home/.local/lib/simlease/simlease"
shim_directory="$test_home/.local/lib/simlease/shims"
assert_file "$installed"
for command_name in simlease xcodebuild xcrun axe agent-device; do
  assert_symlink_target "$shim_directory/$command_name" "$installed"
done
assert_symlink_target "$test_home/.local/bin/axe" "$custom_axe"
resolved_axe="$(
  PATH="$shim_directory:$test_home/.local/bin:/usr/bin:/bin" \
  "$shim_directory/axe" --version
)"
[[ "$resolved_axe" == custom-d45fd82 ]] || fail "custom AXe not delegated"

SIMLEASE_INSTALL_HOME="$test_home" \
SIMLEASE_SOURCE_BINARY="$bin_dir/simlease" \
SIMLEASE_SOURCE_APP="$source_app" \
scripts/install.sh

block_count="$(grep -c '^# >>> SimLease PATH >>>$' "$test_home/.zprofile")"
[[ "$block_count" == 1 ]] || fail "PATH block duplicated"
grep -q '^export KEEP_ME=1$' "$test_home/.zprofile" || fail "profile content changed"

SIMLEASE_INSTALL_HOME="$test_home" scripts/uninstall.sh

[[ ! -e "$installed" ]] || fail "installed binary remains"
for command_name in simlease xcodebuild xcrun axe agent-device; do
  [[ ! -e "$shim_directory/$command_name" ]] || fail "shim remains: $command_name"
done
assert_file "$test_home/.local/bin/keep-tool"
assert_symlink_target "$test_home/.local/bin/axe" "$custom_axe"
[[ "$(cat "$test_home/.zprofile")" == 'export KEEP_ME=1' ]] \
  || fail "uninstaller changed unrelated profile content"

conflict_home="$test_root/conflict-home"
conflict_shims="$conflict_home/.local/lib/simlease/shims"
mkdir -p "$conflict_shims"
print -r -- 'do not overwrite' > "$conflict_shims/xcrun"
if SIMLEASE_INSTALL_HOME="$conflict_home" \
   SIMLEASE_SOURCE_BINARY="$bin_dir/simlease" \
   SIMLEASE_SOURCE_APP="$source_app" \
   scripts/install.sh; then
  fail "installer accepted conflicting executable"
fi
[[ "$(cat "$conflict_shims/xcrun")" == 'do not overwrite' ]] \
  || fail "installer overwrote conflict"

print -- "install-cli: PASS"
