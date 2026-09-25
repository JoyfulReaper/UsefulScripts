# Clanker DN42 Peering Notes

Reusable notes for adding and troubleshooting DN42 BGP peers on Clanker.

## Local DN42 Identity

- ASN: `AS4242420425`
- IPv4 prefix: `172.20.220.48/28`
- Router IPv4: `172.20.220.49`
- IPv6 prefix: `fdf0:e12c:5528::/48`
- Router IPv6: `fdf0:e12c:5528::1`
- Routing daemon: BIRD 2.18
- Peer configs: `/etc/bird/peers/`
- WireGuard configs: `/etc/wireguard/`

## Current Peers

### RoutedBits EWR

- ASN: `AS4242420207`
- BIRD protocol: `routedbits_ewr1`
- WireGuard interface: `wg-dn42-ewr1`
- BGP transport: IPv6 link-local
- Peer link-local: `fe80::207`
- Local link-local: `fe80::425`
- MP-BGP IPv4/IPv6
- Extended next-hop for IPv4

### Baragoon NY

- ASN: `AS4242421732`
- BIRD protocol: `baragoon_ny1`
- WireGuard interface: `wg-dn42-ny1`
- BGP transport: IPv6 link-local
- Peer link-local: `fe80::1732`
- Local link-local: `fe80::425`

### HEADSCARF175 EWR

- ASN: `AS4242420842`
- BIRD protocol: `headscarf_ewr1`
- WireGuard interface: `wg-dn42-hs1`
- BGP transport: IPv6 link-local
- Peer link-local: `fe80:842::1:4fc9`
- Local link-local: `fe80:842::2:4fc9`
- Relationship: HEADSCARF provider / AS4242420425 customer
- MP-BGP IPv4/IPv6
- Extended next-hop for IPv4

## Routing Policy

Clanker currently behaves as a stub DN42 AS.

Peers may advertise DN42 routes to Clanker, but Clanker only exports its own
registered prefixes:

- `172.20.220.48/28`
- `fdf0:e12c:5528::/48`

Do not casually replace the export policy with `export all`.

Transit routing should be enabled deliberately only after considering:

- peer routing policy
- route leaks
- local preference
- failure behavior
- bandwidth / VPS transfer limits
- monitoring
- whether third-party DN42 traffic should be carried at all

Verify exports with:

    sudo birdc show route export <protocol>

Expected current result is one IPv4 prefix and one IPv6 prefix.

## ROA Validation

DN42 ROA tables are loaded into BIRD:

    roa4 table dn42_roa;
    roa6 table dn42_roa_v6;

Generated tables are stored at:

    /etc/bird/roa_dn42.conf
    /etc/bird/roa_dn42_v6.conf

They are refreshed by:

    /usr/local/sbin/update-dn42-roa

Repository copy:

    VPS/Clanker/update-dn42-roa.sh

The updater:

1. downloads new IPv4 and IPv6 tables
2. performs a basic route-count sanity check
3. does nothing if both files are byte-for-byte unchanged
4. validates the resulting BIRD configuration
5. restores the previous files on failure
6. reloads BIRD only when the tables actually changed

Peer imports require a valid DN42 ROA origin.

ROA validation checks the authorized route origin. It does not validate every
ASN in the complete AS path and does not prevent every possible route leak.

## Typical BIRD Peer

Peers generally inherit the shared `dnpeers` template, which contains the
common import/export and ROA policy.

Example:

    protocol bgp example_peer from dnpeers {
        description "Example DN42 peer - AS424242XXXX";

        neighbor fe80::1234 as 424242XXXX;
        interface "wg-dn42-example";

        ipv4 {
            extended next hop on;
        };
    }

For an assigned link-local address tied to an interface, BIRD can also use:

    neighbor fe80::1234 % 'wg-dn42-example' as 424242XXXX;

When using IPv6 link-local transport for both address families, enable
extended next-hop for the IPv4 channel.

Some peers may also negotiate RFC 9234 BGP roles, for example:

    local role customer;

Only configure a role that matches the relationship agreed with the peer.

## WireGuard

Use a dedicated WireGuard interface/key for each peer unless there is a good
reason not to.

Typical peer configuration:

    [Interface]
    PrivateKey = <private key>
    ListenPort = <local UDP port>
    Table = off

    [Peer]
    PublicKey = <peer public key>
    Endpoint = <peer hostname>:<peer port>
    PersistentKeepalive = 25
    AllowedIPs = 172.20.0.0/14, 10.0.0.0/8, fd00::/8, fe80::/10

Some peers assign explicit point-to-point link-local addresses. In that case
install the addresses/routes exactly as their peering documentation specifies.

Never store private WireGuard keys in this repository.

## Firewall

The public WireGuard UDP listening port must be permitted.

For example:

    sudo ufw allow 21733/udp

BGP itself may also require an INPUT rule on the DN42 WireGuard interface:

    sudo ufw allow in on wg-dn42-example proto tcp to any port 179

Prefer an interface-specific BGP rule rather than opening TCP/179 globally.

### Important Gotcha

A working WireGuard handshake does not prove that BGP can establish.

RoutedBits and Baragoon initially worked without an inbound TCP/179 rule
because Clanker initiated those TCP sessions. UFW allowed their reply traffic
as ESTABLISHED/RELATED.

HEADSCARF175 exposed the difference:

- WireGuard handshake worked
- link-local addressing was correct
- BIRD remained in `Connect`
- tcpdump showed HEADSCARF sending TCP SYN packets to Clanker's port 179
- Clanker did not answer
- UFW's default incoming policy was deny
- adding an interface-specific TCP/179 rule allowed BGP to establish

This means an outbound-working BGP peer does not prove inbound BGP connection
attempts will work.

## Adding a Peer

1. Confirm peer ASN, endpoint, addresses, link-local scheme and routing policy.
2. Test latency/connectivity to the public endpoint.
3. Generate a dedicated WireGuard keypair.
4. Choose an unused local UDP port.
5. Create the WireGuard configuration.
6. Allow the WireGuard UDP port through UFW.
7. Bring up WireGuard.
8. Verify a recent handshake.
9. Verify assigned link-local addressing and routes.
10. Add the BIRD peer using the shared `dnpeers` template.
11. Run:

       sudo bird -p -c /etc/bird/bird.conf

12. Apply:

       sudo birdc configure

13. Verify:

       sudo birdc show protocols all <peer>

14. Confirm only our own prefixes are exported:

       sudo birdc show route export <peer>

15. Check route counts and ROA filtering.

## Troubleshooting

### WireGuard

    sudo wg show <interface>

A recent handshake proves the encrypted tunnel is alive, but not that BGP is
reachable.

### Link-local addressing

    ip -6 addr show dev <interface>
    ip -6 route show dev <interface>

### BIRD

    sudo birdc show protocols
    sudo birdc show protocols all <peer>

Common states:

- `Established`: BGP is operational
- `Connect`: TCP session cannot currently establish

### TCP/179

    sudo ss -tnp | grep ':179'
    sudo ss -ltnp | grep ':179'

Test the peer:

    nc -6 -vz -w 3 'fe80::<peer>%<interface>' 179

### Packet capture

    sudo tcpdump -ni <interface> -vv 'icmp6 or tcp port 179'

This is particularly useful for determining whether:

- SYNs leave Clanker
- the peer sends SYNs toward Clanker
- Clanker sends SYN-ACK/RST responses
- traffic reaches the WireGuard interface at all

### Firewall

    sudo ufw status verbose
    sudo nft list ruleset

Do not add ad-hoc nftables rules when UFW owns the corresponding ruleset.
Make persistent changes through UFW instead.

## Useful Checks

All peers:

    sudo birdc show protocols

Full peer details:

    sudo birdc show protocols all <peer>

Routes learned from a peer:

    sudo birdc show route protocol <peer> count

Routes exported to a peer:

    sudo birdc show route export <peer>

Inspect routing choices:

    sudo birdc show route all for <DN42-address>

WireGuard state:

    sudo wg show