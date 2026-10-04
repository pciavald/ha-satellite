# Fork only: the macOS app (macos/README.md). Upstream uses ./script/*.

# List the recipes
default:
    @just --list

# Build the self-contained HA Satellite.app (Python, dependencies, libmpv) and sign it
mac-build:
    macos/build.sh build

# Check the built app: nothing loaded from outside it, the bundled satellite loads
mac-check:
    macos/build.sh check

# Swift unit tests
mac-test:
    macos/build.sh test

# Build, check, copy to ~/Applications and open
mac-install:
    macos/build.sh install

# Unregister the login item, quit and delete the app (--purge: settings and logs too)
mac-uninstall *args:
    macos/build.sh uninstall {{args}}

# Login item, permissions, configuration and satellite pid as JSON
mac-status:
    macos/build.sh status

# Capture and play through voice processing (quit the app first)
mac-selftest *args:
    macos/build.sh selftest {{args}}

# Measure the echo removed by voice processing (quit the app first)
mac-echo-test:
    macos/build.sh echo-test

# Follow the app and satellite logs
mac-logs:
    tail -F "$HOME/Library/Logs/HA Satellite/app.log" "$HOME/Library/Logs/HA Satellite/satellite.log"
