# DN42 Standard Community Metadata

Verified: 2026-10-04

This document records the informational DN42 standard-community metadata used by
AS4242420425 across Clanker, ScopeCreep, and hbg1.

The current implementation is **metadata only**. It does not change BGP local
preference, MED, or route selection.

## Standard community namespace

AS4242420425 uses the DN42 informational standard-community namespace under
ASN `64511`.

Relevant categories:

- `64511:1-9` — latency
- `64511:21-29` — minimum path bandwidth
- `64511:31-36` — encryption / crypto quality
- `64511:41-70` — origin region
- `64511:81-89` — topology
- `64511:91-94` — packet loss
- `64511:1000+` — origin country

Values currently used by this network include:

- latency `1` = `(0, 2.7 ms]`
- latency `3` = `(7.3, 20 ms]`
- latency `4` = `(20, 55 ms]`
- latency `5` = `(55, 148 ms]`
- bandwidth `23` = at least 10 Mbps
- crypto `34` = safe encryption with PFS, including WireGuard
- topology `83` = tunnel
- region `42` = North America-East
- region `44` = North America-West
- country `1840` = United States

A metadata argument of `0` means unknown. Unknown values do not overwrite an
existing community in that category.

Short ping samples are not used to assert a packet-loss class. Loss is left
unknown unless there is enough evidence to advertise one responsibly.

## Operational interpretation

Keep these rules in mind when reading route metadata:

- `0` does **not** mean zero latency, zero bandwidth, or zero packet loss. It
  means unknown / do not alter that metadata category.
- geography describes the route origin, not the router currently viewing the
  route
- latency propagates pessimistically: the highest / worst bucket wins
- bandwidth propagates pessimistically: the weakest / lowest bucket wins
- crypto propagates pessimistically: the weakest / lowest security bucket wins
- unknown local values do not erase known upstream values
- short ping tests are not sufficient evidence to assign a packet-loss class
- existing unrelated standard communities, large communities, and other BGP
  attributes should survive metadata processing
- these communities are informational only; they currently do not influence
  local preference, MED, or route selection

## Propagation behavior

The shared BIRD helpers preserve the DN42 path semantics while adding metadata
for each local link:

- latency keeps the worst / highest bucket encountered
- bandwidth keeps the weakest / lowest bucket encountered
- crypto keeps the weakest / lowest security bucket encountered
- origin geography is stamped only on locally originated routes
- unrelated standard communities and BGP large communities are preserved

No helper changes `bgp_local_pref`, MED, or any other route-selection attribute.

## Shared BIRD helper

Linux routers:

```text
/etc/bird/community_filters.conf
```

hbg1 / FreeBSD:

```text
/usr/local/etc/bird/community_filters.conf
```

The helper provides:

```text
dn42_update_latency()
dn42_update_bandwidth()
dn42_update_crypto()
dn42_update_topology()
dn42_update_packetloss()
dn42_update_link_metadata()
dn42_add_origin_geo()
```

On hbg1 the helper include must appear before `protocol direct direct_lo`,
because the direct-protocol import filters call `dn42_add_origin_geo()`.

hbg1 also uses a wildcard peer include, so configuration backups must not be
left in `/usr/local/etc/bird/peers/`; otherwise BIRD will parse the backup as a
second protocol definition. Backups are kept under
`/usr/local/etc/bird/backups/` instead.

## Clanker

BIRD: 2.18

Origin geography for locally originated AS4242420425 aggregate routes:

```text
64511:42    North America-East
64511:1840  United States
```

Current link metadata:

| Link | Metadata tuple | Notes |
| --- | --- | --- |
| RoutedBits EWR | `(1,23,34,83,0)` | ~2 ms, 50 Mbps controlled-transit cap, WireGuard tunnel |
| Baragoon NY | `(1,23,34,83,0)` | ~1.6 ms, 50 Mbps controlled-transit cap, WireGuard tunnel |
| HEADSCARF Piscataway | `(1,0,34,83,0)` | ~2.4 ms, bandwidth intentionally unknown |
| ScopeCreep core | `(5,0,34,83,0)` | ~56 ms |
| hbg1 core | `(3,0,34,83,0)` | ~14 ms |

The tuple order is:

```text
(latency, bandwidth, crypto, topology, packet-loss)
```

## ScopeCreep

BIRD: 2.17.5

Origin geography for ScopeCreep-owned host routes:

```text
64511:44    North America-West
64511:1840  United States
```

Current link metadata:

| Link | Metadata tuple | Notes |
| --- | --- | --- |
| iEdon Dallas | `(4,23,34,83,0)` | ~21.6 ms, 50 Mbps cap |
| Kioubit LAX | `(3,23,34,83,0)` | ~9.9 ms, 50 Mbps cap |
| MOE233 Las Vegas | `(3,0,34,83,0)` | ~7.5 ms, bandwidth unknown |
| Clanker core | `(5,0,34,83,0)` | ~56 ms |
| hbg1 core | `(5,0,34,83,0)` | ~72 ms |

ScopeCreep-owned routes currently include:

```text
172.20.220.51/32
172.20.220.52/32
fdf0:e12c:5528::51/128
fdf0:e12c:5528::52/128
```

## hbg1

BIRD: 2.19.1

hbg1 originates its router identities from `lo0` through `protocol direct
direct_lo`:

```text
172.20.220.53/32
fdf0:e12c:5528::53/128
```

Origin geography:

```text
64511:42    North America-East
64511:1840  United States
```

Current core metadata:

| Link | Metadata tuple | Measured from hbg1 |
| --- | --- | --- |
| Clanker | `(3,0,34,83,0)` | 13.541 ms average on 2026-10-04 |
| ScopeCreep | `(5,0,34,83,0)` | 71.077 ms average on 2026-10-04 |

Both IPv4 and IPv6 exports were verified to carry origin geography plus the
appropriate local core-link metadata. Both core BGP sessions remained
Established after the change.

## Phase 2B validation evidence

Phase 2B was completed on 2026-10-04 using live BIRD route views on Clanker,
ScopeCreep, and hbg1.

| Test | Observed result |
| --- | --- |
| hbg1 origin `172.20.220.53/32` viewed from Clanker | East/US origin retained; Clanker-facing latency became `3`; crypto `34`; topology `83`; local-pref `100` |
| hbg1 origin `172.20.220.53/32` viewed from ScopeCreep | East/US origin retained; ScopeCreep-facing latency became `5`; crypto `34`; topology `83`; local-pref `100` |
| External IPv4 `172.22.105.8/29` via Clanker -> hbg1 | Baragoon upstream latency `1` plus hbg1-Clanker latency `3` produced final latency `3` |
| External IPv4 `172.22.105.8/29` via ScopeCreep -> hbg1 | Kioubit upstream latency `3` plus hbg1-ScopeCreep latency `5` produced final latency `5` |
| Known upstream bandwidth plus unknown local bandwidth | Existing bandwidth `23` remained present rather than being erased by local `0` |
| External IPv6 `fd42:420:3967::/48` via HEADSCARF -> Clanker -> hbg1 | Clanker saw latency `1`; hbg1 saw latency `3`; bandwidth `26`, crypto `34`, topology `83`, and loss `91` survived |
| Large communities | Preserved on inspected IPv4 and IPv6 routes |
| BGP OTC | Preserved on the inspected HEADSCARF IPv6 route |
| Local preference | Remained `100` on inspected BGP routes |

Representative Clanker view for `172.22.105.8/29` also showed three candidate
paths with distinct propagated metadata:

- Baragoon selected path: latency `1`, bandwidth `23`, crypto `34`, East/US,
  topology `83`
- ScopeCreep/Kioubit alternate: latency `5`, bandwidth `23`, crypto `34`,
  West/US, topology `83`
- HEADSCARF alternate: latency `3`, bandwidth `26`, crypto `34`, East/US,
  topology `83`, loss `91`

This verifies that an excellent immediate link does not incorrectly replace a
worse latency bucket already accumulated farther upstream.

The IPv6 sample also demonstrated the reverse case: Clanker's direct HEADSCARF
path had latency bucket `1`, but exporting the route across the hbg1 core raised
the resulting path metadata to bucket `3`, matching the worse local segment.

No routing-policy changes were made during Phase 2B.

## Human-readable route reporter

Repository helper:

```text
VPS/dn42/dn42-route-report.py
```

The reporter is read-only. It consumes `birdc show route ... all` text from
standard input; it does not connect to BIRD, query BIRD itself, or modify BIRD
configuration/state.

It separates candidate paths, identifies the selected path, shows AS-path /
next-hop / local-pref / MED when present, and decodes DN42 `64511:*`
communities into readable labels.

Example from the repository checkout:

```sh
sudo birdc 'show route for 172.22.105.8/29 all' |
  ./VPS/dn42/dn42-route-report.py
```

Install as a normal locally maintained command:

```sh
sudo install -o root -g root -m 0755 \
  VPS/dn42/dn42-route-report.py \
  /usr/local/bin/dn42-route-report
```

Then use it as:

```sh
sudo birdc 'show route for 172.22.105.8/29 all' |
  dn42-route-report
```

`/usr/local/bin` is used rather than `/usr/bin` because this is locally managed
tooling rather than an OS/package-manager-owned file.

Current deployment status:

- installed at `/usr/local/bin/dn42-route-report` on Clanker
- not installed on ScopeCreep or hbg1; install there only when useful

## Current phase status

Phase 1 — informational metadata deployment: **complete** on all three routers.

Phase 2A — route inspection / specimen collection: **complete**.

Phase 2B — propagation validation across routers and both address families:
**complete** as of 2026-10-04.

Phase 2C — human-readable reporting and canonical operational documentation:
**complete for current needs**. The reporter and this document are tracked in
UsefulScripts.

Phase 2D — optional UI / looking-glass integration: deferred until it would be
useful.

Phase 3 — using communities to influence route selection: deliberately deferred.
No community-driven local-pref or MED policy should be introduced until that is
a separate, explicit routing-policy project.
