# AGENTS.md

Working guide for humans and AI agents in `UsefulScripts`.

The main purpose of this file is to keep this repository from quietly turning
back into a private infrastructure/runbook repository.

## Repository scope

`UsefulScripts` is the **public reusable-tools repository**.

A file belongs here when it is useful outside the exact current state of Kyle's
infrastructure. Good fits include:

- reusable shell/PowerShell/Python helpers;
- generic administration utilities;
- generic backup/restore tooling;
- templates and example configuration;
- public DN42 tools and documentation;
- small monitoring/diagnostic helpers;
- reusable snippets and prompts.

`UsefulScripts` is **not** the canonical repository for live infrastructure
state.

Live operational material belongs in the private `JoyfulReaper/InfraOps`
repository, including:

- host inventories/dossiers;
- exact internal topology;
- current firewall/routing state;
- recovery runbooks tied to real hosts;
- deployment-specific configuration;
- real SSH alias/topology maps;
- home/residential-network documentation;
- exact backup relationships and recovery dependencies;
- notes whose usefulness depends on current hostnames, addresses, providers,
  ports, disks, services, or machine roles.

Secrets belong in **neither repository**. Keep passwords, private keys, API
tokens, populated environment files, restic passwords, certificate private
keys, WireGuard private keys, and similar material in the approved secret store
or protected host-local files.

## The scope test

Before adding a file, ask:

> Would this still make sense if the current hosts and topology disappeared
> tomorrow?

If yes, it probably belongs in `UsefulScripts`.

If no, it probably belongs in `InfraOps`.

If something is borderline, default to `InfraOps`. If part of it is genuinely
reusable, extract a sanitized/generic version into `UsefulScripts` rather than
copying the live runbook here.

Do not solve scope creep by duplicating the same operational document in both
repositories.

## Top-level map

Typical public/reusable areas include:

```text
UsefulScripts/
├── AGENTS.md
├── README.md
├── Docs/                  generic/public notes
├── LLMs/                  reusable prompt/context files
├── VPS/                   reusable VPS/service/network tooling and examples
├── bash/                  Unix/Linux helpers
├── powershell/            PowerShell helpers
├── windows/               Windows-specific tooling
└── kvirc/                 KVirc scripts/hooks
```

Some historical directories may still contain deployment-specific material
while the repository split is being completed. Do not treat that as precedent
for adding more private operational state here.

## DN42

Public DN42 material may remain in this repository when it is intentionally
public or reusable, for example:

- route/community decoding tools;
- generic BIRD helpers;
- public peering/tooling documentation;
- registry-facing information;
- scripts that are useful to another DN42 operator without requiring Kyle's
  private underlay/topology.

Private/internal DN42 implementation details belong in `InfraOps` when they
primarily document the live core, private underlay, host recovery, firewall
state, or residential network.

Current community metadata policy is informational only unless a separate,
deliberate routing-policy change says otherwise. Do not casually turn metadata
communities into route-selection policy during cleanup/refactoring.

## Backup tooling

Reusable backup scripts may remain public when they keep credentials outside
Git and can reasonably be adapted elsewhere.

Prefer:

- configuration/environment inputs instead of hardcoded live topology;
- secret files referenced by path rather than embedded values;
- generic repository/host variables instead of one-off deployment constants;
- example configs with placeholder values.

Detailed restore reports, exact backup topology, real repository relationships,
and host-specific disaster-recovery procedures belong in `InfraOps`.

Do not put secrets into a public example just because the surrounding script is
safe to publish.

## Deployment configuration

Examples/templates may live here.

A real production Compose file, firewall dump, SSH config, host inventory, or
other deployment map should generally live in `InfraOps`. If a public example is
valuable, create a sanitized example instead of publishing the live file.

Repository configuration is not proof of current runtime state. Do not make
claims about a live machine from an old script/template unless the live state
was separately verified.

## Safety and secrets

Never commit or ask the user to paste:

- populated `.env` files;
- passwords;
- API keys/access tokens;
- restic repository passwords;
- SSH private keys;
- WireGuard private keys;
- certificate private keys;
- Cloudflare tunnel credentials/tokens;
- ntfy authentication secrets;
- application data-protection keys;
- database credentials;
- private secret-store contents.

Before suggesting a diagnostic command that might expose credentials, prefer a
narrower command or explicitly warn about the output.

Avoid dumping unrestricted output from commands such as:

- `env` / `printenv` / `set`;
- `docker compose config` on a live deployment;
- service environment dumps;
- whole secret-bearing WireGuard/SSH configs;
- secret directories or password files.

Treat credential paths and filenames as potentially sensitive even when the
values themselves are not present.

## Change style

For scripts, infrastructure helpers, and network tooling:

- prefer one contained change at a time;
- inspect before editing;
- back up before risky live edits;
- validate syntax/configuration before reload/restart;
- verify behavior afterward;
- prefer narrow and reversible changes;
- do not mix unrelated cleanup into a routing/firewall/backup change;
- preserve unrelated edits;
- fetch the current Git file/blob immediately before overwriting it;
- use small descriptive commits.

When editing a live environment, keep live verification and public source
control as separate concepts. A reusable script can live here; the machine's
current state and recovery record belong in `InfraOps`.

## Routing/BIRD tooling

Routing changes are high-impact. A normal workflow is:

1. inspect current state;
2. make a backup outside wildcard include directories;
3. make one narrow change;
4. parse/validate the complete configuration;
5. reload only after validation;
6. verify the affected protocol/session;
7. verify representative routes/attributes;
8. verify actual forwarding before claiming data-plane transit works.

A WireGuard handshake alone does not prove BGP or forwarding policy is correct.

Keep OS differences in mind: FreeBSD paths/tools/firewall behavior differ from
Linux. Do not blindly copy Linux commands into BSD procedures.

## Documentation rules

Generic/public documentation belongs here. Live host state belongs in
`InfraOps`.

When documentation and reality disagree:

1. current live non-secret inspection wins;
2. recent verified subsystem documentation comes next;
3. generic templates/examples come after that;
4. old logs/history are historical evidence, not current truth.

Do not silently convert a dated observation into a statement about current
state.

When a live operational change materially changes infrastructure, update
`InfraOps`, not this repository, unless the reusable tool/template itself also
changed.

## Repository hygiene

Keep examples obviously non-secret and preferably placeholder-based.

Do not add files merely because they are "useful someday." Prefer a clear
purpose and reusable scope.

If a new file starts documenting things like:

- which host currently has which IP;
- how the home network is wired;
- exactly which peer/service is active;
- where a production database lives;
- which machine backs up which other machine;
- how to rebuild a named production host;

stop and put it in `InfraOps` instead.

The intended long-term shape is simple:

```text
UsefulScripts = reusable/public tools and examples
InfraOps       = private live operations and recovery state
Secrets        = outside Git
```
