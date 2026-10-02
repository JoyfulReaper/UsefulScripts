#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STAGING="/var/lib/vps-backup/staging"
readonly ROOT_STAGE="$STAGING/root"
readonly MANIFEST_STAGE="$STAGING/manifest"

readonly SCOPECREEP_ENV="/etc/vps-backup/scopecreep.env"
readonly SCOPECREEP_PASSWORD_FILE="/etc/vps-backup/scopecreep-repository-password"
readonly SCOPECREEP_REPOSITORY="rest:http://10.99.0.9:8000/frontdesk/"

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


restic_scopecreep()
{
    (
        set -a
        # shellcheck disable=SC1091
        source "$SCOPECREEP_ENV"
        set +a

        exec restic \
            -r "$SCOPECREEP_REPOSITORY" \
            --password-file "$SCOPECREEP_PASSWORD_FILE" \
            "$@"
    )
}


trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


[[ "$EUID" -eq 0 ]] ||
    die "This script must run as root."


for command in \
    restic \
    rsync \
    flock \
    ip \
    ss \
    systemctl \
    dpkg-query
do
    command -v "$command" >/dev/null ||
        die "Required command not found: $command"
done


[[ -f "$SCOPECREEP_ENV" ]] ||
    die "Missing $SCOPECREEP_ENV"

[[ -f "$SCOPECREEP_PASSWORD_FILE" ]] ||
    die "Missing $SCOPECREEP_PASSWORD_FILE"


exec 9>/run/lock/vps-backup.lock

if ! flock -n 9; then
    die "Another FrontDesk backup or repository-maintenance run is active."
fi


log "Starting FrontDesk recovery-configuration backup."


CURRENT_STAGE="ScopeCreep repository connectivity"

log "Checking ScopeCreep repository connectivity."

restic_scopecreep cat config >/dev/null ||
    die "Unable to access FrontDesk repository on ScopeCreep."


CURRENT_STAGE="staging initialization"

rm -rf "$STAGING"

mkdir -p \
    "$ROOT_STAGE" \
    "$MANIFEST_STAGE"

chmod 700 "$STAGING"


#
# Broad /etc backup.
#
# FrontDesk is intentionally a small, boring host. Capturing /etc makes the
# recovery copy resilient to future service/config additions without maintaining
# a fragile allow-list. Backup-client credentials are excluded because the
# repository must not contain the password needed to unlock itself.
#

CURRENT_STAGE="staging /etc"

log "Staging /etc."

mkdir -p "$ROOT_STAGE/etc"

rsync_safe \
    -aHAX \
    --numeric-ids \
    --exclude='/vps-backup/' \
    /etc/ \
    "$ROOT_STAGE/etc/"


#
# Small recovery-relevant paths outside /etc.
#

FILESYSTEM_PATHS=(
    /home/joyfulreaper/.ssh
    /home/backup-molasses/.ssh
    /root/.ssh
    /var/lib/missioncontrol-agent
    /var/lib/beszel-agent
    /opt/missioncontrol-agent
    /opt/beszel-agent
    /usr/local/bin
    /usr/local/sbin
)


CURRENT_STAGE="staging recovery paths"

log "Staging additional recovery paths."

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
# Recovery manifest.
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

getent passwd \
    > "$MANIFEST_STAGE/passwd.txt"

getent group \
    > "$MANIFEST_STAGE/group.txt"

find /srv/storage/backups/restic \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%f\n' \
    2>/dev/null \
    | sort \
    > "$MANIFEST_STAGE/restic-repositories.txt" || true

find /srv/storage/backups/vms \
    -mindepth 1 \
    -maxdepth 2 \
    -type d \
    -printf '%P\n' \
    2>/dev/null \
    | sort \
    > "$MANIFEST_STAGE/vm-backup-layout.txt" || true


#
# Encrypted off-host backup to ScopeCreep.
#

CURRENT_STAGE="restic ScopeCreep backup"

log "Sending recovery configuration snapshot to ScopeCreep."

(
    cd "$STAGING"

    restic_scopecreep \
        backup . \
        --host frontdesk \
        --tag frontdesk \
        --tag config \
        --tag scopecreep
)


CURRENT_STAGE="complete"

log "FrontDesk recovery-configuration backup completed successfully in $(duration)."

log "Recent ScopeCreep snapshots."

restic_scopecreep \
    snapshots \
    --host frontdesk \
    --latest 3 || true
