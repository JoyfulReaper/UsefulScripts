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
├── VPS/            reusable DN42, Unbound, and monitoring helpers
├── kvirc/          KVirc hooks and snippets
├── LLMs/           reusable prompt/context files
├── powershell/     Windows administration and diagnostic helpers
├── yggdrasil/      Yggdrasil-related helpers
├── Docs/           reusable documentation
├── AGENTS.md       repository scope and working rules
└── README.md
```

New material should follow the scope rule above rather than expanding this
repository back into an infrastructure inventory.

## VPS material

`VPS/` contains reusable tooling and documentation for server administration
and networking. Current material includes:

- DN42 tools and documentation
- Linux and FreeBSD BIRD ROA update helpers
- Unbound configuration snippets
- monitoring and health-check helpers

Application source normally lives in its own project repository rather than
here.

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

## Other utilities

### PowerShell

`powershell/` contains Windows administration, diagnostics, IIS, cleanup,
networking, and related helpers.

### KVirc

`kvirc/` contains IRC-related hooks/snippets such as ntfy notification helpers.
Examples must use placeholders or external secret loading rather than real
tokens.

### Yggdrasil

`yggdrasil/` contains small helpers for experimenting with and browsing
Yggdrasil-network resources.

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
