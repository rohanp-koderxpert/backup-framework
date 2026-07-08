#!/bin/bash
#
# core/retry.sh
#
# Wraps the restic backup call with automatic retry on transient
# connection failures. Since this retry loop lives inside a single
# run.sh execution (called once per systemd start), manifest generation
# and the database dump — which already ran once before this function
# is called — are never redundantly re-run on a connection-loss retry.
# A deliberate `systemctl stop` still kills the whole process and a
# subsequent `systemctl start` will redo those stages from scratch —
# that's expected; this only protects against transient network drops
# the process survives internally.
#
# Sourced by backup/run.sh. Depends on render_backup_progress()
# from core/progress.sh, and the same config vars run.sh already loads
# (BACKUP_SOURCE, EXCLUDE_FILE, BACKUP_COMPRESSION, LOCK_RETRY_SECONDS,
# SERVER_NAME).

run_restic_backup_with_retry() {
    local max_attempts="${RESTIC_RETRY_MAX_ATTEMPTS:-5}"
    local base_delay="${RESTIC_RETRY_BASE_DELAY:-10}"
    local attempt=1
    local stderr_log

    while (( attempt <= max_attempts )); do
        echo "Running restic backup (attempt $attempt/$max_attempts)..."
        stderr_log="$(mktemp)"

        if restic backup "$BACKUP_SOURCE" \
            --exclude-file="$EXCLUDE_FILE" \
            --exclude-caches \
            --compression "$BACKUP_COMPRESSION" \
            --retry-lock "${LOCK_RETRY_SECONDS}s" \
            --tag "${SERVER_NAME}-daily" \
            --json \
            2>"$stderr_log" \
            | render_backup_progress; then
            cat "$stderr_log" >&2
            rm -f "$stderr_log"
            return 0
        fi

        cat "$stderr_log" >&2

        if grep -qiE "connection lost|broken pipe|client_loop|i/o timeout|connection reset by peer|unexpected EOF" "$stderr_log"; then
            rm -f "$stderr_log"
            if (( attempt < max_attempts )); then
                local delay=$(( base_delay * (2 ** (attempt - 1)) ))
                echo "WARNING: backup failed due to what looks like a connection issue. Retrying in ${delay}s (attempt $((attempt+1))/$max_attempts)..." >&2
                sleep "$delay"
            fi
        else
            echo "FATAL: restic backup failed with a non-retryable error. Not retrying." >&2
            rm -f "$stderr_log"
            return 1
        fi

        ((attempt++))
    done

    echo "FATAL: restic backup failed after $max_attempts attempts, giving up." >&2
    return 1
}