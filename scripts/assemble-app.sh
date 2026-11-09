#!/bin/zsh
set -euo pipefail

app="$1"
bin_dir="$2"
repository_root="${0:A:h:h}"
cd "$repository_root"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Frameworks"
/usr/bin/install -m 0644 Resources/SimLease-Info.plist "$app/Contents/Info.plist"
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" \
  --app-icon AppIcon --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist "$app/Contents/Resources/icon-partial.plist" >/dev/null
/usr/bin/plutil -extract CFBundleIconName raw "$app/Contents/Resources/icon-partial.plist" | /usr/bin/grep -qx AppIcon
/bin/rm "$app/Contents/Resources/icon-partial.plist"
/usr/bin/install -m 0755 "$bin_dir/SimLeaseMenuBar" "$app/Contents/MacOS/SimLeaseMenuBar"
/usr/bin/install -m 0755 "$bin_dir/simlease" "$app/Contents/Resources/bin/simlease"
/usr/bin/install -m 0755 scripts/install-release.sh "$app/Contents/Resources/install-release.sh"
/usr/bin/install -m 0644 NOTICE "$app/Contents/Resources/NOTICE"

framework="$app/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$bin_dir/Sparkle.framework" "$framework"
/bin/rm -rf "$framework/XPCServices" "$framework/Versions/B/XPCServices"
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks \
  "$app/Contents/MacOS/SimLeaseMenuBar"

app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
[[ "$("$app/Contents/Resources/bin/simlease" --version)" == "simlease $app_version" ]] \
  || { print -u2 -- "SimLease: bundled CLI version does not match Info.plist $app_version"; exit 74; }
