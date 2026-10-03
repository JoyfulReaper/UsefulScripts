# AS4242420425 Looking Glass

Operational notes for the read-only DN42 BIRD looking glass.

## Current implementation

Production uses the current `bird-lg-go` upstream, not the old Arnie97 fork.

- fork: `https://github.com/JoyfulReaper/bird-lg-go`
- upstream: `https://github.com/xddxdd/bird-lg-go`
- deployed version: `v1.4.8`
- deployed source commit: `4f787e5` (`release: v1.4.8`)
- source checkout on Clanker: `~/src/bird-lg-go`

The old Arnie97 binaries are intentionally still present for short-term rollback,
but no production service points at them.

## Endpoints

DN42:

- `https://lg.joyfulreaper.dn42/`
- A: `172.20.220.50`
- AAAA: `fdf0:e12c:5528::50`
- nginx on Clanker proxies to `http://127.0.0.1:5000`
- TLS is issued by the Burble DN42 ACME service

Clearnet:

- `https://lg.kgivler.com/`
- Cloudflare Tunnel on Clanker proxies directly to `http://127.0.0.1:5000`

## Frontend

The frontend runs on Clanker only.

Service:

- systemd unit: `bird-lg-frontend.service`
- binary: `/usr/local/bin/bird-lg-go`
- listen: `127.0.0.1:5000`
- routers: `clanker`, `scopecreep`, `hbg1`
- backend domain suffix: `lg.wg.kgivler.com`
- backend proxy port: `18000`
- DN42 mode enabled
- WHOIS server: `whois.dn42`
- backend HTTP timeout: `45` seconds
- branding: `AS4242420425 Looking Glass`

Current command-line shape:

```text
/usr/local/bin/bird-lg-go \
  --servers clanker,scopecreep,hbg1 \
  --domain lg.wg.kgivler.com \
  --proxy-port 18000 \
  --listen 127.0.0.1:5000 \
  --net-specific-mode dn42 \
  --whois whois.dn42 \
  --time-out 45 \
  --title-brand "AS4242420425 Looking Glass" \
  --navbar-brand "AS4242420425 Looking Glass"
```

Important: current upstream interprets `--time-out` in **seconds**. The previous
Arnie97 deployment used an older timeout option with different semantics; do not
copy its old value into the current service.

Backend names on Clanker resolve privately:

- `clanker.lg.wg.kgivler.com` -> `10.99.0.1`
- `scopecreep.lg.wg.kgivler.com` -> `10.99.0.9`
- `hbg1.lg.wg.kgivler.com` -> `192.168.252.6`

## BIRD proxy endpoints

Each router runs the current `bird-lg-go` proxy on TCP/18000:

- Clanker: `10.99.0.1:18000`
- ScopeCreep: `10.99.0.9:18000`
- hbg1: `192.168.252.6:18000`

The proxies are bound only to private/core addresses. Each proxy permits only the
Clanker frontend source address.

Current upstream command restriction is enabled. BIRD requests are limited to
read-only `show protocols` and `show route` commands. Traceroute is exposed by
its separate proxy endpoint.

BIRD control sockets:

- Clanker: `/run/bird/bird.ctl`
- ScopeCreep: `/run/bird/bird.ctl`
- hbg1: `/var/run/bird.ctl`

### Clanker proxy

- systemd unit: `bird-lg-proxy.service`
- binary: `/usr/local/bin/bird-lgproxy-go`
- service user/group: `bird:bird`
- allowed caller: `10.99.0.1`

Relevant command-line settings:

```text
--bird /run/bird/bird.ctl
--listen 10.99.0.1:18000
--allowed 10.99.0.1
--traceroute-bin traceroute
--traceroute-flags "-n -m 30 -q1 -w1"
```

### ScopeCreep proxy

- systemd unit: `bird-lg-proxy.service`
- binary: `/usr/local/bin/bird-lgproxy-go`
- service user/group: `bird:bird`
- allowed caller: `10.99.0.1`

Relevant command-line settings:

```text
--bird /run/bird/bird.ctl
--listen 10.99.0.9:18000
--allowed 10.99.0.1
--traceroute-bin traceroute
--traceroute-flags "-n -m 30 -q1 -w1"
```

Debian's `traceroute` package is installed on ScopeCreep. The `bird` service user
can run it without extra Linux capabilities.

### hbg1 proxy (FreeBSD)

hbg1 runs a FreeBSD/amd64 static build of the same current proxy source.

- rc.d service: `bird_lg_proxy`
- rc.d script: `/usr/local/etc/rc.d/bird_lg_proxy`
- binary: `/usr/local/sbin/bird-lgproxy-go`
- service user: `birdlg`
- config: `/etc/bird-lg/bird-lgproxy.yaml`
- allowed caller: `192.168.252.5` (Clanker side of the core link)

Current proxy configuration:

```yaml
bird_socket: /var/run/bird.ctl
bird_restrict_cmds: true

listen:
  - 192.168.252.6:18000

allowed_ips: 192.168.252.5

traceroute_bin: /usr/sbin/traceroute
traceroute_flags: "-n -m 30 -q1 -w1"
traceroute_raw: false
traceroute_max_concurrent: 10
```

The explicit `-m 30` is important on FreeBSD. Its traceroute default can run to
64 hops, which previously made an unanswered traceroute take about 65 seconds.
With the configured flags the worst-case unanswered test is about 30 seconds,
which fits under the frontend's 45-second backend timeout.

To cross-build the proxy on Clanker:

```bash
cd ~/src/bird-lg-go/proxy

CGO_ENABLED=0 \
GOOS=freebsd \
GOARCH=amd64 \
go build -o /tmp/bird-lgproxy-go-freebsd .
```

## DNS and resolver notes

`joyfulreaper.dn42` authoritative DNS is served by both AS4242420425 name
servers. When changing the zone, bump its serial so the secondary transfers the
new version.

Clanker Unbound listens on the private WireGuard resolver addresses:

- `10.99.0.1:53`
- `fd42:42:42::1:53`

The WireGuard client ranges are allowed to recurse through it:

```text
10.99.0.0/24
fd42:42:42::/64
```

Clanker Unbound has:

- a `dn42.` forward zone using DN42 recursive resolvers
- a `joyfulreaper.dn42.` authoritative stub zone pointing at the two local
  authoritative service addresses

General home/client resolver path remains:

```text
clients -> Pi-hole on Molasses -> Unbound on Clanker
        -> DN42 forwarders / normal DNS as appropriate
```

ScopeCreep intentionally uses Clanker directly as its system resolver so `.dn42`
hostnames work for looking-glass traceroutes as well as normal DNS:

```text
nameserver 10.99.0.1
nameserver fd42:42:42::1
```

ScopeCreep uses `openresolv`; its persistent interface DNS configuration is in:

```text
/etc/network/interfaces.d/50-cloud-init
```

Cloud-init network configuration is disabled in
`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`, so that interface file is
not expected to be regenerated by cloud-init.

hbg1 also resolves `.dn42` names successfully.

After authoritative changes, stale negative answers on Clanker can be removed
narrowly with:

```bash
sudo unbound-control flush_zone joyfulreaper.dn42
```

## WHOIS

The current frontend explicitly uses:

```text
--whois whois.dn42
```

This avoids the old default behavior of querying the Verisign WHOIS server for
DN42 objects.

Example known-good query:

```text
/whois/joyfulreaper.dn42
```

It should return the DN42 registry object for `dns/joyfulreaper.dn42`, including
`JOYFULREAPER-MNT` and the local authoritative nameservers.

## Quick smoke tests

### Frontends

From Clanker:

```bash
echo '=== public frontend ==='
curl -fsSL https://lg.kgivler.com/ \
  | grep -oE '<h2>(clanker|scopecreep|hbg1): show protocols</h2>'

echo
echo '=== DN42 frontend ==='
curl -fsSL https://lg.joyfulreaper.dn42/ \
  | grep -oE '<h2>(clanker|scopecreep|hbg1): show protocols</h2>'
```

A healthy result shows all three protocol headings on both endpoints.

### Backend BIRD proxies

Current upstream rejects arbitrary BIRD commands, so use `show protocols` or a
`show route ...` query for backend smoke tests. `show status` is intentionally
not accepted.

```bash
for x in \
  clanker:10.99.0.1 \
  scopecreep:10.99.0.9 \
  hbg1:192.168.252.6
do
  name=${x%%:*}
  ip=${x#*:}
  printf '%-12s ' "$name"
  if curl -fsG \
      --data-urlencode 'q=show protocols' \
      "http://$ip:18000/bird" >/dev/null
  then
    echo OK
  else
    echo FAIL
  fi
done
```

Expected:

```text
clanker      OK
scopecreep   OK
hbg1         OK
```

### Traceroute

Numeric target through ScopeCreep:

```bash
curl --max-time 35 -fsSG \
  --data-urlencode 'q=172.20.0.53' \
  http://10.99.0.9:18000/traceroute
```

DN42 hostname through ScopeCreep:

```bash
curl --max-time 35 -fsSG \
  --data-urlencode 'q=burble.dn42' \
  http://10.99.0.9:18000/traceroute
```

hbg1 production traceroute from Clanker:

```bash
time curl --max-time 35 -fsSG \
  --data-urlencode 'q=172.20.0.53' \
  http://192.168.252.6:18000/traceroute
```

The hbg1 unanswered case should complete in about 30 seconds rather than the old
~65-second FreeBSD default behavior.

Useful frontend checks include:

- route lookup: `/route/clanker/172.20.0.53`
- traceroute: `/traceroute/clanker/172.20.0.53`
- ScopeCreep DN42 hostname traceroute:
  `/traceroute/scopecreep/burble.dn42`

## Security posture

- frontend listens on localhost only
- backend proxies listen only on private/core addresses
- proxy ACLs allow only the Clanker frontend source
- current proxy command restriction permits only `show protocols` and
  `show route` BIRD commands
- traceroute targets are handled by current upstream validation rather than the
  stale 2020 fork
- DN42 nginx and the clearnet Cloudflare hostname expose only the frontend
- no BIRD reconfiguration or peering-management functionality is exposed

The looking glass is intended to expose useful read-only routing information
without exposing private BIRD configuration or allowing routing changes.

## Rollback files retained after migration

The old binaries and pre-v1.4.8 service backups were deliberately retained for
short-term rollback after the migration.

Clanker:

- `/usr/local/bin/bird-lg-frontend`
- `/usr/local/bin/bird-lg-proxy`
- systemd unit backups ending in `.bak-2026-10-03-pre-v1.4.8`

ScopeCreep:

- `/usr/local/bin/bird-lg-proxy`
- systemd unit backup ending in `.bak-2026-10-03-pre-v1.4.8`

hbg1:

- `/usr/local/sbin/bird-lg-proxy`
- `/usr/local/etc/rc.d/bird_lg_proxy.bak-2026-10-03-pre-v1.4.8`

Once the v1.4.8 deployment has been stable long enough, these can be removed in
a separate cleanup pass.