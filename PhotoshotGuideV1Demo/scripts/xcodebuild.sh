#!/bin/bash
# Main build script. Automatically detects the workspace/project and scheme, builds, and filters output.
# Output: errors, warnings, and status only. Does not dump the full log.
#
# Usage:
#   bash xcodebuild.sh                    # Auto-detect scheme
#   bash xcodebuild.sh --scheme MyApp     # Override scheme

set -euo pipefail

# ============================================================
# Argument parsing
# ============================================================

SCHEME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scheme)
            SCHEME_OVERRIDE="$2"
            shift 2
            ;;
        --scheme=*)
            SCHEME_OVERRIDE="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--scheme SCHEME_NAME]"
            echo ""
            echo "Options:"
            echo "  --scheme NAME   Specify a scheme (recommended)"
            echo "  -h, --help      Show help"
            exit 0
            ;;
        *)
            echo "[STATUS] UNKNOWN_ARG"
            echo "Unknown argument: $1"
            echo "Usage: $0 [--scheme SCHEME_NAME]"
            exit 1
            ;;
    esac
done

# ============================================================
# Setup
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
BUILD_LOG=$(mktemp -t xcodebuild_log)
source "$SCRIPT_DIR/run-lock.sh"

cleanup() {
    rm -f "$BUILD_LOG"
    release_run_lock
}
trap cleanup EXIT

# ============================================================
# Step 1: Detect workspace / project
# ============================================================

WORKSPACE=$(ls -d *.xcworkspace 2>/dev/null | head -1 || true)
PROJECT=$(ls -d *.xcodeproj 2>/dev/null | head -1 || true)

if [ -z "$WORKSPACE" ] && [ -z "$PROJECT" ]; then
    echo "[STATUS] NO_PROJECT"
    echo "No .xcworkspace or .xcodeproj found in $(pwd)"
    exit 1
fi

if [ -n "$WORKSPACE" ]; then
    TARGET_TYPE="workspace"
    TARGET_PATH="$PROJECT_DIR/$WORKSPACE"
    BUILD_TARGET=("-workspace" "$TARGET_PATH")
    BUILD_TARGET_DISPLAY="-workspace $TARGET_PATH"
    PROJECT_NAME="$WORKSPACE"
else
    TARGET_TYPE="project"
    TARGET_PATH="$PROJECT_DIR/$PROJECT"
    BUILD_TARGET=("-project" "$TARGET_PATH")
    BUILD_TARGET_DISPLAY="-project $TARGET_PATH"
    PROJECT_NAME="$PROJECT"
fi

# Project name used for the DerivedData path (without the .xcworkspace or .xcodeproj extension).
PROJECT_BASENAME=$(basename "$PROJECT_NAME" | cut -d. -f1)

# ============================================================
# Step 2: Detect scheme
# ============================================================

if [ -n "$SCHEME_OVERRIDE" ]; then
    SCHEME="$SCHEME_OVERRIDE"
    echo "[SCHEME] $SCHEME (override)"
else
    SCHEME=$(xcodebuild "${BUILD_TARGET[@]}" -list -json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
container = data.get(sys.argv[1], {})
schemes = container.get("schemes", [])
project_name = sys.argv[2]
if project_name in schemes:
    print(project_name)
else:
    ignored = ("test", "widget", "pods", "firebase", "google")
    for candidate in schemes:
        if not any(word in candidate.lower() for word in ignored):
            print(candidate)
            break
' "$TARGET_TYPE" "$PROJECT_BASENAME" || true)

    if [ -z "$SCHEME" ]; then
        echo "[STATUS] NO_SCHEME"
        echo "No iOS app scheme found in $PROJECT_NAME"
        echo "Hint: specify one with --scheme: bash $0 --scheme YourSchemeName"
        exit 1
    fi

    echo "[SCHEME] $SCHEME (auto-detected)"
fi

acquire_run_lock "$PROJECT_DIR/.build-cli" || exit $?

# ============================================================
# Step 3: Check simulator
# ============================================================

SIM_OUTPUT=$("$SCRIPT_DIR/check-simulator.sh")
echo "$SIM_OUTPUT" | grep -E "^\[" | head -3

if echo "$SIM_OUTPUT" | grep -q "NO_SIMULATOR"; then
    echo "[STATUS] NO_SIMULATOR"
    exit 1
fi

UDID=$(echo "$SIM_OUTPUT" | grep "^\[UDID\]" | awk '{print $2}')

# ============================================================
# Step 4: Stop an existing build for this project only
# ============================================================

"$SCRIPT_DIR/kill-processes.sh" "--$TARGET_TYPE" "$TARGET_PATH" | grep -E "^\["

# ============================================================
# Step 5: Run build (capture full log)
# ============================================================

echo "[BUILDING]..."
START_TIME=$(date +%s)
NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
if [ "$NUM_CORES" -gt 8 ]; then NUM_CORES=8; fi

# Build while capturing output and optimizing speed (using .build-cli independently from the Xcode IDE).
xcodebuild build \
    "${BUILD_TARGET[@]}" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$PROJECT_DIR/.build-cli" \
    -configuration Debug \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ONLY_ACTIVE_ARCH=YES \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    -jobs "$NUM_CORES" \
    > "$BUILD_LOG" 2>&1 || BUILD_EXIT=$?

END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))

# ============================================================
# Step 6: Filter output to essential errors and warnings.
# ============================================================

# Split errors into two categories:
# - ERRORS_PROJECT: in the project source code (always printed)
# - ERRORS_DEPS: in Pods/SPM (printed only when the build fails so the user knows they need attention)
#
# Exclude:
# - Source-code strings (indentation > 8 spaces), for example: `sendLog("...error: ...")`
# - Pre-built framework (swiftinterface/swiftmodule, could not read priors)

# Errors in the project source code (excluding Pods/SPM).
# Do NOT limit the count: errors may cascade (error A can cause errors B, C, and so on).
# Show ALL errors to preserve context.
ERRORS_PROJECT=$(grep -E "error:" "$BUILD_LOG" \
    | grep -v -E "^[[:space:]]{8,}error:" \
    | grep -v -E "(swiftinterface|swiftmodule)" \
    | grep -v -E "could not read priors" \
    | grep -v -E "sendLog|print\(" \
    | grep -v -E "/Pods/|SourcePackages/|\.build/checkouts/" \
    | grep -v -E "in target '.*' from project '(Pods|.*Package)'" \
    || true)

# Errors in Pods/SPM (used only when the build fails).
ERRORS_DEPS=$(grep -E "error:" "$BUILD_LOG" \
    | grep -v -E "^[[:space:]]{8,}error:" \
    | grep -v -E "(swiftinterface|swiftmodule)" \
    | grep -v -E "could not read priors" \
    | grep -v -E "sendLog|print\(" \
    | grep -E "/Pods/|SourcePackages/|\.build/checkouts/|in target '.*' from project '(Pods|.*Package)'" \
    || true)

# Filter warnings similarly, excluding source-code strings, pre-built cache, and Pods/SPM.
# Limit warnings to 50 because they are less critical and often numerous.
WARNINGS=$(grep -E "warning:" "$BUILD_LOG" \
    | grep -v -E "^[[:space:]]{8,}warning:" \
    | grep -v -E "(swiftinterface|swiftmodule)" \
    | grep -v -E "DEBUG_INFORMATION_FORMAT" \
    | grep -v -E "Skipping duplicate build file" \
    | grep -v -E "no rule to process file" \
    | grep -v -E "Could not read priors" \
    | grep -v -E "sendLog|print\(" \
    | grep -v -E "/Pods/|SourcePackages/|\.build/checkouts/" \
    | grep -v -E "in target '.*' from project '(Pods|.*Package)'" \
    | head -50 || true)

ERROR_COUNT=$(echo "$ERRORS_PROJECT" | grep -c "error:" || true)
ERROR_DEPS_COUNT=$(echo "$ERRORS_DEPS" | grep -c "error:" || true)
WARNING_COUNT=$(echo "$WARNINGS" | grep -c "warning:" || true)

# Detect a corrupt cache: a nonzero build exit with no real errors, caused by a swiftinterface/swiftmodule cache.
HAS_CACHE_CORRUPT=$(grep -qE "(swiftinterface|swiftmodule).*error" "$BUILD_LOG" && echo "yes" || echo "no")

# ============================================================
# Step 7: Output
# ============================================================

if [ -z "${BUILD_EXIT:-}" ]; then
    echo ""
    echo "[STATUS] SUCCESS"
    echo "[BUILD_TIME] ${BUILD_TIME}s"
    echo "[ERRORS] $ERROR_COUNT"
    echo "[WARNINGS] $WARNING_COUNT"
    # Show only the count; warnings are not listed because errors are more important.

    # Also report a corrupt-cache warning if the build still succeeds.
    if [ "$HAS_CACHE_CORRUPT" = "yes" ]; then
        echo ""
        echo "[HINT] The build succeeded, but the pre-built cache is corrupt."
        echo "       Clean it to make the next build faster:"
        echo "       rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_BASENAME}-*"
        echo "       xcodebuild -resolvePackageDependencies $BUILD_TARGET_DISPLAY -scheme $SCHEME"
    fi

    exit 0
elif [ "$HAS_CACHE_CORRUPT" = "yes" ] \
    && [ "$ERROR_COUNT" -eq 0 ] \
    && [ "$ERROR_DEPS_COUNT" -eq 0 ]; then
    # The build failed only because of a corrupt cache, with no real errors.
    # Note: this does not guarantee that the source code is correct; it means no real errors were found.
    echo ""
    echo "[STATUS] CACHE_CORRUPT"
    echo "[BUILD_TIME] ${BUILD_TIME}s"
    echo "[ERRORS] 0 detected"
    echo ""
    echo "[HINT] A corrupt pre-built framework cache was detected."
    echo "       Run these commands in order:"
    echo "       1. rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_BASENAME}-*"
    echo "       2. xcodebuild -resolvePackageDependencies $BUILD_TARGET_DISPLAY -scheme $SCHEME"
    echo "       3. bash $0 --scheme $SCHEME"
    exit 2
else
    echo ""
    echo "[STATUS] FAILED"
    echo "[BUILD_TIME] ${BUILD_TIME}s"
    echo "[ERRORS] $ERROR_COUNT"
    echo "[ERRORS_DEPS] $ERROR_DEPS_COUNT"
    echo "[WARNINGS] $WARNING_COUNT"

    # Print errors from the project source code.
    if [ -n "$ERRORS_PROJECT" ] && [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo "[ERRORS]"
        echo "$ERRORS_PROJECT"
    fi

    # Print errors from Pods/SPM only when the build fails.
    if [ -n "$ERRORS_DEPS" ] && [ "$ERROR_DEPS_COUNT" -gt 0 ]; then
        echo ""
        echo "[ERRORS_DEPS] (Pods/SPM)"
        echo "$ERRORS_DEPS"
    fi
    # Show only the warning count; errors are more important.

    # If a corrupt pre-built framework cache caused the error, suggest a cleanup.
    if grep -qE "(swiftinterface|swiftmodule).*error" "$BUILD_LOG"; then
        echo ""
        echo "[HINT] The pre-built framework cache is corrupt."
        echo "       Run: rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_BASENAME}-*"
        echo "       Then: xcodebuild -resolvePackageDependencies $BUILD_TARGET_DISPLAY -scheme $SCHEME"
    fi

    exit 1
fi
