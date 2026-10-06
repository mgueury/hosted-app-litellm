#!/usr/bin/env bash
#
# Serialize OCI Starter commands that change infrastructure or deployments.
# This uses mkdir instead of flock so it works on the macOS build hosts used by
# OCI Starter and leaves useful diagnostic metadata for a waiting operator.

BUILD_LOCK_DIR=""

# -- build_lock_acquire -----------------------------------------------------
build_lock_acquire() {
    local command_name="$1"

    if [ -z "${TARGET_DIR:-}" ]; then
        echo "ERROR: TARGET_DIR must be set before acquiring the build lock" >&2
        return 1
    fi

    BUILD_LOCK_DIR="$TARGET_DIR/build.lock"
    if [ -e "$BUILD_LOCK_DIR" ]; then
        build_lock_unlock_stale || return 1
    fi

    if ! (umask 077; mkdir "$BUILD_LOCK_DIR") 2>/dev/null; then
        echo "ERROR: could not acquire OCI Starter build lock: $BUILD_LOCK_DIR" >&2
        return 1
    fi

    if ! (
        umask 077
        printf '%s\n' "$$" > "$BUILD_LOCK_DIR/pid"
        printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$BUILD_LOCK_DIR/started_at"
        printf '%s\n' "$command_name" > "$BUILD_LOCK_DIR/command"
    ); then
        echo "ERROR: could not write OCI Starter build lock metadata" >&2
        rm -rf "$BUILD_LOCK_DIR"
        return 1
    fi
}

# -- build_lock_release -----------------------------------------------------
build_lock_release() {
    if [ ! -d "$BUILD_LOCK_DIR" ]; then
        return 0
    fi
    rm -rf "$BUILD_LOCK_DIR"
}

# -- build_lock_register_cleanup --------------------------------------------
build_lock_register_cleanup() {
    trap 'build_lock_release' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

# -- build_lock_unlock_stale ------------------------------------------------
build_lock_unlock_stale() {
    local lock_pid

    if [ -z "${TARGET_DIR:-}" ]; then
        echo "ERROR: TARGET_DIR must be set before unlocking the build lock" >&2
        return 1
    fi

    BUILD_LOCK_DIR="$TARGET_DIR/build.lock"
    if [ ! -e "$BUILD_LOCK_DIR" ]; then
        return 0
    fi

    if [ ! -d "$BUILD_LOCK_DIR" ]; then
        echo "ERROR: OCI Starter build lock is not a directory: $BUILD_LOCK_DIR" >&2
        return 1
    fi

    lock_pid="$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || true)"
    if ! [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: OCI Starter build lock has no valid PID: $BUILD_LOCK_DIR" >&2
        return 1
    fi

    if kill -0 "$lock_pid" 2>/dev/null; then
        echo "ERROR: OCI Starter build command is still running (PID $lock_pid): $BUILD_LOCK_DIR" >&2
        return 1
    fi

    build_lock_release
    echo "Removed stale OCI Starter build lock from dead PID $lock_pid."
}
