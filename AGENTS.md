# AGENTS.md

Operational guide for humans and AI agents working in this repository.

This file is intended to answer two questions quickly:

1. What is this repository and where does a thing belong?
2. What safety/operational rules should be followed before changing it?

## Repository role

`UsefulScripts` is the operations/configuration/recovery repository for the
JoyfulReaper infrastructure. It contains deployment models, host inventories,
backup scripts, systemd units, routing/network documentation, monitoring
helpers, shell utilities, and recovery notes.

It is **not** normally the source repository for the applications themselves.
Application source generally lives in separate repositories. Live deployment
trees can contain assembled build contexts that are intentionally not all
tracked here.

For example, Clanker's live main Compose tree is:

```text
/opt/stacks/joyful-stack
```

and `/opt/joyful-stack` is a symlink to that tree. The live tree may contain
application build contexts that do not exist in `UsefulScripts`.

## Top-level map

```text
UsefulScripts/
├── AGENTS.md              this operational guide
├── README.md              public/high-level repository overview
├── Docs/                  general infrastructure/recovery notes
├── LLMs/                  reusable LLM prompts/context
├── VPS/                   server, service, DN42, backup, and deployment material
├── bash/                  small Unix/Linux shell utilities
├── powershell/            Windows administration/diagnostic helpers
├── windows/               other Windows-specific material
├── kvirc/                 KVirc hooks/config snippets
└── ssh_config.txt          convenient SSH aliases/topology reference
```

`README.md` is for a human-facing overview. `AGENTS.md` is the more explicit
working map and safety guide.

## VPS directory

`VPS/` is the main infrastructure area.

Important entries include:

- `VPS/compose.yml` — version-controlled model for the main Clanker Compose
  stack. Validate/deploy from the assembled live tree, not by assuming every
  build context exists in this repository.
- `VPS/.env.example` — example variable names only. Never replace this with a
  populated secret-bearing environment file.
- `VPS/New-VPS-Setup.md` — notes/checklist for provisioning a new VPS.
- `VPS/Clanker/` — Clanker host dossier and Clanker-specific operational docs.
- `VPS/ScopeCreep/` — ScopeCreep host dossier and helpers.
- `VPS/HBG1/` — hbg1 FreeBSD residential DN42 POP dossier, restore notes, and
  ROA updater.
- `VPS/Molasses/` — Molasses home-server dossier.
- `VPS/frontdesk/` — FrontDesk host material.
- `VPS/dn42/` — cross-router DN42 documentation/tools shared by the AS.
- `VPS/Backup/` — backup and repository-maintenance tooling organized by host.
- service directories such as `HappyEcho`, `HappyDaytime`, `HappyFinger`,
  `HappyGopher`, `HappyQOTD`, `MissionControl`, `RandomSteamGame`, and `Beszel`
  contain deployment/configuration material for those services, not necessarily
  their complete application source.

When looking for the current state of a machine, prefer its host dossier before
inferring state from old scripts or snippets.

## Host dossiers: canonical operational snapshots

The large `*.txt` host files are broad infrastructure/recovery inventories.
They are intentionally more detailed than a normal README and should be kept
useful for rebuilding or understanding a machine.

Primary dossiers:

- `VPS/Clanker/clanker.txt`
- `VPS/ScopeCreep/scopecreep.txt`
- `VPS/HBG1/hbg1.txt`
- `VPS/Molasses/molasses.txt`
- `VPS/frontdesk/frontdesk.txt`

These files may contain dated observations. Do not silently convert an old
observation into a claim about current live state. If a change is being made
live and the resulting state has been verified, update the relevant dossier or
specialized documentation when practical.

Prefer specialized docs for detailed procedures and let the host dossier point
to them rather than duplicating many pages of the same material.

## DN42

AS identity:

```text
AS4242420425
IPv4: 172.20.220.48/28
IPv6: fdf0:e12c:5528::/48
```

Main DN42 routers currently documented in this repo:

- **Clanker** — primary VPS edge/router.
- **ScopeCreep** — secondary VPS edge/router.
- **hbg1** — FreeBSD residential POP hosted on Molasses.

Clanker, ScopeCreep, and hbg1 form the internal three-router core. Do not assume
that every external peer has the same export/transit policy.

### DN42 documentation map

Use these before reinventing or guessing policy:

- `VPS/dn42/internal-core.md` — internal core topology/design.
- `VPS/dn42/looking-glass.md` — looking-glass deployment/architecture.
- `VPS/dn42/community-metadata.md` — canonical documentation for the current
  DN42 standard-community metadata implementation across the three routers.
- `VPS/dn42/dn42-route-report.py` — read-only human-readable decoder/report for
  BIRD route output and DN42 `64511:*` communities.
- `VPS/dn42/netrate` — DN42 network-rate helper.
- `VPS/Clanker/dn42-peering.md` — Clanker peering details/policy.
- `VPS/Clanker/dn42-controlled-transit.md` — Clanker controlled-transit design
  and current explicit transit peers.
- `VPS/Clanker/boot-recovery.md` — verified Clanker boot/recovery behavior.
- `VPS/HBG1/hbg1-restore.md` — hbg1 restore/rebuild procedure.

### DN42 community policy

As of 2026-10-04, DN42 standard communities are used as **informational
metadata only**. They describe latency, bandwidth, crypto, topology, packet
loss, and origin geography. The helpers intentionally do **not** change
`local_pref`, MED, or route selection.

Do not introduce community-driven route preference as an incidental cleanup.
That is a separate routing-policy change and must be deliberate, reviewed, and
verified independently.

The canonical details and current link tuples belong in
`VPS/dn42/community-metadata.md` rather than being duplicated here.

### BIRD operational rules

Routing changes are high-impact. Use this sequence unless there is a strong
reason not to:

1. Inspect the current config/state.
2. Make a backup outside any wildcard include directory.
3. Make one narrow change.
4. Parse/validate the entire BIRD config.
5. Only then reload/reconfigure BIRD.
6. Verify the affected protocol remains Established.
7. Verify representative IPv4 and IPv6 routes/attributes.

On Linux routers, the main configuration is under `/etc/bird/`.
On hbg1/FreeBSD, it is under `/usr/local/etc/`.

Important hbg1 lesson: the config includes the peer directory with a wildcard.
Do **not** leave backup copies in `/usr/local/etc/bird/peers/`; BIRD will parse
them too and duplicate protocol definitions. Put backups under a separate
backup directory.

BIRD helper functions must be included/defined before a protocol/filter calls
them.

### hbg1 / FreeBSD differences

Do not blindly paste Linux administration commands onto hbg1.

Common differences include:

- BIRD config: `/usr/local/etc/bird.conf`
- BIRD support files: `/usr/local/etc/bird/`
- service/package paths under `/usr/local/`
- administrative group commonly `wheel`
- BSD `sed -i ''` syntax differs from GNU `sed -i`
- firewall is PF, not UFW

Prefer a parse test before any `birdc configure`.

## Backup layout and rules

Backup tooling lives under:

```text
VPS/Backup/<Host>/
```

Current host directories include:

- `Clanker`
- `ScopeCreep`
- `FrontDesk`
- `HBG1`
- `Molasses`
- `RyzenShine`

A host directory may contain:

- `backup.sh` — ordinary backup job
- `*-repo-maintenance.sh` — trusted repository maintenance
- `*-restore.md` — restore/verification notes
- `systemd/` — tracked service/timer units

Restic is the preferred backup mechanism.

Keep ordinary backup runs separate from repository maintenance
(`forget`/`prune`/`check`) when practical. The machine physically storing a
repository generally owns trusted maintenance for that repository.

### Backup safety

- Backblaze B2 is currently **broken / under investigation** for this
  environment. Do not treat old successful B2 logs/code as proof that it is a
  viable required destination. Re-evaluate cost/limits and restore/maintenance
  behavior before relying on it.
- Clanker is storage-constrained. Avoid large temporary copies/tarballs there
  unless necessary.
- Use SQLite online backup/snapshot logic for live SQLite databases; do not
  blindly copy an actively written database.
- Preserve the existing NATS/stateful-service consistency procedures in the
  backup scripts.
- Do not back up Docker images, layer/cache data, containerd cache, package
  cache, or other easily regenerated runtime/build cache without a specific
  reason.
- Do not casually delete old recovery material or repositories. Destructive
  retention/prune changes require explicit review.

## Clanker

Clanker is the primary always-on Ubuntu VPS and a central application/network
host.

Useful starting points:

- `VPS/Clanker/clanker.txt` — broad host/recovery inventory.
- `VPS/Clanker/dn42-peering.md` — DN42 peering/policy.
- `VPS/Clanker/dn42-controlled-transit.md` — explicit controlled transit.
- `VPS/Clanker/boot-recovery.md` — boot/recovery validation.
- `VPS/Backup/Clanker/backup.sh` — current tracked backup implementation.
- `VPS/Clanker/update-dn42-roa.sh` — tracked DN42 ROA updater.

Live main Compose tree:

```text
/opt/stacks/joyful-stack
```

Compatibility symlink:

```text
/opt/joyful-stack
```

Installed backup entry point is normally:

```text
/usr/local/sbin/vps-backup
```

Before changing Clanker backup coverage, compare the current Docker mounts and
persistent host paths with what the script already stages.

## ScopeCreep

ScopeCreep is the secondary always-on VPS and DN42 edge/router. It also
participates in reciprocal backup/storage duties.

Useful starting points:

- `VPS/ScopeCreep/scopecreep.txt` — broad host/recovery inventory.
- `VPS/ScopeCreep/iedon-transit-status.sh` — status helper for the iEdon
  controlled-transit path.
- `VPS/Backup/ScopeCreep/` — backup and repository-maintenance tooling.
- `VPS/dn42/community-metadata.md` — current DN42 metadata behavior.

Do not generalize a controlled-transit exception into a default full-transit
policy for every peer.

## hbg1

hbg1 is the FreeBSD residential DN42 POP/router hosted on Molasses.

Useful starting points:

- `VPS/HBG1/hbg1.txt` — broad host/recovery inventory.
- `VPS/HBG1/hbg1-restore.md` — restore procedure.
- `VPS/HBG1/update-dn42-roa.sh` — FreeBSD-compatible DN42 ROA updater.
- `VPS/Backup/HBG1/` — backup material.
- `VPS/dn42/community-metadata.md` — community/link metadata.

hbg1 is not a general unrestricted transit node by default. Preserve its
intended export/import policy unless deliberately changing network design.

## Molasses / FrontDesk / RyzenShine

- `VPS/Molasses/molasses.txt` documents the home server and the infrastructure
  around hbg1.
- `VPS/frontdesk/frontdesk.txt` documents FrontDesk.
- `VPS/Backup/Molasses/`, `VPS/Backup/FrontDesk/`, and
  `VPS/Backup/RyzenShine/` contain their corresponding backup/recovery tooling.

When a task is host-specific, read the host dossier and matching backup folder
before making assumptions about paths, services, or storage responsibilities.

## Main Compose/deployment model

`VPS/compose.yml` is a deployment model, not proof of current runtime state.
The assembled live tree is authoritative for a deployment operation, while the
repository is authoritative for what is intentionally version-controlled.

Typical safe validation from the live tree:

```sh
docker compose config --quiet
```

Do not paste unrestricted `docker compose config` output into chat/logs because
interpolated environment values can contain secrets.

Do not assume that a missing application source directory in this repository
means the service is absent from production; its build context may be assembled
from another repository into the live tree.

## General utilities

- `bash/` — small Unix/Linux helpers.
- `powershell/` — Windows administration/diagnostic helpers.
- `windows/` — other Windows-specific material.
- `kvirc/` — KVirc scripts/hooks such as ntfy integration.
- `ssh_config.txt` — SSH alias/topology reference. It may contain operational
  topology information but must not contain private keys/passwords.
- `Docs/` — general notes that span more than one specific host/service.
- `LLMs/` — reusable prompt/context files; do not treat them as live system
  state unless independently verified.

## Safety and secrets

Never commit or ask the user to paste:

- populated `.env` files
- passwords
- API keys/access tokens
- restic repository passwords
- SSH private keys
- WireGuard private keys
- certificate private keys
- Cloudflare tunnel credentials/tokens
- ntfy authentication secrets
- application data-protection keys
- database secrets
- `/etc/vps-backup/*` contents

Before suggesting a diagnostic command that could print credentials or
secret-bearing configuration, warn about it and prefer a narrower command.

Prefer metadata-only inspection such as:

- `ls -l`
- `stat`
- targeted `grep` for known non-secret fields
- `systemctl status`
- `birdc show ...`
- redacted output

Avoid unrestricted output from:

- `env`
- `printenv`
- `set`
- `docker compose config`
- `systemctl show ... Environment`
- `cat /etc/vps-backup/*`
- whole WireGuard/SSH secret-bearing configs

Treat `/home/*/.ssh`, `/etc/wireguard`, `/usr/local/etc/wireguard`,
`/etc/vps-backup`, deployment `.env` files, and certificate private material as
secret-bearing even if only one line is needed.

Do not put secrets into commits, examples, logs, issue text, or chat output.

## Change style

For operational/infrastructure work:

- Prefer one contained step at a time.
- Inspect before editing.
- Back up before risky edits.
- Keep backups out of wildcard include directories.
- Validate syntax/configuration before reload/restart.
- Verify the affected service/session afterward.
- Prefer narrow/reversible changes.
- Do not combine unrelated cleanup with a routing/firewall/backup change.
- Preserve working behavior unless the requested task explicitly changes it.
- Fetch the current Git blob/file before overwriting it.
- Preserve unrelated edits made since an earlier conversation or commit.
- Use small, descriptive commits.
- Update the relevant host dossier or specialized runbook after a verified
  operational change when that documentation would otherwise become misleading.

For firewall/routing work, a successful tunnel handshake is not proof that BGP
or forwarding policy is correct. Verify the relevant control plane and, when
claiming real transit/data-plane behavior, verify actual packet forwarding rather
than inferring it from route advertisements alone.

## Documentation precedence

When documents disagree, do not silently merge them into a fictional state.
Use this order of confidence:

1. Current live, non-secret inspection performed for the task.
2. A recently verified specialized runbook/document for that subsystem.
3. The relevant host dossier and its dated observations.
4. Generic README/example/template material.
5. Old logs/snippets/history.

State uncertainty when the live system has not been checked.

## Before finishing an infrastructure change

A useful completion checklist is:

- syntax/config validation passed
- affected service/session healthy
- representative behavior verified
- IPv4 and IPv6 both checked when the subsystem is dual-stack
- no secrets were exposed
- backup/recovery implications considered
- documentation updated if the change materially altered the documented system
- repository working tree/commit state is understood
