#!/bin/bash
#
# restore/deploy.sh
#
# Deploys a previously-restored staging directory onto the live
# system. This is the missing piece between "we have the data back"
# (restore/wizard.sh) and "the server actually works again."
#
# Deliberately conservative: never touches disk partitioning or
# networking config, and never reboots the system itself. A reboot
# remains an explicit, separate, human decision.
#
# Safety model, two layers:
#   1. The same excludes.txt used for backups (anything not worth
#      backing up is equally not worth restoring over the live system)
#   2. A small, hardcoded, ALWAYS-applied safety list below - this is
#      belt-and-suspenders protection even if an operator's excludes.txt
#      is missing or misconfigured, since these specific paths (machine
#      identity, networking, SSH host keys) can cause total, unrecoverable
#      lockout on a host with no out-of-band console access if overwritten
#      with a different machine's values and the box is rebooted.
#
# Usage: sudo bash restore/deploy.sh <staging-directory> [--yes]
#   --yes : don't prompt before starting services found enabled in the
#           restored manifest but not currently running (still prompts
#           for the actual file-copy step regardless)

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"
EXCLUDES_FILE="/etc/backup-framework/excludes.txt"

# Always applied, regardless of what excludes.txt contains - this is
# the safety net, not the primary mechanism.
SAFETY_EXCLUDES=(
    "/etc/fstab"
    "/etc/netplan"
    "/etc/machine-id"
    "/etc/ssh/ssh_host_*"
    "/etc/hostname"
    "/etc/resolv.conf"
    "/var/lib/dbus/machine-id"
    "/var/lib/cloud"
    "/boot"
)

build_rsync_excludes() {
    local user_excludes_file="$1"
    local -a rsync_args=()

    if [[ -f "$user_excludes_file" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            rsync_args+=(--exclude="$line")
        done < "$user_excludes_file"
    fi

    local path
    for path in "${SAFETY_EXCLUDES[@]}"; do
        rsync_args+=(--exclude="$path")
    done

    printf '%s\n' "${rsync_args[@]}"
}

deploy_enabled_services() {
    local manifest_path="$1"
    local auto_yes="$2"

    if [[ ! -f "$manifest_path" ]]; then
        echo "No manifest found at $manifest_path - skipping service enable/start step." >&2
        return 0
    fi

    local enabled_services
    enabled_services="$(jq -r '.services.enabled[]?.name // empty' "$manifest_path" 2>/dev/null)"

    if [[ -z "$enabled_services" ]]; then
        echo "No enabled services listed in the restored manifest."
        return 0
    fi

    systemctl daemon-reload

    local svc
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue

        if systemctl is-active --quiet "$svc"; then
            echo "  $svc - already running, skipping."
            continue
        fi

        if [[ "$auto_yes" == "true" ]]; then
            do_start="y"
        else
            read -rp "  Start and enable '$svc'? [y/N]: " do_start
        fi

        if [[ "$do_start" == "y" || "$do_start" == "Y" ]]; then
            systemctl enable --now "$svc" 2>&1 | sed 's/^/    /'
            echo "  $svc - enabled and started."
        else
            echo "  $svc - skipped."
        fi
    done <<< "$enabled_services"
}

main() {
    local staging_dir="${1:-}"
    local auto_yes="false"
    [[ "${2:-}" == "--yes" ]] && auto_yes="true"

    if [[ -z "$staging_dir" ]]; then
        echo "Usage: sudo bash restore/deploy.sh <staging-directory> [--yes]" >&2
        exit 1
    fi

    if [[ ! -d "$staging_dir" ]]; then
        echo "FATAL: staging directory not found: $staging_dir" >&2
        exit 1
    fi

    echo "=== Backup Framework: Post-Restore Deploy ==="
    echo ""
    echo "This will copy the contents of:"
    echo "  $staging_dir"
    echo "onto the live filesystem (/), EXCLUDING:"
    echo "  - everything in $EXCLUDES_FILE"
    echo "  - machine identity and networking files (always excluded, for safety):"
    for path in "${SAFETY_EXCLUDES[@]}"; do
        echo "      $path"
    done
    echo ""
    echo "This does NOT reboot the system. You decide separately whether/when to reboot."
    echo ""
    read -rp "Proceed with deploy onto /? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled. Nothing was changed."
        exit 0
    fi

    local -a exclude_args=()
    while IFS= read -r arg; do
        exclude_args+=("$arg")
    done < <(build_rsync_excludes "$EXCLUDES_FILE")

    local rsync_log
    rsync_log="$(mktemp)"

    echo ""
    echo "=== Deploying files ==="
    rsync -a --itemize-changes "${exclude_args[@]}" "$staging_dir/" / 2>&1 | tee "$rsync_log"
    local rsync_exit="${PIPESTATUS[0]}"

    if [[ "$rsync_exit" -ne 0 ]]; then
        echo ""
        echo "=== Deploy FAILED ===" >&2
        echo "rsync exited with status $rsync_exit. Review the output above." >&2
        rm -f "$rsync_log"
        exit 1
    fi

    echo ""
    echo "=== Excluded paths actually encountered (for transparency) ==="
    grep -oE '\S+ (skipping|excluded)\b' "$rsync_log" 2>/dev/null | sort -u || echo "(none reported by rsync)"
    rm -f "$rsync_log"

    echo ""
    echo "=== Checking restored services ==="
    local manifest_path="$staging_dir/var/backups/backup-framework/manifest/manifest.json"
    deploy_enabled_services "$manifest_path" "$auto_yes"

    echo ""
    echo "=== Deploy complete ==="
    echo "Files have been copied onto the live system. This script did NOT reboot."
    echo "Review service status above, then reboot manually when you're ready:"
    echo "  sudo reboot"
}

main "$@"