#!/usr/bin/env bash
# Builds, signs, installs and removes HA Satellite.app (see macos/README.md).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
package="$here/HASatellite"
bundle_id="io.iostud.ha-satellite"
app_name="HA Satellite.app"
build_app="$package/.build/$app_name"
install_dir="$HOME/Applications"
installed_app="$install_dir/$app_name"
support="${HA_SATELLITE_HOME:-$HOME/Library/Application Support/ha-satellite}"
logs="${HA_SATELLITE_LOGS:-$HOME/Library/Logs/HA Satellite}"

usage() {
  cat <<EOF
usage: macos/build.sh <command> [options]

  build [--no-sign]        build and sign $build_app (default command)
  test                     run the Swift unit tests
  install                  build, copy to $install_dir, write satellite.json if missing, open
  config [--force] [--name NAME]
                           write $support/satellite.json from satellite.json.example
  uninstall [--purge]      unregister the login item, quit, delete the app
                           (--purge also deletes $support and the logs)
  status                   print the app's status (login item, permissions, satellite)

Signing identity: LVA_SIGN_IDENTITY (default "-", ad hoc: the microphone grant
is then lost at every rebuild).
EOF
}

# The Nix dev shell points DEVELOPER_DIR and SDKROOT at a Nix SDK and puts its
# own xcrun first on PATH; Swift and the app need Apple's toolchain.
swift_env() {
  local args=()
  [[ "${DEVELOPER_DIR:-}" == /nix/* ]] && args+=(-u DEVELOPER_DIR)
  [[ "${SDKROOT:-}" == /nix/* ]] && args+=(-u SDKROOT)
  [[ -n "${NIX_APPLE_SDK_VERSION:-}" ]] && args+=(-u MACOSX_DEPLOYMENT_TARGET)
  env ${args[@]+"${args[@]}"} "$@"
}

build() {
  local sign=1
  for arg in "$@"; do
    case "$arg" in
      --no-sign) sign=0 ;;
      *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
  done
  swift_env /usr/bin/xcrun swift --version | head -n 1
  swift_env /usr/bin/xcrun swift build --package-path "$package" -c release --arch arm64
  local bin
  bin="$(swift_env /usr/bin/xcrun swift build --package-path "$package" -c release --arch arm64 --show-bin-path)"

  rm -rf "$build_app"
  mkdir -p "$build_app/Contents/MacOS" "$build_app/Contents/Resources"
  cp "$bin/HASatellite" "$build_app/Contents/MacOS/HASatellite"
  cp "$package/Resources/Info.plist" "$build_app/Contents/Info.plist"
  local commit
  commit="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  /usr/libexec/PlistBuddy -c "Add :HASatelliteCommit string $commit" "$build_app/Contents/Info.plist"
  printf 'APPL????' > "$build_app/Contents/PkgInfo"

  if [[ $sign == 0 ]]; then
    echo "built $build_app (not signed)"
    return
  fi
  local identity="${LVA_SIGN_IDENTITY:--}"
  if [[ "$identity" == "-" ]]; then
    echo "warning: ad hoc signature: the microphone grant will not survive a rebuild (set LVA_SIGN_IDENTITY)" >&2
  fi
  codesign --force --options runtime --timestamp=none \
    --entitlements "$package/Resources/entitlements.plist" \
    --sign "$identity" "$build_app"
  codesign --verify --strict --deep --verbose=1 "$build_app"
  codesign -dr - "$build_app" 2>&1 | sed -n -E 's/^#? ?designated => /designated requirement: /p'
  echo "built $build_app"
}

run_tests() {
  swift_env /usr/bin/xcrun swift test --package-path "$package"
}

mac_address() {
  local device
  device="$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')"
  ifconfig "${device:-en0}" 2>/dev/null | awk '/ether/{print $2; exit}'
}

config() {
  local force=0 name
  name="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --name) name="$2"; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  local target="$support/satellite.json"
  if [[ -e "$target" && $force == 0 ]]; then
    echo "$target exists (use --force to replace it)"
    return
  fi
  local mac libmpv="${LVA_LIBMPV_DIR:-}"
  mac="$(mac_address)"
  if [[ -z "$libmpv" ]]; then
    echo "warning: LVA_LIBMPV_DIR is not set: music playback needs libmpv, edit LVA_LIBMPV_DIR in $target" >&2
  fi
  [[ -x "$repo/.venv/bin/python" ]] || echo "warning: $repo/.venv/bin/python does not exist yet" >&2
  mkdir -p "$support"
  chmod 700 "$support"
  REPO="$repo" SUPPORT="$support" NAME="$name" MAC="$mac" LIBMPV="$libmpv" /usr/bin/python3 - "$here/satellite.json.example" "$target" <<'PY'
import json, os, sys
text = open(sys.argv[1]).read()
for key in ("REPO", "SUPPORT", "NAME", "MAC", "LIBMPV"):
    text = text.replace(f"@{key}@", json.dumps(os.environ[key])[1:-1])
config = json.loads(text)
config.pop("_comment", None)
with open(sys.argv[2], "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY
  echo "wrote $target"
}

quit_app() {
  if pgrep -x HASatellite >/dev/null; then
    osascript -e "quit app id \"$bundle_id\"" || true
    for _ in $(seq 1 30); do
      pgrep -x HASatellite >/dev/null || return 0
      sleep 0.5
    done
    echo "HA Satellite did not quit" >&2
    exit 1
  fi
}

install() {
  # Duplicate copies confuse login item registration.
  local others
  others="$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" | grep -v "/.build/" | grep -vxF "$installed_app" || true)"
  if [[ -n "$others" ]]; then
    echo "other copies of $bundle_id exist, remove them first:" >&2
    echo "$others" >&2
    exit 1
  fi
  build
  quit_app
  mkdir -p "$install_dir"
  rm -rf "$installed_app"
  ditto "$build_app" "$installed_app"
  echo "installed $installed_app"
  config
  open "$installed_app"
}

uninstall() {
  local purge=0
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
  done
  if [[ -x "$installed_app/Contents/MacOS/HASatellite" ]]; then
    "$installed_app/Contents/MacOS/HASatellite" --unregister || true
  fi
  quit_app
  rm -rf "$installed_app"
  echo "removed $installed_app"
  if [[ $purge == 1 ]]; then
    rm -rf "$support" "$logs"
    echo "removed $support and $logs"
  fi
  cat <<EOF
To also forget the permissions:
  tccutil reset Microphone $bundle_id
  Local Network: System Settings > Privacy & Security > Local Network
EOF
}

status() {
  local app="$installed_app"
  [[ -x "$app/Contents/MacOS/HASatellite" ]] || app="$build_app"
  "$app/Contents/MacOS/HASatellite" --status
}

command="${1:-build}"
[[ $# -gt 0 ]] && shift
case "$command" in
  build) build "$@" ;;
  test) run_tests ;;
  install) install ;;
  config) config "$@" ;;
  uninstall) uninstall "$@" ;;
  status) status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
