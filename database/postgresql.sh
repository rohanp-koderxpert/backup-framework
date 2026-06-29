#!/bin/bash
#
# database/postgresql.sh
#
# Dumps every currently-online PostgreSQL cluster to a logical
# (pg_dumpall) backup, one file per cluster. A clean exit code from
# pg_dumpall isn't enough on its own to trust — we additionally
# verify each dump file actually contains real SQL content, since a
# silently-empty "successful" dump is the worst possible failure mode,
# only discovered during an actual disaster.

set -uo pipefail

dump_postgresql_clusters() {
    local dump_dir="${1:?dump_dir argument required}"
    local skip_ports="${2:-}"
    local dumped=() skipped=() failed=()

    if ! command -v pg_lsclusters &>/dev/null; then
        echo "No PostgreSQL installation detected, nothing to dump."
        return 0
    fi

    mkdir -p "$dump_dir"

    while read -r version cluster port status _; do
        [[ "$status" != "online" ]] && continue

        if [[ ",$skip_ports," == *",$port,"* ]]; then
            echo "Skipping cluster ${version}/${cluster} on port $port (explicitly excluded)."
            skipped+=("${version}/${cluster}")
            continue
        fi

        local outfile="$dump_dir/pg${version}_${cluster}_dumpall.sql"
        echo "Dumping cluster ${version}/${cluster} (port $port) -> $outfile"

        if sudo -u postgres pg_dumpall -p "$port" > "$outfile" 2>"$outfile.err"; then
            local size
            size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
            if [[ "$size" -lt 100 ]]; then
                echo "ERROR: dump for ${version}/${cluster} completed but is suspiciously small ($size bytes), treating as failed." >&2
                failed+=("${version}/${cluster}")
            elif ! grep -q "PostgreSQL database cluster dump complete" "$outfile"; then
                echo "ERROR: dump for ${version}/${cluster} is missing its completion marker, treating as failed." >&2
                failed+=("${version}/${cluster}")
            else
                rm -f "$outfile.err"
                dumped+=("${version}/${cluster}")
            fi
        else
            echo "ERROR: pg_dumpall failed for ${version}/${cluster}, see $outfile.err" >&2
            failed+=("${version}/${cluster}")
        fi
    done < <(pg_lsclusters | tail -n +2)

    echo "Dump summary: ${#dumped[@]} succeeded, ${#skipped[@]} skipped, ${#failed[@]} failed."

    if [[ ${#failed[@]} -gt 0 ]]; then
        return 1
    fi
    return 0
}
