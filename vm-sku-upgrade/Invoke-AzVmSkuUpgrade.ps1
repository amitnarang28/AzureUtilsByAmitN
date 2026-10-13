[CmdletBinding()]
param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VmName,

    [string]$SourceVmSize,
    [string]$TargetVmSize,

    [ValidateSet('Plan', 'Run')]
    [string]$Mode = 'Plan',

    [ValidateSet('Preserve', 'Gen2')]
    [string]$TargetGeneration = 'Preserve',

    [ValidateSet('Preserve', 'PremiumV2_LRS')]
    [string]$TargetDataDiskSku = 'Preserve',

    [ValidateSet('Preserve', 'Zone')]
    [string]$AvailabilityTarget = 'Preserve',

    [ValidatePattern('^[1-9][0-9]*$')]
    [string]$TargetZone,

    [ValidateRange(3000, 80000)]
    [int]$DiskIops = 5000,

    [ValidateRange(125, 2000)]
    [int]$DiskThroughputMBps = 200,

    [switch]$ConfirmNvmeReady,
    [switch]$PrepareWindowsForNvme,
    [switch]$ReuseExistingArtifacts,
    [switch]$KeepStopped
)

$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $json = (Invoke-AzCli -Arguments $Arguments) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }
    return $json | ConvertFrom-Json
}

function Get-SkuCapability {
    param(
        [Parameter(Mandatory)]$Sku,
        [Parameter(Mandatory)][string]$Name
    )

    return @($Sku.capabilities | Where-Object { $_.name -eq $Name } | Select-Object -First 1).value
}

function Get-SkuGeneration {
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -match '_v(?<Generation>[1-9][0-9]*)$') {
        return [int]$Matches.Generation
    }
    return 0
}

function Get-TargetController {
    param([Parameter(Mandatory)]$Sku)

    $controllers = [string](Get-SkuCapability -Sku $Sku -Name 'DiskControllerTypes')
    if ($controllers -match 'NVMe') {
        return 'NVMe'
    }
    return 'SCSI'
}

function Test-LocationRestricted {
    param([Parameter(Mandatory)]$Sku)

    return @($Sku.restrictions | Where-Object { $_.type -eq 'Location' }).Count -gt 0
}

function Test-ZoneRestricted {
    param(
        [Parameter(Mandatory)]$Sku,
        [Parameter(Mandatory)][string]$Zone
    )

    $restrictedZones = @(
        $Sku.restrictions |
            Where-Object { $_.type -eq 'Zone' } |
            ForEach-Object { $_.restrictionInfo.zones } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    return $restrictedZones -contains $Zone
}

function Read-Value {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default
    )

    $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
    $value = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Read-Selection {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$AllowedValues,
        [Parameter(Mandatory)][string]$Default
    )

    while ($true) {
        $value = Read-Value -Prompt "$Prompt ($($AllowedValues -join '/'))" -Default $Default
        $match = @($AllowedValues | Where-Object { $_ -ieq $value } | Select-Object -First 1)
        if ($match.Count -eq 1) {
            return $match[0]
        }
        Write-Warning "Enter one of: $($AllowedValues -join ', ')."
    }
}

function ConvertTo-CommandToken {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match "[\s'`"]") {
        return "'$($Value.Replace("'", "''"))'"
    }
    return $Value
}

function New-RunCommand {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Switches
    )

    $tokens = @('&', (ConvertTo-CommandToken -Value $PSCommandPath))
    foreach ($name in @(
            'SubscriptionId', 'ResourceGroupName', 'VmName', 'SourceVmSize', 'TargetVmSize',
            'TargetGeneration', 'TargetDataDiskSku', 'AvailabilityTarget', 'TargetZone',
            'DiskIops', 'DiskThroughputMBps'
        )) {
        if ($Values.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$name])) {
            $tokens += "-$name"
            $tokens += ConvertTo-CommandToken -Value ([string]$Values[$name])
        }
    }
    $tokens += @('-Mode', 'Run')
    foreach ($name in $Switches) {
        $tokens += "-$name"
    }
    return $tokens -join ' '
}

function Get-SystemIdentityRoleAssignments {
    param($Vm)

    if ($Vm.identity.type -notmatch 'SystemAssigned' -or -not $Vm.identity.principalId) {
        return @()
    }
    return @(
        Invoke-AzJson @(
            'role', 'assignment', 'list', '--assignee-object-id', $Vm.identity.principalId,
            '--all', '--query', '[].{roleDefinitionId:roleDefinitionId,scope:scope}', '--output', 'json'
        )
    )
}

function Restore-SystemIdentityRoleAssignments {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][object[]]$Assignments
    )

    foreach ($assignment in $Assignments) {
        Invoke-AzCli @(
            'role', 'assignment', 'create', '--assignee-object-id', $PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $assignment.roleDefinitionId, '--scope', $assignment.scope
        ) | Out-Null
    }
}

function Convert-WindowsVmToGen2 {
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter(Mandatory)]$OsDisk,
        [Parameter(Mandatory)][bool]$WasRunning
    )

    if (-not $WasRunning) {
        throw 'Generation 1-to-2 conversion requires the Windows VM to be running with a ready Azure VM Agent.'
    }

    $snapshotName = "$($OsDisk.name.Substring(0, [Math]::Min($OsDisk.name.Length, 71)))-pre-gen2"
    $snapshotExists = ((Invoke-AzCli @(
                'snapshot', 'list', '--resource-group', $ResourceGroupName,
                '--query', "[?name=='$snapshotName'].name | [0]", '--output', 'tsv'
            )) -join '').Trim() -eq $snapshotName
    if ($snapshotExists -and -not $ReuseExistingArtifacts) {
        throw "Recovery snapshot '$snapshotName' already exists. Remove it or use -ReuseExistingArtifacts."
    }

    Write-Host "Deallocating '$VmName' for the Generation 1 recovery snapshot..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
    Invoke-AzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
    ) | Out-Null
    if (-not $snapshotExists) {
        Invoke-AzCli @(
            'snapshot', 'create', '--resource-group', $ResourceGroupName,
            '--name', $snapshotName, '--source', $OsDisk.id,
            '--location', $Vm.location, '--incremental', 'true'
        ) | Out-Null
    }

    Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
    $conversionScript = @'
& "$env:SystemRoot\System32\mbr2gpt.exe" /validate /disk:0 /allowFullOS
if ($LASTEXITCODE -ne 0) { throw "MBR2GPT validation failed with exit code ${LASTEXITCODE}." }
& "$env:SystemRoot\System32\mbr2gpt.exe" /convert /disk:0 /allowFullOS
if ($LASTEXITCODE -ne 0) { throw "MBR2GPT conversion failed with exit code ${LASTEXITCODE}." }
Write-Output 'GEN2_OS_CONVERSION_COMPLETE'
'@
    $conversionPath = Join-Path ([System.IO.Path]::GetTempPath()) 'convert-windows-os-to-gpt.ps1'
    Set-Content -LiteralPath $conversionPath -Value $conversionScript -Encoding utf8
    try {
        $result = Invoke-AzJson @(
            'vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
            '--name', $VmName, '--command-id', 'RunPowerShellScript',
            '--scripts', "@$conversionPath", '--output', 'json'
        )
    }
    finally {
        Remove-Item -LiteralPath $conversionPath -Force -ErrorAction SilentlyContinue
    }
    $output = @($result.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
    if ($output -notmatch 'GEN2_OS_CONVERSION_COMPLETE' -or $output -match '\[ERROR\]|MBR2GPT validation failed|MBR2GPT conversion failed') {
        throw "Windows MBR-to-GPT conversion failed. Use snapshot '$snapshotName' for recovery if needed:`n$output"
    }

    Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
    Invoke-AzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
    ) | Out-Null
    Invoke-AzCli @(
        'vm', 'update', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--security-type', 'TrustedLaunch', '--enable-secure-boot', 'true', '--enable-vtpm', 'true'
    ) | Out-Null

    $reportedGeneration = ((Invoke-AzCli @(
                'disk', 'show', '--ids', $OsDisk.id, '--query', 'hyperVGeneration', '--output', 'tsv'
            )) -join '').Trim()
    if ($reportedGeneration -ne 'V2') {
        throw "Azure reports generation '$reportedGeneration' after conversion instead of 'V2'. Recovery snapshot: '$snapshotName'."
    }
}

function Enable-WindowsNvmeSupport {
    param([Parameter(Mandatory)]$Vm)

    if ($Vm.storageProfile.osDisk.osType -ne 'Windows') {
        throw 'Automatic NVMe guest preparation currently supports Windows only.'
    }
    if (-not $PrepareWindowsForNvme) {
        throw 'NVMe conversion requires Microsoft guest preparation. Review the migration plan, then use -PrepareWindowsForNvme.'
    }

    $scriptUrl = 'https://raw.githubusercontent.com/Azure/SAP-on-Azure-Scripts-and-Utilities/main/Azure-NVMe-Utils/windows-manual-nvme-prepare.ps1'
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) 'windows-manual-nvme-prepare.ps1'
    Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing
    try {
        $result = Invoke-AzJson @(
            'vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
            '--name', $VmName, '--command-id', 'RunPowerShellScript',
            '--scripts', "@$scriptPath", '--output', 'json'
        )
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    $output = @($result.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
    if ($output -notmatch 'All checks passed across ALL ControlSets' -or $output -match '\[ERROR\]|FATAL:') {
        throw "Windows NVMe preparation did not report success:`n$output"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it and run az login before using this script.'
}

if ($SubscriptionId) {
    Invoke-AzCli @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}
else {
    $SubscriptionId = ((Invoke-AzCli @('account', 'show', '--query', 'id', '--output', 'tsv')) -join '').Trim()
}

$vm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
$currentVmSize = [string]$vm.hardwareProfile.vmSize
if ($SourceVmSize -and $SourceVmSize -ne $currentVmSize) {
    throw "Source VM size '$SourceVmSize' does not match the deployed size '$currentVmSize'."
}
$SourceVmSize = $currentVmSize

$osDisk = Invoke-AzJson @('disk', 'show', '--ids', $vm.storageProfile.osDisk.managedDisk.id, '--output', 'json')
$currentGeneration = [string]$osDisk.hyperVGeneration
$currentController = if ($vm.storageProfile.diskControllerType) {
    [string]$vm.storageProfile.diskControllerType
}
else {
    'SCSI'
}
$nicCount = @($vm.networkProfile.networkInterfaces).Count
$dataDiskCount = @($vm.storageProfile.dataDisks).Count
$availabilitySetId = [string]$vm.availabilitySet.id
$currentZone = [string](@($vm.zones | Where-Object { $_ } | Select-Object -First 1))

Write-Host "Inspecting VM '$VmName' in '$($vm.location)'..." -ForegroundColor Cyan
$regionalSkuResponse = Invoke-AzJson @(
        'vm', 'list-skus', '--location', $vm.location,
        '--resource-type', 'virtualMachines', '--all', '--output', 'json'
    )
$regionalSkus = [System.Collections.Generic.List[object]]::new()
foreach ($sku in $regionalSkuResponse) {
    $regionalSkus.Add($sku)
}
$sourceSku = @($regionalSkus | Where-Object { $_.name -eq $SourceVmSize } | Select-Object -First 1)
if ($sourceSku.Count -ne 1) {
    throw "Current VM size '$SourceVmSize' was not returned for region '$($vm.location)'."
}

$sourceCores = [int](Get-SkuCapability -Sku $sourceSku[0] -Name 'vCPUs')
$sourceMemory = [decimal](Get-SkuCapability -Sku $sourceSku[0] -Name 'MemoryGB')
$sourceHasTempDisk = (Get-SkuCapability -Sku $sourceSku[0] -Name 'MaxResourceVolumeMB') -as [long]

$candidateSkus = @(
    $regionalSkus |
        Where-Object {
            $sku = $_
            $generation = Get-SkuGeneration -Name ([string]$sku.name)
            $cores = (Get-SkuCapability -Sku $sku -Name 'vCPUs') -as [int]
            $memory = (Get-SkuCapability -Sku $sku -Name 'MemoryGB') -as [decimal]
            $maxNics = (Get-SkuCapability -Sku $sku -Name 'MaxNetworkInterfaces') -as [int]
            $maxDisks = (Get-SkuCapability -Sku $sku -Name 'MaxDataDiskCount') -as [int]
            $generation -ge 4 -and $generation -le 7 -and
            -not (Test-LocationRestricted -Sku $sku) -and
            $cores -ge $sourceCores -and $memory -ge $sourceMemory -and
            ($maxNics -eq 0 -or $maxNics -ge $nicCount) -and
            ($maxDisks -eq 0 -or $maxDisks -ge $dataDiskCount)
        } |
        ForEach-Object {
            $sku = $_
            $cores = [int](Get-SkuCapability -Sku $sku -Name 'vCPUs')
            $memory = [decimal](Get-SkuCapability -Sku $sku -Name 'MemoryGB')
            $tempDisk = (Get-SkuCapability -Sku $sku -Name 'MaxResourceVolumeMB') -as [long]
            [pscustomobject]@{
                Sku              = $sku
                Name             = $sku.name
                Generation       = Get-SkuGeneration -Name ([string]$sku.name)
                Cores            = $cores
                MemoryGB         = $memory
                Controller       = Get-TargetController -Sku $_
                HasTempDisk      = $tempDisk -gt 0
                LeastChangeScore = ([math]::Abs($cores - $sourceCores) * 1000) +
                    [math]::Abs([double]($memory - $sourceMemory)) +
                    $(if (($sourceHasTempDisk -gt 0) -ne ($tempDisk -gt 0)) { 100000 } else { 0 })
            }
        } |
        Sort-Object LeastChangeScore, Generation, Name
)

if (-not $TargetVmSize) {
    if ($Mode -eq 'Run') {
        throw '-TargetVmSize is required in Run mode because selecting a different workload profile is not a safe automatic choice.'
    }
    $recommendation = @($candidateSkus | Where-Object { $_.Name -ne $SourceVmSize } | Select-Object -First 1)
    if ($recommendation.Count -ne 1) {
        throw "No compatible v4-v7 target SKU was found in region '$($vm.location)'."
    }
    Write-Host "Least-change candidates:" -ForegroundColor Cyan
    $candidateSkus | Where-Object { $_.Name -ne $SourceVmSize } | Select-Object -First 10 |
        Format-Table Name, Generation, Cores, MemoryGB, Controller, HasTempDisk -AutoSize
    $TargetVmSize = Read-Value -Prompt 'Target VM size' -Default $recommendation[0].Name
}

$targetCandidate = @($candidateSkus | Where-Object { $_.Name -eq $TargetVmSize } | Select-Object -First 1)
if ($targetCandidate.Count -ne 1) {
    throw "Target VM size '$TargetVmSize' is unavailable, restricted, or does not meet the VM's NIC/data-disk requirements in '$($vm.location)'."
}
$target = $targetCandidate[0]
$targetSku = $target.Sku
$targetGenerations = [string](Get-SkuCapability -Sku $targetSku -Name 'HyperVGenerations')
$targetRequiresGen2 = $target.Generation -ge 6 -or ($targetGenerations -and $targetGenerations -notmatch 'V1')
$targetController = $target.Controller

if ($Mode -eq 'Plan') {
    $defaultGeneration = if ($targetRequiresGen2) { 'Gen2' } else { $TargetGeneration }
    $TargetGeneration = Read-Selection -Prompt 'Target VM generation' -AllowedValues @('Preserve', 'Gen2') -Default $defaultGeneration
    $TargetDataDiskSku = Read-Selection -Prompt 'Data disk target' -AllowedValues @('Preserve', 'PremiumV2_LRS') -Default $TargetDataDiskSku
    $defaultAvailability = if ($availabilitySetId -and $TargetDataDiskSku -eq 'PremiumV2_LRS') { 'Zone' } else { $AvailabilityTarget }
    $AvailabilityTarget = Read-Selection -Prompt 'Availability target' -AllowedValues @('Preserve', 'Zone') -Default $defaultAvailability
    if ($AvailabilityTarget -eq 'Zone' -and -not $TargetZone) {
        $zones = @($targetSku.locationInfo.zones | Where-Object { $_ } | Select-Object -Unique)
        if ($zones.Count -eq 0) {
            throw "Target VM size '$TargetVmSize' has no availability zones in '$($vm.location)'."
        }
        Write-Host "Available target zones: $($zones -join ', ')"
        $TargetZone = Read-Value -Prompt 'Target availability zone' -Default $zones[0]
    }
}

if ($targetRequiresGen2) {
    $TargetGeneration = 'Gen2'
}
if ($AvailabilityTarget -eq 'Zone' -and -not $TargetZone) {
    throw '-TargetZone is required when -AvailabilityTarget Zone is selected.'
}
if ($AvailabilityTarget -eq 'Zone') {
    $zones = @($targetSku.locationInfo.zones | Where-Object { $_ } | Select-Object -Unique)
    if ($zones.Count -gt 0 -and $zones -notcontains $TargetZone) {
        throw "Target size '$TargetVmSize' is not available in zone '$TargetZone'. Available zones: $($zones -join ', ')."
    }
    if (Test-ZoneRestricted -Sku $targetSku -Zone $TargetZone) {
        throw "Target size '$TargetVmSize' is restricted for this subscription in zone '$TargetZone'."
    }
}

$resizeOptions = @(
    Invoke-AzCli @(
        'vm', 'list-vm-resize-options', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--query', '[].name', '--output', 'tsv'
    ) | Where-Object { $_ }
)
$needsGenerationConversion = $currentGeneration -eq 'V1' -and $TargetGeneration -eq 'Gen2'
$needsControllerConversion = $currentController -ne $targetController
$needsAvailabilityRecreation = $AvailabilityTarget -eq 'Zone' -and $currentZone -ne $TargetZone
$needsDiskMigration = $TargetDataDiskSku -eq 'PremiumV2_LRS' -and $dataDiskCount -gt 0
$needsResourceDiskRecreation = ($sourceHasTempDisk -gt 0) -ne [bool]$target.HasTempDisk
$requiresRecreation = $needsAvailabilityRecreation -or $needsResourceDiskRecreation

if ($needsAvailabilityRecreation -and -not $availabilitySetId -and -not $currentZone) {
    throw 'This version supports zone migration only from an Availability Set. Regional VM-to-zone migration requires a separate clone name and IP cutover design.'
}
if ($availabilitySetId -and $needsDiskMigration -and -not $needsAvailabilityRecreation) {
    throw 'Premium SSD v2 cannot be attached to a VM in an Availability Set. Select -AvailabilityTarget Zone.'
}
if ($needsGenerationConversion -and $vm.storageProfile.osDisk.osType -ne 'Windows') {
    throw 'Automated Generation 1-to-2 conversion is supported only for Windows. Rebuild this workload from a validated Generation 2 image.'
}
if ($needsControllerConversion -and $targetController -eq 'NVMe' -and -not $ConfirmNvmeReady -and $Mode -eq 'Run') {
    throw 'The target uses NVMe. Validate image and guest readiness, then rerun with -ConfirmNvmeReady.'
}
if ($needsAvailabilityRecreation -and -not $needsDiskMigration) {
    throw 'The current recreation engine supports Availability Set-to-zone migration together with Premium SSD v2 data-disk migration. Use Plan mode to review this unsupported combination.'
}

$migrationType = if ($requiresRecreation) {
    'Clone/Recreate'
}
elseif ($needsGenerationConversion) {
    'Convert generation, then resize in place'
}
elseif ($resizeOptions -contains $TargetVmSize) {
    'Direct in-place resize'
}
else {
    'Deallocate and resize in place'
}

$changes = [System.Collections.Generic.List[string]]::new()
if ($SourceVmSize -ne $TargetVmSize) {
    $changes.Add("VM size: $SourceVmSize -> $TargetVmSize")
}
if ($needsGenerationConversion) {
    $changes.Add('Boot generation: V1/MBR -> V2/GPT with Trusted Launch')
}
if ($needsControllerConversion) {
    $changes.Add("Disk controller: $currentController -> $targetController")
}
if ($needsDiskMigration) {
    $changes.Add("$dataDiskCount data disk(s): snapshot and replace with PremiumV2_LRS disks")
}
if ($needsAvailabilityRecreation) {
    $changes.Add("Availability: Availability Set -> zone $TargetZone by recreating the VM resource")
}
if ($needsResourceDiskRecreation) {
    $changes.Add("Local resource disk presence changes and requires a clone/rebuild path; Azure does not support this as an in-place resize")
}
if ($changes.Count -eq 0) {
    $changes.Add('No Azure resource changes are required.')
}

Write-Host ''
Write-Host 'Migration plan' -ForegroundColor Green
Write-Host "  Subscription:       $SubscriptionId"
Write-Host "  Resource group:     $ResourceGroupName"
Write-Host "  VM:                 $VmName"
Write-Host "  Region:             $($vm.location)"
Write-Host "  Path:               $migrationType"
Write-Host "  Source:             $SourceVmSize, $currentGeneration, $currentController"
Write-Host "  Target:             $TargetVmSize, $TargetGeneration, $targetController"
Write-Host "  Preserve IPs:       Yes, by retaining existing NIC resources"
Write-Host "  Preserve identity:  User-assigned identities retained; system identity RBAC is captured and restored after recreation"
Write-Host '  Required changes:'
foreach ($change in $changes) {
    Write-Host "    - $change"
}

$cloneOptions = @(
    $candidateSkus |
        Where-Object {
            $_.Name -ne $TargetVmSize -and
            ($_.Generation -gt (Get-SkuGeneration -Name $SourceVmSize) -or $_.Controller -eq 'NVMe')
        } |
        Select-Object -First 8
)
if ($cloneOptions.Count -gt 0) {
    Write-Host ''
    Write-Host 'Higher-generation clone/rebuild options:' -ForegroundColor Cyan
    $cloneOptions | Format-Table Name, Generation, Cores, MemoryGB, Controller -AutoSize
}

$switches = [System.Collections.Generic.List[string]]::new()
foreach ($switchName in @('ConfirmNvmeReady', 'PrepareWindowsForNvme', 'ReuseExistingArtifacts', 'KeepStopped')) {
    if ((Get-Variable -Name $switchName -ValueOnly).IsPresent) {
        $switches.Add($switchName)
    }
}
$runCommand = New-RunCommand -Values @{
    SubscriptionId       = $SubscriptionId
    ResourceGroupName    = $ResourceGroupName
    VmName               = $VmName
    SourceVmSize         = $SourceVmSize
    TargetVmSize         = $TargetVmSize
    TargetGeneration     = $TargetGeneration
    TargetDataDiskSku    = $TargetDataDiskSku
    AvailabilityTarget  = $AvailabilityTarget
    TargetZone           = $TargetZone
    DiskIops             = $DiskIops
    DiskThroughputMBps   = $DiskThroughputMBps
} -Switches $switches

Write-Host ''
Write-Host 'Run command:' -ForegroundColor Green
Write-Host $runCommand

if ($Mode -eq 'Plan') {
    return
}
if ($needsResourceDiskRecreation) {
    throw "Migration from '$SourceVmSize' to '$TargetVmSize' changes local resource-disk availability. Use a target with matching temporary-disk support or implement a clone/rebuild cutover."
}

$confirmation = Read-Host "Type Yes to execute this migration"
if ($confirmation -cne 'Yes') {
    Write-Host 'Confirmation was not provided. No Azure resources were changed.' -ForegroundColor Yellow
    return
}
if ($requiresRecreation) {
    $cloneConfirmation = Read-Host "This path deletes and recreates the VM resource while retaining its NICs. Type Yes to confirm cloning/recreation"
    if ($cloneConfirmation -cne 'Yes') {
        Write-Host 'Clone/recreation confirmation was not provided. No Azure resources were changed.' -ForegroundColor Yellow
        return
    }
}

$powerState = ((Invoke-AzCli @(
            'vm', 'get-instance-view', '--resource-group', $ResourceGroupName, '--name', $VmName,
            '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]", '--output', 'tsv'
        )) -join '').Trim()
$wasRunning = $powerState -eq 'PowerState/running'

if ($needsGenerationConversion) {
    Convert-WindowsVmToGen2 -Vm $vm -OsDisk $osDisk -WasRunning $wasRunning
    $vm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
}
if ($needsControllerConversion -and $targetController -eq 'NVMe') {
    if (-not $wasRunning -and -not $needsGenerationConversion) {
        throw 'NVMe guest preparation requires the VM to be running with a ready Azure VM Agent.'
    }
    if ($needsGenerationConversion) {
        Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
    }
    Enable-WindowsNvmeSupport -Vm $vm
}

if (-not $needsDiskMigration -and -not $needsAvailabilityRecreation) {
    Write-Host "Deallocating '$VmName'..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
    Invoke-AzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
    ) | Out-Null
    if ($needsControllerConversion -and $targetController -eq 'NVMe') {
        Invoke-AzCli @(
            'disk', 'update', '--ids', $osDisk.id,
            '--set', 'supportedCapabilities.diskControllerTypes=SCSI, NVMe'
        ) | Out-Null
    }
    $updateArguments = @(
        'vm', 'update', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--size', $TargetVmSize
    )
    if ($needsControllerConversion) {
        $updateArguments += @('--disk-controller-type', $targetController)
    }
    Invoke-AzCli $updateArguments | Out-Null
    if ($wasRunning -and -not $KeepStopped) {
        Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
    }
}
else {
    $enginePath = Join-Path $PSScriptRoot '..\vm-gen1-to-gen2\upgrade-vm-v7-premiumv2.ps1'
    $enginePath = [System.IO.Path]::GetFullPath($enginePath)
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        throw "The complex migration engine was not found at '$enginePath'."
    }

    $systemIdentityAssignments = if ($requiresRecreation) {
        @(Get-SystemIdentityRoleAssignments -Vm $vm)
    }
    else {
        @()
    }
    $oldPrincipalId = [string]$vm.identity.principalId

    $engineParameters = @{
        SubscriptionId             = $SubscriptionId
        ResourceGroupName          = $ResourceGroupName
        VmName                     = $VmName
        TargetVmSize               = $TargetVmSize
        DiskIops                   = $DiskIops
        DiskThroughputMBps         = $DiskThroughputMBps
        TargetDiskControllerType   = $targetController
    }
    if ($needsControllerConversion -and $targetController -eq 'NVMe') {
        $engineParameters.ConfirmNvmeReady = $true
    }
    if ($PrepareWindowsForNvme) {
        $engineParameters.PrepareWindowsForNvme = $true
    }
    if ($needsAvailabilityRecreation) {
        $engineParameters.MigrateAvailabilitySetToZone = $true
        $engineParameters.TargetZone = $TargetZone
    }
    if ($ReuseExistingArtifacts) {
        $engineParameters.ReuseExistingArtifacts = $true
    }
    if ($KeepStopped) {
        $engineParameters.KeepStopped = $true
    }

    & $enginePath @engineParameters

    if ($requiresRecreation -and $oldPrincipalId -and $systemIdentityAssignments.Count -gt 0) {
        $updatedVm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
        $newPrincipalId = [string]$updatedVm.identity.principalId
        if (-not $newPrincipalId) {
            throw 'The recreated VM has no system-assigned identity, so its RBAC assignments could not be restored.'
        }
        if ($newPrincipalId -ne $oldPrincipalId) {
            Restore-SystemIdentityRoleAssignments -PrincipalId $newPrincipalId -Assignments $systemIdentityAssignments
        }
    }
}

$result = Invoke-AzJson @(
    'vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName,
    '--query', '{vmSize:hardwareProfile.vmSize,zones:zones,identity:identity.type,nics:networkProfile.networkInterfaces[].id,diskController:storageProfile.diskControllerType}',
    '--output', 'json'
)
Write-Host 'Migration completed successfully.' -ForegroundColor Green
$result | ConvertTo-Json -Depth 5
