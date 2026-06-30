#!/bin/bash
#
# setup/install-timer.sh
#
# Generates and installs the systemd service + timer units that run
# backup/run.sh daily, using SCHEDULE_TIME and SCHEDULE_JITTER_MINUTES
# from the real config rather than hardcoding a fixed time.

set -uo pipefail

FRAMEWORK_ROOT="/opt/backup-framework"
SERVICE_FILE="/etc/systemd/system/backup-framework.service"
TIMER_FILE="/etc/systemd/system/backup-framework.timer"

source "$FRAMEWORK_ROOT/core/config-loader.sh"

install_timer() {
    local config_path="${1:-/etc/backup-framework/backup.conf}"

    if ! load_config "$config_path"; then
        echo "FATAL: could not load config from $config_path" >&2
        return 1
    fi

    local jitter_seconds=$(( SCHEDULE_JITTER_MINUTES * 60 ))

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backup Framework - run backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/bin/bash $FRAMEWORK_ROOT/backup/run.sh $config_path
EOF

    cat > "$TIMER_FILE" << EOF
[Unit]
Description=Backup Framework - daily schedule

[Timer]
OnCalendar=*-*-* ${SCHEDULE_TIME}:00
RandomizedDelaySec=${jitter_seconds}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    echo "Wrote $SERVICE_FILE"
    echo "Wrote $TIMER_FILE"

    systemctl daemon-reload
    systemctl enable --now backup-framework.timer

    echo "Timer installed and enabled. Scheduled for ${SCHEDULE_TIME} daily, +/- up to ${SCHEDULE_JITTER_MINUTES} minutes jitter."
}

install_timer "$@"
