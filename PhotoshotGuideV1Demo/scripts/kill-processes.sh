#!/bin/bash
# Stop only a previous xcodebuild invocation for the supplied workspace/project.
# Its descendants are stopped recursively; unrelated compiler and Xcode processes
# are never searched for or killed.

set -euo pipefail

if [ "$#" -ne 2 ] || { [ "$1" != "--workspace" ] && [ "$1" != "--project" ]; }; then
    echo "Usage: $0 (--workspace|--project) /absolute/path/to/target" >&2
    exit 1
fi

TARGET_FLAG="$1"
TARGET_PATH="$2"
xcode_target_flag="-${TARGET_FLAG#--}"
PIDS=()

while read -r PID OWNER COMMAND; do
    [ "$OWNER" = "$USER" ] || continue
    [[ "$COMMAND" =~ (^|[[:space:]])([^[:space:]]*/)?xcodebuild([[:space:]]|$) ]] || continue
    [[ "$COMMAND" == *"$xcode_target_flag $TARGET_PATH"* ]] || continue
    PIDS+=("$PID")
done < <(ps -axo pid=,user=,command=)

stop_process_tree() {
    local pid="$1"
    local signal="$2"
    local child_pids

    child_pids=$(pgrep -P "$pid" 2>/dev/null || true)
    for child_pid in $child_pids; do
        stop_process_tree "$child_pid" "$signal"
    done
    kill "-$signal" "$pid" 2>/dev/null || true
}

if [ "${#PIDS[@]}" -eq 0 ]; then
    echo "[OK] No previous build for $TARGET_PATH"
    exit 0
fi

for PID in "${PIDS[@]}"; do
    echo "[STOPPING] Previous build for $TARGET_PATH (PID $PID)"
    stop_process_tree "$PID" TERM
done

sleep 1

for PID in "${PIDS[@]}"; do
    if kill -0 "$PID" 2>/dev/null; then
        echo "[FORCING] Previous build for $TARGET_PATH (PID $PID)"
        stop_process_tree "$PID" KILL
    fi
done

echo "[STOPPED] ${#PIDS[@]} previous build(s)"
