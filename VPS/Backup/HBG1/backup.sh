#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly DOMAIN="hbg1"

readonly FRONTDESK_HOST="10.99.0.14"
readonly FRONTDESK_USER="backup-molasses"
readonly FRONTDESK_KEY="/root/.ssh/frontdesk-backup"

readonly REMOTE_BASE="/srv/storage/backups/vms/hbg1"
readonly LOCAL_DIR="/var/lib/libvirt/images"

STAMP="$(date '+%F-%H%M%S')"
DATE_DIR="$(date '+%F')"

IMAGE="${LOCAL_DIR}/${DOMAIN}-backup-${STAMP}.qcow2"
DOMAIN_XML="/tmp/${DOMAIN}-${STAMP}.xml"
BACKUP_XML="/tmp/${DOMAIN}-backup-${STAMP}.xml"
MANIFEST="/tmp/${DOMAIN}-${STAMP}.sha256"

REMOTE_DIR="${REMOTE_BASE}/${DATE_DIR}"


cleanup_metadata()
{
    rm -f \
        "${DOMAIN_XML}" \
        "${BACKUP_XML}" \
        "${MANIFEST}"
}


fail()
{
    echo "ERROR: $*" >&2
    echo "Local backup retained if it exists: ${IMAGE}" >&2
    exit 1
}


trap cleanup_metadata EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


#
# Preconditions
#

[[ "$EUID" -eq 0 ]] || fail "This script must run as root."

for command in \
    virsh \
    qemu-img \
    rsync \
    ssh \
    sha256sum \
    flock
do
    command -v "$command" >/dev/null ||
        fail "Required command not found: $command"
done

[[ -r "${FRONTDESK_KEY}" ]] ||
    fail "FrontDesk backup key is missing: ${FRONTDESK_KEY}"


#
# Prevent overlapping hbg1 backups.
#

exec 9>/run/lock/hbg1-backup.lock

if ! flock -n 9; then
    fail "Another hbg1 backup is already running."
fi


echo "=== hbg1 backup starting: ${STAMP} ==="


#
# The production VM must be running. This backup is intentionally live because
# hbg1 is a DN42 node where routine backup downtime is undesirable.
#

virsh -c qemu:///system domstate "${DOMAIN}" |
    grep -qx "running" ||
    fail "${DOMAIN} is not running"


#
# Create libvirt live-backup definition.
#

cat > "${BACKUP_XML}" <<EOF
<domainbackup mode='push'>
  <disks>
    <disk name='vda' type='file'>
      <driver type='qcow2'/>
      <target file='${IMAGE}'/>
    </disk>
  </disks>
</domainbackup>
EOF


#
# Save the current libvirt domain definition alongside the disk backup.
#

virsh -c qemu:///system dumpxml "${DOMAIN}" > "${DOMAIN_XML}"


#
# Start a full live backup.
#

echo "Starting live libvirt backup..."

virsh -c qemu:///system \
    backup-begin "${DOMAIN}" "${BACKUP_XML}"


#
# Wait for the asynchronous backup job to finish.
#

while true; do
    JOB_INFO="$(
        virsh -c qemu:///system \
            domjobinfo "${DOMAIN}" 2>&1 || true
    )"

    if grep -qE '^Job type:[[:space:]]+None' <<< "${JOB_INFO}"; then
        break
    fi

    if grep -qE '^Operation:[[:space:]]+Backup' <<< "${JOB_INFO}"; then
        echo "${JOB_INFO}" |
            grep -E 'File processed|File remaining|File total' ||
            true
    fi

    sleep 5
done


#
# Confirm libvirt recorded a successful completed backup job.
#

COMPLETED="$(
    virsh -c qemu:///system \
        domjobinfo "${DOMAIN}" \
        --completed \
        --anystats 2>&1
)" || fail "Could not retrieve completed backup job status"

echo "${COMPLETED}"

grep -qE '^Job type:[[:space:]]+Completed' <<< "${COMPLETED}" ||
    fail "libvirt did not report a completed backup"

grep -qE '^Operation:[[:space:]]+Backup' <<< "${COMPLETED}" ||
    fail "completed domain job was not a backup"

[[ -s "${IMAGE}" ]] ||
    fail "backup image was not created"


#
# Validate the local qcow2 before transfer.
#

echo "Checking local qcow2..."

qemu-img check "${IMAGE}" ||
    fail "local qemu-img check failed"


#
# Build an integrity manifest.
#

IMAGE_HASH="$(sha256sum "${IMAGE}" | awk '{print $1}')"
XML_HASH="$(sha256sum "${DOMAIN_XML}" | awk '{print $1}')"

{
    printf '%s  %s\n' \
        "${IMAGE_HASH}" \
        "$(basename "${IMAGE}")"

    printf '%s  %s\n' \
        "${XML_HASH}" \
        "$(basename "${DOMAIN_XML}")"
} > "${MANIFEST}"


SSH=(
    ssh
    -i "${FRONTDESK_KEY}"
    -o BatchMode=yes
    "${FRONTDESK_USER}@${FRONTDESK_HOST}"
)


#
# Ensure the dated FrontDesk destination exists.
#

"${SSH[@]}" \
    "mkdir -p '${REMOTE_DIR}'"


#
# Transfer image, libvirt XML, and integrity manifest over WireGuard.
#

echo "Transferring to FrontDesk..."

rsync -ah \
    -e "ssh -i ${FRONTDESK_KEY} -o BatchMode=yes" \
    "${IMAGE}" \
    "${DOMAIN_XML}" \
    "${MANIFEST}" \
    "${FRONTDESK_USER}@${FRONTDESK_HOST}:${REMOTE_DIR}/"


#
# Verify the transferred bytes independently on FrontDesk.
#

echo "Verifying FrontDesk hashes..."

"${SSH[@]}" \
    "cd '${REMOTE_DIR}' && sha256sum -c '$(basename "${MANIFEST}")'" ||
    fail "FrontDesk SHA-256 verification failed"


#
# Verify the destination qcow2 structure independently on FrontDesk.
#

echo "Checking FrontDesk qcow2..."

"${SSH[@]}" \
    "qemu-img check '${REMOTE_DIR}/$(basename "${IMAGE}")'" ||
    fail "FrontDesk qemu-img check failed"


#
# The remote copy has now passed both hash and qcow2 checks, so discard the
# temporary local backup image.
#

rm -f "${IMAGE}"


#
# Keep 14 dated daily backup directories on FrontDesk.
#

echo "Applying FrontDesk retention..."

"${SSH[@]}" \
    "find '${REMOTE_BASE}' \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -mtime +13 \
        -print \
        -exec rm -rf -- {} +" ||
    fail "backup succeeded but retention cleanup failed"


echo "=== hbg1 backup completed successfully ==="
echo "FrontDesk: ${REMOTE_DIR}"
