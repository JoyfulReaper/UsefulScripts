#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SCOPECREEP_ENV="/etc/vps-backup/scopecreep.env"
readonly PASSWORD_FILE="/etc/vps-backup/scopecreep-repository-password"
readonly REPOSITORY="rest:http://10.99.0.9:8000/frontdesk/"

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


restic_scopecreep()
{
    (
        set -a
        # shellcheck disable=SC1091
        source "$SCOPECREEP_ENV"
        set +a

        exec restic \
            -r "$REPOSITORY" \
            --password-file "$PASSWORD_FILE" \
            "$@"
    )
}


cleanup()
{
    local exit_code=$?
    local message

    trap - EXIT

    if [[ "$exit_code" -ne 0 ]]; then
        message="$(
            printf \
                'Host: FrontDesk\nRepository: ScopeCreep\nStage: %s\nExit code: %s\nRuntime: %s' \
                "$CURRENT_STAGE" \
                "$exit_code" \
                "$(duration)"
        )"

        notify \
            "FrontDesk ScopeCreep maintenance FAILED" \
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


for command in restic curl flock
do
    command -v "$command" >/dev/null || {
        echo "Required command not found: $command"
        exit 1
    }
done


[[ -f "$SCOPECREEP_ENV" ]] || {
    echo "ScopeCreep REST credentials not found: $SCOPECREEP_ENV"
    exit 1
}

[[ -f "$PASSWORD_FILE" ]] || {
    echo "ScopeCreep repository password not found: $PASSWORD_FILE"
    exit 1
}

[[ -f "$NTFY_ENV" ]] || {
    echo "ntfy configuration not found: $NTFY_ENV"
    exit 1
}


# Use the same local lock as the daily FrontDesk backup so maintenance cannot
# overlap an upload to ScopeCreep.
exec 9>/run/lock/vps-backup.lock

if ! flock -n 9; then
    echo "A FrontDesk backup or repository-maintenance run is already active."
    exit 1
fi


set -a
# shellcheck disable=SC1091
source "$NTFY_ENV"
set +a


log "Starting FrontDesk ScopeCreep repository maintenance."

CURRENT_STAGE="repository connectivity"
log "Checking ScopeCreep repository connectivity."
restic_scopecreep cat config >/dev/null

CURRENT_STAGE="stale lock cleanup"
log "Checking for stale repository locks."
restic_scopecreep unlock

CURRENT_STAGE="90-day retention and prune"
log "Applying 90-day retention policy."
restic_scopecreep \
    forget \
    --keep-within 90d \
    --prune

CURRENT_STAGE="repository integrity check"
log "Checking ScopeCreep repository integrity."
restic_scopecreep check

CURRENT_STAGE="repository statistics"
log "ScopeCreep repository statistics."
restic_scopecreep stats --mode raw-data

CURRENT_STAGE="complete"
log "FrontDesk ScopeCreep repository maintenance completed successfully in $(duration)."

SUCCESS_MESSAGE="$(
    printf \
        'Host: FrontDesk\nRepository: ScopeCreep\nRetention: keep all snapshots within 90 days\nStatus: prune + check completed\nRuntime: %s' \
        "$(duration)"
)"

notify \
    "FrontDesk ScopeCreep maintenance succeeded" \
    "default" \
    "$SUCCESS_MESSAGE"
