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
cache="${HA_SATELLITE_BUILD_CACHE:-$HOME/Library/Caches/ha-satellite-build}"

# The bundled interpreter: python-build-standalone, relocatable, pinned by
# release and checksum (the pins of requirements.txt are made for 3.13).
python_version="3.13.16"
python_minor="${python_version%.*}"
python_release="20261003"
python_sha256="9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147"
python_archive="cpython-$python_version+$python_release-aarch64-apple-darwin-install_only_stripped.tar.gz"
python_url="https://github.com/astral-sh/python-build-standalone/releases/download/$python_release/${python_archive//+/%2B}"

usage() {
  cat <<EOF
usage: macos/build.sh <command> [options]

  build                    build the self-contained $build_app: the app, Python
                           $python_version, the pinned requirements.txt, LVA and libmpv
                           (LVA_LIBMPV_DIR, else Homebrew's), PyAV built against
                           libmpv's FFmpeg (LVA_FFMPEG_PKGCONFIG, else Homebrew's
                           ffmpeg), signed (default command)
  check [APP]              check a built app: nothing loaded from outside it, the
                           bundled satellite imports and loads its native parts
  test                     run the Swift unit tests
  install                  build, check, copy to $install_dir and open
  uninstall [--purge]      unregister the login item, quit, delete the app
                           (--purge also deletes $support and the logs)
  status                   print the app's status (login item, permissions, satellite)
  selftest [--no-play]     capture and play through voice processing (app quit)
  echo-test                measure the echo removed by voice processing (app quit)

Signing identity: LVA_SIGN_IDENTITY, else the keychain's "Developer ID
Application" identity, else ad hoc ("-": the microphone grant is lost at every
rebuild; install refuses it unless LVA_SIGN_IDENTITY=- is set). The hardened
runtime is only used with a real identity.
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

  bundle_python "$build_app"
  bundle_libmpv "$build_app"
  "$(bundled_python "$build_app")" -I -B "$here/bundle.py" check "$build_app"

  local identity
  identity="$(sign_identity)"
  if [[ "$identity" == "-" ]]; then
    echo "warning: ad hoc signature: the microphone grant will not survive a rebuild (set LVA_SIGN_IDENTITY)" >&2
  fi
  echo "signing with: $identity"
  sign_bundle "$identity" "$build_app"
  codesign --verify --strict --deep --verbose=1 "$build_app"
  codesign -dr - "$build_app" 2>&1 | sed -n -E 's/^#? ?designated => /designated requirement: /p'
  echo "built $build_app ($(du -sh "$build_app" | cut -f 1))"
}

bundled_python() {
  echo "$1/Contents/Resources/python/bin/python3"
}

fetch_python() {
  local archive="$cache/$python_archive"
  if [[ ! -f "$archive" ]] || ! echo "$python_sha256  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    mkdir -p "$cache"
    echo "downloading $python_url" >&2
    curl -fsSL --retry 3 -o "$archive.part" "$python_url"
    mv "$archive.part" "$archive"
  fi
  echo "$python_sha256  $archive" | shasum -a 256 -c - >&2
  echo "$archive"
}

# Contents/Resources/python: the interpreter with the pinned dependencies in
# its site-packages; Contents/Resources/lva: LVA with its wake words and
# sounds, found through lva.pth, so the satellite runs isolated (-I).
bundle_python() {
  local app="$1" archive
  archive="$(fetch_python)"
  local resources="$app/Contents/Resources"
  local root="$resources/python"
  local python pkgconfig
  python="$(bundled_python "$app")"
  pkgconfig="$(ffmpeg_pkgconfig)"
  tar -xzf "$archive" -C "$resources"
  # PyAV from source: its wheel carries its own FFmpeg, a second copy next to
  # libmpv's in one process (duplicate Objective-C classes, two decoders);
  # built against libmpv's FFmpeg, bundle_libmpv relinks it to Frameworks.
  # Not from pip's wheel cache, which may hold a build for another FFmpeg.
  local av_pin
  av_pin="$(grep -E -o '^av==[^ ]+' "$here/requirements.txt")"
  # Header padding: bundle.py rewrites its FFmpeg paths to longer ones.
  swift_env PKG_CONFIG_PATH="$pkgconfig" LDFLAGS="-Wl,-headerpad_max_install_names" "$python" -I -m pip install --disable-pip-version-check --no-compile --no-cache-dir \
    --no-deps --no-binary av --progress-bar off "$av_pin"
  "$python" -I -m pip install --disable-pip-version-check --no-warn-script-location --no-compile \
    --only-binary :all: --progress-bar off -r "$here/requirements.txt"
  "$python" -I -m pip uninstall --disable-pip-version-check -y -q pip
  local stdlib site
  stdlib="$("$python" -I -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
  site="$("$python" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
  # Not used at run time: headers, tools, Tk, IDLE, ensurepip.
  find "$root/bin" -mindepth 1 ! -name python3 ! -name "python$python_minor" -exec rm -rf {} +
  rm -rf "$root/include" "$root/share" "$root/lib/pkgconfig" "$root/lib"/tcl* "$root/lib"/tk* "$root/lib"/itcl* "$root/lib"/thread* \
    "$stdlib/tkinter" "$stdlib/idlelib" "$stdlib/turtledemo" "$stdlib/ensurepip" "$stdlib/lib-dynload"/_tkinter.* \
    "$stdlib"/config-*-darwin
  find "$root" -name __pycache__ -type d -prune -exec rm -rf {} +

  local lva="$resources/lva"
  mkdir -p "$lva"
  rsync -a --exclude __pycache__ "$repo/linux_voice_assistant" "$repo/wakewords" "$repo/sounds" "$lva/"
  if [[ -f "$repo/version.txt" ]]; then
    cp "$repo/version.txt" "$lva/version.txt"
  fi
  "$python" -I -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$lva" "$site" > "$site/lva.pth"
  # Unchecked-hash bytecode: valid whatever the files' dates, never rewritten.
  "$python" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$stdlib" "$lva" >/dev/null
  echo "bundled Python $python_version ($(du -sh "$root" | cut -f 1)) and LVA"
}

# pkg-config files of the FFmpeg libmpv uses, for building PyAV against it:
# LVA_FFMPEG_PKGCONFIG (with LVA_LIBMPV_DIR), else Homebrew's ffmpeg.
ffmpeg_pkgconfig() {
  local dir="${LVA_FFMPEG_PKGCONFIG:-}"
  if [[ -z "$dir" ]] && command -v brew >/dev/null; then
    dir="$(brew --prefix ffmpeg)/lib/pkgconfig"
  fi
  if [[ -z "$dir" || ! -e "$dir/libavcodec.pc" ]]; then
    echo "libavcodec.pc not found${dir:+ in $dir}: brew install mpv, or set LVA_FFMPEG_PKGCONFIG" >&2
    exit 1
  fi
  if ! command -v pkg-config >/dev/null; then
    echo "pkg-config not found: brew install pkgconf" >&2
    exit 1
  fi
  echo "$dir"
}

# Contents/Frameworks: libmpv and the libraries it needs, from LVA_LIBMPV_DIR
# or Homebrew (brew install mpv), and PyAV's modules relinked to the same
# FFmpeg; LVA finds libmpv through LVA_LIBMPV_DIR, which the app sets.
bundle_libmpv() {
  local app="$1" dir="${LVA_LIBMPV_DIR:-}"
  if [[ -z "$dir" ]] && command -v brew >/dev/null; then
    dir="$(brew --prefix)/lib"
  fi
  if [[ -z "$dir" || ! -e "$dir/libmpv.dylib" ]]; then
    echo "libmpv.dylib not found${dir:+ in $dir}: brew install mpv, or set LVA_LIBMPV_DIR" >&2
    exit 1
  fi
  local python site
  python="$(bundled_python "$app")"
  site="$("$python" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
  if [[ -d "$site/av/.dylibs" ]]; then
    echo "$site/av/.dylibs: PyAV was installed from its wheel, with its own FFmpeg" >&2
    exit 1
  fi
  local modules=()
  while IFS= read -r -d '' module; do modules+=("$module"); done < <(find "$site/av" -name '*.so' -print0)
  "$python" -I -B "$here/bundle.py" libmpv "$dir/libmpv.dylib" "$app/Contents/Frameworks" "${modules[@]}"
}

# Inside-out: libraries and extension modules, the interpreter, then the app.
# The interpreter needs no entitlement: with a Developer ID every library it
# loads has the same team, which is what library validation asks; ad hoc
# signatures have no team, so nested code is then signed without the
# hardened runtime.
sign_bundle() {
  local identity="$1" app="$2" python
  python="$(bundled_python "$app")"
  local options=(--force --timestamp=none --sign "$identity")
  [[ "$identity" != "-" ]] && options+=(--options runtime)
  local app_options=(--force --timestamp=none --sign "$identity" --options runtime)
  local kind
  for kind in libraries executables; do
    "$python" -I -B "$here/bundle.py" list "$kind" "$app/Contents/Resources" "$app/Contents/Frameworks" \
      | xargs -0 codesign "${options[@]}" 2>&1 | { grep -v ': replacing existing signature$' || true; }
  done
  codesign "${app_options[@]}" --entitlements "$package/Resources/entitlements.plist" "$app"
}

check() {
  local app="${1:-$build_app}"
  local python
  python="$(bundled_python "$app")"
  "$python" -I -B "$here/bundle.py" check "$app"
  LVA_LIBMPV_DIR="$app/Contents/Frameworks" "$python" -I -B "$here/smoke.py"
  "$python" -I -B -m linux_voice_assistant --help >/dev/null
  echo "python -m linux_voice_assistant --help: OK"
  if codesign --verify --strict --deep "$app" 2>/dev/null; then
    echo "signature: valid, $(codesign -dvv "$app" 2>&1 | sed -n -E 's/^Authority=//p; s/^Signature=adhoc/ad hoc/p' | head -n 1)"
  else
    echo "signature: none or invalid"
  fi
}

run_tests() {
  swift_env /usr/bin/xcrun swift test --package-path "$package"
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
  check
  quit_app
  mkdir -p "$install_dir"
  rm -rf "$installed_app"
  ditto "$build_app" "$installed_app"
  echo "installed $installed_app"
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
  build) build ;;
  check) check "$@" ;;
  test) run_tests ;;
  install) install ;;
  uninstall) uninstall "$@" ;;
  status) "$(app_binary)" --status ;;
  selftest) device_test --selftest "$@" ;;
  echo-test) device_test --echo-test ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
