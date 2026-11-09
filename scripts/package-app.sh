#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
app="$repository_root/dist/SimLease.app"

cd "$repository_root"
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --product simlease
swift build -c release -j "${SIMLEASE_BUILD_JOBS:-1}" --product SimLeaseMenuBar
bin_dir="$(swift build -c release --show-bin-path)"

scripts/assemble-app.sh "$app" "$bin_dir"
/usr/bin/codesign --force --deep --sign - "$app"

print -- "SimLease app packaged: $app"
