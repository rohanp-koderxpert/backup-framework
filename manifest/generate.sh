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

generate_manifest() {
    local server_name="${SERVER_NAME:?SERVER_NAME must be set}"
    local generated_at os_json services_json ports_json docker_json databases_json filesystems_json cron_json packages_file
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    os_json="$(collect_os_info)"
    services_json="$(collect_services)"
    ports_json="$(collect_ports)"
    docker_json="$(collect_docker)"
    databases_json="$(collect_databases)"
    filesystems_json="$(collect_filesystems)"
    cron_json="$(collect_cron)"

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

