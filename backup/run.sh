#!/bin/bash
#
# backup/run.sh
#
# The actual unattended backup entrypoint. This first version proves
# the foundation: load config, load secrets (same validated shape as
# config), acquire the concurrency lock, prepare the configured
# destination. Manifest generation, database dumps, the restic
# backup itself, and retention are wired in in later steps. Cleans up
# (releases the lock) no matter how the script exits.

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"

source "$FRAMEWORK_ROOT/core/config-loader.sh"
source "$FRAMEWORK_ROOT/core/lock.sh"

cleanup() {
    release_lock
}
trap cleanup EXIT

main() {
    local config_path="${1:-/etc/backup-framework/backup.conf}"

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
        *)
            echo "FATAL: destination type '$DEST_TYPE' is not yet implemented" >&2
            exit 1
            ;;
    esac

    if ! setup_destination; then
        echo "FATAL: could not prepare destination" >&2
        exit 1
    fi

    echo "=== Foundation complete: config loaded, secrets loaded, lock held, destination ready ==="
    echo "=== (manifest, database dump, restic backup, retention come next) ==="
}

main "$@"
