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
