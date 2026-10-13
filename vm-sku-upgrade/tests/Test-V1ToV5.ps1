[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location = 'SouthAfricaNorth',
    [string]$SourceVmSize = 'Standard_D2',
    [string]$TargetVmSize = 'Standard_D2ds_v5'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$SubscriptionId = Initialize-TestSubscription -SubscriptionId $SubscriptionId
Assert-TestSkuAvailable -Location $Location -VmSize $SourceVmSize
Assert-TestSkuAvailable -Location $Location -VmSize $TargetVmSize

$suffix = "$(Get-Date -Format 'yyyyMMddHHmmss')-$((Get-Random -Minimum 1000 -Maximum 9999))"
$resourceGroupName = "azsku-v1-v5-$suffix"
$vmName = 'test-v1-to-v5'
$migrationScript = Join-Path $PSScriptRoot '..\Invoke-AzVmSkuUpgrade.ps1'

try {
    $before = New-SkuMigrationTestVm `
        -ResourceGroupName $resourceGroupName `
        -VmName $vmName `
        -Location $Location `
        -SourceVmSize $SourceVmSize

    & $migrationScript `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $resourceGroupName `
        -VmName $vmName `
        -SourceVmSize $SourceVmSize `
        -TargetVmSize $TargetVmSize `
        -TargetGeneration Preserve `
        -TargetDataDiskSku Preserve `
        -AvailabilityTarget Preserve `
        -Mode Run

    Assert-SkuMigrationResult `
        -ResourceGroupName $resourceGroupName `
        -VmName $vmName `
        -ExpectedVmSize $TargetVmSize `
        -Before $before
}
finally {
    Remove-SkuMigrationTestResourceGroup -ResourceGroupName $resourceGroupName
}
