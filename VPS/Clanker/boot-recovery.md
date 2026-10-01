# Clanker Boot Ordering / Reboot Verification

Verified: 2026-10-01

## Problem observed

After a kernel-update reboot:

- `unbound.service` remained inactive even though it was enabled.
- Docker restored most containers, but `joyful-stack-archive-1` failed to start because Docker tried to bind `10.99.0.1:5191` before `wg0` had created the `10.99.0.1` address.

The Unbound journal showed an ordering cycle:

```text
unbound.service -> wg-quick@wg0.service -> nss-lookup.target -> unbound.service
```

The local override causing the cycle was:

```ini
[Unit]
Requires=wg-quick@wg0.service
After=wg-quick@wg0.service
```

That override was disabled.

## Current fix

Unbound is allowed to bind the WireGuard listener addresses before `wg0` exists:

```ini
# /etc/unbound/unbound.conf.d/10-freebind.conf
server:
    ip-freebind: yes
```

The tracked copy is:

```text
VPS/Clanker/unbound/10-freebind.conf
```

Docker is ordered after the WireGuard startup job so containers with host bindings on `10.99.0.1` do not race the interface:

```ini
# /etc/systemd/system/docker.service.d/wg0-ordering.conf
[Unit]
Wants=wg-quick@wg0.service
After=wg-quick@wg0.service
```

The tracked copy is:

```text
VPS/Clanker/systemd/docker.service.d/wg0-ordering.conf
```

`Wants=` is intentional rather than `Requires=`: Docker should still be allowed to run services that do not need WireGuard if wg0 itself fails.

## Reboot verification

A deliberate reboot was performed after applying the fix.

Verified after reboot:

- Unbound: active
- wg-quick@wg0: active
- Docker: active
- nginx: active
- BIRD: active
- NSD: active
- cloudflared: active
- missioncontrol-agent: active
- DN42Landing: active
- Yggdrasil: active
- YggLanding: active
- no failed systemd units
- public DNS recursion through Unbound on loopback works
- DN42 DNS recursion through Unbound on loopback works
- Docker started only after `wg-quick@wg0` completed
- no new `ordering cycle` message
- no new Docker `cannot assign requested address` / `failed to allocate port` error

Observed boot order:

```text
16:28:34  Unbound starting/started
16:28:36  wg-quick@wg0 starting/finished
16:28:36  Docker starting
16:28:45  Docker started
```

BGP sessions re-established automatically after the reboot:

- Baragoon: Established
- RoutedBits: Established
- HEADSCARF175: Established
- ScopeCreep core IPv4: Established
- ScopeCreep core IPv6: Established
- hbg1 core: Established

Some peer sessions took several minutes to converge after boot; this was observed but did not require manual intervention.

## Final acceptance reboot

A second deliberate reboot was performed after repairing Archive's Docker network attachment.

Verified after the second reboot:

- all critical systemd services were active;
- no systemd units were failed;
- public and DN42 DNS resolution worked immediately through local Unbound;
- Docker again started only after `wg-quick@wg0` completed;
- no `ordering cycle`, `cannot assign requested address`, or `failed to allocate port` errors were observed;
- `joyful-stack-archive-1` attached to `joyful-stack_backend` automatically;
- Archive returned HTTP 200 / `Healthy` without manual intervention;
- all Docker containers returned to their expected running state;
- all BGP sessions eventually returned to Established without manual intervention.

Observed BGP convergence after the second reboot:

- Baragoon: ~8 seconds
- RoutedBits: ~2m22s
- HEADSCARF175: ~3m43s
- ScopeCreep IPv4: ~3m51s
- hbg1 core: ~4m05s
- ScopeCreep IPv6: ~4m08s

The slower sessions are normal convergence behavior observed across two controlled reboot tests.

## Archive incident detail

After the first fixed reboot, Archive was running but unhealthy because the existing container had no Docker network attached. It therefore could not resolve the Compose service name `nats` and never opened its HTTP listener.

Restarting the same container did not repair the missing network endpoint. Recreating only Archive did:

```bash
cd /opt/stacks/joyful-stack
docker compose up -d --no-deps --force-recreate archive
```

After recreation, Archive joined `joyful-stack_backend`, resolved `nats`, and became healthy. The second reboot confirmed that this broken-network state did not recur with the corrected Docker/WireGuard startup ordering.

## DNS access-control note

Recursive DNS on `10.99.0.1` is intentionally restricted. Current ACLs allow loopback and Molasses (`10.99.0.10` / `fd42:42:42::10`), so FrontDesk (`10.99.0.14`) correctly receives REFUSED.
