# Fork only: the macOS app (macos/README.md). Upstream uses ./script/*.

# List the recipes
default:
    @just --list

# Build and sign HA Satellite.app (Developer ID from the keychain or LVA_SIGN_IDENTITY)
mac-build *args:
    macos/build.sh build {{args}}

# Swift unit tests
mac-test:
    macos/build.sh test

# Create .venv (Python 3.13) and install the pinned macOS dependencies
mac-venv:
    macos/build.sh venv

# Build, sign, set up the venv, install to ~/Applications, write satellite.json, open
mac-install:
    macos/build.sh install

# Write satellite.json (--force --name NAME --mac MAC --libmpv DIR)
mac-config *args:
    macos/build.sh config {{args}}

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
