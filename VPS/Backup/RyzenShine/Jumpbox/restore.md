# Jumpbox Hyper-V Restore Guide

This document describes the current tested restore process for the **Jumpbox** FreeBSD VM hosted on **RyzenShine** and backed up to **FrontDesk** with restic.

The restic restore path was tested successfully on **2026-10-01** using snapshot:

```text
d7b4c991
```

The test proved the complete recovery chain:

- Jumpbox was exported live from Hyper-V while production remained running.
- Restic stored the export in the RyzenShine repository on FrontDesk.
- The snapshot was restored back to RyzenShine.
- The restored Hyper-V configuration and VHDX were located inside an isolated restore tree.
- The VM was imported with `-Copy -GenerateNewId` into a separate restore-test location.
- The imported VHDX pointed only at the isolated restore-test tree.
- Saved runtime state from the live export was discarded on the clone.
- The clone's network adapter was removed before first boot.
- The restored FreeBSD guest booted successfully.
- Expected SSH, WireGuard, and jump-host `PermitOpen` state were present.
- The restore-test VM was shut down and removed.
- Both restore-test directory trees were deleted.
- The production Jumpbox remained running and healthy throughout the test.

## Current production state

```text
Host: RyzenShine
Hypervisor: Hyper-V
VM: Jumpbox
Guest observed during restore test: FreeBSD 15.1-RELEASE-p4
Production storage root: S:\VMs\Jumpbox\Jumpbox
Production disk: S:\VMs\Jumpbox\Jumpbox\Virtual Hard Disks\Jumpbox.vhdx
Checkpoints: none
```

## Current backup layout

```text
Repository: rest:http://10.99.0.14:8000/ryzenshine/
Stable staging path: S:\HyperV-Backup-Staging\Jumpbox
Tags: hyperv, Jumpbox
Frequency: weekly
Retention: keep last 6 snapshots
Upload limit: 10240 KiB/s
Destination: FrontDesk over WireGuard
Prune: separate maintenance operation
Notifications: ntfy success/failure
```

The generic backup engine is:

```text
windows\hyperv\Backup-HyperVVmToRestic.ps1
```

Jumpbox uses the wrapper:

```text
VPS\Backup\RyzenShine\Jumpbox\backup.ps1
```

## Credential model

RyzenShine stores unattended backup credentials under:

```text
C:\ProgramData\UsefulScripts\HyperVBackup\
```

Expected files:

```text
restic-rest-username.txt
restic-rest-password.dpapi
restic-repository-password.dpapi
ntfy-token.dpapi
```

The DPAPI blobs were created by `RYZENSHINE\me`. The scheduled task must run under that same Windows identity.

The rest-server password is replaceable HTTP authentication. If it is lost, reset it on FrontDesk:

```bash
sudo htpasswd -B /etc/restic-rest-server/users.htpasswd ryzenshine
```

The restic repository encryption password is different and is required to decrypt the repository. Keep an independent copy outside RyzenShine.

---

# Important safety rule

Jumpbox is part of the private management/recovery path. A restored copy can contain the same hostname, SSH keys, WireGuard private keys/addresses, jump-host `PermitOpen` rules, and network configuration.

For a restore test, **do not boot the restored copy with networking attached**.

For real disaster recovery, do not attach production networking until the original Jumpbox is confirmed off or permanently unavailable.

---

# Restore-test procedure

Run Hyper-V import/remove commands from an **elevated PowerShell** window.

## 1. Set the repository and snapshot

```powershell
$Repo = "rest:http://10.99.0.14:8000/ryzenshine/"
$Snapshot = "d7b4c991"
```

For future tests, replace the historical snapshot ID with the snapshot you deliberately choose.

## 2. Load the restic credentials

```powershell
$env:RESTIC_REST_USERNAME = (
    Get-Content "C:\ProgramData\UsefulScripts\HyperVBackup\restic-rest-username.txt" -Raw
).Trim()

function Get-DpapiPlainText {
    param([string]$Path)

    $secure = Get-Content -LiteralPath $Path -Raw | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

$env:RESTIC_REST_PASSWORD = Get-DpapiPlainText "C:\ProgramData\UsefulScripts\HyperVBackup\restic-rest-password.dpapi"
$env:RESTIC_PASSWORD = Get-DpapiPlainText "C:\ProgramData\UsefulScripts\HyperVBackup\restic-repository-password.dpapi"
```

Do not echo either password variable.

If the original Windows profile is unavailable, use the independently stored repository encryption password. The rest-server password can be supplied separately or reset on FrontDesk.

## 3. Confirm repository access and choose a snapshot

```powershell
restic -r $Repo cat config
restic -r $Repo snapshots --tag "hyperv,Jumpbox"
restic -r $Repo ls $Snapshot
```

Do not blindly assume `latest` is the snapshot you want during an incident.

## 4. Restore to an isolated workspace

```powershell
$RestoreRoot = "S:\VMBackups\RestoreTest\Jumpbox-$Snapshot"
New-Item -ItemType Directory -Path $RestoreRoot -Force | Out-Null
restic -r $Repo restore $Snapshot --target $RestoreRoot
```

The tested `d7b4c991` snapshot restored approximately `3.131 GiB`.

Locate the VM configuration and VHDX recursively:

```powershell
$Vmcx = Get-ChildItem $RestoreRoot -Recurse -Filter *.vmcx -File |
    Select-Object -First 1

$Vhdx = Get-ChildItem $RestoreRoot -Recurse -Filter *.vhdx -File |
    Select-Object -First 1

$Vmcx.FullName
$Vhdx.FullName
```

For the tested snapshot, restic recreated the original source path below the restore target.

## 5. Prepare an isolated Hyper-V import location

```powershell
$ImportRoot = "S:\VMBackups\RestoreTest\Jumpbox-Imported-$Snapshot"

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

Rename-VM -VM $Restored -NewName "Jumpbox-RestoreTest"
$Restored = Get-VM -Name "Jumpbox-RestoreTest"
```

## 7. Discard saved runtime state if present

The tested live export imported in `Saved` state.

```powershell
Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State, Status

Remove-VMSavedState `
    -VMName "Jumpbox-RestoreTest" `
    -Confirm:$false
```

Verify the clone is now `Off`. This discards only saved RAM/runtime state, not the restored virtual disk.

## 8. Verify disk isolation

```powershell
Get-VMHardDiskDrive -VM $Restored |
    Select-Object VMName, Path
```

The tested VHD landed at:

```text
S:\VMBackups\RestoreTest\Jumpbox-Imported-d7b4c991\VHD\Jumpbox.vhdx
```

The restored disk must **not** point under `S:\VMs\Jumpbox\...`.

## 9. Remove all networking before boot

```powershell
Get-VMNetworkAdapter -VMName "Jumpbox-RestoreTest" |
    Select-Object VMName, Name, SwitchName, MacAddress

Get-VMNetworkAdapter -VMName "Jumpbox-RestoreTest" |
    Remove-VMNetworkAdapter

Get-VMNetworkAdapter -VMName "Jumpbox-RestoreTest"
```

The final command must return no adapters. The tested export initially imported attached to `FreeBSD-NAT`.

## 10. Verify no unexpected checkpoints

```powershell
Get-VMSnapshot -VMName "Jumpbox-RestoreTest" -ErrorAction SilentlyContinue
```

The tested restic restore contained no checkpoints.

## 11. Boot the isolated clone

```powershell
Start-VM -Name "Jumpbox-RestoreTest"

Get-VM -Name "Jumpbox-RestoreTest" |
    Select-Object Name, State, Status

vmconnect.exe localhost "Jumpbox-RestoreTest"
```

## 12. Verify the guest

```sh
hostname
freebsd-version
uname -a
df -h
ls -la ~/.ssh
sudo ls -la /usr/local/etc/wireguard 2>/dev/null
sudo grep -n 'PermitOpen' /etc/ssh/sshd_config
```

The 2026-10-01 restic restore test confirmed:

- hostname `jumpbox`;
- FreeBSD `15.1-RELEASE-p4`;
- the root filesystem mounted normally;
- expected SSH key/configuration files were present;
- `/usr/local/etc/wireguard/wg0.conf` was present;
- the SSH `PermitOpen` whitelist was present with the expected private destinations.

Do not enable networking during the isolated restore test.

## 13. Shut down and clean up

Inside FreeBSD:

```sh
sudo shutdown -p now
```

After Hyper-V reports `Off`:

```powershell
Remove-VM -Name "Jumpbox-RestoreTest" -Force
Remove-Item $ImportRoot -Recurse -Force
Remove-Item $RestoreRoot -Recurse -Force
```

Verify production and cleanup:

```powershell
Get-VM -Name "Jumpbox" |
    Select-Object Name, State, Status

Get-VM -Name "Jumpbox-RestoreTest" -ErrorAction SilentlyContinue

Test-Path $ImportRoot
Test-Path $RestoreRoot
```

The tested cleanup ended with production Jumpbox running normally, no restore-test VM, and both restore-test paths returning `False`.

---

# Full disaster recovery

For an actual Jumpbox loss:

1. Confirm the original Jumpbox cannot rejoin the network.
2. Establish trusted connectivity from the replacement Hyper-V host to FrontDesk.
3. Install restic and Hyper-V.
4. Obtain the rest-server username/password.
5. Obtain the independently stored restic repository encryption password.
6. Confirm repository access with `restic cat config`.
7. List snapshots tagged `hyperv,Jumpbox`.
8. Choose a known-good snapshot deliberately.
9. Restore it to local storage.
10. Locate the exported `.vmcx`.
11. Import it with `Import-VM -Copy -GenerateNewId`.
12. Verify every VHD path.
13. Remove networking before first boot.
14. Boot from the Hyper-V console and verify FreeBSD, SSH, WireGuard, and `PermitOpen`.
15. Attach/recreate production networking only after the original VM is known to be gone.
16. Verify WireGuard, direct SSH, and a ProxyJump connection through Jumpbox.

If the replacement Windows host has different Hyper-V virtual-switch names, do not assume the exported switch mapping is valid.

---

# Legacy archive backup

Before the restic migration, Jumpbox used a tar/SCP backup flow under:

```text
/srv/storage/backups/vms/hyper-v/Jumpbox/
```

A 2026-10-01 archive from that flow was independently restored and boot-tested before the production checkpoint chain was cleaned up.

That archive is historical/legacy coverage. Do not delete it solely because the current flow uses restic; retire it deliberately after enough restic history exists.

---

# Verification status

As of **2026-10-01**:

```text
Restic snapshot creation:     VERIFIED
Restic restore:               VERIFIED
Hyper-V import as copy:       VERIFIED
New VM ID / isolated VHD:     VERIFIED
Saved-state discard:          VERIFIED
Network isolation:            VERIFIED
FreeBSD boot:                 VERIFIED
SSH state:                    VERIFIED
WireGuard config:             VERIFIED
PermitOpen state:             VERIFIED
Restore-test cleanup:         VERIFIED
Production VM unaffected:     VERIFIED
```

Full restic restore-test snapshot:

```text
d7b4c991
```

Repeat a full restore test after major changes to the backup format, repository, credential/encryption model, Hyper-V storage design, or Jumpbox recovery configuration.
