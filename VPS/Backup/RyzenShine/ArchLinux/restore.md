# ArchLinux Hyper-V Restore Guide

ArchLinux is backed up as a live Hyper-V export to the shared RyzenShine restic
repository on FrontDesk.

## Current policy

```text
VM name: ArchLinux
Backup type: live Hyper-V export into restic
Repository: rest:http://10.99.0.14:8000/ryzenshine/
Frequency: every 2 weeks
Retention: keep last 4 ArchLinux snapshots
Upload limit: 10240 KiB/s
Notifications: ntfy success/failure
```

This is intentionally more frequent than NoiseMaker while still treating the VM
as rebuildable rather than production-critical.

## Observed VM/disk state before enabling backups

Observed 2026-10-02:

```text
VM: ArchLinux
State: Running
Status: Operating normally
Disk: S:\VMs\ArchLinux\Virtual Hard Disks\ArchLinux.vhdx
VHD type: Dynamic
Current file size: 20505952256 bytes (~19.1 GiB)
Virtual size: 118111600640 bytes (110 GiB)
ParentPath: blank
```

A blank ParentPath means the observed VHDX is a standalone base disk rather than
a differencing disk.

The generic backup engine refuses to run while Hyper-V checkpoints are present,
so review/merge checkpoints before relying on a scheduled run.

## Backup implementation

Tracked wrapper:

```text
VPS/Backup/RyzenShine/ArchLinux/backup.ps1
```

Tracked task installer:

```text
VPS/Backup/RyzenShine/ArchLinux/install-task.ps1
```

The wrapper uses:

```text
windows/hyperv/Backup-HyperVVmToRestic.ps1
```

The generic engine exports the live VM to:

```text
S:\HyperV-Backup-Staging\ArchLinux
```

then sends the export to restic with tags:

```text
hyperv
ArchLinux
```

The staging export is removed after a successful backup. A failed backup leaves
the staging directory in place for inspection.

## Listing snapshots

Use the existing RyzenShine restic credentials, then:

```powershell
restic -r $Repo snapshots --tag "hyperv,ArchLinux"
```

## Restore outline

Restore a selected snapshot into an isolated directory on RyzenShine:

```powershell
$Snapshot = "<snapshot-id>"
$RestoreRoot = "S:\VMBackups\RestoreTest\ArchLinux-$Snapshot"

New-Item -ItemType Directory -Path $RestoreRoot -Force | Out-Null
restic -r $Repo restore $Snapshot --target $RestoreRoot
```

Locate the exported VM configuration:

```powershell
$Vmcx = Get-ChildItem $RestoreRoot -Recurse -Filter *.vmcx -File |
    Select-Object -First 1

$Vmcx.FullName
```

For a full restore test:

1. Import the restored VM as a copy with a new VM ID.
2. Keep all restored files in the isolated restore tree.
3. Verify every attached disk path points into that tree.
4. Remove virtual NICs before the first boot.
5. If needed, discard only the restored clone's saved state.
6. Boot through VMConnect while isolated.
7. Verify the guest and shut it down.
8. Remove the restore-test VM and files when finished.

## Verification status

As of 2026-10-02:

```text
VM registered:              VERIFIED
VM running normally:        VERIFIED
VHDX path:                  VERIFIED
VHDX type/size:             VERIFIED
VHDX ParentPath blank:      VERIFIED
Scheduled task installed:   NOT YET VERIFIED
First restic snapshot:      NOT YET VERIFIED
ntfy notification:          NOT YET VERIFIED
Full isolated boot restore: NOT YET TESTED
```
