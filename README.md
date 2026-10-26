# AzureUtils by Amit Narang

A collection of Azure utilities created from real-world, ad hoc work with customers. These tools are shared publicly to help cloud architects, administrators, and engineers automate common Azure operations.

Created and maintained by **Amit Narang**, Cloud Solutions Architect.

[Connect with Amit Narang on LinkedIn](https://www.linkedin.com/in/amitnarang28/)

## Utilities

### [Plan and Run Azure VM SKU Upgrades](vm-sku-upgrade/HELP.md)

This PowerShell utility analyzes an existing Azure VM and builds the least-change migration path to a selected v4-v7 SKU. It supports plan-only analysis, generated execution commands, in-place resizing, Windows Generation 1-to-2 conversion, Windows SCSI-to-NVMe preparation, Premium SSD v2 data-disk migration, and Availability Set-to-zone planning.

The utility preserves existing NICs and IP configuration whenever Azure permits it and validates managed identity, regional SKU, zone, disk-controller, VM-generation, and temporary-disk compatibility before execution. Linux support is currently limited to migrations that don't require automated generation or guest NVMe conversion.

Review the parameters, supported scenarios, limitations, tested paths, and examples in the [VM SKU upgrade help](vm-sku-upgrade/HELP.md) before running the script.

### [Upgrade an Azure VM and Migrate Data Disks to Premium SSD v2](vm-gen1-to-gen2/UPGRADE-VM-PREMIUMV2.md)

This PowerShell utility resizes an existing Azure VM and migrates its managed data disks to Premium SSD v2. For supported Windows workloads, it can also upgrade a Generation 1 VM to Generation 2 Trusted Launch, prepare the guest for NVMe, and migrate an Availability Set VM to an availability zone.

Review the prerequisites, downtime considerations, recovery guidance, and usage examples in the [full utility documentation](vm-gen1-to-gen2/UPGRADE-VM-PREMIUMV2.md) before running the script.

### [Export Azure Monitor Snapshots to CSV](MonthlyMetricSnapshot/MonthlyMetricSnapShot.md)

This read-only PowerShell utility exports user-supplied KQL query results from a Log Analytics workspace or platform metric aggregates from Azure Monitor Metrics. It accepts an explicit time window and output path, uses an existing Azure sign-in, and contains no tenant-specific configuration or credentials.

The guide includes generic query-file usage, previous-calendar-month exports, Cosmos DB diagnostic-log examples, and a separate Metrics mode for comparison with service-blade charts. Review the [setup, data-source differences, limitations, and testing steps](MonthlyMetricSnapshot/MonthlyMetricSnapShot.md) before running it.

## Disclaimer

Test each utility in a non-production environment and review it for your requirements before using it with customer workloads.