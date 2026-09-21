#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STAGING="/var/lib/vps-backup/staging"
readonly ROOT_STAGE="$STAGING/root"
readonly MANIFEST_STAGE="$STAGING/manifest"

readonly PEER_ENV="/etc/vps-backup/peer.env"
readonly PEER_PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly PEER_REPOSITORY="rest:http://10.99.0.1:8000/scopecreep/"

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


die()
{
    log "ERROR: $*"
    exit 1
}


cleanup()
{
    local exit_code=$?

    trap - EXIT

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


[[ "$EUID" -eq 0 ]] ||
    die "This script must run as root."


for command in \
    restic \
    sqlite3 \
    rsync \
    flock \
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


exec 9>/run/lock/vps-backup.lock

if ! flock -n 9; then
    die "Another backup is already running."
fi


set -a

# shellcheck disable=SC1091
source "$PEER_ENV"

set +a


export RESTIC_PASSWORD_FILE="$PEER_PASSWORD_FILE"
export RESTIC_REPOSITORY="$PEER_REPOSITORY"


log "Starting ScopeCreep backup."


CURRENT_STAGE="peer repository connectivity"

restic cat config >/dev/null ||
    die "Unable to access peer repository."


CURRENT_STAGE="staging initialization"

rm -rf "$STAGING"

mkdir -p \
    "$ROOT_STAGE" \
    "$MANIFEST_STAGE"

chmod 700 "$STAGING"


CURRENT_STAGE="staging /etc"

log "Staging /etc."

mkdir -p "$ROOT_STAGE/etc"

rsync_safe \
    -aHAX \
    --numeric-ids \
    --exclude='vps-backup/' \
    /etc/ \
    "$ROOT_STAGE/etc/"


FILESYSTEM_PATHS=(
    /home/joyfulreaper/.ssh
    /opt/stacks
    /opt/dockge
    /opt/beszel-agent
    /var/lib/beszel-agent
    /var/lib/restic/.htpasswd
)


CURRENT_STAGE="staging application data"

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


CURRENT_STAGE="SQLite snapshot"

snapshot_sqlite \
    /opt/dockge/data/dockge.db \
    "$ROOT_STAGE/opt/dockge/data/dockge.db"


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

systemctl list-unit-files \
    --state=enabled \
    > "$MANIFEST_STAGE/enabled-systemd-units.txt"

ss -lntup \
    > "$MANIFEST_STAGE/listening-sockets.txt" 2>&1 || true

dpkg-query \
    -W \
    -f='${binary:Package}\t${Version}\n' \
    > "$MANIFEST_STAGE/packages.txt"


CURRENT_STAGE="restic peer backup"

log "Sending snapshot to Clanker."

(
    cd "$STAGING"

    restic backup . \
        --host scopecreep \
        --tag scopecreep \
        --tag peer
)


CURRENT_STAGE="complete"

log "ScopeCreep backup completed successfully in $(duration)."

restic snapshots \
    --host scopecreep \
    --latest 3 || true
