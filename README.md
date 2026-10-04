# Useful Scripts

A public collection of reusable administration helpers, deployment examples,
monitoring scripts, networking tools, and small utilities used across
JoyfulReaper systems.

This repository is intentionally **not** the canonical record of live
infrastructure. Host inventories, private-network topology, recovery runbooks,
and deployment-specific operational state belong in the private `InfraOps`
repository. Secrets belong outside Git entirely.

A useful scope test is:

> Would this file still be useful if the current hosts disappeared tomorrow?

If yes, it probably belongs here. If it mainly describes the current live
environment, it belongs in `InfraOps` instead.

## Repository layout

```text
UsefulScripts/
├── VPS/            reusable VPS, backup, DN42, service, and deployment material
├── bash/           small Unix/Linux shell utilities
├── kvirc/          KVirc hooks and snippets
├── LLMs/           reusable prompt/context files
├── powershell/     Windows administration and diagnostic helpers
├── windows/        other Windows-specific tooling
├── Docs/           reusable documentation
├── AGENTS.md       repository scope and working rules
└── README.md
```

The split between `UsefulScripts` and `InfraOps` is still being cleaned up, so
some older deployment-specific material may remain temporarily. New material
should follow the scope rule above rather than expanding this repository back
into an infrastructure inventory.

## VPS material

`VPS/` contains reusable tooling and examples for server administration and
self-hosted services. Depending on the subdirectory, that may include:

- Docker/Compose examples
- systemd service and timer units
- backup and restic helpers
- monitoring helpers
- DN42 tools and documentation
- service-specific deployment examples
- VPS provisioning notes

Application source normally lives in its own project repository rather than
here.

Deployment examples are not proof of current production state. Always inspect
the actual target environment before making an operational change.

## DN42

Public/reusable DN42 material belongs here when it is useful independently of
the private infrastructure layout.

Examples include:

- BIRD helper/filter examples
- `VPS/dn42/dn42-route-report.py`
- DN42 standard-community documentation
- ROA update helpers
- small routing/network diagnostic tools

Live private-core topology, recovery procedures, host-specific state, and
residential underlay details belong in `InfraOps`.

## Configuration and secrets

Example configuration may document variable names or expected file locations,
but real credential values must stay outside Git.

For example, a checked-in `.env.example` may contain names such as:

```text
API_KEY=
PASSWORD=
TOKEN=
```

while the populated deployment file remains local/private.

Do not commit:

- populated `.env` files
- passwords
- API keys or access tokens
- restic repository passwords
- SSH private keys
- WireGuard private keys
- certificate private keys
- Cloudflare tunnel credentials
- application data-protection keys
- secret-bearing database/configuration files

A private Git repository is not a substitute for a secret store.

## Backups

Backup scripts and maintenance helpers can stay public when they are reusable
and keep credentials outside the repository.

Prefer scripts that load secrets from root-owned files, environment files,
DPAPI, a password manager, or another appropriate secret store rather than
embedding credentials.

Host-specific backup topology, restore evidence, repository inventories, and
recovery runbooks belong in `InfraOps`.

## Other utilities

### Linux

`bash/` contains small shell utilities for Linux/Unix administration and
troubleshooting.

### PowerShell / Windows

`powershell/` and `windows/` contain Windows administration, diagnostics,
Hyper-V, IIS, cleanup, networking, and related helpers.

### KVirc

`kvirc/` contains IRC-related hooks/snippets such as ntfy notification helpers.
Examples must use placeholders or external secret loading rather than real
tokens.

### LLM helpers

`LLMs/` contains reusable prompt/context material. It should not be treated as a
canonical description of live infrastructure unless independently verified.

## Change philosophy

Changes here should generally make a tool or example more reusable rather than
encode more knowledge about one current machine.

When something is borderline, prefer putting the operational version in
`InfraOps` and extracting a sanitized/generic reusable version here if that
would actually be useful.

See `AGENTS.md` for the detailed repository boundary and safety rules.

## License

This repository is licensed under the [MIT License](LICENSE).
