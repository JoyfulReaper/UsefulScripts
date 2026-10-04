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

## Verification examples

Representative Clanker view for `172.22.105.8/29` on 2026-10-04 showed three
candidate paths with distinct propagated metadata:

- Baragoon selected path: latency `1`, bandwidth `23`, crypto `34`, East/US,
  topology `83`
- ScopeCreep/Kioubit alternate: latency `5`, bandwidth `23`, crypto `34`,
  West/US, topology `83`
- HEADSCARF alternate: latency `3`, bandwidth `26`, crypto `34`, East/US,
  topology `83`, loss `91`

This also verifies that an excellent immediate link does not incorrectly replace
a worse latency bucket already accumulated farther upstream.

Existing BGP large communities on the sample route were preserved.

## Human-readable route reporter

Repository helper:

```text
VPS/dn42/dn42-route-report.py
```

Example:

```sh
sudo birdc 'show route for 172.22.105.8/29 all' |
  ./VPS/dn42/dn42-route-report.py
```

The reporter separates candidate paths, identifies the selected path, shows
AS-path / next-hop / local-pref / MED when present, and decodes DN42 `64511:*`
communities into readable labels.

## Current phase status

Phase 1 — informational metadata deployment: complete on all three routers.

Phase 2 — inspection and validation: in progress. The first human-readable route
reporter is now tracked in UsefulScripts.

Phase 3 — using communities to influence route selection: deliberately deferred.
No community-driven local-pref or MED policy should be introduced until the
metadata has been inspected and validated more broadly.
