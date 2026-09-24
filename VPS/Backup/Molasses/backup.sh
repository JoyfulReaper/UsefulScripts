#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STAGING="/var/lib/vps-backup/staging"
readonly ROOT_STAGE="$STAGING/root"
readonly MANIFEST_STAGE="$STAGING/manifest"

readonly PEER_ENV="/etc/vps-backup/peer.env"
readonly PEER_PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly PEER_REPOSITORY="rest:http://10.99.0.1:8000/molasses/"

readonly B2_ENV="/etc/vps-backup/b2.env"
readonly B2_REPOSITORY="s3:https://s3.us-east-005.backblazeb2.com/kgivler-backup-molasses"

readonly NTFY_ENV="/etc/vps-backup/ntfy.env"
readonly NTFY_URL="http://10.99.0.1:5197/vps-backups"

START_EPOCH="$(date +%s)"
CURRENT_STAGE="startup"


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

    if [[ "$exit_code" -ne 0 ]]; then
        message="$(
            printf \
                'Host: Molasses\nStage: %s\nExit code: %s\nRuntime: %s' \
                "$CURRENT_STAGE" \
                "$exit_code" \
                "$(duration)"
        )"

        notify \
            "Molasses backup FAILED" \
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

    if [[ ! -f "$source" ]]; then
        log "SQLite database missing; skipping: $source"
        return 0
    fi

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
    flock \
    curl \
    ip \
    ss \
    systemctl \
    docker
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
# Prevent overlapping backups
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




log "Starting Molasses backup."


#
# Verify peer repository
#

CURRENT_STAGE="peer repository connectivity"

log "Checking Clanker repository connectivity."

restic \
    -r "$PEER_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    cat config \
    >/dev/null ||
    die "Unable to access Molasses repository on Clanker."


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
    die "Unable to access Molasses repository on Backblaze B2."


#
# Fresh staging tree
#

CURRENT_STAGE="staging initialization"

rm -rf "$STAGING"

mkdir -p \
    "$ROOT_STAGE" \
    "$MANIFEST_STAGE"

chmod 700 "$STAGING"


#
# /etc
#
# Keep host/network/service configuration, but do not put backup credentials
# inside the repository they unlock. Pi-hole query history and downloaded list
# cache are intentionally excluded.
#

CURRENT_STAGE="staging /etc"

log "Staging /etc."

mkdir -p "$ROOT_STAGE/etc"

rsync_safe \
    -aHAX \
    --numeric-ids \
    --exclude='/vps-backup/' \
    --exclude='/pihole/pihole-FTL.db' \
    --exclude='/pihole/pihole-FTL.db-wal' \
    --exclude='/pihole/pihole-FTL.db-shm' \
    --exclude='/pihole/listsCache/' \
    /etc/ \
    "$ROOT_STAGE/etc/"


#
# /opt/stacks
#
# Matrix policy is deliberately identity/configuration-only. PostgreSQL and
# media are disposable after a drive failure. Scrutiny time-series history is
# also excluded; its small configuration database is snapshotted below.
#

CURRENT_STAGE="staging /opt/stacks"

log "Staging /opt/stacks with bulk/history exclusions."

mkdir -p "$ROOT_STAGE/opt/stacks"

rsync_safe \
    -aHAX \
    --numeric-ids \
    --exclude='/matrix/postgres/' \
    --exclude='/matrix/synapse/media_store/' \
    --exclude='/scrutiny/influxdb/' \
    /opt/stacks/ \
    "$ROOT_STAGE/opt/stacks/"


#
# Other application/configuration state
#

FILESYSTEM_PATHS=(
    /home/joyfulreaper/.ssh
    /opt/dockge
    /opt/pihole
    /opt/netalertx
    /var/lib/docker/volumes/loungedocker_thelounge-data/_data
    /usr/local/bin
    /usr/local/sbin
)


CURRENT_STAGE="staging application data"

log "Staging additional application and deployment data."

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
# SQLite snapshots
#
# The broad rsync above gives us the surrounding application trees. Replace
# live SQLite copies with consistent snapshots and remove staged WAL/SHM files.
#

CURRENT_STAGE="SQLite snapshots"

snapshot_sqlite \
    /opt/dockge/data/dockge.db \
    "$ROOT_STAGE/opt/dockge/data/dockge.db"

snapshot_sqlite \
    /opt/stacks/netalertx/data/db/app.db \
    "$ROOT_STAGE/opt/stacks/netalertx/data/db/app.db"

snapshot_sqlite \
    /opt/stacks/scrutiny/config/scrutiny.db \
    "$ROOT_STAGE/opt/stacks/scrutiny/config/scrutiny.db"

snapshot_sqlite \
    /opt/stacks/uptime-kuma/data/kuma.db \
    "$ROOT_STAGE/opt/stacks/uptime-kuma/data/kuma.db"

snapshot_sqlite \
    /etc/pihole/gravity.db \
    "$ROOT_STAGE/etc/pihole/gravity.db"


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

systemctl list-timers --all \
    > "$MANIFEST_STAGE/systemd-timers.txt"

ss -lntup \
    > "$MANIFEST_STAGE/listening-sockets.txt" 2>&1 || true

ufw status verbose \
    > "$MANIFEST_STAGE/ufw.txt" 2>&1 || true

dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    > "$MANIFEST_STAGE/packages.txt"

crontab -l \
    > "$MANIFEST_STAGE/root-crontab.txt" 2>&1 || true

crontab -u joyfulreaper -l \
    > "$MANIFEST_STAGE/joyfulreaper-crontab.txt" 2>&1 || true


#
# Backup to Clanker
#

CURRENT_STAGE="restic peer backup"

log "Sending snapshot to Clanker."

(
    cd "$STAGING"

    restic \
        -r "$PEER_REPOSITORY" \
        --password-file "$PEER_PASSWORD_FILE" \
        backup . \
        --host molasses \
        --tag molasses \
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
        --host molasses \
        --tag molasses \
        --tag offsite \
        --tag b2
)


#
# Success
#

CURRENT_STAGE="complete"

log "Molasses backup completed successfully in $(duration)."

log "Recent Clanker snapshots."

restic \
    -r "$PEER_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    snapshots \
    --host molasses \
    --latest 3 || true

log "Recent Backblaze B2 snapshots."

restic \
    -r "$B2_REPOSITORY" \
    --password-file "$PEER_PASSWORD_FILE" \
    snapshots \
    --host molasses \
    --latest 3 || true


SUCCESS_MESSAGE="$(
    printf \
        'Host: Molasses\nDestinations: Clanker + Backblaze B2\nRuntime: %s\nStatus: both backups completed successfully' \
        "$(duration)"
)"

notify \
    "Molasses backup succeeded" \
    "default" \
    "$SUCCESS_MESSAGE"
