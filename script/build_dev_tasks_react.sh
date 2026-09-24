#!/bin/bash
# Builds "Apollo DEV Tasks React.app": isolated DEV build whose task list is
# rendered by React (web/apollo-tasks) in a WKWebView instead of the AppKit
# viewport. Same modes and app args as script/build_dev_board_appkit.sh:
#
#   script/build_dev_tasks_react.sh --build-only
#   script/build_dev_tasks_react.sh --run [app args...]
#   script/build_dev_tasks_react.sh --launch-only [app args...]
#
# e.g. --board-fixtures=169 --route=tasks
#      --tasks-renderer=appkit   same binary with the native list (A/B)
#
# Own bundle id, output folder and SwiftPM scratch path: it never touches
# /Applications/Apollo.app, the production build, Sparkle or releases.
set -euo pipefail
export APOLLO_DEV_APP_NAME="Apollo DEV Tasks React"
export APOLLO_DEV_BUNDLE_ID="com.painellunar.app.dev.tasks-react"
export APOLLO_DEV_OUT_DIR="build/dev-tasks-react"
export APOLLO_DEV_MANIFEST_NAME="DEV-tasks-react-manifest.json"
export APOLLO_DEV_SWIFT_FLAGS="-Xswiftc -DAPOLLO_DEV -Xswiftc -DAPOLLO_TASKS_REACT"
export APOLLO_DEV_SCRATCH_NAME=".build-dev-tasks-react"
export APOLLO_BUNDLE_TASKS_REACT=1
exec "$(dirname "$0")/build_dev_board_appkit.sh" "$@"
