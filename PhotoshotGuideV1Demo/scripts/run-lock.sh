#!/bin/bash
# Source this file to serialize build and test runs that share a DerivedData cache.

RUN_LOCK_PATH=""

acquire_run_lock() {
    local cache_path="$1"
    local holder_pid

    mkdir -p "$cache_path"
    RUN_LOCK_PATH="$cache_path/.xcodebuild-runner.lock"

    if mkdir "$RUN_LOCK_PATH" 2>/dev/null; then
        printf '%s\n' "$$" > "$RUN_LOCK_PATH/pid"
        return 0
    fi

    holder_pid=$(sed -n '1p' "$RUN_LOCK_PATH/pid" 2>/dev/null || true)
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
        echo "[STATUS] BUSY"
        echo "[ACTIVE_PID] $holder_pid"
        echo "Another build or test is already using $cache_path."
        return 4
    fi

    rm -f "$RUN_LOCK_PATH/pid"
    rmdir "$RUN_LOCK_PATH" 2>/dev/null || {
        echo "[STATUS] BUSY"
        echo "Could not reclaim lock $RUN_LOCK_PATH."
        return 4
    }
    mkdir "$RUN_LOCK_PATH" || return 4
    printf '%s\n' "$$" > "$RUN_LOCK_PATH/pid"
}

release_run_lock() {
    [ -n "$RUN_LOCK_PATH" ] || return 0
    rm -f "$RUN_LOCK_PATH/pid"
    rmdir "$RUN_LOCK_PATH" 2>/dev/null || true
}
