# Molasses -> FrontDesk Restic Backup

Verified: 2026-10-02

## Repository

Molasses stores a dedicated restic repository on FrontDesk through the native
restic REST server over the management WireGuard network.

Repository URL:

rest:http://10.99.0.14:8000/molasses/

FrontDesk REST server:

10.99.0.14:8000
/srv/storage/backups/restic
--private-repos

The REST authentication user is molasses. Credentials and the repository
encryption password live only under /etc/vps-backup/ on Molasses and are not
stored in Git.

FrontDesk UFW permits TCP/8000 from Molasses (10.99.0.10), ScopeCreep
(10.99.0.9), Clanker (10.99.0.1), and RyzenShine (10.99.0.2) before denying
other management-WireGuard peers access to that port.

## First validated backup

The first full Molasses snapshot on FrontDesk was created on 2026-10-02:

Repository ID prefix: 531a6d87
Snapshot:             c2ff6533
Host:                 molasses
Tags:                 molasses,frontdesk
Files:                1005
Logical size:         50.740 MiB
Stored:               20.863 MiB

The same backup run also created Clanker peer snapshot 308b84bd. Backblaze B2
was intentionally excluded from the required backup path while B2 viability
remains under investigation.

## Restore verification

The FrontDesk snapshot was not accepted based only on upload success.

Two representative files were restored back to Molasses into a temporary
directory:

/manifest/host.txt
/root/opt/stacks/uptime-kuma/data/kuma.db

The restored recovery manifest identified the expected Molasses host running
Debian 13 (trixie). The restored Uptime Kuma SQLite database returned:

PRAGMA quick_check;
ok

This verifies the path:

Molasses staging
  -> FrontDesk REST repository
  -> restic restore
  -> restored SQLite database
  -> SQLite integrity check

The temporary restore directory was removed after verification.

## Retention / maintenance

Normal daily backups do not run forget/prune.

FrontDesk maintenance is kept separate in:

VPS/Backup/Molasses/frontdesk-repo-maintenance.sh

Policy:

- keep every snapshot within the most recent 90 days;
- run forget/prune separately from ordinary backup uploads;
- run a repository integrity check after maintenance;
- use the same lock as the normal Molasses backup so they cannot overlap.

The tracked timer runs weekly Sunday around 09:00 with a randomized delay.

FrontDesk has substantially more backup capacity than the peer copy, so the
longer 90-day recovery window is intentional.
