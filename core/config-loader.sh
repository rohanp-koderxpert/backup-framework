#!/bin/bash
#
# core/config-loader.sh
#
# Validates and loads backup.conf safely. Never sourced blindly —
# every line is checked against the expected KEY=VALUE shape first,
# since sourcing untrusted/malformed shell as root can execute
# arbitrary code.

set -uo pipefail

CONFIG_PATH="${CONFIG_PATH:-${1:-/etc/backup-framework/backup.conf}}"
VALID_LINE_PATTERN='^[A-Z0-9_]+=.*$'
EXPECTED_CONFIG_VERSION=1

validate_config_shape() {
    local path="$1"
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if ! [[ "$line" =~ $VALID_LINE_PATTERN ]]; then
            echo "ERROR: Invalid line $line_num in $path: $line" >&2
            return 1
        fi
    done < "$path"
    return 0
}

check_config_version() {
    if [[ -z "${CONFIG_VERSION:-}" ]]; then
        echo "WARNING: CONFIG_VERSION not set; assuming version 1. Consider regenerating your config from the latest template." >&2
        return 0
    fi
    if [[ "$CONFIG_VERSION" != "$EXPECTED_CONFIG_VERSION" ]]; then
        echo "WARNING: Config schema version ($CONFIG_VERSION) does not match the framework's expected version ($EXPECTED_CONFIG_VERSION). Some settings may be interpreted differently than intended." >&2
    fi
    return 0
}

load_config() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: Config file not found: $path" >&2
        return 1
    fi
    if ! validate_config_shape "$path"; then
        echo "ERROR: Config file failed validation, refusing to load: $path" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    set -a
    source "$path"
    set +a
    check_config_version
    return 0
}
