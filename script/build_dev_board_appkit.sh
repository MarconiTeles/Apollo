#!/bin/bash
# Builds "Apollo DEV Board AppKit.app": the isolated DEV build used to compare
# the SwiftUI and AppKit board renderers. It reuses ./build.sh (same steps as
# production) with an isolated identity, output path and SwiftPM scratch path.
#
#   script/build_dev_board_appkit.sh --build-only
#   script/build_dev_board_appkit.sh --run [app args...]
#   script/build_dev_board_appkit.sh --launch-only [app args...]   (no rebuild)
#
# App args (DEV build only), e.g.:
#   --board-fixtures=169 --route=board --board-renderer=swiftui --appearance=light
#
# Never touches /Applications/Apollo.app, the Sparkle feed/appcast, releases or
# production secrets. Optional env:
#   APOLLO_DEV_SIGNING_ID          signing identity (default: Developer ID if
#                                  present, else ad-hoc "-")
#   APOLLO_OLLAMA_RUNTIME_SOURCE   existing ollama binary to seed build/ollama-runtime
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="build"
RUN_ARGS=()
case "${1:-}" in
    --build-only|"") MODE="build" ;;
    --run)           MODE="run";         shift; RUN_ARGS=("$@") ;;
    --launch-only)   MODE="launch-only"; shift; RUN_ARGS=("$@") ;;
    -h|--help)       sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Usage: $0 [--build-only | --run [args...] | --launch-only [args...]]" >&2; exit 2 ;;
esac

BUNDLE_ID="com.painellunar.app.dev.board-appkit"
APP_NAME="Apollo DEV Board AppKit"
OUT_DIR="build/dev-board-appkit"
APP="$OUT_DIR/$APP_NAME.app"
ABS_APP="$ROOT/$APP"
WORK_DIR="$OUT_DIR/work"
SCRATCH="$ROOT/.build-dev"
REVIEW_SCRATCH="$ROOT/.build-dev-review"
REVIEW_DIR="$ROOT/../apollo-review-swift"
CONFIG="release"
SWIFT_FLAGS="-Xswiftc -DAPOLLO_DEV"
MANIFEST_NAME="DEV-board-appkit-manifest.json"
DEVELOPER_ID="Developer ID Application: Marconi Lima (CU544M36UD)"

stop_previous_dev_instance() {
    # Only processes whose executable lives inside THIS DEV bundle path.
    local pids
    pids="$(pgrep -f "^$ABS_APP/Contents/MacOS/DayPanel" || true)"
    if [ -n "$pids" ]; then
        echo "→ Stopping previous DEV instance(s): $pids"
        kill $pids 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -f "^$ABS_APP/Contents/MacOS/DayPanel" >/dev/null || break
            sleep 0.5
        done
        pids="$(pgrep -f "^$ABS_APP/Contents/MacOS/DayPanel" || true)"
        [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
    fi
}

launch_dev() {
    [ -d "$APP" ] || { echo "ERROR: $APP not built." >&2; exit 1; }
    stop_previous_dev_instance
    echo "→ open -n \"$APP\" --args ${RUN_ARGS[*]+"${RUN_ARGS[*]}"}"
    open -n "$APP" --args ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}
}

if [ "$MODE" = "launch-only" ]; then
    launch_dev
    exit 0
fi

# ── Pre-flight ───────────────────────────────────────────────────────────
# Google OAuth client values are gitignored per contributor. A fresh checkout
# gets the empty template (Google Calendar connect shows "setup pending");
# no credential is copied from anywhere.
GOOGLE_SECRETS="Sources/DayPanel/Services/GoogleAuthSecrets.swift"
if [ ! -f "$GOOGLE_SECRETS" ]; then
    echo "→ $GOOGLE_SECRETS missing: generating empty template (Google connect disabled)."
    sed 's/enum GoogleAuthSecretsTemplate/enum GoogleAuthSecrets/' \
        Sources/DayPanel/Services/GoogleAuthSecrets.example.swift > "$GOOGLE_SECRETS"
fi
if [ ! -f build/ollama-runtime ] && [ -n "${APOLLO_OLLAMA_RUNTIME_SOURCE:-}" ]; then
    mkdir -p build
    cp -L "$APOLLO_OLLAMA_RUNTIME_SOURCE" build/ollama-runtime
    chmod +x build/ollama-runtime
fi

if [ -n "${APOLLO_DEV_SIGNING_ID:-}" ]; then
    SIGNING_ID="$APOLLO_DEV_SIGNING_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$DEVELOPER_ID\""; then
    SIGNING_ID="$DEVELOPER_ID"
else
    SIGNING_ID="-"
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"

run_build_sh() {
    local signing="$1" legacy="$2"
    APOLLO_APP_DISPLAY_NAME="$APP_NAME" \
    APOLLO_APP_PATH="$APP" \
    APOLLO_BUNDLE_ID="$BUNDLE_ID" \
    APOLLO_IDENTITY_VARIANT="dev" \
    APOLLO_WORK_DIR="$WORK_DIR" \
    APOLLO_SCRATCH_PATH="$SCRATCH" \
    APOLLO_REVIEW_SCRATCH_PATH="$REVIEW_SCRATCH" \
    APOLLO_EXTRA_SWIFT_FLAGS="$SWIFT_FLAGS" \
    APOLLO_SIGNING_ID="$signing" \
    APOLLO_FORCE_LEGACY_SECRET_STORE="$legacy" \
        ./build.sh "$CONFIG"
}

echo "═══ Building $APP_NAME ($CONFIG, $SWIFT_FLAGS) — signing: $SIGNING_ID"
if ! run_build_sh "$SIGNING_ID" ""; then
    # Fall back to ad-hoc only when the compile/package steps succeeded and
    # signing was what failed (the executable is already in the bundle).
    if [ "$SIGNING_ID" != "-" ] && [ -f "$APP/Contents/MacOS/DayPanel" ]; then
        echo "⚠︎ Signing with '$SIGNING_ID' failed; retrying ad-hoc." >&2
        SIGNING_ID="-"
        # Ad-hoc signatures change on every build, so keep secrets in the DEV
        # container's local file store instead of prompting Keychain ACLs.
        run_build_sh "-" "1"
    else
        echo "✗ DEV build failed before signing." >&2
        exit 1
    fi
fi

# ── Identity isolation checks (fail the build if anything leaks) ──────────
PLIST="$APP/Contents/Info.plist"
HELPER="$APP/Contents/Helpers/Apollo Review.app"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }
fail() { echo "✗ DEV isolation check failed: $*" >&2; exit 1; }
[ "$(pb CFBundleIdentifier "$PLIST")" = "$BUNDLE_ID" ] || fail "main bundle id"
[ "$(pb CFBundleIdentifier "$HELPER/Contents/Info.plist")" = "$BUNDLE_ID.review" ] || fail "helper bundle id"
[ -z "$(pb SUFeedURL "$PLIST")" ] || fail "SUFeedURL present"
[ "$(pb SUEnableAutomaticChecks "$PLIST")" = "false" ] || fail "SUEnableAutomaticChecks"
[ -z "$(pb CFBundleURLTypes "$PLIST")" ] || fail "main URL schemes present"
[ -z "$(pb CFBundleURLTypes "$HELPER/Contents/Info.plist")" ] || fail "helper URL schemes present"
ENT_DUMP="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if echo "$ENT_DUMP" | grep -qE '>(CU544M36UD\.)?com\.painellunar\.app(-spki|-spks)?<'; then
    fail "signed entitlements reference the production identity"
fi
echo "  ✓ DEV identity isolated (bundle id, helper id, no feed, no URL schemes, entitlements)"

# ── Manifest ─────────────────────────────────────────────────────────────
PRE_VERIFY_OUT="$(codesign --verify --deep --strict "$APP" 2>&1)" && PRE_VERIFY_RC=0 || PRE_VERIFY_RC=$?
UNSIGNED_BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" $SWIFT_FLAGS --show-bin-path)/DayPanel"
UNSIGNED_REVIEW_BIN="$(swift build --package-path "$REVIEW_DIR" -c "$CONFIG" --scratch-path "$REVIEW_SCRATCH" --show-bin-path)/ApolloReview"

MANIFEST_TMP="$WORK_DIR/$MANIFEST_NAME"
export M_APP="$APP" M_ROOT="$ROOT" M_REVIEW_DIR="$REVIEW_DIR" M_CONFIG="$CONFIG" \
       M_FLAGS="$SWIFT_FLAGS" M_BUNDLE_ID="$BUNDLE_ID" M_SIGNING_ID="$SIGNING_ID" \
       M_PRE_VERIFY_RC="$PRE_VERIFY_RC" M_PRE_VERIFY_OUT="$PRE_VERIFY_OUT" \
       M_UNSIGNED_BIN="$UNSIGNED_BIN" M_UNSIGNED_REVIEW_BIN="$UNSIGNED_REVIEW_BIN" \
       M_SCRATCH="$SCRATCH"
python3 - "$MANIFEST_TMP" <<'PY'
import hashlib, json, os, subprocess, sys, datetime

def sh(*args, cwd=None):
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False).stdout.strip()
    except Exception as e:
        return f"<error: {e}>"

def sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError as e:
        return f"<error: {e}>"

def git_state(repo):
    status = sh("git", "status", "--porcelain", cwd=repo)
    lines = [l for l in status.splitlines() if l]
    state = {
        "path": os.path.realpath(repo),
        "branch": sh("git", "rev-parse", "--abbrev-ref", "HEAD", cwd=repo),
        "commit": sh("git", "rev-parse", "HEAD", cwd=repo),
        "dirty": bool(lines),
        "status_porcelain": lines[:200],
        "status_entries": len(lines),
    }
    if lines:
        # Patch identity: tracked diff vs HEAD + contents of untracked files.
        h = hashlib.sha256()
        h.update(subprocess.run(["git", "diff", "HEAD", "--binary"], cwd=repo,
                                capture_output=True).stdout)
        untracked = sh("git", "ls-files", "--others", "--exclude-standard", cwd=repo).splitlines()
        for rel in sorted(untracked):
            h.update(rel.encode() + b"\0" + sha256(os.path.join(repo, rel)).encode() + b"\n")
        state["patch_sha256"] = h.hexdigest()
        state["untracked_files"] = len(untracked)
    return state

app = os.environ["M_APP"]
exe = os.path.join(app, "Contents/MacOS/DayPanel")
helper = os.path.join(app, "Contents/Helpers/Apollo Review.app")
helper_exe = os.path.join(helper, "Contents/MacOS/ApolloReview")
vtool = sh("xcrun", "vtool", "-show-build", exe)
minos = sorted({l.split()[1] for l in vtool.splitlines() if l.strip().startswith("minos")})
sdks = sorted({l.split()[1] for l in vtool.splitlines() if l.strip().startswith("sdk")})
cs = subprocess.run(["codesign", "-dvv", app], capture_output=True, text=True).stderr
authorities = [l.split("=", 1)[1] for l in cs.splitlines() if l.startswith("Authority=")]
team = next((l.split("=", 1)[1] for l in cs.splitlines() if l.startswith("TeamIdentifier=")), None)
signature = next((l.split("=", 1)[1] for l in cs.splitlines() if l.startswith("Signature=")), None)

manifest = {
    "schema": 1,
    "app": "Apollo DEV Board AppKit",
    "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "bundle_id": os.environ["M_BUNDLE_ID"],
    "helper_bundle_id": sh("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier",
                           os.path.join(helper, "Contents/Info.plist")),
    "version": sh("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                  os.path.join(app, "Contents/Info.plist")),
    "build": sh("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion",
                os.path.join(app, "Contents/Info.plist")),
    "configuration": os.environ["M_CONFIG"],
    "swift_flags": os.environ["M_FLAGS"],
    "compilation_conditions": ["APOLLO_DEV"],
    "optimization": "-O (SwiftPM release)",
    "scratch_path": os.environ["M_SCRATCH"],
    "source": git_state(os.environ["M_ROOT"]),
    "review_kit": git_state(os.environ["M_REVIEW_DIR"]),
    "toolchain": {
        "sdk_version": sh("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": sh("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "xcode": " ".join(sh("xcodebuild", "-version").split()),
        "swift": sh("swift", "--version").splitlines()[0] if sh("swift", "--version") else "",
    },
    "binary": {"minos": minos, "sdk": sdks, "archs": sh("lipo", "-archs", exe).split()},
    "sha256": {
        "main_executable_unsigned_build_product": sha256(os.environ["M_UNSIGNED_BIN"]),
        "review_helper_executable_unsigned_build_product": sha256(os.environ["M_UNSIGNED_REVIEW_BIN"]),
        "review_helper_executable_signed": sha256(helper_exe),
        "main_executable_signed_before_manifest": sha256(exe),
    },
    "signing": {
        "requested_identity": os.environ["M_SIGNING_ID"],
        "authority": authorities,
        "team_identifier": team,
        "signature": signature,
        "codesign_verify_deep_strict_before_manifest": {
            "exit_code": int(os.environ["M_PRE_VERIFY_RC"]),
            "output": os.environ["M_PRE_VERIFY_OUT"],
        },
        "note": ("This manifest is sealed into the bundle by re-signing the outer "
                 "app, which rewrites the main executable's signature. The final "
                 "signed SHA-256 and verification are in the sidecar "
                 "build/dev-board-appkit/DEV-board-appkit-manifest.final.json."),
    },
    "launch_arguments": {
        "--board-renderer": "swiftui | appkit",
        "--board-fixtures": "<N> offline deterministic tasks",
        "--route": "inbox | tasks | board | comments",
        "--appearance": "light | dark | system",
    },
}
with open(sys.argv[1], "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

cp "$MANIFEST_TMP" "$APP/Contents/Resources/$MANIFEST_NAME"

# Re-seal only the outer bundle with the exact entitlements it already had.
SIGNED_ENTS="$WORK_DIR/signed-app.entitlements"
codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENTS" 2>/dev/null
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_ID" --entitlements "$SIGNED_ENTS" "$APP" > /dev/null

FINAL_VERIFY_OUT="$(codesign --verify --deep --strict "$APP" 2>&1)" && FINAL_VERIFY_RC=0 || FINAL_VERIFY_RC=$?
python3 - "$MANIFEST_TMP" "$OUT_DIR/DEV-board-appkit-manifest.final.json" \
    "$APP/Contents/MacOS/DayPanel" "$FINAL_VERIFY_RC" "$FINAL_VERIFY_OUT" <<'PY'
import hashlib, json, sys
src, dst, exe, rc, out = sys.argv[1:6]
m = json.load(open(src))
m["sha256"]["main_executable_signed_final"] = hashlib.sha256(open(exe, "rb").read()).hexdigest()
m["signing"]["codesign_verify_deep_strict_final"] = {"exit_code": int(rc), "output": out}
json.dump(m, open(dst, "w"), indent=2, ensure_ascii=False)
PY

if [ "$FINAL_VERIFY_RC" -ne 0 ]; then
    echo "✗ codesign --verify --deep --strict failed:" >&2
    echo "$FINAL_VERIFY_OUT" >&2
    exit 1
fi
echo "  ✓ codesign --verify --deep --strict OK ($SIGNING_ID)"
echo ""
echo "✓ Built $APP"
echo "  Manifest: $APP/Contents/Resources/$MANIFEST_NAME"
echo "  Final:    $OUT_DIR/DEV-board-appkit-manifest.final.json"

if [ "$MODE" = "run" ]; then
    launch_dev
fi
