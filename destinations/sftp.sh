#!/bin/bash
#
# destinations/sftp.sh
#
# Destination adapter for backups stored on another Linux server, or
# a PC reachable over SSH (e.g. via Tailscale + OpenSSH, as set up
# for the "himesh-backup" host alias). Same three-function interface
# as destinations/local.sh: repository_string, setup_destination,
# test_destination — backup/run.sh doesn't need to know which one
# it's using.
#
# Assumes DEST_SFTP_HOST_ALIAS matches a Host entry in /root/.ssh/config
# with working key-based auth already configured (no password prompts).

set -uo pipefail

repository_string() {
    echo "sftp:${DEST_SFTP_HOST_ALIAS}:${DEST_SFTP_REPO_PATH}"
}

check_ssh_reachable() {
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$DEST_SFTP_HOST_ALIAS" "echo ok" >/dev/null 2>&1; then
        echo "ERROR: cannot reach host '$DEST_SFTP_HOST_ALIAS' over SSH. Check Tailscale connectivity and that key-based auth is configured (no password prompts allowed for unattended use)." >&2
        return 1
    fi
    return 0
}

setup_destination() {
    if ! check_ssh_reachable; then
        return 1
    fi

    local repo
    repo="$(repository_string)"
    export RESTIC_REPOSITORY="$repo"

    if restic snapshots >/dev/null 2>&1; then
        echo "Repository already initialized: $repo"
        return 0
    fi

    echo "Initializing new repository: $repo"
    if restic init; then
        echo "Repository initialized successfully: $repo"
        return 0
    fi

    echo "ERROR: failed to initialize repository at $repo" >&2
    return 1
}

test_destination() {
    if ! check_ssh_reachable; then
        return 1
    fi

    local repo
    repo="$(repository_string)"
    export RESTIC_REPOSITORY="$repo"

    if restic snapshots >/dev/null 2>&1; then
        echo "PASS: SFTP repository reachable at $repo"
        return 0
    fi

    echo "FAIL: cannot access repository at $repo" >&2
    return 1
}
