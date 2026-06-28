#!/bin/bash
#
# manifest/generate.sh
#
# Produces the structured JSON system manifest (matches the frozen
# schema in templates/manifest.example.json). Built incrementally —
# this first version only emits the header fields, to prove the
# JSON-construction approach is sound before adding real collection
# logic.
#
# Requires jq — used to build JSON correctly (proper escaping of
# quotes, backslashes, etc. in collected values) rather than
# hand-concatenating strings, which breaks the moment any value
# contains a character JSON treats specially.

set -uo pipefail

FRAMEWORK_VERSION="1.0.0"
SCHEMA_VERSION=1

generate_manifest() {
    local server_name="${SERVER_NAME:?SERVER_NAME must be set}"
    local generated_at
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg generated_at "$generated_at" \
        --arg server_name "$server_name" \
        --arg framework_version "$FRAMEWORK_VERSION" \
        '{
            schema_version: ($schema_version | tonumber),
            generated_at: $generated_at,
            server_name: $server_name,
            framework_version: $framework_version
        }'
}
