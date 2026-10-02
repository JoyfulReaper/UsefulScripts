# ScopeCreep -> FrontDesk Restic Backup

Verified: 2026-10-02

## Repository

ScopeCreep stores a dedicated restic repository on FrontDesk through the native
restic REST server over the management WireGuard network.

Repository URL:

rest:http://10.99.0.14:8000/scopecreep/

FrontDesk REST server:

10.99.0.14:8000
/srv/storage/backups/restic
--private-repos

The REST authentication user is scopecreep. Credentials and the repository
encryption password live only under /etc/vps-backup/ on ScopeCreep and are not
stored in Git.

FrontDesk UFW permits TCP/8000 from ScopeCreep (10.99.0.9), Clanker
(10.99.0.1), and RyzenShine (10.99.0.2) before denying other
management-WireGuard peers access to that port.

## First validated backup

The first full ScopeCreep snapshot on FrontDesk was created on 2026-10-02:

Repository ID prefix: 933c8224
Snapshot:             f53cd6d8
Host:                 scopecreep
Tags:                 scopecreep,frontdesk
Files:                764
Logical size:         12.184 MiB
Stored:               5.017 MiB

The same backup run also created Clanker peer snapshot be0421b7. Backblaze B2
was intentionally excluded from the required backup path while B2 viability
remains under investigation.

## Restore verification

The FrontDesk snapshot was not accepted based only on upload success.

Two representative files were restored back to ScopeCreep into a temporary
directory:

/manifest/host.txt
/root/opt/dockge/data/dockge.db

The restored recovery manifest identified the expected ScopeCreep host running
Debian 13 (trixie). The restored Dockge SQLite database returned:

PRAGMA quick_check;
ok

This verifies the path:

ScopeCreep staging
  -> FrontDesk REST repository
  -> restic restore
  -> restored SQLite database
  -> SQLite integrity check

The temporary restore directory was removed after verification.

## Retention / maintenance

Normal daily backups do not run forget/prune.

FrontDesk maintenance is kept separate in:

VPS/Backup/ScopeCreep/frontdesk-repo-maintenance.sh

Policy:

- keep every snapshot within the most recent 90 days;
- run forget/prune separately from ordinary backup uploads;
- run a repository integrity check after maintenance;
- use the same lock as the normal ScopeCreep backup so they cannot overlap.

The tracked timer runs weekly Sunday around 08:00 with a randomized delay.

FrontDesk has substantially more backup capacity than the smaller peer copy, so
the longer 90-day recovery window is intentional.
