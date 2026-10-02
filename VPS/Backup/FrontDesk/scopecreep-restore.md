# FrontDesk -> ScopeCreep recovery-configuration backup

Verified: 2026-10-02

## Purpose

FrontDesk is primarily a backup/storage target. This backup protects the small
set of configuration and identity material needed to rebuild FrontDesk itself
without recursively copying the bulk backup repositories or VM images that it
stores.

## Repository

ScopeCreep rest-server:

rest:http://10.99.0.9:8000/frontdesk/

Repository ID prefix:

ab8b348b

The REST authentication credentials and restic repository encryption password
live only under /etc/vps-backup/ on FrontDesk and are not stored in Git.

## Backup scope

The backup stages broad /etc while excluding /etc/vps-backup so the repository
does not contain the credentials needed to unlock itself.

Additional small recovery paths include:

/home/joyfulreaper/.ssh
/home/backup-molasses/.ssh
/root/.ssh
/var/lib/missioncontrol-agent
/var/lib/beszel-agent
/opt/missioncontrol-agent
/opt/beszel-agent
/usr/local/bin
/usr/local/sbin

A recovery manifest records host, filesystem, block-device, network, WireGuard,
systemd, timer, listener, UFW, package, account/group, repository-layout, and
VM-backup-layout information.

The backup intentionally does not copy:

/srv/storage/backups/restic
/srv/storage/backups/vms
/etc/vps-backup

## First validated snapshot

Snapshot:

77d7a828

Observed first run:

Files:      773
Logical:    109.543 MiB
Stored:     40.284 MiB
Runtime:    12 seconds

Tags:

frontdesk
config
scopecreep

## Restore verification

The first ScopeCreep snapshot was restored back to an isolated temporary
directory on FrontDesk.

Restored representative files:

/manifest/host.txt
/root/etc/fstab
/root/etc/restic-rest-server/users.htpasswd
/root/etc/wireguard/wg0.conf

The recovery manifest identified the expected FrontDesk Debian 13 host.

The following files were compared byte-for-byte with the live copies without
printing their secret-bearing contents:

/etc/fstab
/etc/restic-rest-server/users.htpasswd
/etc/wireguard/wg0.conf

All comparisons returned OK.

The temporary restore directory was removed after verification.

## Retention / maintenance

Normal daily backup runs do not prune the repository.

Separate maintenance is tracked in:

VPS/Backup/FrontDesk/scopecreep-repo-maintenance.sh

Policy:

- keep every snapshot within the most recent 90 days;
- run unlock and forget/prune separately from the daily backup;
- run a repository integrity check after pruning;
- report repository raw-data statistics;
- use the same local backup lock as the daily FrontDesk backup.

The tracked timer runs weekly Sunday around 10:00 with a randomized delay.

## Recovery notes

During a real rebuild:

1. Reinstall a compatible Debian host.
2. Establish trusted connectivity to ScopeCreep.
3. Install restic.
4. Obtain the FrontDesk REST-server login for ScopeCreep.
5. Obtain the independently preserved repository encryption password.
6. Confirm repository access with restic cat config.
7. Choose a known-good FrontDesk snapshot deliberately.
8. Restore to a temporary directory first.
9. Review ownership/permissions and copy recovery files into place selectively.
10. Restore WireGuard/SSH access before depending on private management.
11. Restore the restic-rest-server auth/configuration before reopening client
    backup access.
12. Recreate /srv/storage from the storage disk or provider recovery path as
    appropriate; do not expect this small config backup to contain the bulk
    backup repositories or VM images.

Never expose restored WireGuard private keys, SSH private keys, htpasswd data,
or populated environment files while troubleshooting.
