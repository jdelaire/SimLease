#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
test_home="$test_root/home"
mkdir -p "$test_home/Applications" "$test_home/Library/LaunchAgents"
bin_dir="$(swift build -c release --show-bin-path)"
print -r -- 'keep app' > "$test_home/Applications/Keep.txt"
print -r -- 'keep agent' > "$test_home/Library/LaunchAgents/keep.plist"
print -r -- 'keep profile' > "$test_home/.zprofile"

SIMLEASE_INSTALL_HOME="$test_home" \
SIMLEASE_SOURCE_BINARY="$bin_dir/simlease" \
SIMLEASE_SOURCE_APP="$PWD/dist/SimLease.app" \
scripts/install.sh

app="$test_home/Applications/SimLease.app"
agent="$test_home/Library/LaunchAgents/com.jdelaire.simlease.plist"
[[ -x "$app/Contents/MacOS/SimLeaseMenuBar" ]] || fail "app not installed"
[[ -f "$agent" ]] || fail "LaunchAgent not installed"
[[ -x "$test_home/.local/lib/simlease/install-release.sh" ]] \
  || fail "release installer not installed"
grep -q '^keep profile$' "$test_home/.zprofile" \
  || fail "unrelated profile content changed"
program="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent")"
[[ "$program" == "$app/Contents/MacOS/SimLeaseMenuBar" ]] \
  || fail "LaunchAgent executable path is wrong"
[[ "$(/usr/bin/plutil -extract ProgramArguments raw "$agent")" == 1 ]] \
  || fail "LaunchAgent has unexpected arguments"

SIMLEASE_INSTALL_HOME="$test_home" \
SIMLEASE_SOURCE_BINARY="$bin_dir/simlease" \
SIMLEASE_SOURCE_APP="$PWD/dist/SimLease.app" \
scripts/install.sh

[[ "$(grep -c '^# >>> SimLease PATH >>>$' "$test_home/.zprofile")" == 1 ]] \
  || fail "PATH block duplicated"
[[ "$(find "$test_home/Library/LaunchAgents" -name 'com.jdelaire.simlease.plist' | wc -l | tr -d ' ')" == 1 ]] \
  || fail "LaunchAgent duplicated"

SIMLEASE_INSTALL_HOME="$test_home" scripts/uninstall.sh

[[ ! -e "$app" ]] || fail "app remains after uninstall"
[[ ! -e "$agent" ]] || fail "LaunchAgent remains after uninstall"
[[ ! -e "$test_home/.local/lib/simlease/install-release.sh" ]] \
  || fail "release installer remains after uninstall"
[[ -f "$test_home/Applications/Keep.txt" ]] || fail "unrelated app file removed"
[[ -f "$test_home/Library/LaunchAgents/keep.plist" ]] || fail "unrelated agent removed"

print -- "install-app: PASS"
