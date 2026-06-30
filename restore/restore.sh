#!/bin/bash
#
# restore/restore.sh
#
# Restores a snapshot from the configured repository to a target
# directory. Deliberately refuses to restore onto "/" — true in-place
# disaster recovery is a separate, more heavily-guarded path, not the
# default behavior here. Requires an explicit target and an explicit
# snapshot ID, never silently assumes "latest".

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"

source "$FRAMEWORK_ROOT/core/config-loader.sh"

list_snapshots() {
    restic snapshots
}

restore_snapshot() {
    local snapshot_id="${1:?snapshot ID required}"
    local target="${2:?target directory required}"

    if [[ "$target" == "/" ]]; then
        echo "FATAL: refusing to restore directly onto / — restore to a separate target directory instead." >&2
        return 1
    fi

    mkdir -p "$target"

    echo "Restoring snapshot $snapshot_id to $target ..."
    if ! restic restore "$snapshot_id" --target "$target"; then
        echo "FATAL: restic restore failed" >&2
        return 1
    fi

    echo "Restore complete: $snapshot_id -> $target"
    return 0
}

main() {
    local config_path="${1:-/etc/backup-framework/backup.conf}"
    local snapshot_id="${2:?Usage: restore.sh <config_path> <snapshot_id> <target_dir>}"
    local target="${3:?Usage: restore.sh <config_path> <snapshot_id> <target_dir>}"

    if ! load_config "$config_path"; then
        echo "FATAL: could not load config from $config_path" >&2
        exit 1
    fi

    if ! load_config "$SECRETS_FILE"; then
        echo "FATAL: could not load secrets from $SECRETS_FILE" >&2
        exit 1
    fi

    case "$DEST_TYPE" in
        local)
            source "$FRAMEWORK_ROOT/destinations/local.sh"
            ;;
        sftp)
            source "$FRAMEWORK_ROOT/destinations/sftp.sh"
            ;;
        *)
            echo "FATAL: destination type '$DEST_TYPE' is not yet implemented" >&2
            exit 1
            ;;
    esac

    export RESTIC_REPOSITORY="$(repository_string)"

    restore_snapshot "$snapshot_id" "$target"
}

main "$@"

