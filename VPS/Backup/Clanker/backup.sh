#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STAGING="/var/lib/vps-backup/staging"
readonly ROOT_STAGE="$STAGING/root"
readonly VOLUME_STAGE="$STAGING/docker-volumes"
readonly MANIFEST_STAGE="$STAGING/manifest"

readonly PEER_ENV="/etc/vps-backup/peer.env"
readonly PEER_PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly PEER_REPOSITORY="rest:http://10.99.0.9:8000/clanker/"

readonly B2_ENV="/etc/vps-backup/b2.env"
readonly B2_REPOSITORY="s3:https://s3.us-east-005.backblazeb2.com/kgivler-backup-clanker"

readonly NTFY_ENV="/etc/vps-backup/ntfy.env"
readonly NTFY_URL="http://127.0.0.1:5197/vps-backups"

readonly NATS_CONTAINER="joyful-stack-nats-1"
readonly NATS_VOLUME="/var/lib/docker/volumes/joyful-stack_nats-data/_data"

NATS_STOPPED=0
CURRENT_STAGE="startup"
START_EPOCH="$(date +%s)"


log()
{
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}


duration()
{
    local seconds

    seconds=$(( $(date +%s) - START_EPOCH ))

    printf '%dm %02ds' \
        "$(( seconds / 60 ))" \
        "$(( seconds % 60 ))"
}


notify()
{
    local title="$1"
    local priority="$2"
    local message="$3"

    if [[ -z "${NTFY_TOKEN:-}" ]]; then
        log "WARNING: ntfy token unavailable; notification skipped."
        return 0
    fi

    if ! curl \
        --fail \
        --silent \
        --show-error \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -d "$message" \
        "$NTFY_URL" \
        >/dev/null
    then
        log "WARNING: ntfy notification failed."
    fi
}


die()
{
    log "ERROR: $*"
    exit 1
}


cleanup()
{
    local exit_code=$?
    local message

    trap - EXIT

    if [[ "$NATS_STOPPED" -eq 1 ]]; then
        log "NATS was left stopped; attempting recovery..."

        docker start "$NATS_CONTAINER" >/dev/null 2>&1 || true
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        message="$(
            printf \
                'Host: Clanker\nStage: %s\nExit code: %s\nRuntime: %s' \
                "$CURRENT_STAGE" \
                "$exit_code" \
                "$(duration)"
        )"

        notify \
            "Clanker backup FAILED" \
            "high" \
            "$message"
    fi

    rm -rf "$STAGING" 2>/dev/null || true

    exit "$exit_code"
}


rsync_safe()
{
    local rc=0

    rsync "$@" || rc=$?

    if [[ "$rc" -eq 24 ]]; then
        log "WARNING: rsync reported vanished source files."
        return 0
    fi

    return "$rc"
}


snapshot_sqlite()
{
    local source="$1"
    local destination="$2"
    local check

    [[ -f "$source" ]] ||
        die "SQLite database disappeared: $source"

    mkdir -p "$(dirname "$destination")"

    rm -f \
        "$destination" \
        "${destination}-wal" \
        "${destination}-shm" \
        "${destination}-journal"

    log "SQLite: $source"

    sqlite3 "$source" ".backup '$destination'"

    check="$(sqlite3 "$destination" 'PRAGMA quick_check;')"

    [[ "$check" == "ok" ]] ||
        die "SQLite quick_check failed for $source: $check"
}


trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


#
# Preconditions
#

[[ "$EUID" -eq 0 ]] ||
    die "This script must run as root."

for command in \
    restic \
    sqlite3 \
    rsync \
    docker \
    tar \
    flock \
    curl \
    ip \
    ss \
    systemctl
do
    command -v "$command" >/dev/null ||
        die "Required command not found: $command"
done

[[ -f "$PEER_ENV" ]] ||
    die "Missing $PEER_ENV"

[[ -f "$PEER_PASSWORD_FILE" ]] ||
    die "Missing $PEER_PASSWORD_FILE"

[[ -f "$B2_ENV" ]] ||
    die "Missing $B2_ENV"

[[ -f "$NTFY_ENV" ]] ||
    die "Missing $NTFY_ENV"


#
# Prevent overlapping runs
#

exec 9>/run/lock/vps-backup.lock

if ! flock -n 9; then
    die "Another backup is already running."
fi


#
# Credentials
#

set -a

# shellcheck disable=SC1091
source "$PEER_ENV"

# shellcheck disable=SC1091
source "$B2_ENV"

# shellcheck disable=SC1091
source "$NTFY_ENV"

set +a



log "Starting Clanker backup."


#
# Verify repository before touching application state
#

CURRENT_STAGE="peer repository connectivity"

log "Checking ScopeCreep repository connectivity."

restic \
    -r "$PEER_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    cat config \
    >/dev/null ||
    die "Unable to access Clanker repository on ScopeCreep."


#
# Verify B2 repository
#

CURRENT_STAGE="B2 repository connectivity"

log "Checking Backblaze B2 repository connectivity."

restic \
    -r "$B2_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    cat config \
    >/dev/null ||
    die "Unable to access Clanker repository on Backblaze B2."


#
# Fresh staging tree
#

CURRENT_STAGE="staging initialization"

rm -rf "$STAGING"

mkdir -p \
    "$ROOT_STAGE" \
    "$VOLUME_STAGE" \
    "$MANIFEST_STAGE"

chmod 700 "$STAGING"


#
# /etc
#

CURRENT_STAGE="staging /etc"

log "Staging /etc."

mkdir -p "$ROOT_STAGE/etc"

rsync_safe \
    -aHAX \
    --numeric-ids \
    --exclude='vps-backup/' \
    /etc/ \
    "$ROOT_STAGE/etc/"


#
# Filesystem/application state
#

FILESYSTEM_PATHS=(
    /home/joyfulreaper/.ssh

    /var/lib/happygopher
    /var/lib/happygopher-mystery
    /var/lib/happygemini
    /var/lib/happyqotd
    /var/lib/randomsteam
    /var/lib/randomgithub
    /var/lib/wsiwot
    /var/lib/missioncontrol-agent

    /opt/stacks
    /opt/dockge
    /opt/smolsearch

    /opt/joyful-stack
)

CURRENT_STAGE="staging application data"

log "Staging application and deployment data."

for source in "${FILESYSTEM_PATHS[@]}"; do
    if [[ -e "$source" || -L "$source" ]]; then
        log "  $source"

        rsync_safe \
            -aHAXR \
            --numeric-ids \
            "$source" \
            "$ROOT_STAGE/"
    else
        log "  skipping missing path: $source"
    fi
done


#
# Filesystem SQLite databases
#

SQLITE_DATABASES=(
    /opt/dockge/data/dockge.db
    /opt/smolsearch/data/smolsearch.db

    /opt/stacks/beszel/beszel_data/auxiliary.db
    /opt/stacks/beszel/beszel_data/data.db

    /opt/stacks/joyful-stack/dashboard-auth.db

    /opt/stacks/joyful-stack/data/ntfy/auth.db
    /opt/stacks/joyful-stack/data/ntfy/cache.db

    /var/lib/happygopher/content/commands/tcpnoise.db

    /var/lib/happyqotd/data/happyqotd.db

    /var/lib/missioncontrol-agent/mission-control-agent.db

    /var/lib/randomgithub/data/randomgithub.db

    /var/lib/randomsteam/data/kgivler_com.db
    /var/lib/randomsteam/data/steam_cache.db

    /var/lib/wsiwot/WhatShouldIWorkOnToday.db
)

CURRENT_STAGE="SQLite snapshots"

log "Creating consistent SQLite snapshots."

for database in "${SQLITE_DATABASES[@]}"; do
    snapshot_sqlite \
        "$database" \
        "$ROOT_STAGE$database"
done


#
# Docker-volume SQLite
#

CURRENT_STAGE="Docker volume SQLite snapshots"

log "Snapshotting SQLite databases from Docker named volumes."

snapshot_sqlite \
    /var/lib/docker/volumes/joyful-stack_archive-data/_data/mission-control.db \
    "$VOLUME_STAGE/joyful-stack_archive-data/mission-control.db"

snapshot_sqlite \
    /var/lib/docker/volumes/joyful-stack_gitactivity-data/_data/git-activity.db \
    "$VOLUME_STAGE/joyful-stack_gitactivity-data/git-activity.db"

snapshot_sqlite \
    /var/lib/docker/volumes/joyful-stack_dashboard-data/_data/dashboard-auth.db \
    "$VOLUME_STAGE/joyful-stack_dashboard-data/dashboard-auth.db"


#
# Dashboard Data Protection keys
#

CURRENT_STAGE="dashboard Data Protection keys"

readonly DASHBOARD_KEYS="/var/lib/docker/volumes/joyful-stack_dashboard-data/_data/data-protection"

if [[ -d "$DASHBOARD_KEYS" ]]; then
    log "Staging dashboard Data Protection keys."

    mkdir -p \
        "$VOLUME_STAGE/joyful-stack_dashboard-data/data-protection"

    rsync_safe \
        -aHAX \
        --numeric-ids \
        "$DASHBOARD_KEYS/" \
        "$VOLUME_STAGE/joyful-stack_dashboard-data/data-protection/"
else
    log "WARNING: dashboard Data Protection directory not found."
fi


#
# NATS JetStream
#

CURRENT_STAGE="NATS JetStream snapshot"

log "Snapshotting NATS JetStream."

[[ -d "$NATS_VOLUME" ]] ||
    die "NATS volume not found: $NATS_VOLUME"

docker inspect "$NATS_CONTAINER" >/dev/null 2>&1 ||
    die "NATS container not found: $NATS_CONTAINER"

mkdir -p "$VOLUME_STAGE/joyful-stack_nats-data"

if [[ "$(docker inspect -f '{{.State.Running}}' "$NATS_CONTAINER")" == "true" ]]; then
    log "Stopping NATS."

    docker stop --time 30 "$NATS_CONTAINER" >/dev/null
    NATS_STOPPED=1
else
    log "NATS was already stopped."
fi

tar \
    --numeric-owner \
    --acls \
    --xattrs \
    -C "$NATS_VOLUME" \
    -cpf "$VOLUME_STAGE/joyful-stack_nats-data/nats.tar" \
    .

if [[ "$NATS_STOPPED" -eq 1 ]]; then
    log "Restarting NATS."

    docker start "$NATS_CONTAINER" >/dev/null
    NATS_STOPPED=0

    [[ "$(docker inspect -f '{{.State.Running}}' "$NATS_CONTAINER")" == "true" ]] ||
        die "NATS did not restart."
fi


#
# Recovery manifest
#

CURRENT_STAGE="recovery manifest"

log "Generating recovery manifest."

{
    echo "Backup generated:"
    date --iso-8601=seconds
    echo

    hostnamectl || true
    echo

    uname -a
    echo

    cat /etc/os-release
} > "$MANIFEST_STAGE/host.txt"

df -hT \
    > "$MANIFEST_STAGE/filesystems.txt"

lsblk -f \
    > "$MANIFEST_STAGE/block-devices.txt"

ip -brief address \
    > "$MANIFEST_STAGE/ip-addresses.txt"

ip route \
    > "$MANIFEST_STAGE/routes-ipv4.txt"

ip -6 route \
    > "$MANIFEST_STAGE/routes-ipv6.txt"

wg show \
    > "$MANIFEST_STAGE/wireguard.txt" 2>&1 || true

docker ps -a \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' \
    > "$MANIFEST_STAGE/docker-containers.txt"

docker compose ls \
    > "$MANIFEST_STAGE/docker-compose.txt" 2>&1 || true

docker volume ls \
    > "$MANIFEST_STAGE/docker-volumes.txt"

docker network ls \
    > "$MANIFEST_STAGE/docker-networks.txt"

systemctl list-unit-files \
    --state=enabled \
    > "$MANIFEST_STAGE/enabled-systemd-units.txt"

ss -lntup \
    > "$MANIFEST_STAGE/listening-sockets.txt" 2>&1 || true

dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    > "$MANIFEST_STAGE/packages.txt"

crontab -l \
    > "$MANIFEST_STAGE/root-crontab.txt" 2>&1 || true

crontab -u joyfulreaper -l \
    > "$MANIFEST_STAGE/joyfulreaper-crontab.txt" 2>&1 || true


#
# Backup to ScopeCreep
#

CURRENT_STAGE="restic peer backup"

log "Sending snapshot to ScopeCreep."

(
    cd "$STAGING"

    restic \
        -r "$PEER_REPOSITORY" \
        --password-file "$PEER_PASSWORD_FILE" \
        backup . \
        --host clanker \
        --tag clanker \
        --tag peer
)


#
# Backup to Backblaze B2
#

CURRENT_STAGE="restic B2 backup"

log "Sending snapshot to Backblaze B2."

(
    cd "$STAGING"

    restic \
        -r "$B2_REPOSITORY" \
        --password-file "$PEER_PASSWORD_FILE" \
        backup . \
        --host clanker \
        --tag clanker \
        --tag offsite \
        --tag b2
)


#
# Repository verification
#
# Sunday = ISO weekday 7.
#

if [[ "$(date +%u)" == "7" ]]; then
    CURRENT_STAGE="weekly peer repository check"

    log "Running weekly ScopeCreep repository check."

    restic \
        -r "$PEER_REPOSITORY" \
        --password-file "$PEER_PASSWORD_FILE" \
        check

    CURRENT_STAGE="weekly B2 repository check"

    log "Running weekly Backblaze B2 repository check."

    restic \
        -r "$B2_REPOSITORY" \
        --password-file "$PEER_PASSWORD_FILE" \
        check
else
    log "Skipping full repository checks; scheduled for Sunday."
fi


#
# Success
#

CURRENT_STAGE="complete"

log "Backup completed successfully."

log "Recent ScopeCreep snapshots."

restic \
    -r "$PEER_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    snapshots \
    --host clanker \
    --latest 3 || true

log "Recent Backblaze B2 snapshots."

restic \
    -r "$B2_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    snapshots \
    --host clanker \
    --latest 3 || true

SUCCESS_MESSAGE="$(
    printf \
        'Host: Clanker\nDestinations: ScopeCreep + Backblaze B2\nRuntime: %s\nStatus: both backups completed successfully' \
        "$(duration)"
)"

notify \
    "Clanker backup succeeded" \
    "default" \
    "$SUCCESS_MESSAGE"
