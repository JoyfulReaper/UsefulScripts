# AS4242420425 Looking Glass

Operational notes for the read-only DN42 BIRD looking glass.

## Endpoints

DN42:

- `https://lg.joyfulreaper.dn42/`
- A: `172.20.220.50`
- AAAA: `fdf0:e12c:5528::50`
- nginx on Clanker proxies to `http://127.0.0.1:5000`
- TLS is issued by the Burble DN42 ACME service

Clearnet:

- `https://lg.kgivler.com/`
- Existing Cloudflare Tunnel proxies to `http://127.0.0.1:5000`

## Frontend

The `bird-lg-frontend` service runs on Clanker only:

- binary: `/usr/local/bin/bird-lg-frontend`
- listen: `127.0.0.1:5000`
- routers: `clanker`, `scopecreep`, `hbg1`
- backend domain suffix: `lg.wg.kgivler.com`
- backend proxy port: `18000`
- DN42 mode enabled
- branding: `AS4242420425 Looking Glass`

Backend names on Clanker resolve privately:

- `clanker.lg.wg.kgivler.com` -> `10.99.0.1`
- `scopecreep.lg.wg.kgivler.com` -> `10.99.0.9`
- `hbg1.lg.wg.kgivler.com` -> `192.168.252.6`

## BIRD proxy endpoints

Each router runs the read-only `bird-lg-proxy` on TCP/18000:

- Clanker: `10.99.0.1:18000`
- ScopeCreep: `10.99.0.9:18000`
- hbg1: `192.168.252.6:18000`

The proxies are bound only to private/core addresses and are restricted so the
Clanker frontend is the allowed caller. Peering/configuration functionality is
not enabled.

BIRD control sockets:

- Clanker: `/run/bird/bird.ctl`
- ScopeCreep: `/run/bird/bird.ctl`
- hbg1: `/var/run/bird.ctl`

## Services

Clanker:

- `bird-lg-proxy.service`
- `bird-lg-frontend.service`

ScopeCreep:

- `bird-lg-proxy.service`

hbg1 (FreeBSD):

- rc.d service: `bird_lg_proxy`
- service script: `/usr/local/etc/rc.d/bird_lg_proxy`

## DNS and resolver notes

`joyfulreaper.dn42` authoritative DNS is served by both AS4242420425 name
servers. When adding `lg.joyfulreaper.dn42`, the zone serial must be bumped so
the secondary transfers the changed zone.

The intended client resolver path is:

```text
clients -> Pi-hole on Molasses -> Unbound on Clanker (10.99.0.1:53)
        -> DN42 recursive anycast / local authoritative stub zones
```

Clanker Unbound has a stub zone for `joyfulreaper.dn42` pointing at the two
authoritative service addresses and a broader `dn42.` forward-zone using the
DN42 recursive anycast resolvers.

After authoritative changes, stale negative answers can be removed narrowly
with:

```bash
sudo unbound-control flush_zone joyfulreaper.dn42
```

## Quick smoke test

From Clanker:

```bash
echo '=== public frontend ==='
curl -fsSL https://lg.kgivler.com/ \
  | grep -oE '<h2>(clanker|scopecreep|hbg1): show protocols</h2>'

echo
echo '=== DN42 frontend ==='
curl -kfsSL https://lg.joyfulreaper.dn42/ \
  | grep -oE '<h2>(clanker|scopecreep|hbg1): show protocols</h2>'

echo
echo '=== backend proxies ==='
for x in \
  clanker:10.99.0.1 \
  scopecreep:10.99.0.9 \
  hbg1:192.168.252.6
do
  name=${x%%:*}
  ip=${x#*:}
  printf '%-12s ' "$name"
  if curl -fsG \
      --data-urlencode 'q=show status' \
      "http://$ip:18000/bird" >/dev/null
  then
    echo OK
  else
    echo FAIL
  fi
done
```

A healthy result shows protocol headings for all three routers on both public
frontends and `OK` for all three backend proxies.

Useful direct looking-glass checks include:

- route lookup: `/route/clanker/172.20.0.53`
- traceroute: `/traceroute/clanker/172.20.0.53`

`172.20.0.53` is one of the DN42 recursive-anycast addresses and is a convenient
basic path sanity target.

## Security posture

- frontend listens on localhost only
- backend proxies listen only on private/core addresses
- proxy ACLs allow the Clanker frontend source only
- no automatic peering/configuration endpoint is enabled
- DN42 nginx and the clearnet Cloudflare hostname expose only the frontend

This is intended to expose useful read-only routing information without
exposing private BIRD configuration or allowing routing changes.
