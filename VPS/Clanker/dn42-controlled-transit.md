# Clanker DN42 Controlled Transit

Current controlled-transit state for `AS4242420425` on Clanker.

## Transit peers

Clanker currently provides controlled full-table IPv4 and IPv6 transit to two peers:

| Peer | ASN | Interface | BIRD protocol | BIRD transit tables | Linux table | Rate limit |
|---|---|---|---|---|---:|---|
| Baragoon | `AS4242421732` | `wg-dn42-ny1` | `baragoon_ny1` | `baragoon_transit4`, `baragoon_transit6` | `1732` | 50 Mbps each direction |
| RoutedBits | `AS4242420207` | `wg-dn42-ewr1` | `routedbits_ewr1` | `routedbits_transit4`, `routedbits_transit6` | `2207` | 50 Mbps each direction |

Other Clanker external sessions remain own-prefix-only exports unless explicitly configured otherwise.

## Policy model

Each transit peer gets its own alternate BIRD routing tables and Linux policy-routing table.

Traffic arriving from a transit peer follows two policy rules:

1. Traffic destined for `172.20.220.48/28` or `fdf0:e12c:5528::/48` bypasses the transit table and uses normal local/main routing.
2. Other traffic arriving from that peer uses the peer-specific transit table.

The alternate table excludes third-party paths learned through the same ingress peer, preventing traffic from being sent straight back to the peer that delivered it. Routes originated directly by that peer remain on the direct link.

The BGP export policy for each controlled-transit peer:

- always advertises AS4242420425's own IPv4/IPv6 prefixes;
- rejects paths containing the peer ASN, preventing reflection of that peer's routes back to it;
- honors standard `NO_EXPORT` (`65535:65281`) and `NO_ADVERTISE` (`65535:65282`) communities;
- exports only valid DN42 networks;
- uses `secondary on` so BIRD can choose an eligible alternate path when the preferred route is unsuitable for export to that peer.

## Baragoon

Ingress policy rules:

```text
priority 21860  own-prefix destination bypass -> main
priority 21870  iif wg-dn42-ny1 -> table 1732
```

Persistent services:

```text
dn42-baragoon-transit-policy.service
dn42-baragoon-rate-limit.service
```

## RoutedBits

Ingress policy rules:

```text
priority 21880  own-prefix destination bypass -> main
priority 21890  iif wg-dn42-ewr1 -> table 2207
```

Persistent services:

```text
dn42-routedbits-transit-policy.service
dn42-routedbits-rate-limit.service
```

RoutedBits transit was enabled on 2026-10-04. Immediately after activation, Clanker exported approximately 1,310 IPv4 and 1,233 IPv6 routes to `routedbits_ewr1`. RoutedBits telemetry showed 2,539 prefixes received from AS4242420425 and 2,575 prefixes sent toward Clanker.

## Rate limiting

Each controlled-transit WireGuard interface is capped at 50 Mbps in both directions:

- egress: root TBF qdisc;
- ingress: `clsact` + `matchall` police action.

Typical verification:

```bash
sudo tc qdisc show dev <interface>
sudo tc filter show dev <interface> ingress
```

## Verification

Useful checks:

```bash
sudo birdc show protocols all baragoon_ny1
sudo birdc show protocols all routedbits_ewr1

sudo birdc show route table baragoon_transit4 count
sudo birdc show route table baragoon_transit6 count
sudo birdc show route table routedbits_transit4 count
sudo birdc show route table routedbits_transit6 count

ip -4 rule show
ip -6 rule show
ip -4 route show table 1732
ip -6 route show table 1732
ip -4 route show table 2207
ip -6 route show table 2207

systemctl is-active \
  dn42-baragoon-transit-policy.service \
  dn42-baragoon-rate-limit.service \
  dn42-routedbits-transit-policy.service \
  dn42-routedbits-rate-limit.service
```

When simulating an incoming IPv4 route decision with `ip route get ... iif`, provide an explicit source address. IPv6 tests do not necessarily require it.

Transit remains experimental and best-effort. Do not turn a normal peering session into full-table transit without deliberately adding the peer-specific export, anti-hairpin, persistence, and rate-limit policy.
