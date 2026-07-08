#!/bin/bash
#
# core/retry.sh
#
# Wraps the restic backup call with automatic retry on two distinct
# failure modes:
#   1. Abrupt failures (broken pipe, connection reset) - detected via
#      restic's own error output on stderr.
#   2. Silent stalls (e.g. a VPN/Tailscale interface disappearing
#      cleanly, with no error ever surfacing) - detected via a
#      stall-timeout watchdog that kills and retries if no progress
#      output has been written for RESTIC_STALL_TIMEOUT_SECONDS.
#
# Since this retry loop lives inside a single run.sh execution (called
# once per systemd start), manifest generation and the database dump -
# which already ran once before this function is called - are never
# redundantly re-run on a retry within this loop. A deliberate
# `systemctl stop` still kills the whole process and a subsequent
# `systemctl start` will redo those stages from scratch - that's
# expected; this only protects against transient/silent network
# failures the process survives internally.
#
# restic is launched via `setsid` so it becomes the leader of its own
# process group - this lets the watchdog kill the entire group
# (including any SSH/SFTP child processes) on a stall, rather than
# leaving orphaned child processes behind.
#
# Sourced by backup/run.sh. Depends on render_backup_progress()
# from core/progress.sh, and the same config vars run.sh already loads
# (BACKUP_SOURCE, EXCLUDE_FILE, BACKUP_COMPRESSION, LOCK_RETRY_SECONDS,
# SERVER_NAME).
#
# Tunable via environment/config: RESTIC_RETRY_MAX_ATTEMPTS (default 5),
# RESTIC_RETRY_BASE_DELAY (default 10s), RESTIC_STALL_TIMEOUT_SECONDS
# (default 300s / 5min), RESTIC_STALL_POLL_SECONDS (default 15s).

run_restic_backup_with_retry() {
    local max_attempts="${RESTIC_RETRY_MAX_ATTEMPTS:-5}"
    local base_delay="${RESTIC_RETRY_BASE_DELAY:-10}"
    local stall_timeout="${RESTIC_STALL_TIMEOUT_SECONDS:-300}"
    local poll_interval="${RESTIC_STALL_POLL_SECONDS:-15}"
    local attempt=1

    while (( attempt <= max_attempts )); do
        echo "Running restic backup (attempt $attempt/$max_attempts)..."
        local json_log stderr_log
        json_log="$(mktemp)"
        stderr_log="$(mktemp)"

        setsid restic backup "$BACKUP_SOURCE" \
            --exclude-file="$EXCLUDE_FILE" \
            --exclude-caches \
            --compression "$BACKUP_COMPRESSION" \
            --retry-lock "${LOCK_RETRY_SECONDS}s" \
            --tag "${SERVER_NAME}-daily" \
            --json \
            >"$json_log" 2>"$stderr_log" &
        local restic_pid=$!

        tail -n +1 -f "$json_log" 2>/dev/null | render_backup_progress &
        local tail_pid=$!

        local last_size=0 last_change_time
        last_change_time="$(date +%s)"
        local stalled=false

        while kill -0 "$restic_pid" 2>/dev/null; do
            sleep "$poll_interval"
            local current_size now
            current_size="$(stat -c %s "$json_log" 2>/dev/null || echo 0)"
            now="$(date +%s)"
            if (( current_size > last_size )); then
                last_size="$current_size"
                last_change_time="$now"
            elif (( now - last_change_time >= stall_timeout )); then
                echo "" >&2
                echo "WARNING: no backup progress for ${stall_timeout}s - possible silent connection loss (e.g. VPN/Tailscale interface down). Killing this attempt and retrying." >&2
                kill -TERM -"$restic_pid" 2>/dev/null
                sleep 2
                kill -KILL -"$restic_pid" 2>/dev/null
                stalled=true
                break
            fi
        done

        wait "$restic_pid" 2>/dev/null
        local restic_exit=$?
        kill "$tail_pid" 2>/dev/null
        wait "$tail_pid" 2>/dev/null

        local stderr_content
        stderr_content="$(cat "$stderr_log" 2>/dev/null)"
        echo "$stderr_content" >&2

        if (( restic_exit == 0 )) && ! $stalled; then
            rm -f "$json_log" "$stderr_log"
            return 0
        fi

        local retryable=false
        if $stalled; then
            retryable=true
        elif grep -qiE "connection lost|broken pipe|client_loop|i/o timeout|connection reset by peer|unexpected EOF" <<<"$stderr_content"; then
            retryable=true
        fi
        rm -f "$json_log" "$stderr_log"

        if $retryable; then
            if (( attempt < max_attempts )); then
                local delay=$(( base_delay * (2 ** (attempt - 1)) ))
                echo "WARNING: backup failed due to what looks like a connection issue. Retrying in ${delay}s (attempt $((attempt+1))/$max_attempts)..." >&2
                sleep "$delay"
            fi
        else
            echo "FATAL: restic backup failed with a non-retryable error. Not retrying." >&2
            return 1
        fi

        ((attempt++))
    done

    echo "FATAL: restic backup failed after $max_attempts attempts, giving up." >&2
    return 1
}