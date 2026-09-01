#!/bin/bash
# Runs XCTest on a booted simulator with concise, actionable output.
set -euo pipefail

scheme_override=""
only_testing=()
timeout_seconds="${XCODEBUILD_TEST_TIMEOUT:-300}"

usage() {
    echo "Usage: $0 [--scheme NAME] [--only-testing IDENTIFIER]... [--timeout SECONDS]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scheme)
            [ "$#" -ge 2 ] || { usage; exit 1; }
            scheme_override="$2"
            shift 2
            ;;
        --scheme=*) scheme_override="${1#*=}"; shift ;;
        --only-testing)
            [ "$#" -ge 2 ] || { usage; exit 1; }
            only_testing+=("$2")
            shift 2
            ;;
        --only-testing=*) only_testing+=("${1#*=}"); shift ;;
        --timeout)
            [ "$#" -ge 2 ] || { usage; exit 1; }
            timeout_seconds="$2"
            shift 2
            ;;
        --timeout=*) timeout_seconds="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "[STATUS] UNKNOWN_ARG"
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "[STATUS] INVALID_TIMEOUT"
    echo "--timeout must be a positive number of seconds."
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(pwd)"
test_log=$(mktemp -t xcodebuild_test_log)
timeout_marker=$(mktemp -t xcodebuild_test_timeout)
rm -f "$timeout_marker"
source "$script_dir/run-lock.sh"

cleanup() {
    rm -f "$test_log" "$timeout_marker"
    release_run_lock
}
trap cleanup EXIT

workspace=$(ls -d *.xcworkspace 2>/dev/null | head -1 || true)
project=$(ls -d *.xcodeproj 2>/dev/null | head -1 || true)
if [ -z "$workspace" ] && [ -z "$project" ]; then
    echo "[STATUS] NO_PROJECT"
    echo "No .xcworkspace or .xcodeproj found in $project_dir"
    exit 1
fi

if [ -n "$workspace" ]; then
    target_type="workspace"
    target_path="$project_dir/$workspace"
    build_target=("-workspace" "$target_path")
    project_name="$workspace"
else
    target_type="project"
    target_path="$project_dir/$project"
    build_target=("-project" "$target_path")
    project_name="$project"
fi
project_basename="${project_name%%.*}"

if [ -n "$scheme_override" ]; then
    scheme="$scheme_override"
    echo "[SCHEME] $scheme (override)"
else
    scheme=$(xcodebuild "${build_target[@]}" -list -json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
schemes = data.get(sys.argv[1], {}).get("schemes", [])
project_name = sys.argv[2]
if project_name in schemes:
    print(project_name)
else:
    ignored = ("test", "widget", "pods", "firebase", "google")
    for candidate in schemes:
        if not any(word in candidate.lower() for word in ignored):
            print(candidate)
            break
' "$target_type" "$project_basename" || true)
    if [ -z "$scheme" ]; then
        echo "[STATUS] NO_SCHEME"
        echo "No app scheme was found in $project_name; pass --scheme NAME."
        exit 1
    fi
    echo "[SCHEME] $scheme (auto-detected)"
fi

acquire_run_lock "$project_dir/.build-cli" || exit $?

sim_output=$("$script_dir/check-simulator.sh")
echo "$sim_output" | grep -E '^\[' | head -3
if echo "$sim_output" | grep -q 'NO_SIMULATOR'; then
    echo "[STATUS] NO_SIMULATOR"
    exit 1
fi
udid=$(echo "$sim_output" | awk '/^\[UDID\]/{print $2}')

"$script_dir/kill-processes.sh" "--$target_type" "$target_path" | grep -E '^\['

test_selection_args=()
if [ "${#only_testing[@]}" -gt 0 ]; then
    for identifier in "${only_testing[@]}"; do
        test_selection_args+=("-only-testing:$identifier")
    done
fi

cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
if [ "$cores" -gt 8 ]; then jobs=8; else jobs="$cores"; fi

echo "[TESTING]..."
start_time=$(date +%s)
test_exit=0
test_command=(
    xcodebuild test
    "${build_target[@]}"
    -scheme "$scheme"
    -destination "platform=iOS Simulator,id=$udid"
    -derivedDataPath "$project_dir/.build-cli"
    -configuration Debug
    -parallel-testing-enabled NO
    -maximum-concurrent-test-simulator-destinations 1
    COMPILER_INDEX_STORE_ENABLE=NO
    ONLY_ACTIVE_ARCH=YES
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO
    -jobs "$jobs"
)
if [ "${#test_selection_args[@]}" -gt 0 ]; then
    test_command+=("${test_selection_args[@]}")
fi
"${test_command[@]}" > "$test_log" 2>&1 &
xcodebuild_pid=$!
(
    sleep "$timeout_seconds"
    if kill -0 "$xcodebuild_pid" 2>/dev/null; then
        touch "$timeout_marker"
        "$script_dir/kill-processes.sh" "--$target_type" "$target_path" >> "$test_log" 2>&1
    fi
) &
watchdog_pid=$!
wait "$xcodebuild_pid" 2>/dev/null || test_exit=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
end_time=$(date +%s)
test_time=$((end_time - start_time))

test_summary=$(grep -E 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" | tail -1 || true)
test_count=$(printf '%s\n' "$test_summary" | sed -nE 's/.*Executed ([0-9]+) tests?, with.*/\1/p')
failure_count=$(printf '%s\n' "$test_summary" | sed -nE 's/.*with ([0-9]+) failures?.*/\1/p')
test_count=${test_count:-0}
failure_count=${failure_count:-0}
compile_errors=$(grep -E 'error:' "$test_log" | grep -v -E '^[[:space:]]{8,}error:|swiftinterface|swiftmodule|could not read priors|sendLog|print\(|/Pods/|SourcePackages/|\.build/checkouts/' || true)
test_failures=$(grep -E "Test Case '.*' failed|:[0-9]+: error:" "$test_log" || true)
warnings=$(grep -E 'warning:' "$test_log" | grep -v -E '^[[:space:]]{8,}warning:|swiftinterface|swiftmodule|DEBUG_INFORMATION_FORMAT|Skipping duplicate build file|no rule to process file|Could not read priors|/Pods/|SourcePackages/|\.build/checkouts/' | head -50 || true)
compile_error_count=$(printf '%s\n' "$compile_errors" | grep -c 'error:' || true)
warning_count=$(printf '%s\n' "$warnings" | grep -c 'warning:' || true)
cache_corrupt=no
grep -qE '(swiftinterface|swiftmodule).*error' "$test_log" && cache_corrupt=yes || true

echo
if [ -f "$timeout_marker" ]; then
    echo "[STATUS] TIMEOUT"
    echo "[TEST_TIME] ${test_time}s"
    echo "[HINT] The run exceeded ${timeout_seconds}s and was stopped to release simulator resources."
    exit 3
fi
if [ "$test_exit" -eq 0 ]; then
    echo "[STATUS] SUCCESS"
    echo "[TESTS] $test_count"
    echo "[FAILURES] 0"
    echo "[ERRORS] $compile_error_count"
    echo "[WARNINGS] $warning_count"
    echo "[TEST_TIME] ${test_time}s"
    exit 0
fi
if [ "$cache_corrupt" = yes ] && [ "$compile_error_count" -eq 0 ]; then
    echo "[STATUS] CACHE_CORRUPT"
    echo "[TEST_TIME] ${test_time}s"
    echo "[HINT] A pre-built framework cache error was detected."
    exit 2
fi

echo "[STATUS] FAILED"
echo "[TESTS] $test_count"
echo "[FAILURES] $failure_count"
echo "[ERRORS] $compile_error_count"
echo "[WARNINGS] $warning_count"
echo "[TEST_TIME] ${test_time}s"
if [ -n "$test_failures" ]; then
    echo
    echo "[TEST_FAILURES]"
    echo "$test_failures"
fi
if [ -n "$compile_errors" ]; then
    echo
    echo "[ERRORS]"
    echo "$compile_errors"
fi
exit 1
