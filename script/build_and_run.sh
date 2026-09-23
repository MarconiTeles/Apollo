#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---run}"
case "$MODE" in
  --run|--build-only|--verify|--logs|--telemetry) ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--logs|--telemetry]' >&2; exit 2 ;;
esac
./build.sh "${APOLLO_DEV_CONFIGURATION:-release}"
if [ "$MODE" = --build-only ]; then exit 0; fi
APP_PATH="$ROOT_DIR/build/Apollo.app"
# Stop only this checkout's process; never replace the installed application.
/usr/bin/pkill -f "^$APP_PATH/Contents/MacOS/DayPanel$" 2>/dev/null || true
/usr/bin/open -n "$APP_PATH"
case "$MODE" in
  --verify) /bin/sleep 1; /usr/bin/pgrep -f "^$APP_PATH/Contents/MacOS/DayPanel$" ;;
  --logs|--telemetry) /usr/bin/log stream --info --predicate 'process == "DayPanel"' ;;
esac
