# NoiseMaker Hyper-V Restore Guide

NoiseMaker is intended to have a low-frequency recovery backup rather than frequent VM backups.

## Intended current policy

```text
Backup type: live Hyper-V export into restic
Repository: rest:http://10.99.0.14:8000/ryzenshine/
Frequency: every 13 weeks (approximately 4 times per year)
Retention: keep last 4 NoiseMaker snapshots
Upload limit: 10240 KiB/s
Prune: separate maintenance operation
Notifications: ntfy success/failure
```

The scheduled restic task should only be installed while a VM named `NoiseMaker` is actually registered in Hyper-V.

On 2026-10-01 the VM was confirmed registered and running normally:

```text
Name: NoiseMaker
VM ID: 5E3AB739-B31F-48E4-A66C-8AC2AEB4E374
State: Running
Status: Operating normally
Configuration: C:\ProgramData\Microsoft\Windows\Hyper-V
Disk: S:\VMs\TcpNoiseResidential.vhdx
```

The current VHDX is a standalone dynamic base disk with no parent:

```text
VhdType: Dynamic
File size: 4299161600 bytes
Virtual size: 12884901888 bytes
ParentPath: (blank)
```

`Get-DiskImage` reported the VHDX was not mounted into the Windows host. Hyper-V reported the disk attached to the running NoiseMaker VM.

## Verified legacy recovery copy

A one-time legacy backup exists on FrontDesk:

```text
/srv/storage/backups/vms/hyper-v/NoiseMaker/2026-10-01/NoiseMaker-2026-10-01-012727.tar.gz
```

Observed size:

```text
2699971476 bytes
approximately 2.51 GiB
```

SHA-256:

```text
1375040d988711598ea2c9afb58814c81f3a7ac0e9676c9ba4228faef3b4324c
```

The archive test completed successfully on FrontDesk on 2026-10-01.

Its Hyper-V contents include:

```text
NoiseMaker/Virtual Machines/5E3AB739-B31F-48E4-A66C-8AC2AEB4E374.vmcx
NoiseMaker/Virtual Machines/5E3AB739-B31F-48E4-A66C-8AC2AEB4E374.vmgs
NoiseMaker/Virtual Machines/5E3AB739-B31F-48E4-A66C-8AC2AEB4E374.VMRS
NoiseMaker/Virtual Hard Disks/TcpNoiseResidential.vhdx
NoiseMaker/Virtual Hard Disks/TcpNoiseResidential_1D2A2C1B-B3A0-40D6-8A5A-90E9824C6062.avhdx
NoiseMaker/Virtual Hard Disks/TcpNoiseResidential_564FE0F6-A45E-47CD-A054-B5BEC179D5E1.avhdx
NoiseMaker/Virtual Hard Disks/TcpNoiseResidential_D53D108B-D558-44E1-A632-A50EABF314BC.avhdx
```

It also contains three exported checkpoint configurations under `NoiseMaker/Snapshots/`.

This legacy archive therefore preserves a Hyper-V checkpoint/differencing-disk chain. Do not manually discard the `.avhdx` files when restoring it.

## CPU note for FrontDesk

Do not routinely decompress or recompress the legacy `.tar.gz` on FrontDesk. Gzip can peg one of the VPS CPU cores.

The new recurring design avoids creating tar/gzip archives on FrontDesk. Restic receives the Hyper-V export directly over the WireGuard/rest-server path.

For future integrity work, prefer restic-native verification and keep heavy prune/check work as separate maintenance.

## Legacy archive restore outline

For a disaster recovery from the legacy archive:

1. Copy the archive from FrontDesk to RyzenShine first.
2. Verify its SHA-256 against the value above.
3. Extract it on RyzenShine, not on FrontDesk.
4. Locate the exported `.vmcx`.
5. Import with `Import-VM -Copy -GenerateNewId` into an isolated restore directory.
6. Verify that all VHD/VHDX/AVHDX paths point only inside the restore tree.
7. Remove all virtual NICs before first boot.
8. If the imported VM is in Saved state, discard only the restore clone's saved state with `Remove-VMSavedState`.
9. Inspect the imported checkpoints/disk chain through Hyper-V.
10. Boot the clone from VMConnect with no network attached.
11. Verify the guest.
12. Shut it down and remove the restore-test VM and files when finished.

Because the archive contains checkpoint differencing disks, let Hyper-V manage the chain. Never delete `.avhdx` files by hand.

## Future restic restore

Once NoiseMaker exists again and the quarterly restic task has produced snapshots, list them with:

```powershell
restic -r $Repo snapshots --tag "hyperv,NoiseMaker"
```

Restore a selected snapshot to an isolated workspace:

```powershell
$Snapshot = "<snapshot-id>"
$RestoreRoot = "S:\VMBackups\RestoreTest\NoiseMaker-$Snapshot"

New-Item -ItemType Directory -Path $RestoreRoot -Force | Out-Null
restic -r $Repo restore $Snapshot --target $RestoreRoot
```

Then locate the VM configuration:

```powershell
$Vmcx = Get-ChildItem $RestoreRoot -Recurse -Filter *.vmcx -File |
    Select-Object -First 1

$Vmcx.FullName
```

Use the same safety pattern as the tested Jumpbox restore:

- import as a copy with a new VM ID;
- place all restored VM files in an isolated directory;
- verify disk paths;
- remove networking before first boot;
- discard saved state on the clone if needed;
- inspect checkpoints;
- boot only through VMConnect while isolated.


## Verified quarterly restic run

The scheduled task was started manually through Windows Task Scheduler on 2026-10-01 and completed successfully:

```text
Task: NoiseMaker Quarterly Backup
LastTaskResult: 0
Snapshot: 16464437
Tags: hyperv,NoiseMaker
Path: S:\HyperV-Backup-Staging\NoiseMaker
Snapshot size: 4.158 GiB
```

This verifies that the password-backed scheduled-task context can access the stored DPAPI credentials and complete the NoiseMaker restic backup path unattended.


## Verification status

As of 2026-10-01:

```text
Legacy backup exists:                 VERIFIED
Legacy archive integrity test:        VERIFIED
Legacy SHA-256 recorded:              VERIFIED
Hyper-V configuration present:        VERIFIED
Base VHDX present:                    VERIFIED
Checkpoint AVHDX chain present:       VERIFIED
Full isolated boot restore:           NOT TESTED
Current NoiseMaker VM registered:     VERIFIED
Current NoiseMaker VM running:        VERIFIED
Current VHDX has no parent:            VERIFIED
Quarterly restic task installed:      VERIFIED
Quarterly restic scheduled run:       VERIFIED
First restic snapshot:                16464437
Restic snapshot size:                 4.158 GiB
```

The legacy backup remains useful historical recovery coverage. Keep it distinct from future restic snapshots; the current running VM uses a standalone merged base VHDX, while the legacy archive preserves the older checkpoint chain.
