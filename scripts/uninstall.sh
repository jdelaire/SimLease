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

installed_executable="$installed_app/Contents/MacOS/SimLeaseMenuBar"

if [[ -z "${SIMLEASE_INSTALL_HOME+x}" ]]; then
  /bin/launchctl bootout \
    "gui/$(id -u)/com.jdelaire.simlease" >/dev/null 2>&1 || true
  /bin/launchctl remove com.jdelaire.simlease-sparkle-updater >/dev/null 2>&1 || true
  /bin/launchctl remove com.jdelaire.simlease-sparkle-progress >/dev/null 2>&1 || true
  terminated_pids=()
  for candidate_pid in $(/usr/bin/pgrep -x SimLeaseMenuBar 2>/dev/null || true); do
    executable="$(/bin/ps -p "$candidate_pid" -o comm= 2>/dev/null)" || continue
    while [[ "$executable" == ' '* ]]; do
      executable="${executable# }"
    done
    [[ "$executable" == "$installed_executable" ]] || continue
    kill -TERM "$candidate_pid" 2>/dev/null && terminated_pids+=("$candidate_pid")
  done
  for attempt in {1..50}; do
    running=0
    for candidate_pid in "${terminated_pids[@]}"; do
      kill -0 "$candidate_pid" 2>/dev/null && running=1
    done
    [[ "$running" == 0 ]] && break
    sleep 0.1
  done
fi

for command_name in simlease xcodebuild xcrun axe agent-device; do
  target="$simlease_shim_dir/$command_name"
  if [[ -L "$target" && "${target:A}" == "${installed_binary:A}" ]]; then
    rm "$target"
  fi
done
rmdir "$simlease_shim_dir" 2>/dev/null || true

for managed_file in "$installed_binary" "$installed_updater"; do
  if [[ -L "$managed_file" || -f "$managed_file" ]]; then
    rm "$managed_file"
  fi
done
rmdir "$simlease_lib_dir" 2>/dev/null || true

if [[ -d "$installed_app" ]]; then
  rm -rf "$installed_app"
fi
if [[ -f "$launch_agent" ]]; then
  rm "$launch_agent"
fi

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
