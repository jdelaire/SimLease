#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 -- "SimLease: $1"
  exit "${2:-74}"
}

script_dir="${0:A:h}"
repository_root="${script_dir:h}"
simlease_user_home="${SIMLEASE_INSTALL_HOME:-${HOME:?}}"
lib_parent="$simlease_user_home/.local/lib"
simlease_lib_dir="$lib_parent/simlease"
simlease_shim_dir="$simlease_lib_dir/shims"
simlease_profile="$simlease_user_home/.zprofile"
source_binary="${SIMLEASE_SOURCE_BINARY:-$repository_root/.build/release/simlease}"
source_app="${SIMLEASE_SOURCE_APP:-$repository_root/dist/SimLease.app}"
source_updater="${SIMLEASE_SOURCE_UPDATER:-$repository_root/scripts/install-release.sh}"
source_agent="${SIMLEASE_SOURCE_AGENT:-$repository_root/Resources/com.jdelaire.simlease.plist}"
installed_binary="$simlease_lib_dir/simlease"
installed_app="$simlease_user_home/Applications/SimLease.app"
installed_executable="$installed_app/Contents/MacOS/SimLeaseMenuBar"
launch_agent_dir="$simlease_user_home/Library/LaunchAgents"
launch_agent="$launch_agent_dir/com.jdelaire.simlease.plist"
launchctl_command="${SIMLEASE_LAUNCHCTL_COMMAND:-/bin/launchctl}"
service="gui/$(id -u)/com.jdelaire.simlease"
service_was_loaded=0
manage_launch_agent=0
if [[ "${SIMLEASE_SKIP_LAUNCH_AGENT:-0}" != 1 \
      && (
        -z "${SIMLEASE_INSTALL_HOME+x}" \
        || "${SIMLEASE_MANAGE_LAUNCH_AGENT:-0}" == 1
      ) ]]; then
  manage_launch_agent=1
fi

[[ -x "$source_binary" ]] \
  || fail "source binary is missing or not executable: $source_binary" 66
[[ -x "$source_app/Contents/MacOS/SimLeaseMenuBar" ]] \
  || fail "source app is missing or invalid: $source_app" 66
[[ -r "$source_updater" ]] \
  || fail "release installer is missing: $source_updater" 66
if [[ "$manage_launch_agent" == 1 && ! -x "$launchctl_command" ]]; then
  fail "launchctl command is missing or not executable: $launchctl_command" 66
fi
/usr/bin/plutil -lint "$source_app/Contents/Info.plist" >/dev/null \
  || fail "source app Info.plist is invalid"
/usr/bin/plutil -lint "$source_agent" >/dev/null \
  || fail "LaunchAgent template is invalid"

mkdir -p \
  "$lib_parent" \
  "$simlease_user_home/Applications" \
  "$launch_agent_dir"

for command_name in simlease xcodebuild xcrun axe; do
  target="$simlease_shim_dir/$command_name"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ ! -L "$target" || "${target:A}" != "${installed_binary:A}" ]]; then
      fail "refusing to overwrite unrelated path: $target" 73
    fi
  fi
done

work_root="$(mktemp -d "$simlease_user_home/.simlease-install.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT
stage_lib="$work_root/stage-lib"
stage_app="$work_root/SimLease.app"
stage_agent="$work_root/com.jdelaire.simlease.plist"
backup_root="$work_root/backup"
mkdir -p "$stage_lib/shims" "$backup_root"

/usr/bin/install -m 0755 "$source_binary" "$stage_lib/simlease"
/usr/bin/install -m 0755 "$source_updater" "$stage_lib/install-release.sh"
for command_name in simlease xcodebuild xcrun axe; do
  ln -s "$installed_binary" "$stage_lib/shims/$command_name"
done
/usr/bin/ditto "$source_app" "$stage_app"
/usr/bin/install -m 0644 "$source_agent" "$stage_agent"
/usr/bin/plutil -insert ProgramArguments.0 \
  -string "$installed_app/Contents/MacOS/SimLeaseMenuBar" \
  "$stage_agent"

[[ -x "$stage_lib/simlease" && -x "$stage_lib/install-release.sh" ]] \
  || fail "staged command files are invalid"
[[ -x "$stage_app/Contents/MacOS/SimLeaseMenuBar" ]] \
  || fail "staged app is invalid"
/usr/bin/plutil -lint "$stage_agent" >/dev/null \
  || fail "staged LaunchAgent is invalid"

stop_installed_app() {
  if "$launchctl_command" print "$service" >/dev/null 2>&1; then
    service_was_loaded=1
    "$launchctl_command" bootout "$service" || return 1
  fi

  local candidate_pid executable
  local -a terminated_pids
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" && "$candidate_pid" != "$$" ]] || continue
    executable="$(/bin/ps -p "$candidate_pid" -o comm= 2>/dev/null)" \
      || continue
    while [[ "$executable" == ' '* ]]; do
      executable="${executable# }"
    done
    [[ "$executable" == "${installed_executable:t}" ]] || continue
    kill -TERM "$candidate_pid" || return 1
    terminated_pids+=("$candidate_pid")
  done < <(
    /usr/bin/pgrep -f "$installed_executable" 2>/dev/null || true
  )

  local attempt candidate_running
  for attempt in {1..50}; do
    candidate_running=0
    for candidate_pid in "${terminated_pids[@]}"; do
      if kill -0 "$candidate_pid" 2>/dev/null; then
        candidate_running=1
        break
      fi
    done
    [[ "$candidate_running" == 0 ]] && return 0
    sleep 0.1
  done
  return 1
}

if [[ "$manage_launch_agent" == 1 ]] && ! stop_installed_app; then
  if [[ "$service_was_loaded" == 1 && -f "$launch_agent" ]]; then
    "$launchctl_command" bootstrap "gui/$(id -u)" "$launch_agent" \
      >/dev/null 2>&1 || true
  fi
  fail "unable to stop the running SimLease app before update"
fi

[[ -e "$simlease_lib_dir" ]] && mv "$simlease_lib_dir" "$backup_root/lib"
[[ -e "$installed_app" ]] && mv "$installed_app" "$backup_root/app"
[[ -e "$launch_agent" ]] && mv "$launch_agent" "$backup_root/agent"
[[ -e "$simlease_profile" ]] \
  && /usr/bin/ditto "$simlease_profile" "$backup_root/profile"

rollback() {
  rm -rf "$simlease_lib_dir" "$installed_app"
  rm -f "$launch_agent"
  [[ -e "$backup_root/lib" ]] && mv "$backup_root/lib" "$simlease_lib_dir"
  [[ -e "$backup_root/app" ]] && mv "$backup_root/app" "$installed_app"
  [[ -e "$backup_root/agent" ]] && mv "$backup_root/agent" "$launch_agent"
  if [[ -e "$backup_root/profile" ]]; then
    /usr/bin/ditto "$backup_root/profile" "$simlease_profile"
  else
    rm -f "$simlease_profile"
  fi
  if [[ "$manage_launch_agent" == 1 \
        && "$service_was_loaded" == 1 \
        && -f "$launch_agent" ]]; then
    "$launchctl_command" bootstrap "gui/$(id -u)" "$launch_agent" \
      >/dev/null 2>&1 || true
  fi
}

activate() {
  mv "$stage_lib" "$simlease_lib_dir" || return 1
  mv "$stage_app" "$installed_app" || return 1
  mv "$stage_agent" "$launch_agent" || return 1

  touch "$simlease_profile" || return 1
  profile_temp="$(mktemp "$simlease_profile.simlease.XXXXXX")" || return 1
  awk '
    $0 == "# >>> SimLease PATH >>>" { skipping = 1; next }
    $0 == "# <<< SimLease PATH <<<" { skipping = 0; next }
    !skipping { print }
  ' "$simlease_profile" > "$profile_temp" || return 1
  mv "$profile_temp" "$simlease_profile" || return 1
  {
    print -- '# >>> SimLease PATH >>>'
    print -- 'export PATH="$HOME/.local/lib/simlease/shims:$PATH"'
    print -- '# <<< SimLease PATH <<<'
  } >> "$simlease_profile" || return 1

  if [[ "$manage_launch_agent" == 1 ]]; then
    "$launchctl_command" bootstrap "gui/$(id -u)" "$launch_agent" || return 1
  fi
}

if ! activate; then
  rollback
  fail "installation failed; previous version restored"
fi

print -- "SimLease installed:"
print -- "  app: $installed_app"
print -- "  CLI: $installed_binary"
print -- "  shims: $simlease_shim_dir"
print -- "Restart login shells and Codex desktop to inherit PATH."
