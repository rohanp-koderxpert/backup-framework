#!/bin/bash
#
# core/dispatcher.sh
#
# Decides, on every invocation, whether to launch the interactive
# setup wizard or run the unattended backup. This is the single
# entry point's brain — both the human-run command and the systemd
# timer call into this same logic.
#
# Hard safety rule: if no config exists AND there is no interactive
# terminal attached, this MUST fail immediately rather than attempt
# to prompt — a hung, silent, unattended job is far worse than a
# clear, fast failure.

set -uo pipefail

CONFIG_PATH="${1:-/etc/backup-framework/backup.conf}"

is_interactive() {
    [[ -t 0 ]]
}

dispatch() {
    local config_path="$1"

    if [[ -f "$config_path" ]]; then
        echo "DECISION: config exists at $config_path -> would run unattended backup"
        return 0
    fi

    if is_interactive; then
        echo "DECISION: no config found, interactive terminal detected -> would launch setup wizard"
        return 0
    fi

    echo "ERROR: no config found at $config_path and no interactive terminal attached. Refusing to prompt in a non-interactive context. Run this manually from a terminal to complete first-time setup." >&2
    return 1
}

dispatch "$CONFIG_PATH"
