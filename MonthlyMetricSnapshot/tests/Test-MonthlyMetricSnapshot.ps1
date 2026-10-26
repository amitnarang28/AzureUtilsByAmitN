#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$snapshotScript = Join-Path $PSScriptRoot '..\monthlymetricsnapshot.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "MonitorSnapshotTests-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($testRoot)
$fixture = @{
    Subscription = [guid]::NewGuid()
    Tenant       = [guid]::NewGuid()
    Workspace    = [guid]::NewGuid()
    Start        = [datetimeoffset]([datetime]::UtcNow.Date.AddDays(-1))
}
$fixture.End = $fixture.Start.AddHours(1)
$fixture.Resource = "/subscriptions/$($fixture.Subscription)/resourceGroups/synthetic-group/providers/Microsoft.DocumentDB/databaseAccounts/synthetic-account"
$testState = @{
    Passed   = 0
    Requests = [System.Collections.Generic.List[object]]::new()
}

# These local stubs prevent authentication, module loading, and network access.
function Import-Module {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -ne 'Az.Accounts') {
        throw "Unexpected module import in offline test: $Name"
    }
}

function Get-AzContext {
    [CmdletBinding()]
    param()
    return $testState.Context
}

function Invoke-AzRestMethod {
    [CmdletBinding()]
    param([uri]$Uri, [string]$Method, $DefaultProfile, [uri]$ResourceId, [string]$Payload)

    $testState.Requests.Add(@{
        Uri = $Uri; Method = $Method; Context = $DefaultProfile
        Audience = $ResourceId; Payload = $Payload
    })
    if ($testState.RequestFailure) {
        throw $testState.RequestFailure
    }
    if ($testState.CreateDestinationDuringRequest) {
        Set-Content -LiteralPath $testState.Output -Value 'concurrent writer' -NoNewline
    }
    return $testState.Response
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = 'Values differ')
    if ($Actual -cne $Expected) {
        throw "$Message. Expected '$Expected'; got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern)
    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Expected error matching '$MessagePattern'; got '$($_.Exception.Message)'."
        }
    }
    Assert-True $threw "Expected a terminating error matching '$MessagePattern'."
}

function Set-TestResponse {
    param([hashtable]$Body, [int]$StatusCode = 200)
    $testState.Body = $Body
    $testState.Response = [pscustomobject]@{
        StatusCode = $StatusCode
        Content    = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
    }
}

function Set-MetricResponse {
    Set-TestResponse @{
        interval = 'PT1M'
        value = @(@{
            name = @{ value = 'SyntheticRequests' }
            unit = 'Count'
            errorCode = 'Success'
            timeseries = @(@{
                metadatavalues = @(@{ name = @{ value = 'Region' }; value = 'Synthetic Region' })
                data = @(
                    @{ timeStamp = $fixture.Start.ToString('o'); total = 0; average = 0 }
                    @{ timeStamp = $fixture.Start.AddMinutes(1).ToString('o'); average = 1.25 }
                )
            })
        })
    }
}

function Invoke-TestExport {
    param([switch]$Metrics, [hashtable]$Arguments = @{})
    $parameters = @{
        SubscriptionId = $fixture.Subscription
        TenantId       = $fixture.Tenant
        StartTime      = $fixture.Start
        EndTime        = $fixture.End
        OutputPath     = $testState.Output
    }
    if ($Metrics) {
        $parameters.ResourceId = $fixture.Resource
        $parameters.MetricNames = @('SyntheticRequests')
        $parameters.Aggregation = @('Total', 'Average')
        $parameters.TimeGrain = 'PT1M'
    }
    else {
        $parameters.WorkspaceId = $fixture.Workspace
        $parameters.Query = 'print Count = 3'
    }
    foreach ($key in $Arguments.Keys) {
        $parameters[$key] = $Arguments[$key]
    }
    if ($parameters.ContainsKey('QueryPath')) {
        $parameters.Remove('Query')
    }
    & $snapshotScript @parameters
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Action)
    $testState.Requests.Clear()
    $testState.RequestFailure = $null
    $testState.CreateDestinationDuringRequest = $false
    $testState.Output = Join-Path $testRoot "case-$($testState.Passed).csv"
    $testState.Context = [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'synthetic-account' }
        Subscription = [pscustomobject]@{ Id = $fixture.Subscription.ToString() }
        Tenant       = [pscustomobject]@{ Id = $fixture.Tenant.ToString() }
        Environment  = [pscustomobject]@{
            Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/'
        }
    }
    Set-TestResponse @{
        tables = @(@{
            name = 'PrimaryResult'
            columns = @(@{ name = 'Count'; type = 'long' })
            rows = ,@(3)
        })
    }
    try {
        & $Action
        $testState.Passed++
        Write-Output "PASS: $Name"
    }
    catch {
        throw "FAIL: $Name`n$($_.Exception.Message)"
    }
}

try {
    Invoke-TestCase 'Inline KQL preserves a single-column result and request context' {
        $result = Invoke-TestExport
        Assert-Equal 1 $result.RowCount
        Assert-Equal '3' (Import-Csv -LiteralPath $testState.Output).Count
        Assert-Equal 1 $testState.Requests.Count
        $request = $testState.Requests[0]
        Assert-Equal 'POST' $request.Method
        Assert-True ([object]::ReferenceEquals($testState.Context, $request.Context)) 'The selected context was not passed to the request.'
        Assert-True ($request.Uri.AbsolutePath -eq "/v1/workspaces/$($fixture.Workspace)/query") 'Workspace query URL differs.'
        $payload = $request.Payload | ConvertFrom-Json
        Assert-Equal 'print Count = 3' $payload.query
        Assert-Equal "$($fixture.Start.UtcDateTime.ToString('o'))/$($fixture.End.UtcDateTime.ToString('o'))" $payload.timespan
    }

    Invoke-TestCase 'CSV preserves schema, escaping, dynamic values, nulls, and invariant decimals' {
        $testState.Body.tables[0].columns = @(
            @{ name = 'Name'; type = 'string' }, @{ name = 'Total'; type = 'long' }
            @{ name = 'Average'; type = 'real' }, @{ name = 'Details'; type = 'dynamic' }
            @{ name = 'Missing'; type = 'string' }, @{ name = 'At'; type = 'datetime' }
        )
        $label = "comma, quote `"value`"`nnext line"
        $testState.Body.tables[0].rows = ,@(
            $label, 0, 12.5, @{ items = @('a', 'b') }, $null, $fixture.Start.ToString('o')
        )
        Set-TestResponse $testState.Body
        $previousCulture = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('fr-FR')
            $null = Invoke-TestExport
        }
        finally {
            [cultureinfo]::CurrentCulture = $previousCulture
        }
        $row = Import-Csv -LiteralPath $testState.Output
        Assert-Equal 'Name,Total,Average,Details,Missing,At' ($row.PSObject.Properties.Name -join ',')
        Assert-Equal $label $row.Name
        Assert-Equal '0' $row.Total
        Assert-Equal '12.5' $row.Average
        Assert-Equal '{"items":["a","b"]}' $row.Details
        Assert-Equal '' $row.Missing
        Assert-Equal $fixture.Start.UtcDateTime.ToString('o') $row.At
    }

    Invoke-TestCase 'Query files and output paths use literal rather than wildcard paths' {
        $queryFile = Join-Path $testRoot 'query [sample].local.kql'
        $text = "print Count = 3`n"
        Set-Content -LiteralPath $queryFile -Value $text -NoNewline -Encoding utf8
        $testState.Output = Join-Path $testRoot 'result [sample].csv'
        $null = Invoke-TestExport -Arguments @{ QueryPath = $queryFile }
        Assert-Equal $text ($testState.Requests[0].Payload | ConvertFrom-Json).query
        Assert-True (Test-Path -LiteralPath $testState.Output) 'Literal output file is missing.'
    }

    Invoke-TestCase 'Empty KQL produces a warning and a header-only CSV' {
        $testState.Body.tables[0].rows = @()
        Set-TestResponse $testState.Body
        $messages = @(Invoke-TestExport 3>&1)
        Assert-Equal 1 @($messages | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
        Assert-Equal 1 @(Get-Content -LiteralPath $testState.Output).Count
        Assert-Equal '"Count"' (Get-Content -LiteralPath $testState.Output)
        Assert-Equal 0 @((Import-Csv -LiteralPath $testState.Output)).Count
    }

    Invoke-TestCase 'Partial KQL fails without replacing an existing export' {
        Set-Content -LiteralPath $testState.Output -Value 'previous export' -NoNewline
        $testState.Body.error = @{ code = 'PartialError'; message = 'Synthetic query limit' }
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Arguments @{ Force = $true } } 'partial result'
        Assert-Equal 'previous export' (Get-Content -LiteralPath $testState.Output -Raw)
    }

    Invoke-TestCase 'HTTP and transport failures are terminating and publish no file' {
        Set-TestResponse @{ error = @{ code = 'Forbidden' } } -StatusCode 403
        Assert-Throws { Invoke-TestExport } 'HTTP 403'
        $testState.RequestFailure = 'Synthetic transport failure'
        Assert-Throws { Invoke-TestExport } 'Synthetic transport failure'
        Assert-True (-not (Test-Path -LiteralPath $testState.Output)) 'A failed request published a CSV.'
    }

    Invoke-TestCase 'Invalid time windows fail before any request' {
        Assert-Throws { Invoke-TestExport -Arguments @{ EndTime = $fixture.Start } } 'earlier than'
        Assert-Equal 0 $testState.Requests.Count
    }

    Invoke-TestCase 'Offset timestamps are sent and reported as exact UTC instants' {
        $start = $fixture.Start.ToOffset([timespan]::FromHours(2))
        $result = Invoke-TestExport -Arguments @{ StartTime = $start }
        Assert-Equal $fixture.Start.UtcDateTime.ToString('o') $result.SnapshotStartUtc
    }

    Invoke-TestCase 'Missing or mismatched Azure contexts fail before any request' {
        $testState.Context = $null
        Assert-Throws { Invoke-TestExport } 'No authenticated Azure context'
        $testState.Context = [pscustomobject]@{
            Account = 'synthetic'; Subscription = @{ Id = [guid]::NewGuid().ToString() }
        }
        Assert-Throws { Invoke-TestExport } 'does not match SubscriptionId'
        $testState.Context.Subscription.Id = $fixture.Subscription.ToString()
        $testState.Context | Add-Member Tenant @{ Id = [guid]::NewGuid().ToString() }
        Assert-Throws { Invoke-TestExport } 'does not match TenantId'
        Assert-Equal 0 $testState.Requests.Count
    }

    Invoke-TestCase 'Existing outputs require explicit Force' {
        Set-Content -LiteralPath $testState.Output -Value 'previous export' -NoNewline
        Assert-Throws { Invoke-TestExport } 'already exists'
        Assert-Equal 0 $testState.Requests.Count
        $null = Invoke-TestExport -Arguments @{ Force = $true }
        Assert-Equal '3' (Import-Csv -LiteralPath $testState.Output).Count
    }

    Invoke-TestCase 'A concurrent destination writer is not overwritten and staging is cleaned up' {
        $testState.CreateDestinationDuringRequest = $true
        Assert-Throws { Invoke-TestExport } 'already exists'
        Assert-Equal 'concurrent writer' (Get-Content -LiteralPath $testState.Output -Raw)
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $testRoot -Filter '*.snapshot.tmp' -Force).Count
    }

    Invoke-TestCase 'Blank queries and missing query files fail before any request' {
        Assert-Throws { Invoke-TestExport -Arguments @{ Query = " `n " } } 'empty or whitespace'
        Assert-Throws { Invoke-TestExport -Arguments @{ QueryPath = (Join-Path $testRoot 'missing.kql') } } 'does not exist'
        Assert-Equal 0 $testState.Requests.Count
    }

    Invoke-TestCase 'The query input cannot be used as the CSV destination' {
        Set-Content -LiteralPath $testState.Output -Value 'print Count = 3' -NoNewline
        Assert-Throws { Invoke-TestExport -Arguments @{ QueryPath = $testState.Output; Force = $true } } 'input query file'
        Assert-Equal 0 $testState.Requests.Count
    }

    Invoke-TestCase 'Multiple tables, duplicate columns, and malformed rows are rejected' {
        $originalTable = $testState.Body.tables[0]
        $testState.Body.tables = @($originalTable, $originalTable)
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport } 'exactly one result table'
        $testState.Body.tables = @($originalTable)
        $originalTable.columns = @(@{ name = 'Count' }, @{ name = 'count' })
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport } 'unique ignoring case'
        $originalTable.columns = @(@{ name = 'Count' })
        $originalTable.rows = ,@(1, 2)
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport } 'does not match'
        Assert-True (-not (Test-Path -LiteralPath $testState.Output)) 'A malformed response published a CSV.'
    }

    Invoke-TestCase 'Metrics flatten aggregations, dimensions, zero, and missing values' {
        Set-MetricResponse
        $result = Invoke-TestExport -Metrics -Arguments @{
            MetricFilter = "Region eq 'Synthetic Region'"
            MetricNamespace = 'Microsoft.DocumentDB/databaseAccounts'
        }
        Assert-Equal 'Metrics' $result.Mode
        Assert-Equal 4 $result.RowCount
        $rows = @(Import-Csv -LiteralPath $testState.Output)
        Assert-Equal '0' $rows[0].Value
        Assert-Equal 'Total' $rows[0].Aggregation
        Assert-Equal '' $rows[2].Value
        Assert-Equal '1.25' $rows[3].Value
        Assert-Equal '{"Region":"Synthetic Region"}' $rows[0].Dimensions
        Assert-Equal $fixture.Start.UtcDateTime.ToString('o') $rows[0].TimeStampUtc
        $request = $testState.Requests[0]
        Assert-Equal 'GET' $request.Method
        $queryString = [uri]::UnescapeDataString($request.Uri.Query)
        Assert-True ($queryString.Contains("`$filter=Region eq 'Synthetic Region'")) 'Metric filter was not encoded correctly.'
        Assert-True ($queryString.Contains('AutoAdjustTimegrain=false')) 'Automatic time-grain changes were not disabled.'
        Assert-True ($queryString.Contains('ValidateDimensions=true')) 'Dimension validation was not enabled.'
        Assert-True ($queryString.Contains('aggregation=Total,Average')) 'Requested aggregations were not preserved.'
    }

    Invoke-TestCase 'Empty metrics create a header-only CSV, not a fabricated zero' {
        Set-MetricResponse
        $testState.Body.value[0].timeseries = @()
        Set-TestResponse $testState.Body
        $null = Invoke-TestExport -Metrics -Arguments @{ WarningAction = 'SilentlyContinue' }
        Assert-Equal 1 @(Get-Content -LiteralPath $testState.Output).Count
        Assert-Equal 0 @(Import-Csv -LiteralPath $testState.Output).Count
    }

    Invoke-TestCase 'Metrics use canonical UTC Z instants without query-string plus offsets' {
        Set-MetricResponse
        $result = Invoke-TestExport -Metrics -Arguments @{
            StartTime = $fixture.Start.ToOffset([timespan]::FromHours(-7))
            EndTime = $fixture.End.ToOffset([timespan]::FromHours(-7))
        }
        $queryString = [uri]::UnescapeDataString($testState.Requests[0].Uri.Query)
        $expectedWindow = "$($fixture.Start.UtcDateTime.ToString('o'))/$($fixture.End.UtcDateTime.ToString('o'))"
        Assert-True ($queryString.Contains("timespan=$expectedWindow")) 'Metrics did not receive the exact canonical UTC Z window.'
        Assert-True (-not $queryString.Contains('+')) 'A plus offset can be decoded as a space by the Metrics endpoint.'
        Assert-Equal $fixture.Start.UtcDateTime.ToString('o') $result.SnapshotStartUtc
        Assert-Equal $fixture.End.UtcDateTime.ToString('o') $result.SnapshotEndUtc
    }

    Invoke-TestCase 'Count aggregation exports the API count field rather than a different aggregate' {
        Set-MetricResponse
        $testState.Body.value[0].timeseries[0].data[0].count = 7
        Set-TestResponse $testState.Body
        $result = Invoke-TestExport -Metrics -Arguments @{ Aggregation = @('Count') }
        $rows = @(Import-Csv -LiteralPath $testState.Output)
        Assert-Equal 2 $result.RowCount
        Assert-Equal 'Count' $rows[0].Aggregation
        Assert-Equal '7' $rows[0].Value
        Assert-Equal '' $rows[1].Value
    }

    Invoke-TestCase 'A changed interval or missing requested metric is rejected' {
        Set-MetricResponse
        $testState.Body.interval = 'PT5M'
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'different or missing time grain'
        $testState.Body.interval = 'PT1M'
        $testState.Body.value = @()
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'exactly the requested metrics'
    }

    Invoke-TestCase 'Equivalent ISO durations are accepted without changing the interval' {
        Set-MetricResponse
        $testState.Body.interval = 'PT60S'
        Set-TestResponse $testState.Body
        $result = Invoke-TestExport -Metrics
        Assert-Equal 4 $result.RowCount
        Assert-Equal 'PT60S' @(Import-Csv -LiteralPath $testState.Output)[0].TimeGrain
    }

    Invoke-TestCase 'Per-metric failures and unexpected split-by series are rejected' {
        Set-MetricResponse
        $testState.Body.value[0].errorCode = 'BadRequest'
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'BadRequest'
        $testState.Body.value[0].errorCode = 'Success'
        $series = $testState.Body.value[0].timeseries[0]
        $testState.Body.value[0].timeseries = @($series, $series)
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'single rolled-up series'
    }

    Invoke-TestCase 'Wildcard filters, invalid durations, duplicate names, and wrong subscriptions fail locally' {
        Assert-Throws { Invoke-TestExport -Metrics -Arguments @{ MetricFilter = "Region eq '*'" } } 'Wildcard split-by'
        Assert-Throws { Invoke-TestExport -Metrics -Arguments @{ TimeGrain = 'PT0S' } } 'positive ISO'
        Assert-Throws { Invoke-TestExport -Metrics -Arguments @{ MetricNames = @('a', 'a') } } 'duplicate'
        $otherResource = $fixture.Resource.Replace($fixture.Subscription.ToString(), [guid]::NewGuid().ToString())
        Assert-Throws { Invoke-TestExport -Metrics -Arguments @{ ResourceId = $otherResource } } 'selected subscription'
        Assert-Equal 0 $testState.Requests.Count
    }

    Invoke-TestCase 'Unexpected pagination and non-object JSON responses cannot pass as success' {
        $testState.Body.nextLink = 'https://management.azure.com/synthetic-next-page'
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport } 'paged result'
        $testState.Response.Content = 'null'
        Assert-Throws { Invoke-TestExport } 'invalid response object'
    }

    Invoke-TestCase 'Null result arrays are not mistaken for legitimate empty results' {
        $testState.Body.tables[0].rows = $null
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport } 'valid columns/rows schema'
        Set-MetricResponse
        $testState.Body.value[0].timeseries = $null
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'timeseries array'
        Set-MetricResponse
        $testState.Body.value[0].timeseries[0].data = $null
        Set-TestResponse $testState.Body
        Assert-Throws { Invoke-TestExport -Metrics } 'data array'
        Assert-True (-not (Test-Path -LiteralPath $testState.Output)) 'A malformed empty response published a CSV.'
    }

    Invoke-TestCase 'Non-public clouds require explicit HTTPS Logs endpoints and audience' {
        $testState.Context.Environment.Name = 'AzureUSGovernment'
        Assert-Throws { Invoke-TestExport } 'explicitly supply'
        Assert-Throws {
            Invoke-TestExport -Arguments @{ LogAnalyticsEndpoint = 'http://invalid.example' }
        } 'absolute HTTPS'
        $null = Invoke-TestExport -Arguments @{
            LogAnalyticsEndpoint = 'https://api.loganalytics.us'
            LogAnalyticsAudience = 'https://api.loganalytics.us'
        }
        Assert-Equal 'api.loganalytics.us' $testState.Requests[0].Uri.Host
        Assert-Equal 'api.loganalytics.us' $testState.Requests[0].Audience.Host
    }

    Write-Output "$($testState.Passed) offline tests passed. No Azure calls were made."
}
finally {
    foreach ($file in Get-ChildItem -LiteralPath $testRoot -File -Force) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    [IO.Directory]::Delete($testRoot)
}
