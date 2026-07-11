#!/bin/bash
#
# backup/run.sh
#
# The actual unattended backup entrypoint. Foundation (config,
# secrets, lock, destination) plus manifest generation and database
# dumps. The restic backup call and retention come in the next step.
# Cleans up (releases the lock) no matter how the script exits.

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"

source "$FRAMEWORK_ROOT/core/config-loader.sh"
source "$FRAMEWORK_ROOT/core/lock.sh"
source "$FRAMEWORK_ROOT/manifest/generate.sh"
source "$FRAMEWORK_ROOT/database/postgresql.sh"
source "$FRAMEWORK_ROOT/core/progress.sh"
source "$FRAMEWORK_ROOT/core/retry.sh"
source "$FRAMEWORK_ROOT/core/repo-lock.sh"

cleanup() {
    release_lock
}
trap cleanup EXIT

main() {
    local config_path="${1:-/etc/backup-framework/backup.conf}"
    local db_dump_failed=0
    local verify_failed=0
    local retention_failed=0

    echo "=== Backup run starting ==="

    if ! load_config "$config_path"; then
        echo "FATAL: could not load config from $config_path" >&2
        exit 1
    fi

    if ! load_config "$SECRETS_FILE"; then
        echo "FATAL: could not load secrets from $SECRETS_FILE" >&2
        exit 1
    fi

    if ! acquire_lock "$LOCK_FILE" "$LOCK_RETRY_SECONDS"; then
        echo "FATAL: another backup run appears to be in progress" >&2
        exit 1
    fi

    case "$DEST_TYPE" in
        local)
            source "$FRAMEWORK_ROOT/destinations/local.sh"
            ;;
        sftp)
            source "$FRAMEWORK_ROOT/destinations/sftp.sh"
            ;;
	rclone)
            source "$FRAMEWORK_ROOT/destinations/rclone.sh"
            ;;
        *)
            echo "FATAL: destination type '$DEST_TYPE' is not yet implemented" >&2
            exit 1
            ;;
    esac

    if ! setup_destination; then
        echo "FATAL: could not prepare destination" >&2
        exit 1
    fi

    if [[ "$MANIFEST_ENABLED" == "true" ]]; then
        echo "Preparing manifest directory: $MANIFEST_DIR"
        rm -rf "$MANIFEST_DIR"
        mkdir -p "$MANIFEST_DIR"

        if ! generate_manifest > "$MANIFEST_DIR/manifest.json"; then
            echo "FATAL: manifest generation failed" >&2
            exit 1
        fi
        echo "Manifest written to $MANIFEST_DIR/manifest.json"
    else
        echo "Manifest generation disabled by config, skipping."
    fi

    if [[ "$DB_MODE" == "auto" || "$DB_MODE" == "manual" ]]; then
        echo "Preparing dump directory: $DUMP_DIR"
        rm -rf "$DUMP_DIR"
        mkdir -p "$DUMP_DIR"

        if ! dump_postgresql_clusters "$DUMP_DIR" "$DB_POSTGRES_SKIP_PORTS"; then
            echo "WARNING: one or more database dumps failed, continuing with filesystem backup anyway" >&2
            db_dump_failed=1
        fi
    else
        echo "Database dumps disabled by config (DB_MODE=$DB_MODE), skipping."
    fi

    echo "=== Manifest + database stage complete (db_dump_failed=$db_dump_failed) ==="

    if ! run_restic_backup_with_retry; then
        echo "FATAL: restic backup failed" >&2
        exit 1
    fi

    # A backup killed mid-write (e.g. systemctl stop) can leave restic's own
    # repository lock behind even though our application-level lock released
    # cleanly - this would otherwise silently block verification/retention
    # below. Only clears a lock confirmed to belong to this host with a
    # confirmed-dead PID; never touches a lock that might belong to another
    # server sharing this repository.
    clear_stale_repo_locks

    if [[ "$VERIFY_BACKUP" == "true" ]]; then
        echo "Verifying repository structure..."
        if ! restic check; then
            echo "WARNING: repository structural check failed after backup" >&2
            verify_failed=1
        fi
    fi

    if [[ "$RETENTION_ENABLED" == "true" ]]; then
        echo "Applying retention policy: keep last $RETENTION_DAILY daily snapshots..."
        if ! restic forget --keep-daily "$RETENTION_DAILY" --prune; then
            echo "WARNING: retention/prune step failed" >&2
            retention_failed=1
        fi
    else
        echo "Retention disabled by config, skipping cleanup."
    fi

    if [[ "$verify_failed" -eq 1 || "$retention_failed" -eq 1 ]]; then
        echo "=== Backup run complete WITH WARNINGS (db_dump_failed=$db_dump_failed, verify_failed=$verify_failed, retention_failed=$retention_failed) ==="
        echo "The backup itself succeeded, but one or more post-backup safety steps did not complete."
        echo "Review the WARNING lines above - this needs attention, not just the overall success message."
    else
        echo "=== Backup run complete (db_dump_failed=$db_dump_failed) ==="
    fi
}

main "$@"
