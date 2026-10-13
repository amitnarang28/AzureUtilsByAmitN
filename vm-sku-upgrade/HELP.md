# Azure VM SKU Upgrade

`Invoke-AzVmSkuUpgrade.ps1` analyzes and migrates an existing Azure VM to a compatible v4-v7 VM SKU. It uses live Azure subscription, region, SKU, zone, VM-generation, disk, NIC, and identity information to recommend the migration path that requires the fewest changes.

The script provides two operating modes:

- **Plan** gathers requirements, validates compatibility, reports every expected change, and outputs a ready-to-run command without modifying Azure resources.
- **Run** repeats validation, displays the selected migration plan, and modifies Azure resources only after the user enters exactly `Yes`.

## Important safety notice

The script can deallocate, resize, convert, delete, and recreate Azure VM resources. These operations can cause downtime.

Before using Run mode:

1. Test the complete path in a non-production subscription.
2. Confirm that the application has a tested backup and recovery plan.
3. Validate target SKU capacity and quota.
4. Confirm operating-system, driver, boot-generation, and NVMe readiness.
5. Schedule an appropriate outage window.
6. Retain recovery snapshots until application validation is complete.

Plan mode doesn't modify Azure resources.

## Prerequisites

- PowerShell 5.1 or PowerShell 7.
- Azure CLI installed and available as `az`.
- An authenticated Azure CLI session created with `az login`.
- Permission to read and modify the VM and its disks, NICs, public IPs, identities, snapshots, role assignments, and availability configuration.
- Sufficient regional vCPU quota and capacity for the target SKU.
- Network access to Microsoft-hosted preparation scripts when `-PrepareWindowsForNvme` is used.

Set the intended subscription before running:

```powershell
az account set --subscription '<subscription-id>'
```

You can alternatively provide `-SubscriptionId` to the script.

## Supported functionality

The script can:

- Discover compatible v4-v7 target SKUs in the VM's current region.
- Validate vCPU, memory, NIC, data-disk, region, zone, and subscription restrictions.
- Compare the source and target VM generation and disk-controller requirements.
- Detect direct in-place and deallocate-and-resize paths.
- Detect changes that require cloning or VM-resource recreation.
- Identify temporary/resource-disk incompatibility before Azure rejects the resize.
- Convert a supported Windows Generation 1 VM to Generation 2 Trusted Launch.
- Prepare a supported Windows guest for SCSI-to-NVMe conversion.
- Update the OS disk to support both SCSI and NVMe before an NVMe resize.
- Migrate managed data disks to Premium SSD v2 using snapshots and replacement disks.
- Plan or perform supported Availability Set-to-availability-zone migrations.
- Retain existing NIC resources so private and static public IP configuration can be preserved.
- Preserve user-assigned managed identities.
- Capture and restore system-assigned identity role assignments when VM-resource recreation changes the principal ID.
- Restore the original running state unless `-KeepStopped` is specified.
- Output higher-generation clone or rebuild options.

## Operating modes

### Plan mode

Plan is the default mode. It:

1. Reads the current VM configuration.
2. Queries current regional SKU capabilities and subscription restrictions.
3. Prompts for missing target choices.
4. Ranks compatible targets by the amount of required change.
5. Reports the selected path, prerequisites, risks, and resource changes.
6. Outputs a Run-mode command containing the resolved parameters.
7. Exits without changing Azure resources.

Example:

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'my-resource-group' `
    -VmName 'my-vm' `
    -TargetVmSize 'Standard_D4s_v5' `
    -Mode Plan
```

If `-TargetVmSize` is omitted, Plan mode displays compatible least-change candidates and prompts for a target.

### Run mode

Run mode requires `-TargetVmSize`. The script prints the complete plan and then prompts:

```text
Type Yes to execute this migration
```

Only the exact response `Yes` starts the migration. Any other response exits without modifying Azure resources.

Paths that delete and recreate the VM resource require a second explicit confirmation.

Example:

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName 'my-resource-group' `
    -VmName 'my-vm' `
    -SourceVmSize 'Standard_D4s_v4' `
    -TargetVmSize 'Standard_D4s_v5' `
    -TargetGeneration Preserve `
    -TargetDataDiskSku Preserve `
    -AvailabilityTarget Preserve `
    -Mode Run
```

## Parameters

| Parameter | Required | Default | Description |
|---|---:|---|---|
| `SubscriptionId` | No | Current Azure CLI subscription | Azure subscription containing the VM. |
| `ResourceGroupName` | Yes | None | Resource group containing the VM. |
| `VmName` | Yes | None | Name of the existing VM. |
| `SourceVmSize` | No | Deployed VM size | Optional safety assertion. The script stops if it doesn't match the deployed size. |
| `TargetVmSize` | Run: Yes; Plan: No | Plan prompts | Target Azure VM SKU. |
| `Mode` | No | `Plan` | `Plan` performs analysis only. `Run` can execute after confirmation. |
| `TargetGeneration` | No | `Preserve` | Preserve the current generation or request `Gen2`. Targets that require Gen2 override Preserve. |
| `TargetDataDiskSku` | No | `Preserve` | Preserve data disks or migrate them to `PremiumV2_LRS`. |
| `AvailabilityTarget` | No | `Preserve` | Preserve availability configuration or migrate a supported Availability Set VM to `Zone`. |
| `TargetZone` | With zone migration | None | Target availability-zone number. |
| `DiskIops` | No | `5000` | Provisioned IOPS for replacement Premium SSD v2 data disks. Valid range: 3,000-80,000. |
| `DiskThroughputMBps` | No | `200` | Provisioned throughput for replacement Premium SSD v2 data disks. Valid range: 125-2,000 MB/s. |
| `ConfirmNvmeReady` | For NVMe targets | Off | Confirms that the image and guest were reviewed for NVMe compatibility. |
| `PrepareWindowsForNvme` | For automated Windows conversion | Off | Runs Microsoft's Windows NVMe preparation script and validates its result. |
| `ReuseExistingArtifacts` | No | Off | Reuses matching migration snapshots or disks left by an earlier attempt. Review them before enabling this option. |
| `KeepStopped` | No | Off | Leaves the VM stopped instead of restoring its original running state. |

## Common examples

### Analyze a v4-to-v5 upgrade

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -ResourceGroupName 'rg-app-prod' `
    -VmName 'app-vm-01' `
    -TargetVmSize 'Standard_D4s_v5' `
    -Mode Plan
```

### Run an in-place v5 migration

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -ResourceGroupName 'rg-app-prod' `
    -VmName 'app-vm-01' `
    -SourceVmSize 'Standard_D4s_v4' `
    -TargetVmSize 'Standard_D4s_v5' `
    -Mode Run
```

### Analyze a Windows migration to v7

v6 and v7 VM families generally require Generation 2 and NVMe. Plan mode reports the generation, guest, controller, and disk changes.

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -ResourceGroupName 'rg-app-test' `
    -VmName 'windows-vm-01' `
    -TargetVmSize 'Standard_D2s_v7' `
    -TargetGeneration Gen2 `
    -ConfirmNvmeReady `
    -PrepareWindowsForNvme `
    -Mode Plan
```

Run the generated command only after reviewing the plan and validating the workload.

### Migrate data disks to Premium SSD v2

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -ResourceGroupName 'rg-data-test' `
    -VmName 'data-vm-01' `
    -TargetVmSize 'Standard_E4s_v5' `
    -TargetDataDiskSku PremiumV2_LRS `
    -DiskIops 5000 `
    -DiskThroughputMBps 200 `
    -Mode Plan
```

Premium SSD v2 availability varies by region and zone. Premium SSD v2 isn't supported on VMs in Availability Sets. Such a configuration requires a supported zone-migration path.

### Plan Availability Set-to-zone migration

```powershell
.\Invoke-AzVmSkuUpgrade.ps1 `
    -ResourceGroupName 'rg-app-test' `
    -VmName 'app-vm-01' `
    -TargetVmSize 'Standard_D4s_v5' `
    -TargetDataDiskSku PremiumV2_LRS `
    -AvailabilityTarget Zone `
    -TargetZone '1' `
    -Mode Plan
```

## Windows support

Windows is supported for:

- In-place resizing.
- Generation 1-to-2 conversion using `MBR2GPT`.
- Trusted Launch enablement.
- SCSI-to-NVMe preparation using Microsoft's preparation script.
- v6/v7 migration when the selected SKU, image, region, drivers, and workload are compatible.

The Generation 1 conversion creates a recovery snapshot before modifying the OS disk. Keep that snapshot until the migrated workload is fully validated.

## Linux support and limitations

Linux support is currently partial.

Supported Linux paths include:

- In-place resizing when source and target use the same boot generation and disk-controller type.
- Common compatible v4-to-v5 SCSI migrations.
- Migration between compatible NVMe SKUs when the Linux VM is already Generation 2 and NVMe-ready.

The script doesn't currently automate:

- Linux Generation 1-to-2 conversion.
- Linux bootloader or partition-table conversion.
- Linux initramfs rebuilding for NVMe.
- Distribution-specific NVMe and MANA driver installation or validation.
- SCSI-to-NVMe conversion for a Linux guest that isn't already NVMe-ready.

Generation 1-to-2 automation stops explicitly for non-Windows VMs. Automated NVMe guest preparation also stops for non-Windows VMs instead of attempting an unsafe migration.

Before extending Linux support, add distribution-aware checks for Ubuntu, RHEL, SUSE, and other intended distributions, including kernel, NVMe, MANA, initramfs, bootloader, and Azure Agent readiness.

## IP and networking preservation

In-place migrations retain the VM's NIC resources.

For supported recreation paths, the script detaches and reuses existing NICs. This preserves:

- Private IP configuration.
- Network security group association.
- Backend-pool memberships represented on the NIC.
- Static public IP resource association.

A dynamic public IP address isn't guaranteed to retain the same address during VM recreation. Convert it to static before a recreation path.

## Managed identities and permissions

For in-place migrations, the VM resource and its managed identities remain unchanged.

For supported recreation paths:

- User-assigned identities are reassigned to the recreated VM.
- A system-assigned identity receives a new principal ID.
- The script captures role assignments belonging to the old system identity and recreates them for the new principal.

Review role assignments after migration, especially when access is controlled outside Azure RBAC or by systems that store the old principal ID.

## Temporary/resource-disk compatibility

Azure doesn't support an in-place resize that adds or removes the local temporary/resource disk.

For example, a resize from a SKU with a resource disk to a target without one can fail even after deallocation. The script detects this difference, marks the path as requiring clone/rebuild, and stops Run mode before modifying the VM.

Select a target with matching temporary-disk behavior or design a clone/rebuild cutover.

Never store persistent application data on the temporary/resource disk.

## Integration tests

The `tests` folder contains destructive Azure integration-test runners:

- `Test-V1ToV5.ps1`
- `Test-V1ToV7.ps1`
- `Test-V2ToV5.ps1`
- `Test-V2ToV7.ps1`

Each runner:

1. Verifies source and target SKU availability.
2. Creates an isolated resource group.
3. Creates a Windows VM with a static public IP and system-assigned identity.
4. Invokes the migration script.
5. Validates the target SKU, private IP, public IP, identity, and power state.
6. Deletes the resource group in a `finally` block.

These tests create billable Azure resources. Run them only in an approved test subscription.

Example:

```powershell
.\tests\Test-V2ToV7.ps1 `
    -SubscriptionId '<subscription-id>'
```

All SKU and region defaults can be overridden because availability and subscription restrictions differ.

## Troubleshooting

### Target SKU isn't found

- Confirm the target exists in the VM's region.
- Check subscription restrictions and quota.
- Check the exact SKU spelling.
- Run `az vm list-skus --location <region> --resource-type virtualMachines --all`.

### Resize is rejected because of a resource disk

Choose a target SKU with matching local temporary-disk behavior. A clone or rebuild is required to add or remove the local resource disk.

### v7 migration reports that NVMe isn't supported

- Confirm the VM is Generation 2.
- Run the Windows preparation path with `-PrepareWindowsForNvme`.
- Confirm readiness with `-ConfirmNvmeReady`.
- Confirm the OS disk advertises SCSI and NVMe controller support.
- Verify that the selected image and operating-system version support the target SKU.

### Generation conversion fails

- Review the `MBR2GPT` output.
- Verify Windows partition-layout requirements.
- Confirm the Azure VM Agent is healthy.
- Use the recovery snapshot created before conversion if rollback is required.

### Public IP changed

Dynamic public IP addresses aren't guaranteed during recreation. Use a Standard static public IP before migration.

### Existing snapshot or disk blocks a retry

Review the artifact to determine whether it belongs to the failed migration. Remove it or rerun with `-ReuseExistingArtifacts` only when reuse is safe.

## Microsoft documentation

- [Modernize to the v5 VM series](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview)
- [Modernize to the v6 and v7 VM series](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-overview)
- [Azure Generation 2 VMs](https://learn.microsoft.com/azure/virtual-machines/generation-2)
- [NVMe overview](https://learn.microsoft.com/azure/virtual-machines/nvme-overview)
- [Trusted Launch](https://learn.microsoft.com/azure/virtual-machines/trusted-launch)
- [Premium SSD v2](https://learn.microsoft.com/azure/virtual-machines/disks-types#premium-ssd-v2)
- [Availability zones](https://learn.microsoft.com/azure/reliability/availability-zones-overview)

## Disclaimer

Azure SKU capabilities, availability, quota, pricing, and migration support change over time. Always review the generated plan and current Microsoft documentation before executing a migration.
