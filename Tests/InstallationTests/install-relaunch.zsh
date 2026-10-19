#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

test_root="$(mktemp -d)"
old_pid=""
trap '
  [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
  rm -rf "$test_root"
' EXIT

test_home="$test_root/home"
source_app="$test_root/SimLease.app"
fake_launchctl="$test_root/launchctl"
launchctl_log="$test_root/launchctl.log"
mkdir -p "$source_app/Contents/MacOS"
/bin/cp /bin/sleep "$source_app/Contents/MacOS/SimLeaseMenuBar"
/usr/bin/install -m 0644 Resources/SimLease-Info.plist \
  "$source_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$source_app"

{
  print -- '#!/bin/zsh'
  print -- 'print -r -- "$*" >> "$SIMLEASE_LAUNCHCTL_LOG"'
  print -- 'exit 0'
} > "$fake_launchctl"
chmod +x "$fake_launchctl"

bin_dir="$(swift build -c release --show-bin-path)"
install_environment=(
  "SIMLEASE_INSTALL_HOME=$test_home"
  "SIMLEASE_SOURCE_BINARY=$bin_dir/simlease"
  "SIMLEASE_SOURCE_APP=$source_app"
  "SIMLEASE_MANAGE_LAUNCH_AGENT=1"
  "SIMLEASE_LAUNCHCTL_COMMAND=$fake_launchctl"
  "SIMLEASE_LAUNCHCTL_LOG=$launchctl_log"
)

env "${install_environment[@]}" scripts/install.sh >/dev/null

installed_executable="$test_home/Applications/SimLease.app/Contents/MacOS/SimLeaseMenuBar"
"$installed_executable" 60 &
old_pid=$!
kill -0 "$old_pid" || fail "fixture app did not start"

env "${install_environment[@]}" scripts/install.sh >/dev/null

if kill -0 "$old_pid" 2>/dev/null; then
  fail "old app process survived update"
fi
set +e
wait "$old_pid"
fixture_exit=$?
set -e
old_pid=""
[[ "$fixture_exit" == 143 ]] \
  || fail "fixture app did not exit from installer SIGTERM: $fixture_exit"

grep -q "^bootout gui/$(id -u)/com.jdelaire.simlease$" "$launchctl_log" \
  || fail "loaded LaunchAgent was not booted out"
grep -q "^bootstrap gui/$(id -u) $test_home/Library/LaunchAgents/com.jdelaire.simlease.plist$" \
  "$launchctl_log" || fail "updated LaunchAgent was not bootstrapped"

print -- "install-relaunch: PASS"
