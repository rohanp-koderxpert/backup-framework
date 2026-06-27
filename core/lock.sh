#!/bin/bash
#
# core/lock.sh
#
# Prevents two backup runs from executing at the same time on this
# server (e.g. a slow manual run still active when the scheduled
# timer fires). Uses flock, which ties the lock to an open file
# descriptor — it's automatically released the moment the process
# holding it exits, even if it crashes, so a dead run can never
# leave a permanent stale lock behind.

set -uo pipefail

DEFAULT_LOCK_FILE="/run/backup-framework.lock"
DEFAULT_LOCK_RETRY_SECONDS=600

acquire_lock() {
    local lock_file="${1:-$DEFAULT_LOCK_FILE}"
    local timeout="${2:-$DEFAULT_LOCK_RETRY_SECONDS}"

    exec {LOCK_FD}>"$lock_file"

    if ! flock -w "$timeout" "$LOCK_FD"; then
        echo "ERROR: could not acquire lock on $lock_file after waiting ${timeout}s. Another backup run appears to still be in progress." >&2
        exec {LOCK_FD}>&-
        unset LOCK_FD
        return 1
    fi

    echo "Lock acquired: $lock_file (fd $LOCK_FD)"
    return 0
}

release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&-
        echo "Lock released."
    fi
}
