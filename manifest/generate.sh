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

collect_packages() {
    dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({name: .[0], version: .[1], status: (.[2] | split(" ") | last)})
        | {count: length, items: .}
    '
}

generate_manifest() {
    local server_name="${SERVER_NAME:?SERVER_NAME must be set}"
    local generated_at os_json packages_file
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    os_json="$(collect_os_info)"

    packages_file="$(mktemp)"
    collect_packages > "$packages_file"

    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg generated_at "$generated_at" \
        --arg server_name "$server_name" \
        --arg framework_version "$FRAMEWORK_VERSION" \
        --argjson os "$os_json" \
        --slurpfile packages "$packages_file" \
        '{
            schema_version: ($schema_version | tonumber),
            generated_at: $generated_at,
            server_name: $server_name,
            framework_version: $framework_version,
            os: $os,
            packages: $packages[0]
        }'

    rm -f "$packages_file"
}
