param(
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$TargetVmSize,

    [ValidateSet('PremiumV2_LRS')]
    [string]$TargetDataDiskSku = 'PremiumV2_LRS',

    [ValidateRange(3000, 80000)]
    [int]$DiskIops = 5000,

    [ValidateRange(125, 2000)]
    [int]$DiskThroughputMBps = 200,

    [string]$SnapshotSuffix = '-pre-premiumv2',
    [string]$TargetDiskSuffix = '-premiumv2',
    [ValidateSet('Auto', 'NVMe', 'SCSI')]
    [string]$TargetDiskControllerType = 'Auto',
    [switch]$ConfirmNvmeReady,
    [switch]$UpgradeGen1ToTrustedLaunch,
    [string]$Gen1OsSnapshotSuffix = '-pre-gen2',
    [switch]$PrepareWindowsForNvme,
    [string]$WindowsNvmePreparationScriptUrl = 'https://raw.githubusercontent.com/Azure/SAP-on-Azure-Scripts-and-Utilities/main/Azure-NVMe-Utils/windows-manual-nvme-prepare.ps1',
    [switch]$MigrateAvailabilitySetToZone,
    [ValidatePattern('^[1-9][0-9]*$')]
    [string]$TargetZone,
    [string]$ZonalOsSnapshotSuffix = '-pre-zone',
    [string]$ZonalOsDiskSuffix = '-zonal',
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
    return $json | ConvertFrom-Json
}

function Get-ArtifactName {
    param(
        [Parameter(Mandatory)][string]$SourceName,
        [Parameter(Mandatory)][string]$Suffix
    )

    $maximumBaseLength = 80 - $Suffix.Length
    if ($maximumBaseLength -lt 1) {
        throw "Suffix '$Suffix' is too long for an Azure disk or snapshot name."
    }
    $baseName = $SourceName.Substring(0, [Math]::Min($SourceName.Length, $maximumBaseLength))
    return "$baseName$Suffix"
}

function New-SpecializedVm {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$OsDiskId,
        [Parameter(Mandatory)][string]$OsType,
        [Parameter(Mandatory)][string[]]$NicIds,
        [Parameter(Mandatory)][string]$DiskControllerType,
        [string]$Zone,
        [string]$AvailabilitySetId,
        [string]$SecurityType,
        [bool]$SecureBootEnabled,
        [bool]$VTpmEnabled,
        [string]$LicenseType,
        [bool]$EncryptionAtHost,
        [string[]]$IdentityIds,
        [string[]]$Tags
    )

    $arguments = @(
        'vm', 'create', '--resource-group', $ResourceGroup, '--name', $Name,
        '--location', $Location, '--size', $Size,
        '--attach-os-disk', $OsDiskId, '--os-type', $OsType,
        '--disk-controller-type', $DiskControllerType,
        '--os-disk-delete-option', 'Detach', '--nic-delete-option', 'Detach',
        '--nics'
    ) + $NicIds
    if ($Zone) {
        $arguments += @('--zone', $Zone)
    }
    elseif ($AvailabilitySetId) {
        $arguments += @('--availability-set', $AvailabilitySetId)
    }
    if ($SecurityType) {
        $arguments += @('--security-type', $SecurityType)
        if ($SecurityType -eq 'TrustedLaunch') {
            $arguments += @('--enable-secure-boot', ([string]$SecureBootEnabled).ToLowerInvariant())
            $arguments += @('--enable-vtpm', ([string]$VTpmEnabled).ToLowerInvariant())
        }
    }
    if ($LicenseType) {
        $arguments += @('--license-type', $LicenseType)
    }
    if ($EncryptionAtHost) {
        $arguments += @('--encryption-at-host', 'true')
    }
    if ($IdentityIds.Count -gt 0) {
        $arguments += @('--assign-identity') + $IdentityIds
    }
    if ($Tags.Count -gt 0) {
        $arguments += @('--tags') + $Tags
    }
    $arguments = @($arguments | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    Invoke-AzCli $arguments | Out-Null
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found. Install it and run az login before using this script.'
}

if ($TargetVmSize -match '_v[67]$' -and -not $ConfirmNvmeReady) {
    throw 'Dsv6/Dsv7 requires a Generation 2 OS image and NVMe-ready guest. Validate both, then rerun with -ConfirmNvmeReady.'
}

if ($TargetDiskControllerType -eq 'Auto') {
    $TargetDiskControllerType = if ($TargetVmSize -match '_v[67]$') { 'NVMe' } else { 'SCSI' }
}

if ($SubscriptionId) {
    Invoke-AzCli @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}
else {
    $SubscriptionId = (Invoke-AzCli @('account', 'show', '--query', 'id', '--output', 'tsv')) -join ''
}

$vm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
$osDisk = Invoke-AzJson @('disk', 'show', '--ids', $vm.storageProfile.osDisk.managedDisk.id, '--output', 'json')
$hyperVGeneration = $osDisk.hyperVGeneration
$originalOsDiskSku = $osDisk.sku.name
Write-Host "Preserving OS disk SKU $originalOsDiskSku." -ForegroundColor Cyan
$currentDiskControllerType = if ($vm.storageProfile.diskControllerType) { $vm.storageProfile.diskControllerType } else { 'SCSI' }
$originalVmSize = $vm.hardwareProfile.vmSize
$originalOsDiskId = $vm.storageProfile.osDisk.managedDisk.id
$nicAttachments = @($vm.networkProfile.networkInterfaces | Sort-Object @{ Expression = { if ($_.primary -or $_.properties.primary) { 0 } else { 1 } } })
$nicIds = @($nicAttachments | ForEach-Object { $_.id })
$vmTags = @($vm.tags.psobject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })
$userAssignedIdentityIds = @($vm.identity.userAssignedIdentities.psobject.Properties | ForEach-Object { $_.Name })
$identityIds = @()
if ($vm.identity.type -match 'SystemAssigned') {
    $identityIds += '[system]'
}
$identityIds += $userAssignedIdentityIds
$powerState = (Invoke-AzCli @(
        'vm', 'get-instance-view', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]", '--output', 'tsv'
    )) -join ''
$wasRunning = $powerState -eq 'PowerState/running'
$availabilitySetId = $vm.availabilitySet.id
if (@($vm.storageProfile.dataDisks).Count -gt 0 -and $TargetDataDiskSku -eq 'PremiumV2_LRS' -and $availabilitySetId) {
    if (-not $MigrateAvailabilitySetToZone) {
        throw "VM '$VmName' belongs to Availability Set '$($availabilitySetId.Split('/')[-1])'. Azure does not support attaching Premium SSD v2 managed disks to VMs in Availability Sets. Rerun with -MigrateAvailabilitySetToZone and -TargetZone to recreate the VM in an availability zone while retaining its NICs."
    }
    if (-not $TargetZone) {
        throw '-TargetZone is required with -MigrateAvailabilitySetToZone.'
    }
    foreach ($nicId in $nicIds) {
        $nic = Invoke-AzJson @('network', 'nic', 'show', '--ids', $nicId, '--output', 'json')
        foreach ($ipConfiguration in @($nic.ipConfigurations)) {
            if ($ipConfiguration.publicIPAddress.id) {
                $publicIp = Invoke-AzJson @(
                    'network', 'public-ip', 'show', '--ids', $ipConfiguration.publicIPAddress.id,
                    '--output', 'json'
                )
                if ($publicIp.publicIPAllocationMethod -ne 'Static') {
                    throw "Public IP '$($publicIp.name)' uses dynamic allocation and is not guaranteed to retain its address during VM recreation. Change it to static before using -MigrateAvailabilitySetToZone."
                }
            }
        }
    }
    $vmExtensions = @(Invoke-AzJson @(
            'vm', 'extension', 'list', '--resource-group', $ResourceGroupName,
            '--vm-name', $VmName, '--output', 'json'
        ))
    if ($vmExtensions.Count -gt 0) {
        Write-Warning "VM extensions are VM child resources and cannot be retained during recreation. Reinstall after migration: $(@($vmExtensions.name) -join ', ')."
    }
    Write-Warning "VM '$VmName' will be deleted and recreated in availability zone $TargetZone. Its NIC resources and IP configuration will be retained, but VM extensions are removed and a system-assigned identity receives a new principal ID."
}
elseif ($MigrateAvailabilitySetToZone) {
    throw '-MigrateAvailabilitySetToZone can be used only when the source VM belongs to an Availability Set and has data disks to migrate.'
}
if (@($vm.storageProfile.dataDisks).Count -gt 0 -and $TargetDataDiskSku -eq 'PremiumV2_LRS') {
    $targetDiskSku = @(Invoke-AzJson @(
            'vm', 'list-skus', '--location', $vm.location, '--resource-type', 'disks', '--all', '--output', 'json'
        ) | Where-Object { $_.name -eq $TargetDataDiskSku }) | Select-Object -First 1
    $targetDiskZones = @($targetDiskSku.locationInfo.zones | Where-Object { $_ })
    $effectiveZone = if ($MigrateAvailabilitySetToZone) { $TargetZone } else { @($vm.zones | Where-Object { $_ })[0] }
    if ($effectiveZone -and $targetDiskZones.Count -gt 0 -and $targetDiskZones -notcontains $effectiveZone) {
        throw "Premium SSD v2 is not available in zone '$effectiveZone' of region '$($vm.location)'. Supported zones: $($targetDiskZones -join ', ')."
    }
    if (-not $effectiveZone -and $targetDiskZones.Count -gt 0) {
        throw "Premium SSD v2 data disks in region '$($vm.location)' require a zonal VM, but VM '$VmName' is non-zonal. A VM cannot be moved into an availability zone in place. Create a zonal replacement VM or choose a region that supports regional Premium SSD v2."
    }
}

if ($hyperVGeneration -eq 'V1' -and $TargetDiskControllerType -eq 'NVMe') {
    if (-not $UpgradeGen1ToTrustedLaunch) {
        throw "VM '$VmName' is Generation 1. Rerun with -UpgradeGen1ToTrustedLaunch to perform the supported Windows Gen1-to-Gen2 Trusted Launch upgrade."
    }
    if ($vm.storageProfile.osDisk.osType -ne 'Windows') {
        throw 'This script only automates the Windows Gen1-to-Gen2 Trusted Launch upgrade.'
    }
    if (-not $wasRunning) {
        throw 'The Windows Gen1-to-Gen2 upgrade requires the VM to be running with a ready Azure VM Agent.'
    }

    $osSnapshotName = Get-ArtifactName -SourceName $vm.storageProfile.osDisk.name -Suffix $Gen1OsSnapshotSuffix
    $osSnapshotExists = ((Invoke-AzCli @(
                'snapshot', 'list', '--resource-group', $ResourceGroupName,
                '--query', "[?name=='$osSnapshotName'].name | [0]", '--output', 'tsv'
            )) -join '') -eq $osSnapshotName
    if ($osSnapshotExists -and -not $ReuseExistingArtifacts) {
        throw "Pre-conversion OS snapshot '$osSnapshotName' already exists. Remove it or rerun with -ReuseExistingArtifacts."
    }

    Write-Host "Deallocating $VmName to create the Gen1 recovery snapshot..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
    Invoke-AzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
    ) | Out-Null
    if (-not $osSnapshotExists) {
        Write-Host "Creating Gen1 OS recovery snapshot $osSnapshotName..." -ForegroundColor Cyan
        Invoke-AzCli @(
            'snapshot', 'create', '--resource-group', $ResourceGroupName,
            '--name', $osSnapshotName, '--source', $vm.storageProfile.osDisk.managedDisk.id,
            '--location', $vm.location, '--incremental', 'true'
        ) | Out-Null
    }

    Write-Host "Starting $VmName for Windows MBR-to-GPT conversion..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
    $mbr2GptScript = @'
& "$env:SystemRoot\System32\mbr2gpt.exe" /validate /disk:0 /allowFullOS
if ($LASTEXITCODE -ne 0) { throw "MBR2GPT validation failed with exit code ${LASTEXITCODE}." }
& "$env:SystemRoot\System32\mbr2gpt.exe" /convert /disk:0 /allowFullOS
if ($LASTEXITCODE -ne 0) { throw "MBR2GPT conversion failed with exit code ${LASTEXITCODE}." }
Write-Output 'GEN2_OS_CONVERSION_COMPLETE'
'@
    Write-Host 'Validating and converting the Windows OS disk from MBR to GPT...' -ForegroundColor Cyan
    $mbr2GptScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) 'convert-windows-os-to-gpt.ps1'
    Set-Content -LiteralPath $mbr2GptScriptPath -Value $mbr2GptScript -Encoding utf8
    try {
        $scriptArgument = "@$mbr2GptScriptPath"
        $mbr2GptResult = Invoke-AzJson @(
            'vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
            '--name', $VmName, '--command-id', 'RunPowerShellScript',
            '--scripts', $scriptArgument, '--output', 'json'
        )
    }
    finally {
        Remove-Item -LiteralPath $mbr2GptScriptPath -Force -ErrorAction SilentlyContinue
    }
    $mbr2GptOutput = @($mbr2GptResult.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
    if ($mbr2GptOutput -notmatch 'GEN2_OS_CONVERSION_COMPLETE' -or $mbr2GptOutput -match '\[ERROR\]|MBR2GPT validation failed|MBR2GPT conversion failed') {
        throw "Windows MBR-to-GPT conversion did not report success. The VM remains Generation 1; use snapshot '$osSnapshotName' for recovery if needed:`n$mbr2GptOutput"
    }

    Write-Host "Deallocating $VmName to enable Trusted Launch..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
    Invoke-AzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
    ) | Out-Null
    Invoke-AzCli @(
        'vm', 'update', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--security-type', 'TrustedLaunch', '--enable-secure-boot', 'true', '--enable-vtpm', 'true'
    ) | Out-Null

    Write-Host "Starting $VmName to verify the Generation 2 conversion..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
    $vm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
    $hyperVGeneration = ((Invoke-AzCli @(
                'disk', 'show', '--ids', $vm.storageProfile.osDisk.managedDisk.id,
                '--query', 'hyperVGeneration', '--output', 'tsv'
            )) -join '').Trim()
    if ($hyperVGeneration -ne 'V2') {
        throw "Trusted Launch update completed, but Azure reports Hyper-V generation '$hyperVGeneration' instead of 'V2'. Do not continue with the NVMe resize."
    }
    Write-Host "VM is now Generation 2 with Trusted Launch. Recovery snapshot: $osSnapshotName" -ForegroundColor Green
}
elseif ($UpgradeGen1ToTrustedLaunch -and $hyperVGeneration -ne 'V1') {
    Write-Host "Skipping Gen1 conversion; Azure reports Hyper-V generation '$hyperVGeneration'." -ForegroundColor Yellow
}

if ($MigrateAvailabilitySetToZone) {
    $targetVmSku = @(Invoke-AzJson @(
            'vm', 'list-skus', '--location', $vm.location,
            '--resource-type', 'virtualMachines', '--all', '--output', 'json'
        ) | Where-Object { $_.name -eq $TargetVmSize }) | Select-Object -First 1
    if (-not $targetVmSku) {
        throw "VM size '$TargetVmSize' was not found in region '$($vm.location)'."
    }
    $targetVmZones = @($targetVmSku.locationInfo.zones | Where-Object { $_ })
    if ($targetVmZones.Count -gt 0 -and $targetVmZones -notcontains $TargetZone) {
        throw "VM size '$TargetVmSize' is not available in zone '$TargetZone' of region '$($vm.location)'. Supported zones: $($targetVmZones -join ', ')."
    }
    $locationRestrictions = @($targetVmSku.restrictions | Where-Object { $_.type -eq 'Location' })
    if ($locationRestrictions.Count -gt 0) {
        throw "VM size '$TargetVmSize' is restricted for this subscription in region '$($vm.location)'."
    }
    $restrictedZones = @(
        $targetVmSku.restrictions |
            Where-Object { $_.type -eq 'Zone' } |
            ForEach-Object { $_.restrictionInfo.zones } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    if ($restrictedZones -contains $TargetZone) {
        throw "VM size '$TargetVmSize' is restricted for this subscription in zone '$TargetZone' of region '$($vm.location)'."
    }
    $maximumNics = [int](($targetVmSku.capabilities | Where-Object { $_.name -eq 'MaxNetworkInterfaces' }).value)
    if ($maximumNics -gt 0 -and $nicIds.Count -gt $maximumNics) {
        throw "VM size '$TargetVmSize' supports $maximumNics NIC(s), but VM '$VmName' has $($nicIds.Count)."
    }
}
else {
    $resizeOptions = @((Invoke-AzCli @(
                'vm', 'list-vm-resize-options', '--resource-group', $ResourceGroupName, '--name', $VmName,
                '--query', "[?name=='$TargetVmSize'].name", '--output', 'tsv'
            )) | Where-Object { $_ })
    if ($resizeOptions -notcontains $TargetVmSize) {
        Write-Warning "VM size '$TargetVmSize' is not available on the VM's current cluster. The script will deallocate the VM and let Azure attempt placement on compatible regional hardware."
    }
}

$diskMigrations = @()
foreach ($attachment in @($vm.storageProfile.dataDisks | Sort-Object lun)) {
    $sourceDisk = Invoke-AzJson @(
        'disk', 'show', '--resource-group', $ResourceGroupName, '--name', $attachment.name, '--output', 'json'
    )
    if ($sourceDisk.managedBy -ne $vm.id) {
        throw "Disk '$($attachment.name)' is not exclusively managed by VM '$VmName'. Shared disks are not supported by this script."
    }
    if ($sourceDisk.location -ne $vm.location) {
        throw "Disk '$($attachment.name)' is not in the VM region '$($vm.location)'."
    }
    if ($sourceDisk.sku.name -eq $TargetDataDiskSku) {
        Write-Host "Skipping $($attachment.name); it already uses $TargetDataDiskSku." -ForegroundColor Yellow
        continue
    }

    $diskMigrations += [pscustomobject]@{
        Source         = $sourceDisk
        Lun            = [int]$attachment.lun
        OriginalCache  = if ($attachment.caching) { $attachment.caching } else { 'None' }
        SnapshotName   = Get-ArtifactName -SourceName $attachment.name -Suffix $SnapshotSuffix
        TargetDiskName = Get-ArtifactName -SourceName $attachment.name -Suffix $TargetDiskSuffix
    }
}

Write-Host "Discovered $(@($vm.storageProfile.dataDisks).Count) data disk(s); $($diskMigrations.Count) require migration." -ForegroundColor Cyan
foreach ($migration in $diskMigrations) {
    Write-Host "  LUN $($migration.Lun): $($migration.Source.name) -> $($migration.TargetDiskName)"
}

if ($TargetDiskControllerType -eq 'NVMe' -and $currentDiskControllerType -ne 'NVMe') {
    if ($vm.storageProfile.osDisk.osType -ne 'Windows') {
        throw 'Automatic NVMe guest preparation currently supports Windows only. Prepare and verify the guest independently before conversion.'
    }
    if (-not $PrepareWindowsForNvme) {
        throw 'Windows SCSI-to-NVMe conversion requires Microsoft guest preparation. Rerun with -PrepareWindowsForNvme after reviewing the official preparation script URL.'
    }
    if (-not $wasRunning) {
        throw 'Windows NVMe preparation requires the VM to be running with a ready Azure VM Agent.'
    }

    $preparationScriptPath = Join-Path ([System.IO.Path]::GetTempPath()) 'windows-manual-nvme-prepare.ps1'
    Write-Host 'Downloading Microsoft Windows NVMe preparation script...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri $WindowsNvmePreparationScriptUrl -OutFile $preparationScriptPath -UseBasicParsing
    try {
        $scriptArgument = "@$preparationScriptPath"
        $preparationResult = Invoke-AzJson @(
            'vm', 'run-command', 'invoke', '--resource-group', $ResourceGroupName,
            '--name', $VmName, '--command-id', 'RunPowerShellScript',
            '--scripts', $scriptArgument, '--output', 'json'
        )
        $preparationOutput = @($preparationResult.value | ForEach-Object { $_.message }) -join [Environment]::NewLine
        if ($preparationOutput -notmatch 'All checks passed across ALL ControlSets' -or $preparationOutput -match '\[ERROR\]|FATAL:') {
            throw "Windows NVMe preparation did not report success:`n$preparationOutput"
        }
        Write-Host 'Windows guest is prepared for NVMe conversion.' -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $preparationScriptPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Stopping and deallocating $VmName..." -ForegroundColor Cyan
Invoke-AzCli @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--no-wait') | Out-Null
Invoke-AzCli @(
    'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName,
    '--custom', "instanceView.statuses[?code=='PowerState/deallocated']"
) | Out-Null

foreach ($migration in $diskMigrations) {
    $snapshotExists = ((Invoke-AzCli @(
                'snapshot', 'list', '--resource-group', $ResourceGroupName,
                '--query', "[?name=='$($migration.SnapshotName)'].name | [0]", '--output', 'tsv'
            )) -join '') -eq $migration.SnapshotName
    if ($snapshotExists -and -not $ReuseExistingArtifacts) {
        throw "Snapshot '$($migration.SnapshotName)' already exists. Remove it or rerun with -ReuseExistingArtifacts."
    }
    if (-not $snapshotExists) {
        Write-Host "Creating incremental snapshot $($migration.SnapshotName)..." -ForegroundColor Cyan
        Invoke-AzCli @(
            'snapshot', 'create', '--resource-group', $ResourceGroupName,
            '--name', $migration.SnapshotName, '--source', $migration.Source.id,
            '--location', $migration.Source.location, '--incremental', 'true'
        ) | Out-Null
    }

    $targetDiskExists = ((Invoke-AzCli @(
                'disk', 'list', '--resource-group', $ResourceGroupName,
                '--query', "[?name=='$($migration.TargetDiskName)'].name | [0]", '--output', 'tsv'
            )) -join '') -eq $migration.TargetDiskName
    if ($targetDiskExists -and -not $ReuseExistingArtifacts) {
        throw "Disk '$($migration.TargetDiskName)' already exists. Remove it or rerun with -ReuseExistingArtifacts."
    }
    if (-not $targetDiskExists) {
        Write-Host "Creating $TargetDataDiskSku disk $($migration.TargetDiskName)..." -ForegroundColor Cyan
        $createArguments = @(
            'disk', 'create', '--resource-group', $ResourceGroupName,
            '--name', $migration.TargetDiskName, '--source', $migration.SnapshotName,
            '--location', $migration.Source.location, '--sku', $TargetDataDiskSku,
            '--logical-sector-size', '512', '--size-gb', ([string]$migration.Source.diskSizeGb),
            '--disk-iops-read-write', ([string]$DiskIops),
            '--disk-mbps-read-write', ([string]$DiskThroughputMBps)
        )
        $replacementZone = if ($MigrateAvailabilitySetToZone) {
            $TargetZone
        }
        else {
            @($migration.Source.zones | Where-Object { $_ })[0]
        }
        if ($replacementZone) {
            $createArguments += @('--zone', [string]$replacementZone)
        }
        Invoke-AzCli $createArguments | Out-Null
    }
}

$zonalOsDiskId = $null
if ($MigrateAvailabilitySetToZone) {
    $zonalOsSnapshotName = Get-ArtifactName -SourceName $vm.storageProfile.osDisk.name -Suffix $ZonalOsSnapshotSuffix
    $zonalOsDiskName = Get-ArtifactName -SourceName $vm.storageProfile.osDisk.name -Suffix $ZonalOsDiskSuffix
    $zonalOsSnapshotExists = ((Invoke-AzCli @(
                'snapshot', 'list', '--resource-group', $ResourceGroupName,
                '--query', "[?name=='$zonalOsSnapshotName'].name | [0]", '--output', 'tsv'
            )) -join '') -eq $zonalOsSnapshotName
    if ($zonalOsSnapshotExists -and -not $ReuseExistingArtifacts) {
        throw "Zonal migration OS snapshot '$zonalOsSnapshotName' already exists. Remove it or rerun with -ReuseExistingArtifacts."
    }
    if (-not $zonalOsSnapshotExists) {
        Write-Host "Creating post-conversion OS snapshot $zonalOsSnapshotName..." -ForegroundColor Cyan
        Invoke-AzCli @(
            'snapshot', 'create', '--resource-group', $ResourceGroupName,
            '--name', $zonalOsSnapshotName, '--source', $vm.storageProfile.osDisk.managedDisk.id,
            '--location', $vm.location, '--incremental', 'true'
        ) | Out-Null
    }

    $zonalOsDisk = @(Invoke-AzJson @(
            'disk', 'list', '--resource-group', $ResourceGroupName, '--output', 'json'
        ) | Where-Object { $_.name -eq $zonalOsDiskName }) | Select-Object -First 1
    if ($zonalOsDisk -and -not $ReuseExistingArtifacts) {
        throw "Zonal OS disk '$zonalOsDiskName' already exists. Remove it or rerun with -ReuseExistingArtifacts."
    }
    if (-not $zonalOsDisk) {
        Write-Host "Creating zonal OS disk $zonalOsDiskName in zone $TargetZone..." -ForegroundColor Cyan
        $zonalOsDisk = Invoke-AzJson @(
            'disk', 'create', '--resource-group', $ResourceGroupName,
            '--name', $zonalOsDiskName, '--source', $zonalOsSnapshotName,
            '--location', $vm.location, '--zone', $TargetZone,
            '--sku', $originalOsDiskSku, '--output', 'json'
        )
    }
    $zonalOsDiskId = $zonalOsDisk.id
}

$detachedSources = [System.Collections.Generic.List[object]]::new()
$attachedTargets = [System.Collections.Generic.List[object]]::new()
$sourceVmDeleted = $false
try {
    if ($TargetDiskControllerType -eq 'NVMe' -and $currentDiskControllerType -ne 'NVMe') {
        Write-Host 'Enabling SCSI and NVMe support on the OS disk...' -ForegroundColor Cyan
        Invoke-AzCli @(
            'disk', 'update', '--resource-group', $ResourceGroupName,
            '--name', $(if ($MigrateAvailabilitySetToZone) { $zonalOsDiskName } else { $vm.storageProfile.osDisk.name }),
            '--set', 'supportedCapabilities.diskControllerTypes=SCSI, NVMe'
        ) | Out-Null
    }

    if ($MigrateAvailabilitySetToZone) {
        foreach ($migration in $diskMigrations) {
            Write-Host "Detaching source disk $($migration.Source.name) before VM recreation..." -ForegroundColor Cyan
            Invoke-AzCli @(
                'vm', 'disk', 'detach', '--resource-group', $ResourceGroupName,
                '--vm-name', $VmName, '--name', $migration.Source.name
            ) | Out-Null
            $detachedSources.Add($migration)
        }

        $detachProperties = @('storageProfile.osDisk.deleteOption=Detach')
        for ($index = 0; $index -lt $nicIds.Count; $index++) {
            $detachProperties += "networkProfile.networkInterfaces[$index].deleteOption=Detach"
        }
        Invoke-AzCli (@(
                'vm', 'update', '--resource-group', $ResourceGroupName,
                '--name', $VmName, '--set'
            ) + $detachProperties) | Out-Null

        Write-Host "Deleting the Availability Set VM resource while retaining disks and NICs..." -ForegroundColor Cyan
        Invoke-AzCli @('vm', 'delete', '--resource-group', $ResourceGroupName, '--name', $VmName, '--yes') | Out-Null
        $sourceVmDeleted = $true

        $securityType = $vm.securityProfile.securityType
        Write-Host "Recreating $VmName in zone $TargetZone with the existing NIC(s)..." -ForegroundColor Cyan
        New-SpecializedVm `
            -ResourceGroup $ResourceGroupName `
            -Name $VmName `
            -Location $vm.location `
            -Size $TargetVmSize `
            -OsDiskId $zonalOsDiskId `
            -OsType $vm.storageProfile.osDisk.osType `
            -NicIds $nicIds `
            -DiskControllerType $TargetDiskControllerType `
            -Zone $TargetZone `
            -SecurityType $securityType `
            -SecureBootEnabled ([bool]$vm.securityProfile.uefiSettings.secureBootEnabled) `
            -VTpmEnabled ([bool]$vm.securityProfile.uefiSettings.vTpmEnabled) `
            -LicenseType $vm.licenseType `
            -EncryptionAtHost ([bool]$vm.securityProfile.encryptionAtHost) `
            -IdentityIds $identityIds `
            -Tags $vmTags
        $vm = Invoke-AzJson @('vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--output', 'json')
    }
    else {
        Write-Host "Changing $VmName to $TargetVmSize with $TargetDiskControllerType disk controller..." -ForegroundColor Cyan
        Invoke-AzCli @(
            'vm', 'update', '--resource-group', $ResourceGroupName, '--name', $VmName,
            '--size', $TargetVmSize, '--disk-controller-type', $TargetDiskControllerType
        ) | Out-Null

        foreach ($migration in $diskMigrations) {
            Write-Host "Replacing LUN $($migration.Lun): $($migration.Source.name)..." -ForegroundColor Cyan
            Invoke-AzCli @(
                'vm', 'disk', 'detach', '--resource-group', $ResourceGroupName,
                '--vm-name', $VmName, '--name', $migration.Source.name
            ) | Out-Null
            $detachedSources.Add($migration)
        }
    }

    foreach ($migration in $diskMigrations) {
        Write-Host "Attaching replacement disk $($migration.TargetDiskName) at LUN $($migration.Lun)..." -ForegroundColor Cyan
        Invoke-AzCli @(
            'vm', 'disk', 'attach', '--resource-group', $ResourceGroupName,
            '--vm-name', $VmName, '--name', $migration.TargetDiskName,
            '--lun', ([string]$migration.Lun), '--caching', 'None'
        ) | Out-Null
        $attachedTargets.Add($migration)
    }
}
catch {
    Write-Warning 'Migration failed. Attempting to restore the original data-disk attachments.'
    foreach ($migration in $attachedTargets) {
        & az vm disk detach --resource-group $ResourceGroupName --vm-name $VmName --name $migration.TargetDiskName | Out-Null
    }
    if ($MigrateAvailabilitySetToZone -and $sourceVmDeleted) {
        $replacementVmId = (& az vm show --resource-group $ResourceGroupName --name $VmName --query id --output tsv 2>$null) -join ''
        if ($replacementVmId) {
            & az vm delete --resource-group $ResourceGroupName --name $VmName --yes | Out-Null
        }
        Write-Warning "Attempting to recreate $VmName in its original Availability Set. Extensions and the original system-assigned identity cannot be restored automatically."
        New-SpecializedVm `
            -ResourceGroup $ResourceGroupName `
            -Name $VmName `
            -Location $vm.location `
            -Size $originalVmSize `
            -OsDiskId $originalOsDiskId `
            -OsType $vm.storageProfile.osDisk.osType `
            -NicIds $nicIds `
            -DiskControllerType $currentDiskControllerType `
            -AvailabilitySetId $availabilitySetId `
            -SecurityType $vm.securityProfile.securityType `
            -SecureBootEnabled ([bool]$vm.securityProfile.uefiSettings.secureBootEnabled) `
            -VTpmEnabled ([bool]$vm.securityProfile.uefiSettings.vTpmEnabled) `
            -LicenseType $vm.licenseType `
            -EncryptionAtHost ([bool]$vm.securityProfile.encryptionAtHost) `
            -IdentityIds $identityIds `
            -Tags $vmTags
    }
    foreach ($migration in $detachedSources) {
        & az vm disk attach `
            --resource-group $ResourceGroupName `
            --vm-name $VmName `
            --name $migration.Source.name `
            --lun $migration.Lun `
            --caching $migration.OriginalCache | Out-Null
    }
    if ($MigrateAvailabilitySetToZone -and $sourceVmDeleted -and $wasRunning) {
        & az vm start --resource-group $ResourceGroupName --name $VmName | Out-Null
    }
    throw
}

if ($wasRunning -and -not $KeepStopped) {
    Write-Host "Starting $VmName..." -ForegroundColor Cyan
    Invoke-AzCli @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName) | Out-Null
}

$finalOsDiskSku = ((Invoke-AzCli @(
            'disk', 'show', '--ids', $vm.storageProfile.osDisk.managedDisk.id,
            '--query', 'sku.name', '--output', 'tsv'
        )) -join '').Trim()
if ($finalOsDiskSku -ne $originalOsDiskSku) {
    throw "OS disk SKU changed unexpectedly from '$originalOsDiskSku' to '$finalOsDiskSku'. The script only migrates data disks."
}

$result = Invoke-AzJson @(
    'vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName,
    '--query', '{vmSize:hardwareProfile.vmSize,zones:zones,nics:networkProfile.networkInterfaces[].id,osDisk:storageProfile.osDisk.managedDisk.storageAccountType,dataDisks:storageProfile.dataDisks[].{name:name,lun:lun,caching:caching,sku:managedDisk.storageAccountType}}',
    '--output', 'json'
)
$result | ConvertTo-Json -Depth 5
Write-Host "Migration complete. OS disk SKU remains $finalOsDiskSku. Retain the source disks and snapshots until application validation is complete." -ForegroundColor Green