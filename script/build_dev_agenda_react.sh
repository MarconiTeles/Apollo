#!/bin/bash
# Builds "Apollo DEV Agenda React.app": isolated DEV build whose Agenda body
# (event timeline, month grid and day panel) is rendered by React
# (web/apollo-agenda) in a WKWebView instead of the native SwiftUI/AppKit
# views. Same modes and app args as script/build_dev_board_appkit.sh:
#
#   script/build_dev_agenda_react.sh --build-only
#   script/build_dev_agenda_react.sh --run [app args...]
#   script/build_dev_agenda_react.sh --launch-only [app args...]
#
# e.g. --agenda-fixtures=300 --route=today
#      --agenda-renderer=native   same binary with the native views (A/B)
#
# Own bundle id, output folder and SwiftPM scratch path: it never touches
# /Applications/Apollo.app, the production build, Sparkle or releases.
set -euo pipefail
export APOLLO_DEV_APP_NAME="Apollo DEV Agenda React"
export APOLLO_DEV_BUNDLE_ID="com.painellunar.app.dev.agenda-react"
export APOLLO_DEV_OUT_DIR="build/dev-agenda-react"
export APOLLO_DEV_MANIFEST_NAME="DEV-agenda-react-manifest.json"
export APOLLO_DEV_SWIFT_FLAGS="-Xswiftc -DAPOLLO_DEV -Xswiftc -DAPOLLO_AGENDA_REACT"
export APOLLO_DEV_SCRATCH_NAME=".build-dev-agenda-react"
export APOLLO_BUNDLE_AGENDA_REACT=1
exec "$(dirname "$0")/build_dev_board_appkit.sh" "$@"
