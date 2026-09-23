#!/bin/bash
# Builds "Apollo DEV Sidebar 27.app": isolated DEV build of the Finder-style
# (macOS 27) sidebar background, on top of Apollo 2.0.3. Same modes and app
# args as script/build_dev_board_appkit.sh:
#
#   script/build_dev_sidebar_macos27.sh --build-only
#   script/build_dev_sidebar_macos27.sh --run [app args...]
#   script/build_dev_sidebar_macos27.sh --launch-only [app args...]
#
# e.g. --board-fixtures=169 --route=board --appearance=dark
set -euo pipefail
export APOLLO_DEV_APP_NAME="Apollo DEV Sidebar 27"
export APOLLO_DEV_BUNDLE_ID="com.painellunar.app.dev.sidebar27"
export APOLLO_DEV_OUT_DIR="build/dev-sidebar27"
export APOLLO_DEV_MANIFEST_NAME="DEV-sidebar27-manifest.json"
exec "$(dirname "$0")/build_dev_board_appkit.sh" "$@"
