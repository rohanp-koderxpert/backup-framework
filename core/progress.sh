#!/bin/bash
#
# core/progress.sh
#
# Renders live progress for restic --json backup output. Sourced by
# backup/run.sh.

# --- progress rendering for restic --json output -------------------------
#
# render_backup_progress reads newline-delimited JSON from restic's --json
# progress output (piped in via stdin) and renders either:
#   - a live, in-place updating progress bar (when stdout is a real TTY)
#   - throttled one-line summaries every 60s (when running unattended,
#     e.g. under systemd where journalctl captures output — a \r-based bar
#     would just produce garbage log lines there)
#
# Usage: restic backup ... --json | render_backup_progress

render_backup_progress() {
    local is_tty=false
    [[ -t 1 ]] && is_tty=true

    local last_log_time=0
    local bar_width=30

    while IFS= read -r line; do
        local msg_type
        msg_type="$(jq -r '.message_type // empty' <<<"$line" 2>/dev/null)"

        if [[ "$msg_type" == "status" ]]; then
            local percent bytes_done total_bytes files_done total_files elapsed
            percent="$(jq -r '.percent_done // 0' <<<"$line")"
            bytes_done="$(jq -r '.bytes_done // 0' <<<"$line")"
            total_bytes="$(jq -r '.total_bytes // 0' <<<"$line")"
            files_done="$(jq -r '.files_done // 0' <<<"$line")"
            total_files="$(jq -r '.total_files // 0' <<<"$line")"
            elapsed="$(jq -r '.seconds_elapsed // 0' <<<"$line")"

            local pct_int
            pct_int="$(awk -v p="$percent" 'BEGIN{printf "%d", p*100}')"

            local speed_mb eta_str
            if [[ "$elapsed" -gt 0 && "$bytes_done" -gt 0 ]]; then
                speed_mb="$(awk -v b="$bytes_done" -v s="$elapsed" 'BEGIN{printf "%.1f", (b/s)/1024/1024}')"

                # Suppress ETA until we have a reliable sample: at least 10s
                # elapsed AND at least 1% of total data transferred. Early
                # estimates from a tiny sample swing wildly (e.g. 500h down
                # to 3h within a minute) and just alarm the user for no reason.
                local min_bytes_threshold
                min_bytes_threshold="$(awk -v t="$total_bytes" 'BEGIN{printf "%d", t*0.01}')"

                if [[ "$elapsed" -lt 10 ]] || [[ "$bytes_done" -lt "$min_bytes_threshold" ]]; then
                    eta_str="calculating..."
                else
                    eta_str="$(awk -v b="$bytes_done" -v t="$total_bytes" -v s="$elapsed" '
                        BEGIN {
                            if (b <= 0) { print "?"; exit }
                            rate = b / s
                            remaining = t - b
                            if (rate <= 0) { print "?"; exit }
                            eta_sec = remaining / rate
                            m = int(eta_sec / 60)
                            if (m < 1) { print "<1m" }
                            else if (m < 60) { printf "%dm", m }
                            else { printf "%dh%dm", int(m/60), m%60 }
                        }')"
                fi
            else
                speed_mb="0.0"
                eta_str="calculating..."
            fi

            local done_gb total_gb
            done_gb="$(awk -v b="$bytes_done" 'BEGIN{printf "%.1f", b/1024/1024/1024}')"
            total_gb="$(awk -v b="$total_bytes" 'BEGIN{printf "%.1f", b/1024/1024/1024}')"

            if $is_tty; then
                local filled=$(( pct_int * bar_width / 100 ))
                (( filled > bar_width )) && filled=$bar_width
                local empty=$(( bar_width - filled ))
                local bar
                bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"

                printf '\r\033[K[%s] %3d%% | %s/%s GB | %s/%s files | %s MB/s | ETA %s' \
                    "$bar" "$pct_int" "$done_gb" "$total_gb" \
                    "$files_done" "$total_files" "$speed_mb" "$eta_str"
            else
                local now
                now="$(date +%s)"
                if (( now - last_log_time >= 60 )); then
                    echo "Backup progress: ${pct_int}% | ${done_gb}/${total_gb} GB | ${files_done}/${total_files} files | ${speed_mb} MB/s | ETA ${eta_str}"
                    last_log_time="$now"
                fi
            fi
        elif [[ "$msg_type" == "summary" ]]; then
            if $is_tty; then
                printf '\r\033[K'
            fi
            echo "$line" | jq -r '
                "Files: \(.files_new) new, \(.files_changed) changed, \(.files_unmodified) unmodified",
                "Added to the repository: \(.data_added) bytes",
                "snapshot \(.snapshot_id) saved"
            ' 2>/dev/null
        fi
    done

    if $is_tty; then
        echo ""
    fi
    return 0
}