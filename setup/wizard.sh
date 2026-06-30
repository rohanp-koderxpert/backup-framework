#!/bin/bash
#
# setup/wizard.sh
#
# Interactive first-time setup. This first piece only handles the
# safety entry point: detect whether a config already exists, and if
# so, never silently overwrite it — ask the operator explicitly
# whether to reconfigure, just view current settings, or cancel.

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"
CONFIG_PATH="/etc/backup-framework/backup.conf"

source "$FRAMEWORK_ROOT/core/config-loader.sh"

check_existing_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "No existing configuration found at $CONFIG_PATH. Proceeding with first-time setup."
        return 0
    fi

    echo "An existing configuration was found at $CONFIG_PATH."
    if load_config "$CONFIG_PATH" 2>/dev/null; then
        echo "  Server name:        ${SERVER_NAME:-<unset>}"
        echo "  Destination type:   ${DEST_TYPE:-<unset>}"
        echo "  Retention (daily):  ${RETENTION_DAILY:-<unset>}"
        echo "  Schedule:           ${SCHEDULE_TIME:-<unset>} (+/- ${SCHEDULE_JITTER_MINUTES:-0} min jitter)"
    else
        echo "  (existing config could not be parsed for preview)"
    fi

    echo ""
    echo "What would you like to do?"
    echo "  1) Reconfigure (overwrite existing settings)"
    echo "  2) View only (no changes, exit now)"
    echo "  3) Cancel"
    read -rp "Enter choice [1-3]: " choice

    case "$choice" in
        1)
            echo "Proceeding to reconfigure."
            return 0
            ;;
        2)
            echo "No changes made."
            return 1
            ;;
        *)
            echo "Cancelled."
            return 1
            ;;
    esac
}

prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local input
    read -rp "$prompt_text [$default_value]: " input
    echo "${input:-$default_value}"
}

collect_essentials() {
    echo ""
    echo "=== Essential configuration ==="

    SERVER_NAME=""
    while [[ -z "$SERVER_NAME" ]]; do
        SERVER_NAME="$(prompt_with_default "Server name" "$(hostname)")"
        if [[ -z "$SERVER_NAME" ]]; then
            echo "Server name cannot be empty, please enter a value."
        fi
    done

    echo ""
    echo "Backup destination: only 'local' is implemented in this version."
    echo "(sftp / s3 / rclone are reserved for a future release.)"
    DEST_TYPE="local"
    DEST_LOCAL_PATH="$(prompt_with_default "Local repository path" "/var/backups/backup-framework/repo")"

    echo ""
    RETENTION_DAILY="$(prompt_with_default "Days of daily backups to keep" "15")"

    echo ""
    SCHEDULE_TIME="$(prompt_with_default "Daily backup time (24h, HH:MM)" "02:00")"
    SCHEDULE_JITTER_MINUTES="$(prompt_with_default "Random jitter in minutes" "30")"

    echo ""
    echo "Database dump mode: auto (recommended) / manual / disabled"
    DB_MODE="$(prompt_with_default "Database mode" "auto")"

    echo ""
    echo "=== Summary ==="
    echo "  Server name:       $SERVER_NAME"
    echo "  Destination:       $DEST_TYPE -> $DEST_LOCAL_PATH"
    echo "  Retention:         $RETENTION_DAILY days"
    echo "  Schedule:          $SCHEDULE_TIME (+/- $SCHEDULE_JITTER_MINUTES min jitter)"
    echo "  Database mode:     $DB_MODE"
}

generate_repository_password() {
    local secrets_dir="/etc/backup-framework"
    local password_file="$secrets_dir/.restic-password"
    local secrets_file="$secrets_dir/secrets.env"

    mkdir -p "$secrets_dir"

    if [[ -f "$password_file" ]]; then
        echo ""
        echo "A repository password file already exists at $password_file."
        read -rp "Overwrite it with a newly generated password? This makes any existing backup using it unreadable unless you already have a copy saved elsewhere. [y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Keeping existing password file."
            return 0
        fi
    fi

    openssl rand -base64 32 > "$password_file"
    chmod 600 "$password_file"

    cat > "$secrets_file" << EOF
RESTIC_PASSWORD_FILE="$password_file"
EOF
    chmod 600 "$secrets_file"

    local fingerprint
    fingerprint="$(sha256sum "$password_file" | cut -c1-12)"

    echo ""
    echo "=== Repository password generated ==="
    echo "A new, random repository password was generated and saved to:"
    echo "  $password_file"
    echo ""
    echo "This password is NEVER shown on screen. Restic encrypts your"
    echo "entire backup with it — if this file is lost AND you have no"
    echo "other copy, the backup becomes permanently unreadable, even by you."
    echo ""
    echo "Fingerprint (for your records, NOT the password itself): $fingerprint"
    echo ""
    echo "Strongly recommended: copy this file to a separate, secure"
    echo "location now (a password manager, encrypted note, etc.),"
    echo "off this server."
    echo ""
    read -rp "Type CONFIRM once you have done this, or press Enter to continue without confirming: " ack
    if [[ "$ack" == "CONFIRM" ]]; then
        echo "Acknowledged."
    else
        echo "WARNING: proceeding without confirmed off-server backup of the password file."
    fi
}

write_config() {
    local template="$FRAMEWORK_ROOT/templates/backup.conf.example"

    if [[ ! -f "$template" ]]; then
        echo "FATAL: template not found at $template" >&2
        return 1
    fi

    mkdir -p "$(dirname "$CONFIG_PATH")"

    sed \
        -e "s|^SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|" \
        -e "s|^DEST_TYPE=.*|DEST_TYPE=\"$DEST_TYPE\"|" \
        -e "s|^DEST_LOCAL_PATH=.*|DEST_LOCAL_PATH=\"$DEST_LOCAL_PATH\"|" \
        -e "s|^RETENTION_DAILY=.*|RETENTION_DAILY=$RETENTION_DAILY|" \
        -e "s|^SCHEDULE_TIME=.*|SCHEDULE_TIME=\"$SCHEDULE_TIME\"|" \
        -e "s|^SCHEDULE_JITTER_MINUTES=.*|SCHEDULE_JITTER_MINUTES=$SCHEDULE_JITTER_MINUTES|" \
        -e "s|^DB_MODE=.*|DB_MODE=\"$DB_MODE\"|" \
        "$template" > "$CONFIG_PATH"

    echo "Config written to $CONFIG_PATH"

    if [[ ! -f "/etc/backup-framework/excludes.txt" ]]; then
        cat > /etc/backup-framework/excludes.txt << 'EOF'
/proc
/sys
/dev
/run
/tmp
/var/tmp
/mnt
/media
/lost+found
/swapfile
/var/backups/backup-framework/repo
/var/lib/docker/overlay2
/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
EOF
        echo "Default exclude file written to /etc/backup-framework/excludes.txt"
    else
        echo "Exclude file already exists, leaving it untouched."
    fi
}


