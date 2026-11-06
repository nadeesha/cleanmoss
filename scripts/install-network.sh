#!/bin/bash
# Release template: package-network.sh embeds the immutable URL and checksum.
# Keep execution inside main so a truncated streamed script cannot start installation.
main() {
  set -euo pipefail
  local archive_url=@@ARCHIVE_URL@@
  local expected_sha256=@@SHA256@@
  local verify_only=false
  local install_args=()
  local argument
  for argument in "$@"; do
    case "$argument" in
      --verify-only) verify_only=true ;;
      --no-launch|--no-login|--keep-system-shortcut) install_args+=("$argument") ;;
      --help|-h)
        echo 'Usage: curl -fsSL INSTALL_URL | bash -s -- [OPTIONS]'
        echo 'Options: --verify-only --no-launch --no-login --keep-system-shortcut'
        return 0 ;;
      *) echo "Unknown installer option: $argument" >&2; return 2 ;;
    esac
  done
  if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Cleanmoss requires macOS 14 or later.' >&2; return 1
  fi
  local os_version
  os_version="$(sw_vers -productVersion)"
  if [[ ! "${os_version%%.*}" =~ ^[0-9]+$ ]] || (( ${os_version%%.*} < 14 )); then
    echo "Cleanmoss requires macOS 14 or later; this Mac runs $os_version." >&2; return 1
  fi
  case "$(uname -m)" in
    arm64|x86_64) ;;
    *) echo 'This release supports Apple Silicon and Intel Macs.' >&2; return 1 ;;
  esac
  if [[ "$(id -u)" == 0 ]]; then
    echo 'Run this installer as your Mac user, without sudo.' >&2; return 1
  fi
  local temporary
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/cleanmoss-install.XXXXXX")"
  cleanmoss_download_directory="$temporary"
  trap 'rm -rf "$cleanmoss_download_directory"' EXIT
  echo 'Downloading the Cleanmoss release…'
  curl --fail --show-error --silent --location --proto '=http,https' --proto-redir '=http,https' \
    --connect-timeout 15 --max-time 300 --retry 2 "$archive_url" -o "$temporary/release.zip"
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$temporary/release.zip")"
  actual_sha256="${actual_sha256%% *}"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo 'Release checksum failed. Nothing was installed; run the installer again.' >&2; return 1
  fi
  unzip -Z1 "$temporary/release.zip" > "$temporary/members.txt"
  local member
  while IFS= read -r member; do
    case "$member" in
      Cleanmoss.app/*|cleanmoss) ;;
      *) echo "Unexpected archive member: $member" >&2; return 1 ;;
    esac
    case "/$member/" in
      */../*|*\\*) echo 'Unsafe path in release archive.' >&2; return 1 ;;
    esac
  done < "$temporary/members.txt"
  ditto -x -k "$temporary/release.zip" "$temporary/payload"
  local app="$temporary/payload/Cleanmoss.app"
  local cli="$temporary/payload/cleanmoss"
  [[ -x "$app/Contents/MacOS/Cleanmoss" && -x "$cli" ]] || { echo 'Incomplete release archive.' >&2; return 1; }
  codesign --verify --deep --strict "$app"
  codesign --verify --strict "$cli"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.cleanmoss.mac ]] || {
    echo 'Unexpected application identity.' >&2; return 1
  }
  if [[ "$verify_only" == true ]]; then
    echo 'Verified universal Cleanmoss release. No app or settings were installed.'
    return 0
  fi
  if (( ${#install_args[@]} > 0 )); then
    "$cli" install "${install_args[@]}" </dev/null
  else
    "$cli" install </dev/null
  fi
  echo 'Cleanmoss is ready. Configure it with ~/.local/bin/cleanmoss config show'
}
# Bash waits for this complete block, including its closing brace, before invoking main.
{
  main "$@"
}
