# Clanker -> FrontDesk Restic Backup

Verified: 2026-10-01

## Repository

Clanker stores a dedicated restic repository on FrontDesk through the native
restic REST server over the management WireGuard network.

Repository URL:

rest:http://10.99.0.14:8000/clanker/

FrontDesk REST server:

10.99.0.14:8000
/srv/storage/backups/restic
--private-repos

The REST authentication user is clanker. Credentials and the repository
encryption password live only under /etc/vps-backup/ on Clanker and are not
stored in Git.

FrontDesk UFW permits TCP/8000 from Clanker (10.99.0.1) and RyzenShine
(10.99.0.2) before denying other management-WireGuard peers access to that
port.

## First validated backup

The first full Clanker snapshot on FrontDesk was created on 2026-10-01:

Repository ID prefix: 23c4921c
Snapshot:             dd0dc23d
Host:                 clanker
Tags:                 clanker,frontdesk
Files:                6637
Logical size:         385.865 MiB
Stored:               117.718 MiB

The same backup run also created a fresh ScopeCreep snapshot. Backblaze B2 was
intentionally excluded from the required backup path while B2 viability remains
under investigation.

## Restore verification

The FrontDesk snapshot was not accepted based only on upload success.

Two representative files were restored back to Clanker into a temporary
directory:

/manifest/host.txt
/root/var/lib/dn42landing/peering.db

The restored recovery manifest identified the expected Clanker host and OS.
The restored DN42Landing SQLite database returned:

PRAGMA quick_check;
ok

This verifies the path:

Clanker staging
  -> FrontDesk REST repository
  -> restic restore
  -> restored SQLite database
  -> SQLite integrity check

## Retention / maintenance

Normal daily backups do not run forget/prune.

FrontDesk maintenance is kept separate in:

VPS/Backup/Clanker/frontdesk-repo-maintenance.sh

Policy:

- keep every snapshot within the most recent 90 days;
- run forget/prune separately from ordinary backup uploads;
- run a repository integrity check after maintenance;
- use the same lock as the normal Clanker backup so they cannot overlap.

The tracked timer runs weekly Sunday around 07:00 with a randomized delay.

FrontDesk has substantially more backup capacity than the smaller peer copy, so
the longer 90-day recovery window is intentional.
