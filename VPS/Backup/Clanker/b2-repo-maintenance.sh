#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly B2_ENV="/etc/vps-backup/b2.env"
readonly PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly REPOSITORY="s3:https://s3.us-east-005.backblazeb2.com/kgivler-backup-clanker"

readonly NTFY_ENV="/etc/vps-backup/ntfy.env"
readonly NTFY_URL="http://127.0.0.1:5197/vps-backups"

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


cleanup()
{
    local exit_code=$?
    local message

    trap - EXIT

    if [[ "$exit_code" -ne 0 ]]; then
        message="$(
            printf \
                'Host: Clanker\nRepository: Backblaze B2\nStage: %s\nExit code: %s\nRuntime: %s' \
                "$CURRENT_STAGE" \
                "$exit_code" \
                "$(duration)"
        )"

        notify \
            "Clanker B2 maintenance FAILED" \
            "high" \
            "$message"
    fi

    exit "$exit_code"
}


trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


[[ "$EUID" -eq 0 ]] || {
    echo "Must run as root."
    exit 1
}


for command in \
    restic \
    curl \
    flock
do
    command -v "$command" >/dev/null || {
        echo "Required command not found: $command"
        exit 1
    }
done


[[ -f "$B2_ENV" ]] || {
    echo "B2 configuration not found: $B2_ENV"
    exit 1
}

[[ -f "$PASSWORD_FILE" ]] || {
    echo "Password file not found: $PASSWORD_FILE"
    exit 1
}

[[ -f "$NTFY_ENV" ]] || {
    echo "ntfy configuration not found: $NTFY_ENV"
    exit 1
}


#
# Use the same lock as the normal backup so prune/check cannot overlap
# a backup upload.
#
exec 9>/run/lock/vps-backup.lock

if ! flock -n 9; then
    echo "A backup or B2 maintenance run is already active."
    exit 1
fi


set -a

# shellcheck disable=SC1091
source "$B2_ENV"

# shellcheck disable=SC1091
source "$NTFY_ENV"

set +a


log "Starting Clanker Backblaze B2 repository maintenance."


CURRENT_STAGE="repository connectivity"

restic \
    -r "$REPOSITORY" \
    --password-file "$PASSWORD_FILE" \
    cat config \
    >/dev/null


CURRENT_STAGE="stale lock cleanup"

log "Checking for stale repository locks."

restic \
    -r "$REPOSITORY" \
    --password-file "$PASSWORD_FILE" \
    unlock


CURRENT_STAGE="30-day retention and prune"

log "Applying 30-day retention policy."

restic \
    -r "$REPOSITORY" \
    --password-file "$PASSWORD_FILE" \
    forget \
    --keep-within 30d \
    --prune


CURRENT_STAGE="repository integrity check"

log "Checking repository integrity."

restic \
    -r "$REPOSITORY" \
    --password-file "$PASSWORD_FILE" \
    check


CURRENT_STAGE="repository statistics"

log "Repository statistics."

restic \
    -r "$REPOSITORY" \
    --password-file "$PASSWORD_FILE" \
    stats \
    --mode raw-data


CURRENT_STAGE="complete"

log "Clanker Backblaze B2 maintenance completed successfully in $(duration)."

SUCCESS_MESSAGE="$(
    printf \
        'Host: Clanker\nRepository: Backblaze B2\nRetention: keep all snapshots within 30 days\nStatus: prune + check completed\nRuntime: %s' \
        "$(duration)"
)"

notify \
    "Clanker B2 maintenance succeeded" \
    "default" \
    "$SUCCESS_MESSAGE"
