#!/bin/bash
#
# destinations/rclone.sh
#
# Destination adapter for cloud storage via rclone (Google Drive,
# OneDrive, Dropbox, Azure Blob, etc.). Uses restic's native rclone
# backend. The rclone remote must already be configured via
# `rclone config` before this adapter is used.

set -uo pipefail

repository_string() {
    echo "rclone:${DEST_RCLONE_REMOTE_NAME}:${DEST_RCLONE_REPO_PATH}"
}

check_rclone_available() {
    if ! command -v rclone &>/dev/null; then
        echo "ERROR: rclone is not installed. Install it with: apt install rclone" >&2
        return 1
    fi
    return 0
}

check_rclone_remote() {
    local remote="$DEST_RCLONE_REMOTE_NAME"
    if ! rclone listremotes 2>/dev/null | grep -q "^${remote}:$"; then
        echo "ERROR: rclone remote '${remote}' not found." >&2
        echo "Run 'rclone config' to set it up, then re-run this wizard." >&2
        return 1
    fi
    return 0
}

setup_destination() {
    check_rclone_available || return 1
    check_rclone_remote || return 1

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
    check_rclone_available || return 1
    check_rclone_remote || return 1

    local repo
    repo="$(repository_string)"
    export RESTIC_REPOSITORY="$repo"

    if restic snapshots >/dev/null 2>&1; then
        echo "PASS: rclone repository reachable at $repo"
        return 0
    fi

    echo "FAIL: cannot access repository at $repo" >&2
    return 1
}
