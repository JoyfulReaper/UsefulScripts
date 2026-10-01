# New VPS Setup Guide

Repeatable commissioning checklist for JoyfulReaper Linux VPSes.

This baseline was developed while commissioning **FrontDesk** on Debian 13. Adapt package names and service/network details for other distributions. The goal is a host that is inventoried, hardened, reachable over private management, monitored, backed up, reboot-tested, and documented.

> Never put passwords, API tokens, private SSH/WireGuard keys, populated `.env` files, or backup passwords in this document or in Git.

## 1. Record the provider facts first

Before changing anything, record:

- provider, plan, location, billing/renewal details;
- hostname;
- public IPv4 / gateway;
- public IPv6 / gateway;
- CPU, RAM, swap;
- disks;
- provider VNC/console/serial recovery method.

Keep the provider console available until private management has survived a reboot.

Initial inventory:

```bash
hostnamectl
uname -a
lscpu
free -h
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS
df -hT
ip -br addr
ip route
ip -6 route
ss -tulpn
systemctl --failed
```

On a minimal Debian install, useful basics are:

```bash
sudo apt update
sudo apt install -y sudo man-db curl ca-certificates
```

## 2. Hostname and `/etc/hosts`

Set the FQDN:

```bash
sudo hostnamectl set-hostname HOSTNAME.example.com
```

Make sure `/etc/hosts` contains a matching local entry, for example:

```text
127.0.1.1 HOSTNAME.example.com HOSTNAME
```

Verify:

```bash
hostname
hostname -f
```

## 3. Normal administrator account

Do not use root as the normal SSH account.

```bash
sudo adduser joyfulreaper
sudo usermod -aG sudo joyfulreaper
```

Install the administrator's **public** SSH key in `~/.ssh/authorized_keys` and enforce:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Open a second terminal and prove the replacement login works before hardening SSH:

```bash
ssh -i ~/.ssh/KEY joyfulreaper@PUBLIC_IP
whoami
sudo whoami
```

Do not close the known-good session until the new login is proven.

## 4. SSH hardening

Prefer a local drop-in:

```bash
sudo tee /etc/ssh/sshd_config.d/99-local-hardening.conf >/dev/null <<'CONF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
CONF
```

Always validate before reload:

```bash
sudo sshd -t
sudo systemctl reload ssh
```

A silent `sshd -t` is success. Test a fresh login again.

## 5. Firewall baseline

Inspect first:

```bash
sudo nft list ruleset
command -v ufw || true
```

Debian/UFW baseline:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw enable
sudo ufw status verbose
```

Allow SSH **before** enabling UFW. Public SSH is temporary until WireGuard and provider recovery access are proven.

## 6. Optional data-disk setup

Inspect before formatting anything:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS
sudo wipefs -n /dev/vdb
sudo fdisk -l /dev/vdb
```

For a confirmed blank dedicated data disk:

```bash
sudo apt install -y parted
sudo parted /dev/vdb --script mklabel gpt
sudo parted /dev/vdb --script mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L storage -m 1 /dev/vdb1
sudo blkid /dev/vdb1
sudo mkdir -p /srv/storage
```

Use the filesystem UUID in `/etc/fstab`:

```text
UUID=REPLACE_ME /srv/storage ext4 defaults 0 2
```

For required backup/storage disks, omitting `nofail` is often desirable: if the disk disappears, fail loudly instead of silently filling `/`.

Validate:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt --verify
findmnt /srv/storage
df -hT /srv/storage
```

Example layout:

```text
/srv/storage/
├── archives/
├── backups/
├── downloads/
├── staging/
└── secure/
```

A directory named `secure` is **not encrypted** unless encryption was actually configured.

## 7. Record a performance baseline

Simple storage baseline:

```bash
dd if=/dev/zero of=/srv/storage/staging/io-test.bin \
  bs=1M count=2048 conv=fdatasync status=progress

echo 3 | sudo tee /proc/sys/vm/drop_caches
dd if=/srv/storage/staging/io-test.bin of=/dev/null bs=1M status=progress
rm /srv/storage/staging/io-test.bin
```

For controlled network testing:

```bash
iperf3 -c SERVER
iperf3 -c SERVER -R
```

Remove any temporary firewall rule when finished.

## 8. Security-only unattended upgrades

```bash
sudo apt update
sudo apt install -y unattended-upgrades
```

Create `/etc/apt/apt.conf.d/20auto-upgrades`:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Review `/etc/apt/apt.conf.d/50unattended-upgrades`.

Current policy: automatically install **security** updates, not every normal stable update. Keep Debian security origins, and comment the ordinary Debian origin if enabled:

```text
// "origin=Debian,codename=${distro_codename},label=Debian";
```

Explicitly disable automatic rebooting:

```text
Unattended-Upgrade::Automatic-Reboot "false";
```

Verify:

```bash
apt-config dump | grep -Ei 'APT::Periodic|Automatic-Reboot|Origins-Pattern'
sudo unattended-upgrade --dry-run
sudo systemctl status apt-daily.timer --no-pager
sudo systemctl status apt-daily-upgrade.timer --no-pager
```

## 9. Enroll in management WireGuard

```bash
sudo apt install -y wireguard-tools
sudo install -d -m 700 /etc/wireguard
```

Generate the new host's keys **on the new host**:

```bash
sudo sh -c '
umask 077
wg genkey > /etc/wireguard/HOST.key
wg pubkey < /etc/wireguard/HOST.key > /etc/wireguard/HOST.pub
'
```

Only the public key should be copied or pasted.

Before assigning an address, inspect the hub:

```bash
sudo wg show wg0
sudo wg show wg0 allowed-ips
ip -br addr show wg0
```

Add the peer persistently to the hub's `/etc/wireguard/wg0.conf`. If needed, use `wg set` to add it to the running interface without bouncing existing peers.

Client shape:

```ini
[Interface]
Address = 10.99.0.X/24, fd42:42:42::X/64
PrivateKey = PRIVATE_KEY_STORED_LOCALLY

[Peer]
PublicKey = HUB_PUBLIC_KEY
Endpoint = HUB_PUBLIC_ADDRESS:51820
AllowedIPs = 10.99.0.0/24, fd42:42:42::/64
PersistentKeepalive = 25
```

Never commit a config containing `PrivateKey`.

Allow private management traffic:

```bash
sudo ufw allow in on wg0 comment 'WireGuard management'
sudo wg-quick up wg0
sudo systemctl enable wg-quick@wg0
```

If `wg0` was manually created before systemd owns it, a later restart may fail with `wg0 already exists`. From another recovery session:

```bash
sudo wg-quick down wg0
sudo systemctl start wg-quick@wg0
```

Then verify IPv4 and IPv6 in both directions.

## 10. Jump-box enrollment

Current jump box: FreeBSD VM on the workstation.

The new host should:

- be reachable from the jump box over WireGuard;
- authorize the jump box's public SSH key;
- have an alias in jump box `~/.ssh/config`.

Example:

```sshconfig
Host newhost
    HostName 10.99.0.X
    User joyfulreaper
    IdentityFile ~/.ssh/id_ed25519_jump
```

Test:

```sh
ssh newhost
```

The jump-box `sshd` uses `PermitOpen` as a forwarding whitelist. Inspect it with:

```sh
sudo sshd -T | grep -Ei 'allowtcpforwarding|disableforwarding|permitopen|gatewayports'
```

If ProxyJump fails with:

```text
channel 0: open failed: administratively prohibited
stdio forwarding failed
```

add the new `10.99.0.X:22` destination to `PermitOpen`, then:

```sh
sudo sshd -t
sudo service sshd reload
```

## 11. Make SSH private-only

Only after these all work:

- direct SSH over WireGuard;
- jump-box / ProxyJump path;
- provider VNC/console recovery.

Remove the public SSH UFW rule:

```bash
sudo ufw delete allow 22/tcp
sudo ufw status verbose
```

Prove all three:

1. WG SSH still works.
2. public IPv4 SSH fails/times out.
3. public IPv6 SSH fails/times out.

It is fine for `sshd` itself to listen on `0.0.0.0:22` / `[::]:22` when UFW intentionally blocks public access. This makes console recovery simpler.

## 12. Mission Control Agent

Commission monitoring as part of host setup when applicable.

Principles:

- dedicated unprivileged service account;
- known-good published build;
- runtime only on production (no SDK unless needed);
- application binaries root-owned;
- host config under `/etc`;
- API bound to WireGuard, not `0.0.0.0`;
- Docker collection disabled when Docker is absent;
- service starts after `wg-quick@wg0`;
- verify API remotely;
- add node to Dashboard `Agents:Nodes`.

For the current .NET 10 Agent on Debian 13:

```bash
wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb \
  -O /tmp/packages-microsoft-prod.deb
sudo dpkg -i /tmp/packages-microsoft-prod.deb
rm /tmp/packages-microsoft-prod.deb
sudo apt update
sudo apt install -y aspnetcore-runtime-10.0

dotnet --list-runtimes
```

Create the service account:

```bash
sudo adduser --system --group --no-create-home missioncontrol-agent
```

Deploy the published app to:

```text
/opt/missioncontrol-agent
```

Recommended ownership: `root:root`.

Host-specific environment file:

```text
/etc/missioncontrol-agent.env
```

Recommended mode: `0600`, root-owned.

Example non-secret shape:

```text
DOTNET_ENVIRONMENT=Production
DOTNET_EnableDiagnostics=0
ASPNETCORE_URLS=http://10.99.0.X:5194

Agent__DockerEnabled=false
Agent__IntervalSeconds=60
Agent__NodeId=newhost
Agent__NodeName=NewHost
Agent__PublicationHeartbeatMinutes=15

AgentStorage__DatabaseFileName=mission-control-agent.db
AgentStorage__BasePath=/var/lib/missioncontrol-agent
AgentApi__StaleAfterSeconds=180

MissionControl__Enabled=false
```

When publication is enabled, keep the real API key only in protected runtime configuration.

Hardened systemd baseline:

```ini
[Unit]
Description=Mission Control Agent
Wants=network-online.target wg-quick@wg0.service
After=network-online.target wg-quick@wg0.service

[Service]
Type=simple
User=missioncontrol-agent
Group=missioncontrol-agent
WorkingDirectory=/opt/missioncontrol-agent
ExecStart=/opt/missioncontrol-agent/MissionControl.Agent
EnvironmentFile=/etc/missioncontrol-agent.env
Restart=always
RestartSec=5
TimeoutStopSec=30
SyslogIdentifier=missioncontrol-agent
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0027
StateDirectory=missioncontrol-agent
StateDirectoryMode=0750

[Install]
WantedBy=multi-user.target
```

Verify:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now missioncontrol-agent
sudo systemctl status missioncontrol-agent --no-pager
sudo journalctl -u missioncontrol-agent -n 50 --no-pager
```

From another WG host:

```bash
curl -sS http://10.99.0.X:5194/api/snapshot | python3 -m json.tool
```

Dashboard fleet entries currently use Compose variables like:

```text
Agents__Nodes__N__NodeId
Agents__Nodes__N__DisplayName
Agents__Nodes__N__BaseUrl
```

Validate Compose with:

```bash
docker compose config -q
```

Do **not** casually paste unrestricted `docker compose config` output; interpolation may expose secrets.

Known current wart: `MissionControl__Enabled=false` can be displayed as a failed publication attempt even when live Agent monitoring is healthy.

## 13. Backup enrollment

Document:

- what the host backs up;
- what backs up the host;
- destination storage;
- schedule;
- retention;
- credential location;
- exclusions;
- at least one restore/verification test.

A backup stored on another disk in the same VPS/provider account is useful but is **not independent disaster recovery**.

Avoid circular-only backup designs with no independent copy of critical data.

Current FrontDesk policy includes auditing VM coverage so every VM that should be protected lands on its 1 TB `/srv/storage`, while important FrontDesk data also receives an independent copy elsewhere.

## 14. Time synchronization

```bash
timedatectl status
```

Expected:

```text
System clock synchronized: yes
NTP service: active
```

Correct time matters for TLS, logs, monitoring, backups, and authentication.

## 15. Reboot acceptance test

Before reboot:

```bash
sudo systemctl --failed
sudo ufw status verbose
findmnt /srv/storage 2>/dev/null || true
systemctl is-enabled wg-quick@wg0 missioncontrol-agent 2>/dev/null || true
```

Then:

```bash
sudo reboot
```

After reboot verify, as applicable:

```bash
uptime
findmnt /srv/storage
df -hT / /srv/storage
sudo systemctl --failed
sudo systemctl status wg-quick@wg0 --no-pager
sudo systemctl status missioncontrol-agent --no-pager
sudo wg show wg0
sudo ufw status verbose
systemctl status apt-daily.timer --no-pager
systemctl status apt-daily-upgrade.timer --no-pager
ss -tulpn
timedatectl status
```

Also verify externally:

- direct WG SSH;
- jump-box / ProxyJump path;
- Mission Control Agent API;
- intentional public services;
- public SSH is still blocked if that is the policy.

## 16. Write a host-specific runbook

Record:

- purpose;
- provider/plan;
- hostname/OS/kernel;
- CPU/RAM/swap;
- public IPv4/IPv6;
- management WG addresses;
- jump-box aliases;
- SSH/firewall policy;
- disk layout, UUIDs, mount points;
- important directories;
- performance baseline;
- unattended-update policy;
- monitoring paths/bindings;
- backup relationships;
- emergency recovery path;
- known issues and deferred work.

Never include secrets.

## 17. Secret-handling lessons

Read-only commands can still leak credentials.

Be especially careful with:

- recursive `grep` through deployment trees containing `.env` files;
- unrestricted `docker compose config`;
- `env` / `printenv`;
- `systemctl show` or `systemctl cat` when secrets are inline;
- WireGuard configs containing `PrivateKey`;
- shell history containing API keys/passwords.

Prefer exact paths, redacted values, variable **names only**, `docker compose config -q`, and public-key files only.

If a credential is accidentally displayed outside its intended secret store, rotate it.

## 18. Done criteria

- [ ] normal sudo administrator works
- [ ] root SSH disabled
- [ ] password SSH disabled
- [ ] default-deny inbound firewall
- [ ] WireGuard management works after reboot
- [ ] jump-box / ProxyJump works
- [ ] public SSH blocked when private-only is intended
- [ ] security-only unattended upgrades enabled
- [ ] automatic reboot disabled
- [ ] NTP synchronized
- [ ] required data disks survive reboot
- [ ] Mission Control Agent works when applicable
- [ ] backup plan/enrollment is documented
- [ ] zero unexpected failed systemd units
- [ ] listener list reviewed after reboot
- [ ] host-specific runbook created
- [ ] no secrets committed
