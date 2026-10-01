# FreeBSD Hyper-V Restic Restore Guide

This document describes the restore process for the **FreeBSD** Hyper-V VM hosted on **RyzenShine** and backed up to **FrontDesk** with restic.

The current restic backup path was validated on **2026-10-01**:

- Hyper-V exported the running VM successfully.
- The backup script loaded credentials from Windows DPAPI in a clean PowerShell process with the credential environment variables removed.
- Restic authenticated to FrontDesk and opened the encrypted repository.
- Restic automatically found the previous stable-path snapshot as its parent.
- Snapshot `6e21b37c` was saved successfully.
- The run processed about `22.537 GiB` and stored about `822 MiB` of new repository data.
- The staging export was removed after the successful backup.
- ntfy is configured with a dedicated `ryzenshine-backup` account that has write-only access to `vps-backups`.

**Important:** snapshot creation is verified, but a complete restore/import/boot test of the new restic flow has not yet been performed. Update this document after that test.

---

# Current backup layout

Host:

```text
RyzenShine
```

VM:

```text
FreeBSD
```

Repository:

```text
rest:http://10.99.0.14:8000/ryzenshine/
```

Stable staging path:

```text
S:\HyperV-Backup-Staging\FreeBSD
```

Tags:

```text
hyperv
FreeBSD
```

Intended policy:

```text
Frequency: every 4 weeks
Retention: keep last 3 snapshots
Upload limit: 10240 KiB/s
Destination: FrontDesk over WireGuard
Prune: separate maintenance operation
Notifications: ntfy success/failure
```

Backup script:

```text
windows\hyperv\Backup-HyperVVmToRestic.ps1
```

DPAPI setup helper:

```text
windows\hyperv\Initialize-HyperVBackupSecrets.ps1
```

---

# Credential model

RyzenShine stores the unattended backup credentials under:

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

The DPAPI blobs were created by:

```text
RYZENSHINE\me
```

A scheduled task that relies on these files must run as that same Windows identity.

The rest-server password and restic repository encryption password are **not the same thing**.

The rest-server password is replaceable HTTP authentication. If it is lost, reset it on FrontDesk:

```bash
sudo htpasswd -B /etc/restic-rest-server/users.htpasswd ryzenshine
```

The restic repository encryption password is required to decrypt the repository. If it is lost and no independent copy exists, the repository cannot be recovered.

Keep an independent copy of the repository encryption password outside RyzenShine. Do not rely only on the DPAPI copy stored on the machine being protected.

Never commit passwords, tokens, or generated secret files to Git.

---

# Restore safety rule

A restored VM may contain the same hostname, SSH keys, WireGuard keys/addresses, services, and network configuration as production.

For a restore test, **do not boot the restored copy with networking attached**.

For a real disaster recovery, do not attach production networking until the original VM is known to be gone or permanently unable to return.

---

# Restore-test procedure

Run Hyper-V import/remove commands from an **elevated PowerShell** window.

## 1. Set the repository

```powershell
$Repo = "rest:http://10.99.0.14:8000/ryzenshine/"
```

## 2. Load credentials on the original RyzenShine profile

Set the username:

```powershell
$env:RESTIC_REST_USERNAME = (Get-Content "C:\ProgramData\UsefulScripts\HyperVBackup\restic-rest-username.txt" -Raw).Trim()
```

Define a small DPAPI helper:

```powershell
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
```

Load the two restic credentials into the current process:

```powershell
$env:RESTIC_REST_PASSWORD = Get-DpapiPlainText "C:\ProgramData\UsefulScripts\HyperVBackup\restic-rest-password.dpapi"
$env:RESTIC_PASSWORD = Get-DpapiPlainText "C:\ProgramData\UsefulScripts\HyperVBackup\restic-repository-password.dpapi"
```

Do not echo either variable.

If the original Windows profile is unavailable, the DPAPI files alone may not be usable. Use the independently stored repository encryption password, and either supply or reset the rest-server password.

## 3. Confirm repository access

```powershell
restic -r $Repo cat config
```

## 4. List FreeBSD snapshots

```powershell
restic -r $Repo snapshots --tag "hyperv,FreeBSD"
```

Choose the snapshot deliberately. During disaster recovery, do not blindly assume `latest` is the snapshot you want.

A known successful snapshot from the 2026-10-01 validation run is:

```text
6e21b37c
```

That ID is historical evidence only; later snapshots should normally supersede it.

## 5. Inspect the selected snapshot

```powershell
$Snapshot = "6e21b37c"
restic -r $Repo ls $Snapshot
```

Verify that it contains the FreeBSD Hyper-V export, including the VM configuration and virtual disk.

## 6. Restore to an isolated workspace

```powershell
$RestoreRoot = "S:\VMBackups\RestoreTest\FreeBSD-$Snapshot"
New-Item -ItemType Directory -Path $RestoreRoot -Force | Out-Null
restic -r $Repo restore $Snapshot --target $RestoreRoot
```

Restic may recreate part of the original absolute path below the restore target. Do not assume the exported VM starts directly at `$RestoreRoot\FreeBSD`.

Locate the Hyper-V configuration recursively:

```powershell
$Vmcx = Get-ChildItem -Path $RestoreRoot -Recurse -Filter *.vmcx -File | Select-Object -First 1
$Vmcx.FullName
```

The result must point inside the restore-test tree. If no `.vmcx` is found, stop and inspect the restored tree.

## 7. Prepare an isolated import location

```powershell
$ImportRoot = "S:\VMBackups\RestoreTest\FreeBSD-Imported-$Snapshot"
$VmPath = "$ImportRoot\VM"
$VhdPath = "$ImportRoot\VHD"
$SnapPath = "$ImportRoot\Snapshots"
$PagePath = "$ImportRoot\Paging"
New-Item -ItemType Directory -Force $VmPath, $VhdPath, $SnapPath, $PagePath | Out-Null
```

## 8. Import as a copy with a new VM ID

```powershell
$Restored = Import-VM -Path $Vmcx.FullName -Copy -GenerateNewId -VirtualMachinePath $VmPath -VhdDestinationPath $VhdPath -SnapshotFilePath $SnapPath -SmartPagingFilePath $PagePath
Rename-VM -VM $Restored -NewName "FreeBSD-RestoreTest"
$Restored = Get-VM -Name "FreeBSD-RestoreTest"
```

## 9. Handle saved state if present

```powershell
Get-VM -Name "FreeBSD-RestoreTest" | Select-Object Name, State, Status
```

If the clone is `Saved`, discard only the clone's saved RAM state:

```powershell
Remove-VMSavedState -VMName "FreeBSD-RestoreTest" -Confirm:$false
```

This does not discard the restored virtual disk contents.

## 10. Verify disk isolation

```powershell
Get-VMHardDiskDrive -VM $Restored | Select-Object VMName, Path
```

Every VHD path must point underneath the restore/import test tree. Stop immediately if any restored disk points at production storage.

## 11. Remove networking before boot

```powershell
Get-VMNetworkAdapter -VM $Restored | Select-Object VMName, Name, SwitchName, MacAddress
Get-VMNetworkAdapter -VM $Restored | Remove-VMNetworkAdapter
Get-VMNetworkAdapter -VM $Restored
```

The final command should return no adapters.

**Do not boot the restore-test VM if any network adapter remains attached.**

## 12. Boot the isolated clone

```powershell
Start-VM -Name "FreeBSD-RestoreTest"
Get-VM -Name "FreeBSD-RestoreTest" | Select-Object Name, State, Status
vmconnect.exe localhost "FreeBSD-RestoreTest"
```

## 13. Verify FreeBSD

Inside the isolated guest:

```sh
hostname
freebsd-version
uname -a
df -h
```

Verify any VM-specific services and configuration that matter at the time of recovery.

Do not enable networking during the isolated restore test.

## 14. Shut down and clean up the test

Inside FreeBSD:

```sh
sudo shutdown -p now
```

After the VM reaches `Off`:

```powershell
Remove-VM -Name "FreeBSD-RestoreTest" -Force
Remove-Item $ImportRoot -Recurse -Force
Remove-Item $RestoreRoot -Recurse -Force
```

Do not delete the canonical restic snapshot as part of restore-test cleanup.

---

# Full disaster recovery

For an actual loss of the production VM:

1. Confirm the original VM cannot rejoin the network.
2. Establish trusted connectivity from the replacement Hyper-V host to FrontDesk.
3. Install restic.
4. Obtain the rest-server username/password.
5. Obtain the independently stored restic repository encryption password.
6. Confirm repository access with `restic cat config`.
7. List snapshots tagged `hyperv,FreeBSD`.
8. Choose a known-good snapshot deliberately.
9. Restore it to local storage.
10. Locate the exported `.vmcx`.
11. Import it with `-Copy -GenerateNewId`.
12. Verify every restored VHD path.
13. Boot once with networking removed.
14. Verify the guest state.
15. Attach the intended Hyper-V networking only after confirming the original VM is gone.
16. Verify network, SSH, WireGuard, and application state as appropriate.

If the replacement Windows host has different Hyper-V virtual-switch names, do not assume the exported switch mapping is valid.

---

# Repository maintenance and restore notes

Normal backup runs use `forget` for retention but do not `prune` every time. Pruning remains a separate maintenance task.

If time permits before a restore:

```powershell
restic -r $Repo check
```

Do not let an optional long check unnecessarily delay an urgent recovery when repository access and the selected snapshot are otherwise healthy.

---

# Current verification status

As of **2026-10-01**:

```text
Backup creation:             verified
DPAPI unattended loading:    verified
rest-server authentication:  verified
Repository encryption auth:  verified
Automatic parent selection:  verified
Incremental deduplication:    verified
Staging cleanup:             verified
ntfy authenticated publish:  verified
Full restic restore:         NOT YET TESTED
Hyper-V import from restic:  NOT YET TESTED
Isolated guest boot:         NOT YET TESTED
```

After a complete restore/import/boot test succeeds, update this section with the tested snapshot ID and date.
