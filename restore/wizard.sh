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

check_ip_mismatch() {
    local original_manifest="$1"
    local orig_ips current_ips

    orig_ips="$(jq -r '.network[]? | "\(.interface):\(.ip)"' "$original_manifest" 2>/dev/null | sort)"
    current_ips="$(detect_labeled_ips | sort)"

    if [[ -z "$orig_ips" ]]; then
        # older manifest schema, no network section recorded - nothing to compare
        return 0
    fi

    if [[ "$orig_ips" == "$current_ips" ]]; then
        return 0
    fi

    return 1
}

show_ip_comparison() {
    local original_manifest="$1"
    echo "  This backup was created on a server with:"
    jq -r '.network[]? | "\(.interface)\t\(.ip)"' "$original_manifest" 2>/dev/null | \
        awk -F'\t' '{printf "    %-15s %s\n", $1":", $2}'
    echo ""
    echo "  This system currently has:"
    detect_labeled_ips | awk -F: '{printf "    %-15s %s\n", $1":", $2}'
}

scan_for_ip_occurrences() {
    local target_dir="$1" old_ip="$2"
    grep -rlI --exclude-dir=.git "$old_ip" "$target_dir" 2>/dev/null | while read -r file; do
        local count
        count="$(grep -c "$old_ip" "$file" 2>/dev/null)"
        echo "$file"$'\t'"$count"
    done
}

apply_ip_replacement() {
    local old_ip="$1" new_ip="$2" log_file="$3"
    shift 3
    local files=("$@")

    {
        echo "IP migration replacement log - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Old IP: $old_ip -> New IP: $new_ip"
        echo "---"
    } > "$log_file"

    for file in "${files[@]}"; do
        local matched_lines
        matched_lines="$(grep -n "$old_ip" "$file" 2>/dev/null)"
        sed -i "s/${old_ip//./\\.}/${new_ip}/g" "$file"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "$file: $line" >> "$log_file"
        done <<< "$matched_lines"
    done
}

run_ip_migration_check() {
    local original_manifest="$1" target="$2"

    # Defensive: don't rely on manifest/generate.sh having already been
    # sourced by an earlier block in main() - source it here explicitly
    # so this function's dependency on detect_labeled_ips() is self-
    # contained. Sourcing twice is harmless (just re-defines functions).
    source "$FRAMEWORK_ROOT/manifest/generate.sh"

    if [[ ! -f "$original_manifest" ]]; then
        return 0
    fi
    if ! jq empty "$original_manifest" 2>/dev/null; then
        return 0
    fi
    if ! jq -e '.network' "$original_manifest" >/dev/null 2>&1; then
        return 0
    fi

    if check_ip_mismatch "$original_manifest"; then
        return 0
    fi

    echo ""
    echo "=== IP address mismatch detected ==="
    show_ip_comparison "$original_manifest"
    echo ""
    echo "This could mean this is a restore onto different/new hardware, OR it could"
    echo "simply mean an IP changed on the same machine (DHCP renewal, VPN reset, etc.)"
    echo "with no hardware change at all. Only you can tell which applies here."
    echo ""

    if [[ ! -t 0 ]]; then
        echo "Running non-interactively - skipping IP migration check."
        return 0
    fi

    local is_migration
    read -rp "Does this look like a restore onto different/new hardware? [y/N]: " is_migration
    if [[ "$is_migration" != "y" && "$is_migration" != "Y" ]]; then
        echo "Skipping IP migration."
        return 0
    fi

    local old_ip new_ip
    old_ip="$(jq -r '.network[0].ip // empty' "$original_manifest" 2>/dev/null)"
    if [[ -z "$old_ip" ]]; then
        echo "Could not determine the old IP to replace. Skipping."
        return 0
    fi
    new_ip="$(detect_labeled_ips | head -n1 | cut -d: -f2)"

    echo ""
    read -rp "Old IP to replace [$old_ip]: " old_ip_input
    old_ip="${old_ip_input:-$old_ip}"
    read -rp "New IP to use [$new_ip]: " new_ip_input
    new_ip="${new_ip_input:-$new_ip}"

    echo ""
    echo "Scanning $target for occurrences of $old_ip..."
    local -a match_files=()
    while IFS=$'\t' read -r file count; do
        [[ -z "$file" ]] && continue
        echo "  $file ($count matches)"
        match_files+=("$file")
    done < <(scan_for_ip_occurrences "$target" "$old_ip")

    if [[ ${#match_files[@]} -eq 0 ]]; then
        echo "No occurrences found. Nothing to replace."
        return 0
    fi

    echo ""
    read -rp "Review and apply these replacements? [y/N]: " apply_confirm
    if [[ "$apply_confirm" != "y" && "$apply_confirm" != "Y" ]]; then
        echo "Skipped - no files were changed."
        return 0
    fi

    local log_file="${target}-ip-migration-log.txt"
    apply_ip_replacement "$old_ip" "$new_ip" "$log_file" "${match_files[@]}"

    echo ""
    echo "Replacement applied. Log written to: $log_file"
    echo "Note: database-stored configuration (e.g. application base URLs) was NOT"
    echo "modified and may need manual updates inside the application itself."
}

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
    local validation_status="SKIPPED"
    local skip_reason=""

    if [[ ! -f "$original_manifest" ]]; then
        skip_reason="no manifest found in this snapshot"
    elif ! jq empty "$original_manifest" 2>/dev/null; then
        skip_reason="manifest file exists but is corrupted/unreadable (invalid JSON)"
    fi

    if [[ -n "$skip_reason" ]]; then
        echo "WARNING: cannot validate this restore - $skip_reason."
        echo "  Expected manifest at: $original_manifest"
        echo ""
        echo "This can happen for a snapshot from an older framework version,"
        echo "one taken with MANIFEST_ENABLED=false, or a backup not produced by"
        echo "this framework's normal backup process. The restored files above"
        echo "are still on disk at $target - only automatic validation was skipped."

        if [[ -t 0 ]]; then
            echo ""
            read -rp "Press Enter to acknowledge validation was skipped and continue..." _
        else
            echo "(running non-interactively - proceeding without prompting)"
        fi
    else
        source "$FRAMEWORK_ROOT/manifest/generate.sh"
        export SERVER_NAME="${SERVER_NAME:-$(hostname)}"

        local current_manifest
        current_manifest="/tmp/current-manifest-$(date +%Y%m%d%H%M%S).json"
        echo "Generating fresh manifest from current system..."
        generate_manifest > "$current_manifest"

        source "$FRAMEWORK_ROOT/restore/validate.sh"
        if validate_restore "$original_manifest" "$current_manifest"; then
            validation_status="PASSED"
        else
            validation_status="FAILED"
        fi

        rm -f "$current_manifest"
    fi

    run_ip_migration_check "$original_manifest" "$target"

    echo ""
    echo "=== Restore Summary ==="
    echo "Files restored: Yes ($snapshot_id -> $target)"
    case "$validation_status" in
        PASSED)
            echo "Validation:     PASSED - all checks OK"
            ;;
        FAILED)
            echo "Validation:     FAILED - review the failures above before putting this server into service"
            ;;
        SKIPPED)
            echo "Validation:     SKIPPED ($skip_reason)"
            ;;
    esac
}

main "$@"
