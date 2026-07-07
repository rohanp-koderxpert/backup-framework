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
CONFIG_PATH="${CONFIG_PATH:-/etc/backup-framework/backup.conf}"

source "$FRAMEWORK_ROOT/core/config-loader.sh"
source "$FRAMEWORK_ROOT/setup/ssh-helper.sh"

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
    DEST_LOCAL_PATH="/var/backups/backup-framework/repo"
    DEST_SFTP_HOST_ALIAS=""
    DEST_SFTP_REPO_PATH=""
    while [[ -z "$SERVER_NAME" ]]; do
        SERVER_NAME="$(prompt_with_default "Server name" "$(hostname)")"
        if [[ -z "$SERVER_NAME" ]]; then
            echo "Server name cannot be empty, please enter a value."
        fi
    done

    echo ""
    echo "Backup destination:"
    echo "  1) local  — on this server's own disk"
    echo "  2) sftp   — another Linux server or Windows PC over SSH/Tailscale"
    echo "  3) rclone — Google Drive, OneDrive, Dropbox, or any cloud storage"
    local dest_choice
    dest_choice="$(prompt_with_default "Choose destination" "1")"

    case "$dest_choice" in
        2|sftp)
            DEST_TYPE="sftp"
            echo ""
            echo "SFTP destination requires a Host alias in /root/.ssh/config with"
            echo "key-based auth already configured (no password prompts — unattended backups"
            echo "cannot accept interactive input)."
            DEST_SFTP_HOST_ALIAS="$(prompt_with_default "SSH host alias" "backup-destination")"

            echo ""
            echo "What type of machine is the backup destination?"
            echo "  1) Linux server"
            echo "  2) Windows PC"
            local remote_os_choice
            remote_os_choice="$(prompt_with_default "Remote machine type" "1")"
            local remote_os="linux"
            [[ "$remote_os_choice" == "2" ]] && remote_os="windows"

            if ! ensure_ssh_ready "$DEST_SFTP_HOST_ALIAS" "$remote_os"; then
                echo "FATAL: SSH setup did not complete for '$DEST_SFTP_HOST_ALIAS'." >&2
                echo "Re-run this wizard once connectivity is fixed." >&2
                exit 1
            fi

            echo ""
            echo "Use an ABSOLUTE path on the remote machine to avoid landing on an"
            echo "unexpected or space-constrained drive. Examples:"
            echo "  Linux server:  /mnt/backups/$(hostname)"
            echo "  Windows PC:    /D:/backups/$(hostname)"
            echo ""

            local default_sftp_path="/mnt/backups/$(hostname)"
            [[ "$remote_os" == "windows" ]] && default_sftp_path="/D:/backups/$(hostname)"

            while true; do
                DEST_SFTP_REPO_PATH="$(prompt_with_default "Remote repository path" "$default_sftp_path")"
                if [[ ${#DEST_SFTP_REPO_PATH} -lt 3 ]]; then
                    echo "Path too short. Enter a valid absolute path (e.g. /D:/backups/server)."
                    continue
                fi
                if [[ "$DEST_SFTP_REPO_PATH" == *\\* ]]; then
                    DEST_SFTP_REPO_PATH="${DEST_SFTP_REPO_PATH//\\/\/}"
                    echo "Auto-corrected to: $DEST_SFTP_REPO_PATH"
                fi
                break
            done

            echo ""
            echo "NOTE: the first backup will transfer your full filesystem (~50GB+)."
            echo "This may take 1-2 hours or more depending on your connection speed,"
            echo "and may require multiple retries if the connection is unstable."
            echo "Daily incremental backups after the first will be much smaller and faster."
            ;;
	3|rclone)
            DEST_TYPE="rclone"
            echo ""
            echo "rclone remote name must already exist in 'rclone config'."
            DEST_RCLONE_REMOTE_NAME="$(prompt_with_default "rclone remote name" "gdrive")"
            DEST_RCLONE_REPO_PATH="$(prompt_with_default "Remote folder path" "backup-framework/$(hostname)")"
            ;;
        *)
            DEST_TYPE="local"
            DEST_LOCAL_PATH="$(prompt_with_default "Local repository path" "/var/backups/backup-framework/repo")"
            echo ""
            echo "WARNING: local destination means your only backup lives on the same"
            echo "server being backed up. If the server is destroyed, the backup is lost too."
            echo "Consider adding a second destination (sftp/s3) once this is working."
            ;;
    esac

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
    if [[ "$DEST_TYPE" == "sftp" ]]; then
        echo "  Destination:       $DEST_TYPE -> $DEST_SFTP_HOST_ALIAS:$DEST_SFTP_REPO_PATH"
    elif [[ "$DEST_TYPE" == "rclone" ]]; then
        echo "  Destination:       $DEST_TYPE -> $DEST_RCLONE_REMOTE_NAME:$DEST_RCLONE_REPO_PATH"
    else
        echo "  Destination:       $DEST_TYPE -> $DEST_LOCAL_PATH"
    fi
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
        -e "s|^DEST_SFTP_HOST_ALIAS=.*|DEST_SFTP_HOST_ALIAS=\"${DEST_SFTP_HOST_ALIAS:-himesh-backup}\"|" \
        -e "s|^DEST_SFTP_REPO_PATH=.*|DEST_SFTP_REPO_PATH=\"${DEST_SFTP_REPO_PATH:-restic-repo}\"|" \
        -e "s|^RETENTION_DAILY=.*|RETENTION_DAILY=$RETENTION_DAILY|" \
        -e "s|^SCHEDULE_TIME=.*|SCHEDULE_TIME=\"$SCHEDULE_TIME\"|" \
        -e "s|^SCHEDULE_JITTER_MINUTES=.*|SCHEDULE_JITTER_MINUTES=$SCHEDULE_JITTER_MINUTES|" \
        -e "s|^DB_MODE=.*|DB_MODE=\"$DB_MODE\"|" \
	-e "s|^DEST_RCLONE_REMOTE_NAME=.*|DEST_RCLONE_REMOTE_NAME=\"${DEST_RCLONE_REMOTE_NAME:-gdrive}\"|" \
        -e "s|^DEST_RCLONE_REPO_PATH=.*|DEST_RCLONE_REPO_PATH=\"${DEST_RCLONE_REPO_PATH:-backup-framework}\"|" \
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

test_connectivity() {
    echo ""
    echo "=== Testing destination connectivity ==="

    if ! load_config "$CONFIG_PATH"; then
        echo "FATAL: could not reload generated config for testing" >&2
        return 1
    fi
    if ! load_config "$SECRETS_FILE"; then
        echo "FATAL: could not load secrets for testing" >&2
        return 1
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
            return 1
            ;;
    esac

    if setup_destination; then
        echo "Connectivity test PASSED. Repository is ready at $(repository_string)."
        return 0
    else
        echo "Connectivity test FAILED. Review the error above before relying on this setup." >&2
        return 1
    fi
}

main() {
    echo "=== Backup Framework Setup Wizard ==="

    if ! check_existing_config; then
        echo "Setup ended."
        exit 0
    fi

    collect_essentials
    generate_repository_password
    write_config

    if test_connectivity; then
        echo ""
        echo "=== Setup complete ==="
        echo "Your daily backup is configured. To enable the scheduled timer, run:"
        echo "  bash $FRAMEWORK_ROOT/setup/install-timer.sh"
    else
        echo ""
        echo "=== Setup finished with errors ==="
        echo "Configuration was written, but the connectivity test failed."
        echo "Fix the issue above, then re-run this wizard or test manually before relying on it."
        exit 1
    fi
}

main "$@"

