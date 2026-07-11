#!/bin/bash
#
# core/repo-lock.sh
#
# Handles restic's own repository-level lock (distinct from the
# framework's application-level lock in core/lock.sh, which only
# prevents two run.sh invocations from overlapping on THIS server).
#
# A killed backup (e.g. `systemctl stop` mid-transfer) can leave
# restic's repository lock behind even though the framework's own
# lock is released cleanly - this then silently blocks the next
# run's verification and retention steps.
#
# clear_stale_repo_locks() only removes a lock when it can positively
# confirm it's safe: the lock must have been created by THIS hostname
# AND its owning PID must be confirmed no longer running. A lock
# belonging to a different hostname is NEVER touched, even if its PID
# looks dead - this is what makes it safe when multiple servers share
# one repository (a "dead-looking" PID from this host's perspective
# may be alive and legitimate on another host).

clear_stale_repo_locks() {
    local lock_ids
    lock_ids="$(restic list locks 2>/dev/null)"

    if [[ -z "$lock_ids" ]]; then
        return 0
    fi

    local this_hostname
    this_hostname="$(hostname)"
    local cleared_any=false

    while IFS= read -r lock_id; do
        [[ -z "$lock_id" ]] && continue

        local lock_json lock_hostname lock_pid
        lock_json="$(restic cat lock "$lock_id" 2>/dev/null)"
        [[ -z "$lock_json" ]] && continue

        lock_hostname="$(jq -r '.hostname // empty' <<<"$lock_json")"
        lock_pid="$(jq -r '.pid // empty' <<<"$lock_json")"

        if [[ "$lock_hostname" != "$this_hostname" ]]; then
            echo "Repository lock $lock_id belongs to a different host ($lock_hostname) - leaving it alone." >&2
            continue
        fi

        if [[ -z "$lock_pid" ]]; then
            continue
        fi

        if kill -0 "$lock_pid" 2>/dev/null; then
            echo "Repository lock $lock_id belongs to PID $lock_pid on this host, which is still running - leaving it alone." >&2
            continue
        fi

        echo "Repository lock $lock_id belongs to PID $lock_pid on this host, which is no longer running - clearing it." >&2
        cleared_any=true
    done <<< "$lock_ids"

    if $cleared_any; then
        restic unlock >&2
    fi
}