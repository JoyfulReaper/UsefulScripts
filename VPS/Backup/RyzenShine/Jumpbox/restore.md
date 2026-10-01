# Jumpbox Hyper-V Restore Guide

This document describes the tested restore process for the **Jumpbox** FreeBSD VM hosted on **RyzenShine**.

The procedure below was tested successfully on **2026-10-01**:

- Jumpbox was exported live with Hyper-V while production remained running.
- The export included the VM configuration, virtual disks, and both existing checkpoints.
- The export was archived and copied to FrontDesk.
- SHA-256 matched after transfer.
- The FrontDesk copy was downloaded back to RyzenShine.
- The VM was imported with a new VM ID into an isolated restore-test directory.
- The restored VM's network adapter was removed before boot.
- The restored FreeBSD VM booted successfully.
- Expected SSH, WireGuard, and jump-host configuration was present.
- The test VM was shut down and removed.
- The production Jumpbox checkpoints were then removed and Hyper-V merged the chain back into the base `Jumpbox.vhdx`.

## Current production state

Host:

```text
RyzenShine
```

Hypervisor:

```text
Hyper-V
```

Production VM:

```text
Jumpbox
```

Guest:

```text
FreeBSD 15.1
```

Production VM storage root:

```text
S:\VMs\Jumpbox\Jumpbox
```

Current production disk after checkpoint cleanup:

```text
S:\VMs\Jumpbox\Jumpbox\Virtual Hard Disks\Jumpbox.vhdx
```

Observed disk file size after merge:

```text
approximately 2.85 GB
```

Current checkpoint state after the tested cleanup:

```text
No checkpoints
```

## FrontDesk backup location

Jumpbox backups are stored under:

```text
/srv/storage/backups/vms/hyper-v/Jumpbox/
```

The first tested backup was stored as:

```text
/srv/storage/backups/vms/hyper-v/Jumpbox/2026-10-01/Jumpbox-2026-10-01-002444.tar
```

Dedicated FrontDesk backup account:

```text
backup-ryzenshine
```

Dedicated RyzenShine SSH key:

```text
C:\Users\me\.ssh\frontdesk-backup-ryzenshine
```

Do not commit or copy the private key into this repository.

The FrontDesk authorized key is restricted to the RyzenShine WireGuard source address.

---

# Important safety rule

Jumpbox is part of the private management/recovery path.

A restored copy may contain the same:

- hostname;
- SSH host keys;
- SSH client keys;
- WireGuard private keys and addresses;
- jump-host `PermitOpen` rules;
- network configuration.

For a restore test, **do not boot the restored copy with networking attached**.

For a real disaster recovery, do not allow the replacement to join the network until the original Jumpbox is confirmed off or permanently unavailable.

---

# Restore-test procedure

The restore-test procedure intentionally imports a second copy alongside production and isolates it before boot.

Run Hyper-V import/remove commands from an **elevated PowerShell** window.

## 1. Choose a backup

Example tested backup:

```powershell
$Stamp = "2026-10-01-002444"
```

Create a restore workspace:

```powershell
$RestoreRoot = "S:\VMBackups\RestoreTest\Jumpbox-$Stamp"
$Archive = "$RestoreRoot\Jumpbox-$Stamp.tar"

New-Item -ItemType Directory -Path $RestoreRoot -Force | Out-Null
```

## 2. Download the FrontDesk copy

```powershell
scp `
  -i "$env:USERPROFILE\.ssh\frontdesk-backup-ryzenshine" `
  "backup-ryzenshine@10.99.0.14:/srv/storage/backups/vms/hyper-v/Jumpbox/2026-10-01/Jumpbox-$Stamp.tar" `
  $Archive
```

If the automated backup format later changes to `.tar.gz` or `.tar.zst`, use the corresponding archive filename and extraction command.

## 3. Verify the downloaded archive

```powershell
Get-FileHash $Archive -Algorithm SHA256
```

Compare the result with the hash recorded when the backup was created or with a trusted hash stored alongside the backup.

The tested 2026-10-01 archive hash was:

```text
120B4A42753DB8692EA7152F7D6F8C7804D1AF6EE7119916F7AC6A61B8763A35
```

Do not assume this hash applies to later backups.

## 4. Extract the export

For the tested plain tar archive:

```powershell
tar.exe -C $RestoreRoot -xf $Archive
```

The exported VM tree should contain directories similar to:

```text
Jumpbox\
├── Snapshots\
├── Virtual Hard Disks\
└── Virtual Machines\
```

Locate the exported Hyper-V configuration:

```powershell
$Vmcx = Get-ChildItem `
  "$RestoreRoot\Jumpbox\Virtual Machines" `
  -Filter *.vmcx |
  Select-Object -First 1

$Vmcx.FullName
```

The result must point inside the extracted restore tree.

## 5. Prepare an isolated import location

```powershell
$ImportRoot = "S:\VMBackups\RestoreTest\Jumpbox-Imported-$Stamp"

$VmPath   = "$ImportRoot\VM"
$VhdPath  = "$ImportRoot\VHD"
$SnapPath = "$ImportRoot\Snapshots"
$PagePath = "$ImportRoot\Paging"

New-Item -ItemType Directory -Force `
  $VmPath, $VhdPath, $SnapPath, $PagePath |
  Out-Null
```

## 6. Import as a copy with a new VM ID

```powershell
$Restored = Import-VM `
  -Path $Vmcx.FullName `
  -Copy `
  -GenerateNewId `
  -VirtualMachinePath $VmPath `
  -VhdDestinationPath $VhdPath `
  -SnapshotFilePath $SnapPath `
  -SmartPagingFilePath $PagePath
```

Rename the clone immediately:

```powershell
Rename-VM -VM $Restored -NewName "Jumpbox-RestoreTest"

$Restored = Get-VM -Name "Jumpbox-RestoreTest"
```

## 7. If the imported VM is in Saved state

A live Hyper-V export may preserve saved/runtime state.

Check:

```powershell
Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State, Status
```

If the restore copy is `Saved`, discard only the test VM's saved RAM state:

```powershell
Remove-VMSavedState `
  -VMName "Jumpbox-RestoreTest" `
  -Confirm:$false
```

Then verify it is `Off`:

```powershell
Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State, Status
```

This does not discard the restored virtual-disk state.

## 8. Verify the restored disks are isolated

```powershell
Get-VMHardDiskDrive -VM $Restored |
    Select-Object VMName, Path
```

The disk path must point under:

```text
S:\VMBackups\RestoreTest\Jumpbox-Imported-...
```

It must **not** point at the production directory:

```text
S:\VMs\Jumpbox\...
```

## 9. Remove all networking before boot

Inspect the imported NICs:

```powershell
Get-VMNetworkAdapter -VM $Restored |
    Select-Object VMName, Name, SwitchName, MacAddress
```

Remove every NIC from the restore-test clone:

```powershell
Get-VMNetworkAdapter -VM $Restored |
    Remove-VMNetworkAdapter
```

Verify:

```powershell
Get-VMNetworkAdapter -VM $Restored
```

Expected result:

```text
(no output)
```

**Do not boot the restore-test VM if any network adapter remains attached.**

## 10. Inspect checkpoints if the selected backup contains them

```powershell
Get-VMSnapshot -VM $Restored |
    Select-Object VMName, Name, CreationTime
```

The first tested backup contained:

```text
Setup Jumpbox
Move to FreeBSD-NAT Adapter
```

Later scheduled backups may contain no checkpoints because the production chain was subsequently merged.

## 11. Boot the isolated clone

```powershell
Start-VM -Name "Jumpbox-RestoreTest"

Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State, Status
```

Open the Hyper-V console:

```powershell
vmconnect.exe localhost "Jumpbox-RestoreTest"
```

## 12. Verify the guest

Inside FreeBSD, check basic system health:

```sh
hostname
freebsd-version
uname -a
df -h
ls
```

For Jumpbox specifically, verify the recovery/jump-host state:

```sh
ls -la ~/.ssh
sudo ls -la /usr/local/etc/wireguard 2>/dev/null
sudo grep -n 'PermitOpen' /etc/ssh/sshd_config
```

The tested restore confirmed:

- FreeBSD booted normally;
- the expected `~/.ssh` configuration and key material were present;
- WireGuard configuration was present;
- the SSH `PermitOpen` jump-host whitelist was present, including FrontDesk;
- the root filesystem mounted normally.

Do not enable networking during an isolated restore test.

## 13. Shut down the restore-test guest

Inside FreeBSD:

```sh
sudo shutdown -p now
```

Then in PowerShell:

```powershell
Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State
```

Wait for:

```text
Off
```

## 14. Remove the test VM

```powershell
Remove-VM -Name "Jumpbox-RestoreTest" -Force
```

Remove the imported restore tree:

```powershell
Remove-Item `
  "S:\VMBackups\RestoreTest\Jumpbox-Imported-$Stamp" `
  -Recurse -Force
```

Remove the downloaded/extracted restore tree:

```powershell
Remove-Item `
  "S:\VMBackups\RestoreTest\Jumpbox-$Stamp" `
  -Recurse -Force
```

Do not delete the canonical FrontDesk backup as part of restore-test cleanup.

---

# Full disaster recovery

For an actual Jumpbox loss, the same export/import mechanism can be used, but the safety rules differ slightly because the replacement is intended to become production.

1. Confirm the original Jumpbox is stopped, destroyed, or otherwise incapable of rejoining the network.
2. Choose a known-good FrontDesk backup.
3. Download it to RyzenShine.
4. Verify its SHA-256.
5. Extract it.
6. Import it with `Import-VM -Copy -GenerateNewId` into a clean production location.
7. Review all virtual disk paths.
8. Review network adapter/switch mappings before connecting the replacement to a switch.
9. Boot the VM from the Hyper-V console first.
10. Verify FreeBSD, SSH keys/config, WireGuard configuration, and `PermitOpen`.
11. Recreate or attach the intended Hyper-V network adapter only after the guest state is confirmed.
12. Verify the management WireGuard tunnel.
13. Test Jumpbox SSH access from RyzenShine.
14. Test a ProxyJump connection through Jumpbox to a known private host such as FrontDesk.
15. Confirm the old Jumpbox cannot reappear with duplicate WireGuard or SSH identity.

If RyzenShine itself is being rebuilt, Hyper-V virtual-switch names may differ from the original host. Do not assume the exported switch mapping is valid on a replacement Windows host.

---

# Checkpoint cleanup performed after the tested restore

After the successful restore test, the production Jumpbox had two old checkpoints:

```text
Setup Jumpbox
Move to FreeBSD-NAT Adapter
```

They were removed through Hyper-V:

```powershell
Get-VMSnapshot -VMName Jumpbox |
    Remove-VMSnapshot
```

This preserved the current VM state and allowed Hyper-V to merge the differencing-disk chain.

After the merge:

```powershell
Get-VMSnapshot -VMName Jumpbox
```

returned no checkpoints, and:

```powershell
Get-VMHardDiskDrive -VMName Jumpbox |
    Select-Object Path
```

returned:

```text
S:\VMs\Jumpbox\Jumpbox\Virtual Hard Disks\Jumpbox.vhdx
```

The remaining production disk file was approximately:

```text
2.85 GB
```

Never manually delete Hyper-V `.avhdx` files to squash checkpoints. Remove checkpoints through Hyper-V and allow Hyper-V to perform the merge.

---

# Backup verification standard

A Jumpbox backup should not be considered fully proven merely because an archive exists.

The desired verification chain is:

1. Hyper-V live export completes.
2. Archive/export is created.
3. SHA-256 is calculated locally.
4. Backup is transferred to FrontDesk over WireGuard.
5. FrontDesk SHA-256 matches.
6. A representative backup is periodically downloaded back to RyzenShine.
7. It imports successfully with a new VM ID.
8. Networking is removed from the test clone.
9. FreeBSD boots.
10. Important Jumpbox SSH/WireGuard/recovery configuration is present.
11. The test VM shuts down and cleans up normally.

The 2026-10-01 backup passed this complete restore test.

---

# Intended scheduled-backup policy

Jumpbox does not need daily VM exports.

Current intended policy:

```text
Frequency: weekly
Destination: FrontDesk
Retention: approximately 4-6 weekly copies
Transfer path: WireGuard
Backup type: live Hyper-V export
Archive: compressed archive preferred for scheduled backups
Restore test: periodic, and after significant changes to the backup process
```

A fresh backup should also be considered after meaningful Jumpbox configuration changes, especially changes to:

- WireGuard;
- SSH keys;
- `PermitOpen`;
- Hyper-V networking;
- recovery/jump-host configuration.
