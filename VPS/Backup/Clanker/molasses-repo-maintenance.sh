#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPOSITORY="/var/lib/restic/molasses"
readonly PASSWORD_FILE="/etc/vps-backup/molasses-repository-password"

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
                'Storage host: Clanker\nRepository: Molasses\nStage: %s\nExit code: %s\nRuntime: %s' \
                "$CURRENT_STAGE" \
                "$exit_code" \
                "$(duration)"
        )"

        notify \
            "Molasses backup maintenance FAILED" \
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
    flock \
    du \
    df
do
    command -v "$command" >/dev/null || {
        echo "Required command not found: $command"
        exit 1
    }
done


[[ -d "$REPOSITORY" ]] || {
    echo "Repository not found: $REPOSITORY"
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


exec 9>/run/lock/molasses-backup-maintenance.lock

if ! flock -n 9; then
    echo "Another Molasses maintenance run is already active."
    exit 1
fi


set -a

# shellcheck disable=SC1091
source "$NTFY_ENV"

set +a


before="$(du -sh "$REPOSITORY" | awk '{print $1}')"

log "Repository size before maintenance: $before"


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


after="$(du -sh "$REPOSITORY" | awk '{print $1}')"
free="$(df -h / | awk 'NR==2 {print $4}')"
used_pct="$(df -P / | awk 'NR==2 {print $5}')"


CURRENT_STAGE="complete"

log "Repository size after maintenance: $after"
log "Clanker root free space: $free ($used_pct used)"
log "Maintenance completed successfully."


SUCCESS_MESSAGE="$(
    printf \
        'Storage host: Clanker\nRepository: Molasses\nBefore: %s\nAfter: %s\nDisk free: %s (%s used)\nRuntime: %s' \
        "$before" \
        "$after" \
        "$free" \
        "$used_pct" \
        "$(duration)"
)"

notify \
    "Molasses backup maintenance succeeded" \
    "default" \
    "$SUCCESS_MESSAGE"
