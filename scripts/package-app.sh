#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SimLease.app"

cd "$repository_root"
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --product simlease
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --product SimLeaseMenuBar
bin_dir="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
/usr/bin/install -m 0644 Resources/SimLease-Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_dir/SimLeaseMenuBar" "$app/Contents/MacOS/SimLeaseMenuBar"
/usr/bin/install -m 0755 "$bin_dir/simlease" "$app/Contents/Resources/bin/simlease"
/usr/bin/install -m 0644 NOTICE "$app/Contents/Resources/NOTICE"
/usr/bin/codesign --force --deep --sign - "$app"

print -- "SimLease app packaged: $app"
