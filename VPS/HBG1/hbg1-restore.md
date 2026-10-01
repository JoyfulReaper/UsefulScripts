# hbg1 Restore Guide

This document describes the tested restore procedure for the `hbg1` FreeBSD DN42 VM hosted on Molasses.

The procedure below was verified on **2026-09-30** using a live libvirt backup created with `virsh backup-begin`, stored on FrontDesk, restored back to Molasses under a temporary VM name, booted successfully with networking removed, and then cleaned up.

## Important safety rule

`hbg1` is a live DN42 router/node.

**Never boot a restored copy with the production NIC configuration still attached.**

A restored clone may contain the same hostname, IP addresses, WireGuard configuration, DN42/BIRD configuration, private keys, and routing configuration. Booting two copies on the network at the same time could cause duplicate addresses, duplicate tunnels, route advertisements, or other network breakage.

For a restore test, remove **all VM interfaces** before booting.

## Current production VM

Host: `Molasses`

libvirt connection:

```text
qemu:///system
```

VM:

```text
hbg1
```

Production disk:

```text
/var/lib/libvirt/images/hbg1.qcow2
```

Current disk format: `qcow2`

Virtual size observed during commissioning: `8 GiB`

## Backup location

FrontDesk stores hbg1 backups under:

```text
/srv/storage/backups/vms/hbg1/
```

Example tested backup:

```text
/srv/storage/backups/vms/hbg1/2026-09-30/
├── hbg1-backup-2026-09-30-232027.qcow2
└── hbg1.xml
```

The backup account used from Molasses is:

```text
backup-molasses@10.99.0.14
```

Dedicated SSH key on Molasses:

```text
/root/.ssh/frontdesk-backup
```

Do not copy or commit the private key.

# Restore test procedure

The following procedure restores a backup as a **temporary isolated VM** while leaving production `hbg1` running.

## 1. Copy the selected backup from FrontDesk

Choose the backup you want to test.

Example:

```bash
sudo rsync -ah --progress \
  -e 'ssh -i /root/.ssh/frontdesk-backup' \
  backup-molasses@10.99.0.14:/srv/storage/backups/vms/hbg1/2026-09-30/hbg1-backup-2026-09-30-232027.qcow2 \
  /var/lib/libvirt/images/hbg1-restore-test.qcow2
```

Match ownership and mode to the production disk:

```bash
sudo chown --reference=/var/lib/libvirt/images/hbg1.qcow2 \
  /var/lib/libvirt/images/hbg1-restore-test.qcow2

sudo chmod --reference=/var/lib/libvirt/images/hbg1.qcow2 \
  /var/lib/libvirt/images/hbg1-restore-test.qcow2
```

## 2. Verify the restored copy before defining a VM

Check its SHA-256 if you have the expected hash recorded:

```bash
sudo sha256sum \
  /var/lib/libvirt/images/hbg1-restore-test.qcow2
```

Check the qcow2 structure:

```bash
sudo qemu-img check \
  /var/lib/libvirt/images/hbg1-restore-test.qcow2
```

Expected good result:

```text
No errors were found on the image.
```

## 3. Obtain the saved VM XML

Either copy the saved XML from FrontDesk:

```bash
sudo rsync -ah --progress \
  -e 'ssh -i /root/.ssh/frontdesk-backup' \
  backup-molasses@10.99.0.14:/srv/storage/backups/vms/hbg1/2026-09-30/hbg1.xml \
  /tmp/hbg1.xml
```

or use a known-good local copy of the XML corresponding to the backup.

Do not use production XML blindly without applying the isolation changes below.

## 4. Create isolated restore-test XML

This script:

- changes the VM name to `hbg1-restore-test`;
- removes the original VM UUID so libvirt generates a new one;
- removes **every network interface**;
- changes the disk source to the restored qcow2.

```bash
sudo python3 - <<'PY'
import xml.etree.ElementTree as ET

src = "/tmp/hbg1.xml"
dst = "/tmp/hbg1-restore-test.xml"

tree = ET.parse(src)
root = tree.getroot()

root.find("name").text = "hbg1-restore-test"

uuid = root.find("uuid")
if uuid is not None:
    root.remove(uuid)

devices = root.find("devices")

# CRITICAL: remove every NIC before booting the restored DN42 node.
for iface in list(devices.findall("interface")):
    devices.remove(iface)

# Point the restored VM at the copied backup disk.
for disk in devices.findall("disk"):
    if disk.get("device") == "disk":
        source = disk.find("source")
        if source is not None and "file" in source.attrib:
            source.set(
                "file",
                "/var/lib/libvirt/images/hbg1-restore-test.qcow2"
            )

tree.write(dst, encoding="unicode")
PY
```

## 5. Define the temporary VM

```bash
sudo virsh -c qemu:///system \
  define /tmp/hbg1-restore-test.xml
```

## 6. Verify isolation before boot

Confirm the test VM uses the restored disk:

```bash
sudo virsh -c qemu:///system \
  domblklist hbg1-restore-test --details
```

The disk source must be:

```text
/var/lib/libvirt/images/hbg1-restore-test.qcow2
```

It must **not** point at:

```text
/var/lib/libvirt/images/hbg1.qcow2
```

Confirm there are no NICs:

```bash
sudo virsh -c qemu:///system \
  domiflist hbg1-restore-test
```

The interface table should be empty.

One final XML sanity check:

```bash
sudo virsh -c qemu:///system dumpxml hbg1-restore-test \
  | grep -E '<name>|<source file=|<interface'
```

Expected shape:

```text
<name>hbg1-restore-test</name>
<source file='/var/lib/libvirt/images/hbg1-restore-test.qcow2'/>
```

There should be **no `<interface` line**.

Do not continue if a NIC is present.

## 7. Check console configuration

```bash
sudo virsh -c qemu:///system dumpxml hbg1-restore-test \
  | grep -A5 -E '<graphics|<serial|<console'
```

The tested `hbg1` configuration includes a serial console, so `virsh console` works.

## 8. Boot the restored VM

```bash
sudo virsh -c qemu:///system start hbg1-restore-test
sudo virsh -c qemu:///system domstate hbg1-restore-test
```

Expected:

```text
running
```

Connect to the serial console:

```bash
sudo virsh -c qemu:///system console hbg1-restore-test
```

Exit the virsh console with `Ctrl+]`.

## 9. What to verify inside the restored FreeBSD VM

A useful restore test should verify more than "QEMU started."

At minimum confirm:

```sh
freebsd-version
uname -a
hostname
mount
df -h
ls
```

For hbg1 specifically, verify expected configuration and recovery material exist, such as:

```text
hbg1-mgmt-wg.key
hbg1-mgmt-wg.pub
hbg1-wg.key
hbg1-wg.pub
update-dn42-roa.sh
```

Do **not** bring networking up during an isolated restore test.

The tested restore on 2026-09-30 successfully booted FreeBSD 15.1-RELEASE and presented the expected `hbg1` hostname and files.

# Cleanup after a restore test

If convenient, shut down the temporary clone normally:

```bash
sudo virsh -c qemu:///system shutdown hbg1-restore-test
```

If it does not stop promptly and this is only the disposable isolated test VM:

```bash
sudo virsh -c qemu:///system destroy hbg1-restore-test
```

Then undefine it:

```bash
sudo virsh -c qemu:///system undefine hbg1-restore-test
```

Remove the temporary restored disk:

```bash
sudo rm /var/lib/libvirt/images/hbg1-restore-test.qcow2
```

Remove temporary XML:

```bash
sudo rm /tmp/hbg1-restore-test.xml
```

Optionally remove `/tmp/hbg1.xml` if it was only needed for the test.

Do **not** delete the canonical FrontDesk backup.

# Full disaster recovery

If the production `hbg1` VM or disk is lost, use the same general process but with additional care.

A real replacement recovery should:

1. stop or confirm the original `hbg1` can no longer run;
2. select a known-good backup from FrontDesk;
3. verify its SHA-256 and `qemu-img check`;
4. copy the backup to the intended production disk path;
5. restore the saved libvirt XML;
6. review all disk paths and network interfaces before defining the VM;
7. confirm the production network definitions are appropriate for the current Molasses/libvirt environment;
8. define the VM;
9. boot it from console first;
10. verify FreeBSD, WireGuard, routing, BIRD/DN42 configuration, DNS, and firewall state;
11. only then restore production networking and confirm DN42 peer/session health.

Do not boot a replacement while there is any possibility that the old production node is still online.

# Backup integrity checks

A backup is not considered proven merely because a file exists.

The tested hbg1 process uses several levels of verification:

1. live libvirt backup completes;
2. source backup passes `qemu-img check`;
3. SHA-256 is calculated;
4. backup is transferred to FrontDesk;
5. FrontDesk SHA-256 matches the Molasses source;
6. FrontDesk copy passes `qemu-img check`;
7. a backup is restored back to Molasses;
8. restored SHA-256 still matches;
9. restored qcow2 passes `qemu-img check`;
10. isolated test VM boots successfully into FreeBSD.

That final boot test is what demonstrates that the backup is actually recoverable.

# Related backup layout

Current intended FrontDesk hierarchy:

```text
/srv/storage/backups/vms/
└── hbg1/
    └── YYYY-MM-DD/
        ├── hbg1-backup-YYYY-MM-DD-HHMMSS.qcow2
        └── hbg1.xml
```

The automated backup job should eventually handle:

```text
live virsh backup-begin
        ↓
wait for completion
        ↓
qemu-img check
        ↓
dump current domain XML
        ↓
calculate SHA-256
        ↓
rsync over WireGuard to FrontDesk
        ↓
verify remote hash
        ↓
retention cleanup
```

The production VM should remain online during normal backups.
