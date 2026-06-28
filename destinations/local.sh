#!/bin/bash
#
# destinations/local.sh
#
# Destination adapter for backups stored on this server's own disk.
# Every adapter exposes the same three functions so the rest of the
# framework never needs to know which backend is actually in use.
# Assumes RESTIC_PASSWORD_FILE is already exported by the caller
# (normally loaded from secrets.env before any adapter runs).

set -uo pipefail

repository_string() {
    echo "$DEST_LOCAL_PATH"
}

setup_destination() {
    local repo
    repo="$(repository_string)"
    mkdir -p "$(dirname "$repo")"
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
    local repo
    repo="$(repository_string)"
    export RESTIC_REPOSITORY="$repo"

    if restic snapshots >/dev/null 2>&1; then
        echo "PASS: local repository reachable at $repo"
        return 0
    fi

    echo "FAIL: cannot access repository at $repo" >&2
    return 1
}
