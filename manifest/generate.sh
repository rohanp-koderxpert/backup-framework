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

collect_services() {
    local running_json enabled_json failed_json

    running_json="$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null \
        | awk '{print $1"\t"$4}' \
        | jq -R -s '
            split("\n")
            | map(select(length > 0))
            | map(split("\t"))
            | map({name: .[0], sub_state: .[1]})
        ')"

    enabled_json="$(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null \
        | awk '{print $1}' \
        | jq -R -s '
            split("\n")
            | map(select(length > 0))
            | map({name: .})
        ')"

    failed_json="$(systemctl list-units --type=service --state=failed --no-legend --plain 2>/dev/null \
        | awk '{print $1}' \
        | jq -R -s '
            split("\n")
            | map(select(length > 0))
            | map({name: .})
        ')"

    jq -n \
        --argjson running "$running_json" \
        --argjson enabled "$enabled_json" \
        --argjson failed "$failed_json" \
        '{running: $running, enabled: $enabled, failed: $failed}'
}

collect_ports() {
    ss -tulnp 2>/dev/null | tail -n +2 | awk '{print $1"\t"$5"\t"$7}' | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({protocol: .[0], addr_port: .[1], raw_process: .[2]})
        | map(
            (try (.addr_port | capture("^(?<addr>.*):(?<port>[0-9]+)$"))
             catch {addr: .addr_port, port: null}) as $ap
            | {
                protocol: .protocol,
                address: $ap.addr,
                port: (if $ap.port == null then null else ($ap.port | tonumber) end),
                process: (try (.raw_process | capture("\"(?<name>[^\"]+)\"").name) catch null)
              }
          )
    '
}

# --- shared IP detection --------------------------------------------------
#
# Single source of truth for detecting this server's network interfaces
# and their IPv4 addresses. Used both here (captured into the manifest
# at backup time) and by restore/wizard.sh (compared against at restore
# time, for IP-migration detection) - keeping both call sites
# automatically in sync, same pattern as F17's shared SSH config fields.
#
# Outputs one "interface:ip" pair per line, skips loopback.
detect_labeled_ips() {
    # Excludes loopback and known virtual/bridge interface patterns
    # (Docker, LXD/LXC, libvirt, container CNI plugins) - these are
    # noise for IP-migration comparison purposes, since a container's
    # internal address is essentially always different from a real
    # server's regardless of whether actual hardware identity changed.
    ip -4 -o addr show 2>/dev/null | awk '
        $2 != "lo" &&
        $2 !~ /^docker/ &&
        $2 !~ /^br-/ &&
        $2 !~ /^veth/ &&
        $2 !~ /^lxdbr/ &&
        $2 !~ /^lxcbr/ &&
        $2 !~ /^virbr/ &&
        $2 !~ /^cni/ &&
        $2 !~ /^flannel/ {
            split($4, a, "/")
            print $2 ":" a[1]
        }
    '
}

collect_network_interfaces() {
    detect_labeled_ips | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split(":"))
        | map({interface: .[0], ip: .[1]})
    '
}

generate_manifest() {
    local server_name="${SERVER_NAME:?SERVER_NAME must be set}"
    local generated_at os_json services_json ports_json docker_json databases_json filesystems_json cron_json security_json tls_json network_json packages_file
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    os_json="$(collect_os_info)"
    services_json="$(collect_services)"
    ports_json="$(collect_ports)"
    docker_json="$(collect_docker)"
    databases_json="$(collect_databases)"
    filesystems_json="$(collect_filesystems)"
    cron_json="$(collect_cron)"
    security_json="$(collect_security)"
    tls_json="$(collect_tls)"
    network_json="$(collect_network_interfaces)"

    packages_file="$(mktemp)"
    collect_packages > "$packages_file"

    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg generated_at "$generated_at" \
        --arg server_name "$server_name" \
        --arg framework_version "$FRAMEWORK_VERSION" \
        --argjson os "$os_json" \
        --argjson services "$services_json" \
        --argjson ports "$ports_json" \
        --argjson docker "$docker_json" \
        --argjson databases "$databases_json" \
        --argjson filesystems "$filesystems_json" \
        --argjson cron "$cron_json" \
        --argjson security "$security_json" \
        --argjson tls "$tls_json" \
        --argjson network "$network_json" \
        --slurpfile packages "$packages_file" \
        '{
            schema_version: ($schema_version | tonumber),
            generated_at: $generated_at,
            server_name: $server_name,
            framework_version: $framework_version,
            os: $os,
            services: $services,
            ports: $ports,
            docker: $docker,
            databases: $databases,
            filesystems: $filesystems,
            cron: $cron,
            security: $security,
            tls: $tls,
            network: $network,
            packages: $packages[0]
        }'

    rm -f "$packages_file"
}

collect_docker_containers() {
    if ! command -v docker &>/dev/null; then
        echo '[]'
        return 0
    fi

    local ids=()
    while IFS= read -r id; do
        ids+=("$id")
    done < <(docker ps -aq 2>/dev/null)

    if [[ ${#ids[@]} -eq 0 ]]; then
        echo '[]'
        return 0
    fi

    docker inspect "${ids[@]}" 2>/dev/null | jq '
        map({
            names: (.Name | sub("^/"; "")),
            image: .Config.Image,
            status: .State.Status,
            exit_code: .State.ExitCode,
            restart_policy: .HostConfig.RestartPolicy.Name
        })
    '
}

collect_docker_images() {
    if ! command -v docker &>/dev/null; then
        echo '[]'
        return 0
    fi
    docker images --format '{{json .}}' 2>/dev/null | jq -s 'map({repository: .Repository, tag: .Tag})'
}

collect_docker_volumes() {
    if ! command -v docker &>/dev/null; then
        echo '[]'
        return 0
    fi
    docker volume ls --format '{{json .}}' 2>/dev/null | jq -s 'map({name: .Name})'
}

collect_docker_networks() {
    if ! command -v docker &>/dev/null; then
        echo '[]'
        return 0
    fi
    docker network ls --format '{{json .}}' 2>/dev/null | jq -s 'map({name: .Name})'
}

collect_docker() {
    local containers_json images_json volumes_json networks_json
    containers_json="$(collect_docker_containers)"
    images_json="$(collect_docker_images)"
    volumes_json="$(collect_docker_volumes)"
    networks_json="$(collect_docker_networks)"

    jq -n \
        --argjson containers "$containers_json" \
        --argjson images "$images_json" \
        --argjson volumes "$volumes_json" \
        --argjson networks "$networks_json" \
        '{containers: $containers, images: $images, volumes: $volumes, networks: $networks}'
}

collect_postgresql() {
    if ! command -v pg_lsclusters &>/dev/null; then
        echo '[]'
        return 0
    fi

    pg_lsclusters 2>/dev/null | tail -n +2 | awk '{print $1"\t"$2"\t"$3"\t"$4}' | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({version: .[0], cluster: .[1], port: (.[2] | tonumber), status: .[3]})
    '
}

collect_databases() {
    local pg_json
    pg_json="$(collect_postgresql)"

    jq -n --argjson pg_clusters "$pg_json" '
        {
            postgresql: {clusters: $pg_clusters},
            mysql: {clusters: []}
        }
    '
}

collect_filesystems() {
    local mounts_json fstab_json

    mounts_json="$(findmnt -J --real -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null | jq '
        .filesystems
        | map({device: .source, mountpoint: .target, fstype: .fstype, options: .options})
    ')"
    [[ -z "$mounts_json" || "$mounts_json" == "null" ]] && mounts_json='[]'

    fstab_json="$(jq -Rs '.' /etc/fstab 2>/dev/null)"
    [[ -z "$fstab_json" ]] && fstab_json='""'

    jq -n --argjson mounts "$mounts_json" --argjson fstab_raw "$fstab_json" \
        '{mounts: $mounts, fstab_raw: $fstab_raw}'
}

collect_cron() {
    local system_json user_json timers_json

    system_json="$(
        { for f in /etc/crontab /etc/cron.d/*; do
              [[ -f "$f" ]] || continue
              echo "--- $f ---"
              cat "$f"
          done
        } 2>/dev/null | jq -Rs '.'
    )"
    [[ -z "$system_json" ]] && system_json='""'

    user_json="$(
        for user in $(cut -d: -f1 /etc/passwd); do
            crontab -u "$user" -l 2>/dev/null | sed "s/^/[$user] /"
        done | jq -Rs '.'
    )"
    [[ -z "$user_json" ]] && user_json='""'

    timers_json="$(systemctl list-timers --all --no-legend --plain 2>/dev/null \
        | awk '{print $(NF-1)}' \
        | jq -R -s '
            split("\n")
            | map(select(length > 0))
            | map({name: .})
        ')"

    jq -n \
        --argjson system_raw "$system_json" \
        --argjson user_raw "$user_json" \
        --argjson systemd_timers "$timers_json" \
        '{system_raw: $system_raw, user_raw: $user_raw, systemd_timers: $systemd_timers}'
}

collect_security() {
    local users_json sudoers_json keys_json

    users_json="$(awk -F: '$3 >= 0 {print $1"\t"$3"\t"$7}' /etc/passwd | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map({username: .[0], uid: (.[1] | tonumber), shell: .[2]})
    ')"

    sudoers_json="$(
        { cat /etc/sudoers 2>/dev/null
          for f in /etc/sudoers.d/*; do
              [[ -f "$f" ]] || continue
              echo "--- $f ---"
              cat "$f"
          done
        } 2>/dev/null | jq -Rs '.'
    )"
    [[ -z "$sudoers_json" ]] && sudoers_json='""'

    keys_json="$(
        for home_dir in /root /home/*; do
            [[ -d "$home_dir" ]] || continue
            user="$(basename "$home_dir")"
            keyfile="$home_dir/.ssh/authorized_keys"
            if [[ -f "$keyfile" ]]; then
                count=$(grep -cve '^\s*$' -e '^\s*#' "$keyfile" 2>/dev/null)
                [[ -z "$count" ]] && count=0
                printf '%s\t%s\n' "$user" "$count"
            fi
        done | jq -R -s '
            split("\n")
            | map(select(length > 0))
            | map(split("\t"))
            | map({(.[0]): (.[1] | tonumber)})
            | add // {}
        '
    )"

    jq -n \
        --argjson users "$users_json" \
        --argjson sudoers_raw "$sudoers_json" \
        --argjson ssh_authorized_keys_count "$keys_json" \
        '{users: $users, sudoers_raw: $sudoers_raw, ssh_authorized_keys_count: $ssh_authorized_keys_count}'
}

collect_tls() {
    local certs_json="[]"
    local cert_dir="/etc/letsencrypt/live"

    if [[ -d "$cert_dir" ]]; then
        certs_json="$(
            for domain_dir in "$cert_dir"/*/; do
                [[ -d "$domain_dir" ]] || continue
                cert_path="${domain_dir}fullchain.pem"
                [[ -f "$cert_path" ]] || continue

                expiry_raw="$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)"
                [[ -z "$expiry_raw" ]] && continue

                expires_at="$(date -u -d "$expiry_raw" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
                [[ -z "$expires_at" ]] && expires_at="null"

                domain="$(basename "$domain_dir")"
                printf '%s\t%s\t%s\n' "$cert_path" "$domain" "$expires_at"
            done | jq -R -s '
                split("\n")
                | map(select(length > 0))
                | map(split("\t"))
                | map({path: .[0], subject: .[1], expires_at: (if .[2] == "null" then null else .[2] end)})
            '
        )"
        [[ -z "$certs_json" || "$certs_json" == "null" ]] && certs_json='[]'
    fi

    jq -n --argjson certificates "$certs_json" '{certificates: $certificates}'
}

