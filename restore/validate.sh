#!/bin/bash
#
# restore/validate.sh
#
# Compares an original manifest (pulled from a backup snapshot) against
# a current manifest (generated fresh, normally on the restored system)
# and surfaces the differences that actually matter for catching a
# broken or incomplete restore: failed services, enabled services that
# went missing, and package count drift. Exits non-zero if anything
# looks wrong, so this can gate an automated restore-test pipeline.

set -uo pipefail

validate_restore() {
    local original_manifest="${1:?path to original manifest required}"
    local current_manifest="${2:?path to current manifest required}"
    local issues_found=0

    if [[ ! -f "$original_manifest" ]]; then
        echo "FATAL: original manifest not found: $original_manifest" >&2
        return 1
    fi
    if [[ ! -f "$current_manifest" ]]; then
        echo "FATAL: current manifest not found: $current_manifest" >&2
        return 1
    fi

    echo "=== Restore validation report ==="

    local failed_count
    failed_count="$(jq '.services.failed | length' "$current_manifest")"
    if [[ "$failed_count" -gt 0 ]]; then
        echo "FAIL: $failed_count service(s) currently in a failed state:"
        jq -r '.services.failed[].name' "$current_manifest" | sed 's/^/  - /'
        issues_found=1
    else
        echo "PASS: no services currently in a failed state."
    fi

    local missing_enabled
    missing_enabled="$(jq -n \
        --slurpfile orig <(jq '[.services.enabled[].name]' "$original_manifest") \
        --slurpfile curr <(jq '[.services.enabled[].name]' "$current_manifest") \
        '$orig[0] - $curr[0]')"
    local missing_count
    missing_count="$(echo "$missing_enabled" | jq 'length')"
    if [[ "$missing_count" -gt 0 ]]; then
        echo "FAIL: $missing_count enabled service(s) present originally but missing now:"
        echo "$missing_enabled" | jq -r '.[]' | sed 's/^/  - /'
        issues_found=1
    else
        echo "PASS: all originally-enabled services are still present."
    fi

    local orig_pkg_count curr_pkg_count
    orig_pkg_count="$(jq '.packages.count' "$original_manifest")"
    curr_pkg_count="$(jq '.packages.count' "$current_manifest")"
    if [[ "$orig_pkg_count" != "$curr_pkg_count" ]]; then
        echo "WARNING: package count differs (original: $orig_pkg_count, current: $curr_pkg_count) — may be expected if updates ran since backup."
    else
        echo "PASS: package count matches ($curr_pkg_count)."
    fi

    echo "=== End validation report ==="

    if [[ "$issues_found" -eq 1 ]]; then
        return 1
    fi
    return 0
}
