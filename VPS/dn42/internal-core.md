# AS4242420425 Internal DN42 Core

Snapshot: 2026-09-30

This document records the internal routing topology for AS4242420425. It is
deliberately separate from the per-host dossiers so the distinction between
underlay transport, WireGuard, and BGP is visible in one place.

## Routers

| Router | Role | DN42 IPv4 | DN42 IPv6 |
|---|---|---|---|
| Clanker | New York public edge / ns1 | `172.20.220.49` | `fdf0:e12c:5528::1` |
| ScopeCreep | Phoenix public edge / ns2 | `172.20.220.52` | `fdf0:e12c:5528::52` |
| hbg1 | Harrisburg residential FreeBSD POP | `172.20.220.53` | `fdf0:e12c:5528::53` |

Registered allocations:

- IPv4: `172.20.220.48/28`
- IPv6: `fdf0:e12c:5528::/48`
- ASN: `AS4242420425`

## Current topology

```text
                          external DN42 peers
                         /                  \
                        /                    \
                 Clanker ---------------- ScopeCreep
                    \                       /
                     \                     /
                      \                   /
                            hbg1
                    residential FreeBSD POP
```

The three BIRD routers now form a complete internal iBGP full mesh:
- Clanker <-> ScopeCreep
- Clanker <-> hbg1
- ScopeCreep <-> hbg1
Clanker <-> ScopeCreep uses the existing WireGuard/iBGP core.
Both hbg1 legs use native residential IPv6 as their underlay. hbg1 uses IPv6
MP-BGP sessions carrying both IPv4 and IPv6 NLRI, with RFC 8950 Extended Next
Hop for IPv4.
The direct ScopeCreep <-> hbg1 session was added because ordinary iBGP
split-horizon behavior does not simply re-advertise routes learned from one
normal iBGP peer to another. With only three routers, full mesh is simpler than
introducing route reflection.
## Clanker <-> hbg1 core

WireGuard:

- Clanker: `192.168.252.5/30`, `fd42:42:42:252::5/126`
- hbg1: `192.168.252.6/30`, `fd42:42:42:252::6/126`
- Clanker UDP: `51823`
- `Table = off`

`Table = off` is intentional. WireGuard's AllowedIPs determine which peer may
carry traffic, but BIRD is responsible for installing DN42 routes.

Underlay:

- hbg1 initiates WireGuard over native residential IPv6.
- hbg1 management WireGuard remains pinned to IPv4, providing some underlay
  diversity between management and routing-core transport.

BGP:

- one IPv6 TCP session
- local/remote AS: `4242420425`
- IPv4 and IPv6 address families on the same session
- Extended Next Hop enabled and required for the IPv4 channel

RFC 8950 permits IPv4 NLRI to carry an IPv6 next hop. FreeBSD 15.1 was verified
to install real DN42 IPv4 routes through the IPv6 next hop on `wg-dn42-core`.

## ScopeCreep <-> hbg1 core

WireGuard:

- ScopeCreep: `192.168.252.9/30`, `fd42:42:42:252::9/126`
- hbg1: `192.168.252.10/30`, `fd42:42:42:252::a/126`
- ScopeCreep UDP: `51824`
- `Table = off`

Underlay:

- native residential IPv6
- hbg1 initiates the WireGuard session
- ScopeCreep endpoint: `2607:9000:700:1063:b1ee:d:c0ff:ee`

BGP:

- ScopeCreep protocol: `hbg1_core`
- hbg1 protocol: `scopecreep_core`
- one IPv6 BGP TCP session
- AS `4242420425` on both sides
- IPv4 + IPv6 NLRI
- RFC 8950 Extended Next Hop for IPv4

State verified 2026-09-30:

- Established

### Failover verification

The Clanker BGP session was deliberately disabled on hbg1:

```text
clanker_core: disabled
scopecreep_core: Established
```

hbg1 retained approximately:

- 1215 IPv4 routes
- 1163 IPv6 routes

`clanker_core` was then re-enabled and returned to Established while
`scopecreep_core` remained Established.

This confirms hbg1 has a working redundant internal route feed.
## Route policy

Clanker to hbg1:

- exports AS4242420425's own prefixes
- exports valid DN42 routes learned through permitted BGP paths
- sets itself as next hop
- uses RFC 8950 for IPv4

hbg1 to both internal core peers:

- currently exports only:
  - `172.20.220.53/32`
  - `fdf0:e12c:5528::53/128`

hbg1 therefore receives redundant full routing views from both VPS edges but
does not currently provide a third-party transit path between them.

## ROA validation

All three internal routers use generated DN42 ROA tables.

Clanker:
- `/etc/bird/roa_dn42.conf`
- `/etc/bird/roa_dn42_v6.conf`

ScopeCreep:
- `/etc/bird/roa_dn42.conf`
- `/etc/bird/roa_dn42_v6.conf`

hbg1:
- `/usr/local/etc/bird/roa_dn42.conf`
- `/usr/local/etc/bird/roa_dn42_v6.conf`

hbg1 should run its FreeBSD-native updater every 15 minutes.

## hbg1 external peering

Manual external peering requests are accepted for hbg1.

Characteristics:
- FreeBSD residential POP
- Harrisburg, PA
- approximately 200 Mbps residential Internet connection
- WireGuard preferred
- 5 Mbps cap in each direction per external peer
- no general transit by default
- no SLA
- residential addressing may change; return endpoint details after approval
  instead of treating a raw ISP address as permanent documentation

The 5 Mbps cap is per peer. If the number of residential peers grows, add a
separate aggregate DN42 cap for hbg1 so several peers cannot collectively
consume a large share of the home connection.

## Security boundary

hbg1 currently uses PF with an intentionally small policy:
- SSH allowed only when it arrives on private management `wg0`
- SSH blocked on all other interfaces
- other traffic currently allowed pending a listening-socket audit

Audit with:

```sh
sudo sockstat -46l
```

Do not tighten the remainder of PF blindly. Account for WireGuard, BGP, native
IPv6, forwarding, and future external peer interfaces.

## Current next steps

The three-router mesh and initial hbg1 failover test are complete.

Future internal-core work:

- periodically re-test failover after major routing-policy changes
- add looking-glass / monitoring visibility
- decide how future external hbg1-learned routes should propagate internally
- add DN42 BGP community metadata in a separate change without immediately
  changing route-selection policy
