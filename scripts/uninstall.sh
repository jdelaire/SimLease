#!/bin/zsh
set -euo pipefail

simlease_user_home="${SIMLEASE_INSTALL_HOME:-${HOME:?}}"
simlease_lib_dir="$simlease_user_home/.local/lib/simlease"
simlease_shim_dir="$simlease_lib_dir/shims"
simlease_profile="$simlease_user_home/.zprofile"
installed_binary="$simlease_lib_dir/simlease"
installed_updater="$simlease_lib_dir/install-release.sh"
installed_app="$simlease_user_home/Applications/SimLease.app"
launch_agent="$simlease_user_home/Library/LaunchAgents/com.jdelaire.simlease.plist"

if [[ -z "${SIMLEASE_INSTALL_HOME+x}" ]]; then
  /bin/launchctl bootout \
    "gui/$(id -u)/com.jdelaire.simlease" >/dev/null 2>&1 || true
fi

if [[ -d "$installed_app" ]]; then
  rm -rf "$installed_app"
fi
if [[ -f "$launch_agent" ]]; then
  rm "$launch_agent"
fi

for command_name in simlease xcodebuild xcrun axe; do
  target="$simlease_shim_dir/$command_name"
  if [[ -L "$target" && "${target:A}" == "${installed_binary:A}" ]]; then
    rm "$target"
  fi
done
rmdir "$simlease_shim_dir" 2>/dev/null || true

if [[ -f "$installed_binary" ]]; then
  rm "$installed_binary"
fi
if [[ -f "$installed_updater" ]]; then
  rm "$installed_updater"
fi
rmdir "$simlease_lib_dir" 2>/dev/null || true

if [[ -f "$simlease_profile" ]]; then
  profile_temp="$(mktemp "$simlease_profile.simlease.XXXXXX")"
  awk '
    $0 == "# >>> SimLease PATH >>>" { skipping = 1; next }
    $0 == "# <<< SimLease PATH <<<" { skipping = 0; next }
    !skipping { print }
  ' "$simlease_profile" > "$profile_temp"
  mv "$profile_temp" "$simlease_profile"
fi

print -- "SimLease app, LaunchAgent, CLI, and PATH shims removed."
print -- "Simulator data and SimLease cache metadata were preserved."
