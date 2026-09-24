#!/bin/bash
# Builds "Apollo DEV Board React.app": isolated DEV build whose Quadro is the
# ClickUp-parity board rendered by React (web/apollo-board) in a WKWebView
# instead of the AppKit viewport. Tasks and Agenda use their React surfaces
# too, as in production. Same modes and app args as
# script/build_dev_board_appkit.sh:
#
#   script/build_dev_board_react.sh --build-only
#   script/build_dev_board_react.sh --run [app args...]
#   script/build_dev_board_react.sh --launch-only [app args...]
#
# e.g. --board-fixtures=169 --route=board
#      --board-renderer=appkit   same binary with the native board (A/B)
#
# Iterate on the page without rebuilding (DEV only):
#   (cd web/apollo-board && npm run dev)
#   open -n --env APOLLO_BOARD_URL=http://localhost:5321/ "<app>" --args --route=board
#
# Own bundle id, output folder and SwiftPM scratch path: it never touches
# /Applications/Apollo.app, the production build, Sparkle or releases.
set -euo pipefail
export APOLLO_DEV_APP_NAME="Apollo DEV Board React"
export APOLLO_DEV_BUNDLE_ID="com.painellunar.app.dev.board-react"
export APOLLO_DEV_OUT_DIR="build/dev-board-react"
export APOLLO_DEV_MANIFEST_NAME="DEV-board-react-manifest.json"
export APOLLO_DEV_SWIFT_FLAGS="-Xswiftc -DAPOLLO_DEV -Xswiftc -DAPOLLO_TASKS_REACT -Xswiftc -DAPOLLO_AGENDA_REACT -Xswiftc -DAPOLLO_BOARD_REACT"
export APOLLO_DEV_SCRATCH_NAME=".build-dev-board-react"
export APOLLO_BUNDLE_TASKS_REACT=1
export APOLLO_BUNDLE_AGENDA_REACT=1
export APOLLO_BUNDLE_BOARD_REACT=1
exec "$(dirname "$0")/build_dev_board_appkit.sh" "$@"
