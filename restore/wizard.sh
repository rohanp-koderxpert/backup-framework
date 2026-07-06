#!/bin/bash
#
# restore/wizard.sh
#
# Single-command disaster recovery restore. Lists available snapshots,
# lets the operator pick one, restores it to a target directory, then
# runs validate.sh automatically to confirm the restore succeeded.

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"

source "$FRAMEWORK_ROOT/core/config-loader.sh"

main() {
    local config_path="${1:-/etc/backup-framework/backup.conf}"

    echo "=== Backup Framework Restore Wizard ==="

    if ! load_config "$config_path"; then
        echo "FATAL: could not load config from $config_path" >&2
        exit 1
    fi

    if ! load_config "$SECRETS_FILE"; then
        echo "FATAL: could not load secrets from $SECRETS_FILE" >&2
        exit 1
    fi

    case "$DEST_TYPE" in
        local)  source "$FRAMEWORK_ROOT/destinations/local.sh" ;;
        sftp)   source "$FRAMEWORK_ROOT/destinations/sftp.sh" ;;
        rclone) source "$FRAMEWORK_ROOT/destinations/rclone.sh" ;;
        *)
            echo "FATAL: destination type '$DEST_TYPE' not implemented" >&2
            exit 1
            ;;
    esac

    export RESTIC_REPOSITORY="$(repository_string)"

    echo ""
    echo "Available snapshots:"
    restic snapshots --compact
    echo ""

    local snapshot_id
    read -rp "Snapshot ID to restore [latest]: " snapshot_id
    snapshot_id="${snapshot_id:-latest}"

    local default_target="/tmp/restore-$(date +%Y%m%d-%H%M%S)"
    local target
    read -rp "Restore target directory [$default_target]: " target
    target="${target:-$default_target}"

    if [[ "$target" == "/" ]]; then
        echo "FATAL: refusing to restore directly onto /" >&2
        exit 1
    fi

    local available_kb
    available_kb="$(df -k "$(dirname "$target")" | awk 'NR==2{print $4}')"
    local available_gb=$(( available_kb / 1048576 ))
    echo ""
    echo "Available space at target location: ${available_gb}GB"
    echo "Snapshot to restore:                $snapshot_id"
    echo "Target directory:                   $target"
    echo ""
    read -rp "Proceed with restore? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled."
        exit 0
    fi

    echo ""
    echo "=== Starting restore ==="
    mkdir -p "$target"

    if ! restic restore "$snapshot_id" --target "$target"; then
        echo "FATAL: restic restore failed" >&2
        exit 1
    fi

    echo ""
    echo "Restore complete: $snapshot_id -> $target"

    echo ""
    echo "=== Running restore validation ==="

    local original_manifest="$target/var/backups/backup-framework/manifest/manifest.json"

    if [[ ! -f "$original_manifest" ]]; then
        echo "WARNING: no manifest found inside restored snapshot at:"
        echo "  $original_manifest"
        echo "Skipping validation. This snapshot may predate manifest generation."
        exit 0
    fi

    source "$FRAMEWORK_ROOT/manifest/generate.sh"
    export SERVER_NAME="${SERVER_NAME:-$(hostname)}"

    local current_manifest
    current_manifest="/tmp/current-manifest-$(date +%Y%m%d%H%M%S).json"
    echo "Generating fresh manifest from current system..."
    generate_manifest > "$current_manifest"

    source "$FRAMEWORK_ROOT/restore/validate.sh"
    if validate_restore "$original_manifest" "$current_manifest"; then
        echo ""
        echo "=== Restore complete and validated ==="
        echo "All checks passed."
    else
        echo ""
        echo "=== Restore complete with validation issues ==="
        echo "Review the failures above before putting this server into service."
    fi

    rm -f "$current_manifest"
}

main "$@"
