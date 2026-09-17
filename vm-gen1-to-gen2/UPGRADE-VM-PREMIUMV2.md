# Upgrade an Azure VM and Migrate Data Disks to Premium SSD v2

Use [`upgrade-vm-v7-premiumv2.ps1`](upgrade-vm-v7-premiumv2.ps1) to resize an existing Azure VM, optionally upgrade a Windows Generation 1 VM to Generation 2 Trusted Launch, convert its disk controller from SCSI to NVMe, and replace its managed data disks with Premium SSD v2 disks. The OS disk storage SKU is preserved.

Normally, the VM resource is updated in place. With `-MigrateAvailabilitySetToZone`, the VM resource is deleted and recreated with the same name and NICs. Each data disk is migrated by creating a snapshot and a new disk, then replacing the original attachment at the same LUN. The script does not delete the original disks or snapshots.

> **Downtime warning:** The script deallocates the VM before changing its size, controller, OS-disk controller capabilities, and data-disk attachments. Run it during an approved maintenance window.

## Prerequisites

Before running the script, confirm that:

- Azure CLI is installed and `az login` has authenticated to the correct tenant.
- Your identity can read and update the VM and managed disks, create snapshots and disks, and start/deallocate the VM. `Virtual Machine Contributor` plus permission to create and manage snapshots is a typical starting point; use the least-privileged roles required by your environment.
- The target VM size is available for this VM's region, zone, quota, and availability constraints.
- Premium SSD v2 is available for the VM's placement. Azure does not support attaching Premium SSD v2 managed disks to VMs in Availability Sets. Use `-MigrateAvailabilitySetToZone -TargetZone <zone>` to explicitly recreate an Availability Set VM in a supported availability zone. In regions where Premium SSD v2 is zonal only, other non-zonal VMs must already be replaced with a zonal VM. Premium SSD v2 data disks use `None` host caching.
- The requested IOPS and throughput are valid for every migrated disk's size. Azure imposes size-dependent Premium SSD v2 performance limits in addition to the script's parameter ranges.
- You have a current application-consistent backup and a tested recovery procedure. The snapshots created by this script are crash-consistent.
- The guest OS and applications have been stopped cleanly or can tolerate crash-consistent disk copies.
- No attached data disk is shared with another VM. The script rejects shared disks.

For a v6 or v7 VM SKU that uses NVMe, also confirm that the guest is NVMe-ready. Automatic guest preparation and the optional Gen1-to-Gen2 upgrade in this script support Windows only.

Before upgrading a Gen1 VM, also confirm that:

- The Windows version supports Azure's Gen1-to-Trusted-Launch upgrade. Windows Server 2016 is not supported; upgrade the guest OS first.
- OS-volume BitLocker or equivalent guest encryption is disabled. Data-disk encryption does not need to be disabled.
- Azure Backup, if enabled, uses an Enhanced policy rather than a Standard policy.
- The current VM size and configuration support Trusted Launch.
- A full backup or restore point exists. The script creates a crash-consistent OS-disk snapshot, but a Gen1-to-Gen2 conversion cannot be reversed in place.

## Review the Current VM

Set the values for the VM you intend to upgrade:

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroupName = '<resource-group>'
$vmName = '<vm-name>'
$targetVmSize = 'Standard_D8s_v6'

az account set --subscription $subscriptionId
az vm show `
    --resource-group $resourceGroupName `
    --name $vmName `
    --query '{location:location,zone:zones[0],vmSize:hardwareProfile.vmSize,securityType:securityProfile.securityType,diskController:storageProfile.diskControllerType,osType:storageProfile.osDisk.osType,osDiskId:storageProfile.osDisk.managedDisk.id,dataDisks:storageProfile.dataDisks[].{name:name,lun:lun,caching:caching}}' `
    --output json

$osDiskId = az vm show `
    --resource-group $resourceGroupName `
    --name $vmName `
    --query 'storageProfile.osDisk.managedDisk.id' `
    --output tsv

az disk show --ids $osDiskId --query hyperVGeneration --output tsv

az vm list-vm-resize-options `
    --resource-group $resourceGroupName `
    --name $vmName `
    --query "[?name=='$targetVmSize'].name" `
    --output table
```

The resize query shows sizes available on the VM's current cluster. If it does not return the target size, the script warns and lets Azure attempt placement on compatible regional hardware after deallocation. The resize can still fail because of regional capacity, quota, zone, or availability-set constraints.

By default, the script preserves the VM's existing region, zone, and Availability Set membership. Azure cannot update an existing VM from an Availability Set to a zone. The opt-in Availability Set migration therefore deletes and recreates the VM resource with the same name in the selected zone. It retains the existing NIC resources and private IP configuration. Static public IP resources are also retained; the script rejects dynamic public IPs because their address is not guaranteed across recreation.

The Availability Set migration does not preserve everything attached to the VM resource. VM extensions must be reinstalled, and a system-assigned managed identity receives a new principal ID. User-assigned identities, tags, license type, encryption-at-host setting, disks, and NICs are carried into the replacement when present. Review role assignments, backup configuration, monitoring, policy, and extension state after migration.

## Run the Upgrade

Open PowerShell from this utility's folder. The following example upgrades a Windows VM to a v6 SKU, prepares the guest for NVMe, migrates non-Premium-v2 data disks, and leaves the VM stopped for validation:

```powershell
./upgrade-vm-v7-premiumv2.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -VmName $vmName `
    -TargetVmSize $targetVmSize `
    -DiskIops 5000 `
    -DiskThroughputMBps 200 `
    -ConfirmNvmeReady `
    -PrepareWindowsForNvme `
    -KeepStopped
```

`-ConfirmNvmeReady` is an explicit acknowledgement, not an automated Generation 2 or guest-readiness test. When `-PrepareWindowsForNvme` is used, the script downloads Microsoft's Windows NVMe preparation script to the local temporary directory and executes it on the running VM through Azure Run Command. Review and approve the configured URL before use.

For a supported Windows Gen1 VM, add `-UpgradeGen1ToTrustedLaunch`. The script creates an OS-disk recovery snapshot, runs `MBR2GPT` validation and conversion through Azure Run Command, enables Trusted Launch with Secure Boot and vTPM, starts the VM, and verifies that its OS disk reports Generation 2 before continuing:

```powershell
./upgrade-vm-v7-premiumv2.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -VmName $vmName `
    -TargetVmSize $targetVmSize `
    -UpgradeGen1ToTrustedLaunch `
    -ConfirmNvmeReady `
    -PrepareWindowsForNvme `
    -KeepStopped
```

For a VM in an Availability Set, explicitly select the destination availability zone. This is a destructive VM-resource recreation with best-effort rollback, so use an approved maintenance window:

```powershell
./upgrade-vm-v7-premiumv2.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -VmName $vmName `
    -TargetVmSize $targetVmSize `
    -UpgradeGen1ToTrustedLaunch `
    -ConfirmNvmeReady `
    -PrepareWindowsForNvme `
    -MigrateAvailabilitySetToZone `
    -TargetZone '1' `
    -KeepStopped
```

Before deleting the source VM resource, the script creates the replacement data disks and a zonal OS-disk copy from snapshots. It changes disk and NIC delete options to `Detach`, detaches the source data disks, deletes only the VM resource, and recreates the same VM name in the selected zone with the same NIC IDs.

For a target SKU that remains on SCSI, specify the controller explicitly and omit the NVMe switches:

```powershell
./upgrade-vm-v7-premiumv2.ps1 `
    -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName `
    -VmName $vmName `
    -TargetVmSize 'Standard_D8s_v5' `
    -TargetDiskControllerType SCSI `
    -DiskIops 5000 `
    -DiskThroughputMBps 200
```

Unless `-KeepStopped` is supplied, the script restarts the VM only if it was running when the operation began.

## Parameters

| Parameter | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SubscriptionId` | No | Current Azure CLI subscription | Selects the subscription before any VM operation. |
| `ResourceGroupName` | Yes | None | Resource group containing the VM, disks, and generated artifacts. |
| `VmName` | Yes | None | Existing VM to upgrade. |
| `TargetVmSize` | Yes | None | New Azure VM SKU. |
| `TargetDataDiskSku` | No | `PremiumV2_LRS` | Target data-disk SKU. Currently only Premium SSD v2 is accepted. |
| `DiskIops` | No | `5000` | Provisioned IOPS for every new data disk; accepted range is 3,000 to 80,000. |
| `DiskThroughputMBps` | No | `200` | Provisioned throughput for every new data disk; accepted range is 125 to 2,000 MB/s. |
| `SnapshotSuffix` | No | `-pre-premiumv2` | Suffix used for generated snapshot names. |
| `TargetDiskSuffix` | No | `-premiumv2` | Suffix used for generated Premium SSD v2 disk names. |
| `TargetDiskControllerType` | No | `Auto` | Uses NVMe for VM sizes ending in `_v6` or `_v7`; otherwise uses SCSI. It can be forced to `NVMe` or `SCSI`. |
| `ConfirmNvmeReady` | For detected v6/v7 targets | Off | Confirms that Generation 2 and NVMe guest prerequisites were independently checked. |
| `UpgradeGen1ToTrustedLaunch` | For automated Windows Gen1 conversion | Off | Converts a supported Windows Gen1 VM to Gen2 Trusted Launch before an NVMe resize. |
| `Gen1OsSnapshotSuffix` | No | `-pre-gen2` | Suffix used for the pre-conversion OS-disk recovery snapshot. |
| `PrepareWindowsForNvme` | For Windows SCSI-to-NVMe conversion | Off | Runs the Microsoft guest-preparation script before deallocation. |
| `WindowsNvmePreparationScriptUrl` | No | Microsoft GitHub URL | Overrides the Windows NVMe preparation script source. |
| `MigrateAvailabilitySetToZone` | For Availability Set migration | Off | Explicitly permits deleting and recreating an Availability Set VM in an availability zone while retaining its NICs. |
| `TargetZone` | With Availability Set migration | None | Destination availability zone for the replacement VM, OS disk, and Premium SSD v2 data disks. |
| `ZonalOsSnapshotSuffix` | No | `-pre-zone` | Suffix for the post-conversion OS snapshot used to build the zonal OS disk. |
| `ZonalOsDiskSuffix` | No | `-zonal` | Suffix for the replacement OS disk created in the target zone. |
| `ReuseExistingArtifacts` | No | Off | Reuses snapshots and target disks with the generated names after an interrupted run. |
| `KeepStopped` | No | Off | Leaves the VM deallocated after migration. |

All non-Premium-v2 data disks receive the same IOPS and throughput values. Run separate migrations or modify the script if disks require different performance settings. A normal in-place upgrade does not recreate the OS disk. Availability Set-to-zone migration creates a zonal OS-disk copy from a snapshot while preserving the original storage SKU and retaining the source OS disk for recovery.

## What the Script Does

The following sequence matches the script's execution order.

### 1. Validate local input

The script enables terminating errors and reduces non-error Azure CLI output. It then:

- Confirms that the `az` command is installed.
- Validates parameter values through PowerShell, including the allowed disk SKU, controller type, IOPS, and throughput ranges.
- Requires `-ConfirmNvmeReady` when the target size name ends in `_v6` or `_v7`.
- Resolves `TargetDiskControllerType=Auto` to `NVMe` for `_v6` and `_v7` target names, or `SCSI` for other names.

No Azure resource has been changed at this point.

### 2. Select the subscription

When `-SubscriptionId` is supplied, the script changes the active Azure CLI subscription with `az account set`. Otherwise, it reads and uses the current subscription. All subsequent Azure operations use that CLI context.

### 3. Read the source VM state

The script retrieves the VM, its managed OS disk, and its instance view. It records:

- OS type and Hyper-V generation.
- Current VM size and disk controller.
- Original OS-disk SKU.
- Running or stopped state when the script began.
- Region, availability zone, and Availability Set membership.
- Attached managed data disks, LUNs, and caching modes.

The original power state determines whether the script starts the VM at the end. The original OS-disk SKU is retained for the final invariant check.

### 4. Validate Premium SSD v2 placement

This preflight runs only when the VM has at least one data disk to migrate to `PremiumV2_LRS`.

- If the VM belongs to an Availability Set, the script requires `-MigrateAvailabilitySetToZone` and `-TargetZone` because Azure does not support Premium SSD v2 managed disks on Availability Set VMs.
- For an Availability Set migration, it verifies that associated public IPs are static, inventories extensions that must be reinstalled, and warns about VM recreation and system-assigned identity replacement.
- If the VM is non-zonal, the script queries Premium SSD v2 SKU placement metadata for the VM's region. It stops if that region offers only zonal Premium SSD v2.
- A VM that is already zonal proceeds; replacement disks are later created in the source disk's zone.

These checks occur before OS snapshots, `MBR2GPT`, resize, or data-disk changes.

### 5. Convert Windows Gen1 to Gen2 when required

This branch runs only when the OS disk reports `V1` and the target controller is `NVMe`.

1. The script requires `-UpgradeGen1ToTrustedLaunch`.
2. It verifies that the guest is Windows and that the VM was running when execution began.
3. It calculates the recovery snapshot name from the OS-disk name and `Gen1OsSnapshotSuffix`.
4. It stops if that snapshot already exists, unless `-ReuseExistingArtifacts` was supplied.
5. It deallocates the VM and waits for the deallocated state.
6. It creates an incremental snapshot of the Gen1 OS disk when one is not being reused.
7. It starts the VM so Azure Run Command can execute in the guest.
8. It runs `MBR2GPT /validate` and then `MBR2GPT /convert` against Windows disk 0.
9. It requires the guest script's explicit success marker; otherwise, it stops and reports the recovery snapshot name.
10. It deallocates the VM again and enables Trusted Launch, Secure Boot, and vTPM.
11. It starts the VM, rereads the OS disk, and requires Azure to report Hyper-V generation `V2`.

If `-UpgradeGen1ToTrustedLaunch` is supplied for a VM that is not Gen1, the script reports that conversion is skipped. A successful Gen1-to-Gen2 conversion is not rolled back later by this script.

### 6. Check target size availability

For an in-place resize, the script queries the VM's current cluster with `az vm list-vm-resize-options`. If the target size is absent, it prints a warning rather than stopping. Azure can sometimes place the deallocated VM on different compatible hardware, so the actual resize is attempted later.

For Availability Set-to-zone migration, the script instead verifies that the target size exists in the region, supports the target zone and retained NIC count, and has no location or zone restriction for the subscription.

This warning does not guarantee that the resize will work. Azure can still reject it because of capacity, quota, architecture, availability constraints, or a transition between VM sizes with and without a local resource disk.

### 7. Build the data-disk migration plan

For every attached data disk, in LUN order, the script:

- Reads the managed disk resource.
- Rejects shared disks or disks not exclusively managed by this VM.
- Rejects disks in a different region from the VM.
- Skips disks already using `PremiumV2_LRS`.
- Records the source disk, LUN, original caching mode, snapshot name, and replacement disk name.

All disks requiring migration receive the same `DiskIops` and `DiskThroughputMBps` values.

### 8. Prepare Windows for NVMe

This branch runs when the target controller is `NVMe` and the current controller is not.

1. The script requires a Windows guest, `-PrepareWindowsForNvme`, and a VM that was running when execution began.
2. It downloads the configured Microsoft NVMe preparation script to the local temporary directory.
3. It executes that file in the guest through Azure Run Command.
4. It checks the output for Microsoft's success text and rejects reported errors.
5. It deletes the locally downloaded temporary file in a `finally` block.

This step changes guest configuration so Windows can boot after the controller changes. `-ConfirmNvmeReady` remains an operator acknowledgement; it does not replace this preparation step.

### 9. Deallocate the VM for migration

The script deallocates the VM and waits until Azure reports `PowerState/deallocated`. The remaining disk creation, VM resize, controller update, and attachment changes occur while the VM is deallocated.

### 10. Snapshot and recreate each data disk

For each disk in the migration plan, the script:

1. Checks whether the generated snapshot name already exists.
2. Creates an incremental snapshot unless an existing artifact is explicitly reused.
3. Checks whether the generated replacement disk name already exists.
4. Creates a `PremiumV2_LRS` disk from the snapshot unless one is being reused.
5. Preserves disk size and zone, uses a 512-byte logical sector size, and applies the requested IOPS and throughput.

The script does not delete the source disks or snapshots. `-ReuseExistingArtifacts` trusts matching names and does not verify their source or configuration.

### 11. Enable the target controller and resize

When changing from SCSI to NVMe, the script first updates the OS disk's supported controller metadata to `SCSI, NVMe`. It then updates the VM to the requested size and target disk controller.

For a normal in-place upgrade, the OS disk itself is not recreated. For Availability Set-to-zone migration, the controller metadata is applied to the zonal OS-disk copy before VM recreation. In both paths, the storage SKU is preserved.

### 12. Replace data-disk attachments

For a normal in-place migration, the script detaches each source disk. For an Availability Set migration, it first sets the OS-disk and NIC delete options to `Detach`, detaches source data disks, deletes the source VM resource, and creates a specialized replacement VM with:

- The same VM name and NIC resource IDs.
- The zonal OS-disk copy and selected availability zone.
- The requested VM size and disk controller.
- Trusted Launch settings, tags, user-assigned identities, license type, and encryption-at-host setting when present.

For every planned data-disk migration, the script then:

1. Detaches the original managed disk.
2. Attaches the Premium SSD v2 replacement at the same LUN.
3. Sets host caching to `None`, as required by Premium SSD v2.

Disk resource names change, but the LUN is preserved. Drive letters and mount points should still be verified inside the guest after startup.

### 13. Attempt data-disk rollback on failure

If a failure occurs during the VM update or attachment block, the script makes a best-effort recovery attempt:

- Detaches any replacement disks that were successfully attached.
- Reattaches every source disk that had been detached.
- Restores each source disk's original LUN and caching mode.
- Rethrows the original failure.

If Availability Set-to-zone recreation fails after source VM deletion, the script attempts to delete any partial replacement, recreate the VM in its original Availability Set from the retained original OS disk and NICs, reattach source data disks, and restore the original running state. Extensions and the old system-assigned identity cannot be restored automatically.

Rollback does not undo a completed Gen1-to-Gen2 conversion, VM resize, controller change, or OS-disk controller metadata update. It also leaves generated snapshots and replacement disks in place for inspection or reuse.

### 14. Restore the intended power state

The VM is started only when it was running at the beginning and `-KeepStopped` was not supplied. A VM that began stopped remains stopped. `-KeepStopped` always leaves it deallocated.

### 15. Verify and report completion

Finally, the script rereads the OS-disk SKU and throws an error if it differs from the value captured at startup. It then prints JSON containing:

- Final VM size.
- OS-disk storage SKU.
- Data-disk names, LUNs, caching modes, and storage SKUs.

The completion message reminds the operator to retain source disks and snapshots until application validation is complete.

## Validate the Upgrade

Start a VM left stopped for validation, then inspect its configuration:

```powershell
az vm start --resource-group $resourceGroupName --name $vmName

az vm show `
    --resource-group $resourceGroupName `
    --name $vmName `
    --query '{vmSize:hardwareProfile.vmSize,securityType:securityProfile.securityType,secureBoot:securityProfile.uefiSettings.secureBootEnabled,vTpm:securityProfile.uefiSettings.vTpmEnabled,diskController:storageProfile.diskControllerType,osDiskSku:storageProfile.osDisk.managedDisk.storageAccountType,dataDisks:storageProfile.dataDisks[].{name:name,lun:lun,caching:caching,sku:managedDisk.storageAccountType}}' `
    --output json

$osDiskId = az vm show --resource-group $resourceGroupName --name $vmName --query 'storageProfile.osDisk.managedDisk.id' --output tsv
az disk show --ids $osDiskId --query hyperVGeneration --output tsv
```

After the VM boots:

- Confirm that the guest sees every expected volume and that drive letters or mount points are correct.
- Check the Windows System event log or Linux kernel log for storage and NVMe errors.
- Validate application consistency and read/write access.
- Run a representative performance test and compare VM and disk metrics with the requested limits.
- Confirm that the OS disk retains its original storage SKU.
- Retain the original disks and snapshots until application owners approve the migration.

## Failure and Recovery

If replacement fails during data-disk attachment, the script attempts to detach newly attached targets and reattach source disks at their original LUNs and caching settings. This is a best-effort data-disk rollback.

The automatic rollback does **not** restore the previous VM size, disk controller, or OS-disk supported-controller setting. The script does not intentionally change the OS-disk SKU and validates that it remains unchanged. Inspect the VM after any failure and restore the size or controller settings manually if required.

A successful Gen1-to-Gen2 Trusted Launch conversion is one-way. To return to Gen1, recreate the VM and disks from the backup, restore point, or pre-conversion OS snapshot. If a later migration step fails, rerunning with `-ReuseExistingArtifacts` skips the Gen1 conversion after Azure reports the OS disk as Generation 2.

An interrupted run can leave snapshots or target disks behind. After verifying that each artifact belongs to this VM and source disk, either remove it and rerun or pass `-ReuseExistingArtifacts`. Reuse is based on generated names; the script does not verify an existing artifact's source, size, zone, SKU, or performance configuration.

Do not delete source disks or snapshots until the upgraded VM and its applications have passed validation and the rollback retention period has expired.