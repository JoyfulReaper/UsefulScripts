#!/usr/bin/env python3

from pathlib import Path

path = Path("VPS/Backup/Molasses/backup.sh")

if not path.exists():
    raise SystemExit(
        f"Could not find {path}. Run this from the root of the UsefulScripts repository."
    )

text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, description: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one match for {description}, found {count}"
        )
    text = text.replace(old, new, 1)


if 'readonly B2_REPOSITORY=' in text:
    raise SystemExit("Molasses backup.sh already appears to contain B2 support.")


replace_once(
    '''readonly PEER_ENV="/etc/vps-backup/peer.env"
readonly PEER_PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly PEER_REPOSITORY="rest:http://10.99.0.1:8000/molasses/"

readonly NTFY_ENV="/etc/vps-backup/ntfy.env"
''',
    '''readonly PEER_ENV="/etc/vps-backup/peer.env"
readonly PEER_PASSWORD_FILE="/etc/vps-backup/peer-repository-password"
readonly PEER_REPOSITORY="rest:http://10.99.0.1:8000/molasses/"

readonly B2_ENV="/etc/vps-backup/b2.env"
readonly B2_REPOSITORY="s3:https://s3.us-east-005.backblazeb2.com/kgivler-backup-molasses"

readonly NTFY_ENV="/etc/vps-backup/ntfy.env"
''',
    "Backblaze constants",
)

replace_once(
    '''[[ -f "$PEER_PASSWORD_FILE" ]] ||
    die "Missing $PEER_PASSWORD_FILE"

[[ -f "$NTFY_ENV" ]] ||
''',
    '''[[ -f "$PEER_PASSWORD_FILE" ]] ||
    die "Missing $PEER_PASSWORD_FILE"

[[ -f "$B2_ENV" ]] ||
    die "Missing $B2_ENV"

[[ -f "$NTFY_ENV" ]] ||
''',
    "B2 precondition",
)

replace_once(
    '''# shellcheck disable=SC1091
source "$PEER_ENV"

# shellcheck disable=SC1091
source "$NTFY_ENV"
''',
    '''# shellcheck disable=SC1091
source "$PEER_ENV"

# shellcheck disable=SC1091
source "$B2_ENV"

# shellcheck disable=SC1091
source "$NTFY_ENV"
''',
    "B2 credentials",
)

replace_once(
    '''export RESTIC_PASSWORD_FILE="$PEER_PASSWORD_FILE"
export RESTIC_REPOSITORY="$PEER_REPOSITORY"


log "Starting Molasses backup."
''',
    '''log "Starting Molasses backup."
''',
    "global restic exports",
)

replace_once(
    '''log "Checking Clanker repository connectivity."

restic cat config >/dev/null ||
    die "Unable to access Molasses repository on Clanker."


#
# Fresh staging tree
#
''',
    '''log "Checking Clanker repository connectivity."

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
''',
    "B2 connectivity check",
)

replace_once(
    '''    restic backup . \
        --host molasses \
        --tag molasses \
        --tag peer
)


#
# Success
#
''',
    '''    restic \
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
''',
    "B2 backup",
)

replace_once(
    '''restic snapshots \
    --host molasses \
    --latest 3 || true


SUCCESS_MESSAGE="$(
    printf \
        'Host: Molasses\\nDestination: Clanker\\nRuntime: %s\\nStatus: backup completed successfully' \
        "$(duration)"
)"
''',
    '''log "Recent Clanker snapshots."

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
        'Host: Molasses\\nDestinations: Clanker + Backblaze B2\\nRuntime: %s\\nStatus: both backups completed successfully' \
        "$(duration)"
)"
''',
    "dual-destination success output",
)

path.write_text(text, encoding="utf-8", newline="\n")
print(f"Patched {path}")
