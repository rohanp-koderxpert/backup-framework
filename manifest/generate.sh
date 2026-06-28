#!/bin/bash
#
# manifest/generate.sh
#
# Produces the structured JSON system manifest (matches the frozen
# schema in templates/manifest.example.json). Each section has its
# own collect_* function returning a self-contained JSON object,
# merged into the final manifest — keeps each section independently
# testable as more get added.
#
# Requires jq — used to build JSON correctly (proper escaping of
# quotes, backslashes, etc. in collected values) rather than
# hand-concatenating strings, which breaks the moment any value
# contains a character JSON treats specially.

set -uo pipefail

FRAMEWORK_VERSION="1.0.0"
SCHEMA_VERSION=1

collect_os_info() {
    local kernel arch distro
    kernel="$(uname -r)"
    arch="$(uname -m)"
    distro="$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    [[ -z "$distro" ]] && distro="unknown"

    jq -n \
        --arg kernel "$kernel" \
        --arg arch "$arch" \
        --arg distro "$distro" \
        '{kernel: $kernel, arch: $arch, distro: $distro}'
}

generate_manifest() {
    local server_name="${SERVER_NAME:?SERVER_NAME must be set}"
    local generated_at os_json
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    os_json="$(collect_os_info)"

    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg generated_at "$generated_at" \
        --arg server_name "$server_name" \
        --arg framework_version "$FRAMEWORK_VERSION" \
        --argjson os "$os_json" \
        '{
            schema_version: ($schema_version | tonumber),
            generated_at: $generated_at,
            server_name: $server_name,
            framework_version: $framework_version,
            os: $os
        }'
}

