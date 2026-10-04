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
  venv                     create $repo/.venv (Python 3.13) if missing and
                           install the pinned macos/requirements.txt into it
  install                  build, venv, copy to $install_dir, write satellite.json
                           if missing, open the app once no placeholder is left
  config [--force] [--name NAME] [--mac MAC] [--libmpv DIR]
                           write $support/satellite.json from satellite.json.example;
                           values not given stay as @NAME@, @MAC@, @LIBMPV@
  uninstall [--purge]      unregister the login item, quit, delete the app
                           (--purge also deletes $support and the logs)
  status                   print the app's status (login item, permissions, satellite)
  selftest [--no-play]     capture and play through voice processing (app quit)
  echo-test                measure the echo removed by voice processing (app quit)

Signing identity: LVA_SIGN_IDENTITY, else the keychain's "Developer ID
Application" identity, else ad hoc ("-": the microphone grant is lost at every
rebuild; install refuses it unless LVA_SIGN_IDENTITY=- is set).
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

# LVA_SIGN_IDENTITY, else the first Developer ID Application identity, else "-".
sign_identity() {
  if [[ -n "${LVA_SIGN_IDENTITY:-}" ]]; then
    echo "$LVA_SIGN_IDENTITY"
    return
  fi
  local found
  found="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n -E 's/^ *[0-9]+\) [0-9A-F]+ "(Developer ID Application: .*)"$/\1/p' | head -n 1)"
  echo "${found:--}"
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
  local identity
  identity="$(sign_identity)"
  if [[ "$identity" == "-" ]]; then
    echo "warning: ad hoc signature: the microphone grant will not survive a rebuild (set LVA_SIGN_IDENTITY)" >&2
  fi
  echo "signing with: $identity"
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

# The app runs <repo>/.venv/bin/python (satellite.json.example). Packages
# already there are kept (the dev tools of ./script/setup --dev); the pins of
# macos/requirements.txt are installed over them.
venv() {
  local python="$repo/.venv/bin/python"
  if command -v uv >/dev/null; then
    [[ -x "$python" ]] || uv venv --python 3.13 "$repo/.venv"
    uv pip install --python "$python" -r "$here/requirements.txt"
    uv pip install --python "$python" --no-deps -e "$repo"
  else
    if [[ ! -x "$python" ]]; then
      command -v python3.13 >/dev/null || { echo "uv or python3.13 is needed to create $repo/.venv" >&2; exit 1; }
      python3.13 -m venv "$repo/.venv"
    fi
    "$python" -m pip install -r "$here/requirements.txt"
    "$python" -m pip install --no-deps -e "$repo"
  fi
  local version
  version="$("$python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  echo "venv: $python (Python $version)"
  [[ "$version" == "3.13" ]] || echo "warning: the pins are made for Python 3.13, $repo/.venv has $version" >&2
}

placeholders() {
  grep -o -E '@[A-Z_]+@' "$1" | sort -u | tr '\n' ' ' || true
}

config_help() {
  cat <<EOF
Replace the placeholders in $1:
  @NAME@    the satellite's name in Home Assistant, for example "MacBook"
  @MAC@     the built-in Wi-Fi MAC address, which keeps the device identity
            when the Mac moves between Wi-Fi and a dock. Read it with
              networksetup -listallhardwareports | grep -A 2 'Wi-Fi'
            (the "Ethernet Address" line)
  @LIBMPV@  the directory holding libmpv.dylib, for example \$(brew --prefix)/lib
            or the lib directory of nixpkgs mpv-unwrapped
or write it again: macos/build.sh config --force --name NAME --mac MAC --libmpv DIR
EOF
}

config() {
  local force=0 name="@NAME@" mac="@MAC@" libmpv="${LVA_LIBMPV_DIR:-@LIBMPV@}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --name) name="$2"; shift ;;
      --mac) mac="$2"; shift ;;
      --libmpv) libmpv="$2"; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  local target="$support/satellite.json"
  if [[ -e "$target" && $force == 0 ]]; then
    echo "$target exists (use --force to replace it)"
  else
    [[ -x "$repo/.venv/bin/python" ]] || echo "warning: $repo/.venv/bin/python does not exist yet (macos/build.sh venv)" >&2
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
  fi
  if [[ -n "$(placeholders "$target")" ]]; then
    config_help "$target"
  fi
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
  if [[ "$(sign_identity)" == "-" && "${LVA_SIGN_IDENTITY:-}" != "-" ]]; then
    echo "no Developer ID Application identity in the keychain: set LVA_SIGN_IDENTITY (\"-\" for ad hoc)" >&2
    exit 1
  fi
  build
  venv
  quit_app
  mkdir -p "$install_dir"
  rm -rf "$installed_app"
  ditto "$build_app" "$installed_app"
  echo "installed $installed_app"
  config
  local left
  left="$(placeholders "$support/satellite.json")"
  if [[ -n "$left" ]]; then
    echo "not opened: replace ${left% } in $support/satellite.json, then: open \"$installed_app\""
    return
  fi
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

app_binary() {
  local app="$installed_app"
  [[ -x "$app/Contents/MacOS/HASatellite" ]] || app="$build_app"
  echo "$app/Contents/MacOS/HASatellite"
}

# The device tests open their own voice-processing engine: not while the app runs.
device_test() {
  if pgrep -x HASatellite >/dev/null; then
    echo "quit HA Satellite first (menu > Quit)" >&2
    exit 1
  fi
  "$(app_binary)" "$@"
}

command="${1:-build}"
[[ $# -gt 0 ]] && shift
case "$command" in
  build) build "$@" ;;
  test) run_tests ;;
  venv) venv ;;
  install) install ;;
  config) config "$@" ;;
  uninstall) uninstall "$@" ;;
  status) "$(app_binary)" --status ;;
  selftest) device_test --selftest "$@" ;;
  echo-test) device_test --echo-test ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
