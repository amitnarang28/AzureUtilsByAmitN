$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
$env:AZURE_CORE_DISPLAY_REGION_IDENTIFIED = 'false'

function Invoke-TestAzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Invoke-TestAzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $json = (Invoke-TestAzCli -Arguments $Arguments) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }
    return $json | ConvertFrom-Json
}

function Initialize-TestSubscription {
    param([string]$SubscriptionId)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI was not found. Install it and run az login before executing this integration test.'
    }
    if ($SubscriptionId) {
        Invoke-TestAzCli @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
        return $SubscriptionId
    }
    return ((Invoke-TestAzCli @('account', 'show', '--query', 'id', '--output', 'tsv')) -join '').Trim()
}

function Assert-TestSkuAvailable {
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSize
    )

    $sku = Invoke-TestAzJson @(
        'vm', 'list-skus', '--location', $Location, '--resource-type', 'virtualMachines',
        '--size', $VmSize, '--all', '--query', "[?name=='$VmSize'] | [0]", '--output', 'json'
    )
    if (-not $sku) {
        throw "VM size '$VmSize' was not found in '$Location'. Override -Location or the SKU parameter."
    }
    $locationRestrictions = @($sku.restrictions | Where-Object { $_.type -eq 'Location' })
    if ($locationRestrictions.Count -gt 0) {
        $reasons = @($locationRestrictions.reasonCode | Where-Object { $_ } | Select-Object -Unique)
        throw "VM size '$VmSize' is restricted for this subscription in '$Location': $($reasons -join ', ')."
    }
}

function New-TestPassword {
    $bytes = [byte[]]::new(24)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    $random = [Convert]::ToBase64String($bytes).Replace('/', 'x').Replace('+', 'Y').Replace('=', '9')
    return "Az!9a$random"
}

function New-SkuMigrationTestVm {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$SourceVmSize,
        [string]$WindowsImage = 'MicrosoftWindowsServer:WindowsServer:2022-datacenter:latest'
    )

    $publicIpName = "$VmName-pip"
    $adminPassword = New-TestPassword

    Write-Host "Creating test resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
    Invoke-TestAzCli @('group', 'create', '--name', $ResourceGroupName, '--location', $Location) | Out-Null
    Invoke-TestAzCli @(
        'network', 'public-ip', 'create', '--resource-group', $ResourceGroupName,
        '--name', $publicIpName, '--location', $Location,
        '--sku', 'Standard', '--allocation-method', 'Static'
    ) | Out-Null

    Write-Host "Creating Windows VM '$VmName' with source size '$SourceVmSize'..." -ForegroundColor Cyan
    Invoke-TestAzCli @(
        'vm', 'create', '--resource-group', $ResourceGroupName, '--name', $VmName,
        '--location', $Location, '--size', $SourceVmSize, '--image', $WindowsImage,
        '--admin-username', 'azuretestadmin', '--admin-password', $adminPassword,
        '--public-ip-address', $publicIpName, '--storage-sku', 'StandardSSD_LRS',
        '--assign-identity', '[system]'
    ) | Out-Null
    Invoke-TestAzCli @(
        'vm', 'wait', '--resource-group', $ResourceGroupName, '--name', $VmName, '--created'
    ) | Out-Null

    return Invoke-TestAzJson @(
        'vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--show-details',
        '--query', '{vmId:vmId,principalId:identity.principalId,privateIp:privateIps,publicIp:publicIps,vmSize:hardwareProfile.vmSize}',
        '--output', 'json'
    )
}

function Assert-SkuMigrationResult {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$ExpectedVmSize,
        [Parameter(Mandatory)]$Before
    )

    $after = Invoke-TestAzJson @(
        'vm', 'show', '--resource-group', $ResourceGroupName, '--name', $VmName, '--show-details',
        '--query', '{vmId:vmId,principalId:identity.principalId,privateIp:privateIps,publicIp:publicIps,vmSize:hardwareProfile.vmSize,powerState:powerState}',
        '--output', 'json'
    )
    if ($after.vmSize -ne $ExpectedVmSize) {
        throw "Expected VM size '$ExpectedVmSize', but Azure reports '$($after.vmSize)'."
    }
    if ($after.privateIp -ne $Before.privateIp) {
        throw "Private IP changed from '$($Before.privateIp)' to '$($after.privateIp)'."
    }
    if ($after.publicIp -ne $Before.publicIp) {
        throw "Public IP changed from '$($Before.publicIp)' to '$($after.publicIp)'."
    }
    if ($after.principalId -ne $Before.principalId) {
        throw "System-assigned identity changed from '$($Before.principalId)' to '$($after.principalId)'."
    }
    if ($after.powerState -ne 'VM running') {
        throw "Expected the migrated VM to be running, but Azure reports '$($after.powerState)'."
    }

    Write-Host "Validated size, private IP, public IP, managed identity, and power state for '$VmName'." -ForegroundColor Green
}

function Remove-SkuMigrationTestResourceGroup {
    param([Parameter(Mandatory)][string]$ResourceGroupName)

    $exists = ((Invoke-TestAzCli @('group', 'exists', '--name', $ResourceGroupName)) -join '').Trim()
    if ($exists -eq 'true') {
        Write-Host "Deleting test resource group '$ResourceGroupName'..." -ForegroundColor Cyan
        Invoke-TestAzCli @('group', 'delete', '--name', $ResourceGroupName, '--yes') | Out-Null
        Write-Host "Deleted test resource group '$ResourceGroupName'." -ForegroundColor Green
    }
}
