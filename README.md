# AzureUtils by Amit Narang

A collection of Azure utilities created from real-world, ad hoc work with customers. These tools are shared publicly to help cloud architects, administrators, and engineers automate common Azure operations.

Created and maintained by **Amit Narang**, Cloud Solutions Architect.

[Connect with Amit Narang on LinkedIn](https://www.linkedin.com/in/amitnarang28/)

## Utilities

### [Upgrade an Azure VM and Migrate Data Disks to Premium SSD v2](vm-gen1-to-gen2/UPGRADE-VM-PREMIUMV2.md)

This PowerShell utility resizes an existing Azure VM and migrates its managed data disks to Premium SSD v2. For supported Windows workloads, it can also upgrade a Generation 1 VM to Generation 2 Trusted Launch, prepare the guest for NVMe, and migrate an Availability Set VM to an availability zone.

Review the prerequisites, downtime considerations, recovery guidance, and usage examples in the [full utility documentation](vm-gen1-to-gen2/UPGRADE-VM-PREMIUMV2.md) before running the script.

## Disclaimer

Test each utility in a non-production environment and review it for your requirements before using it with customer workloads.