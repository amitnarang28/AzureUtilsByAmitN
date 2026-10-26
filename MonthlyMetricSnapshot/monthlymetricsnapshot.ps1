#Requires -Version 7.2
<#
.SYNOPSIS
Exports Azure Monitor Logs query results or resource metrics to CSV.
.DESCRIPTION
Uses an existing Az.Accounts sign-in and an explicit UTC-convertible time window.
KQL controls its own aggregation. Metrics mode exports API-provided aggregates
without re-aggregating them. No Azure resources or diagnostic settings are changed.
.LINK
https://learn.microsoft.com/azure/azure-monitor/logs/api/request-format
#>
[CmdletBinding(DefaultParameterSetName = 'KqlText')]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [guid]$TenantId,

    [Parameter(Mandatory)]
    [datetimeoffset]$StartTime,

    [Parameter(Mandatory)]
    [datetimeoffset]$EndTime,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory, ParameterSetName = 'KqlText')]
    [Parameter(Mandatory, ParameterSetName = 'KqlFile')]
    [guid]$WorkspaceId,

    [Parameter(Mandatory, ParameterSetName = 'KqlText')]
    [ValidateNotNullOrEmpty()]
    [string]$Query,

    [Parameter(Mandatory, ParameterSetName = 'KqlFile')]
    [ValidateNotNullOrEmpty()]
    [string]$QueryPath,

    [Parameter(ParameterSetName = 'KqlText')]
    [Parameter(ParameterSetName = 'KqlFile')]
    [uri]$LogAnalyticsEndpoint = 'https://api.loganalytics.azure.com',

    [Parameter(ParameterSetName = 'KqlText')]
    [Parameter(ParameterSetName = 'KqlFile')]
    [uri]$LogAnalyticsAudience = 'https://api.loganalytics.io',

    [Parameter(Mandatory, ParameterSetName = 'Metrics')]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceId,

    [Parameter(Mandatory, ParameterSetName = 'Metrics')]
    [ValidateCount(1, 20)]
    [string[]]$MetricNames,

    [Parameter(Mandatory, ParameterSetName = 'Metrics')]
    [ValidateSet('Average', 'Minimum', 'Maximum', 'Total', 'Count')]
    [string[]]$Aggregation,

    [Parameter(Mandatory, ParameterSetName = 'Metrics')]
    [ValidateNotNullOrEmpty()]
    [string]$TimeGrain,

    [Parameter(ParameterSetName = 'Metrics')]
    [ValidateNotNullOrEmpty()]
    [string]$MetricNamespace,

    [Parameter(ParameterSetName = 'Metrics')]
    [ValidateNotNullOrEmpty()]
    [string]$MetricFilter,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Invoke-SnapshotRequest {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)]$Context,
        [string]$Payload,
        [uri]$Audience
    )

    $request = @{
        Uri            = $Uri
        Method         = $Method
        DefaultProfile = $Context
        ErrorAction    = 'Stop'
    }
    if ($Payload) {
        $request.Payload = $Payload
    }
    if ($Audience) {
        $request.ResourceId = $Audience
    }

    $response = Invoke-AzRestMethod @request
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "Azure Monitor returned HTTP $($response.StatusCode): $($response.Content)"
    }
    $body = ConvertFrom-Json -InputObject $response.Content -AsHashtable -Depth 100
    if ($body -isnot [System.Collections.IDictionary]) {
        throw 'Azure Monitor returned an invalid response object.'
    }
    if ($body.error) {
        $details = ConvertTo-Json -InputObject $body.error -Depth 100 -Compress
        throw "Azure Monitor returned an error or partial result; no CSV was published: $details"
    }
    if ($body.nextLink -or $body.'@odata.nextLink') {
        throw 'Azure Monitor returned a paged result. No CSV was published; narrow the request.'
    }
    return $body
}

function ConvertTo-SnapshotCell {
    param(
        [AllowNull()]$Value,
        [string]$ColumnType
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($ColumnType -eq 'datetime' -or $Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Collections.IList]) {
        return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
    }
    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [cultureinfo]::InvariantCulture)
    }
    return [string]$Value
}

if ($SubscriptionId -eq [guid]::Empty -or
    ($PSBoundParameters.ContainsKey('TenantId') -and $TenantId -eq [guid]::Empty)) {
    throw 'SubscriptionId and an explicitly supplied TenantId must be non-empty GUIDs.'
}
if ($StartTime -ge $EndTime) {
    throw 'StartTime must be earlier than EndTime.'
}

# The Metrics endpoint can decode a +00:00 offset as a space; use canonical UTC Z.
$startUtc = $StartTime.UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture)
$endUtc = $EndTime.UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture)
$timespan = "$startUtc/$endUtc"
$isKql = $PSCmdlet.ParameterSetName -ne 'Metrics'

if ([string]::IsNullOrWhiteSpace($OutputPath) -or [IO.Path]::GetExtension($OutputPath) -ne '.csv') {
    throw 'OutputPath must name a .csv file.'
}
$outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $outputFile -PathType Container) {
    throw 'OutputPath points to a directory, not a CSV file.'
}
if ((Test-Path -LiteralPath $outputFile) -and -not $Force) {
    throw 'OutputPath already exists. Choose another path or explicitly specify -Force.'
}

if ($isKql) {
    if ($WorkspaceId -eq [guid]::Empty) {
        throw 'WorkspaceId must be a non-empty workspace GUID, not a workspace resource ID.'
    }
    foreach ($endpoint in @($LogAnalyticsEndpoint, $LogAnalyticsAudience)) {
        if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or
            $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) {
            throw 'The Logs endpoint and audience must be absolute HTTPS URIs without credentials, query strings, or fragments.'
        }
    }
    if ($PSCmdlet.ParameterSetName -eq 'KqlFile') {
        $queryFile = Get-Item -LiteralPath $QueryPath
        if ($queryFile.PSProvider.Name -ne 'FileSystem' -or $queryFile.PSIsContainer) {
            throw 'QueryPath must point to a UTF-8 query file.'
        }
        if ($queryFile.FullName -eq $outputFile) {
            throw 'OutputPath must not overwrite the input query file.'
        }
        $Query = Get-Content -LiteralPath $queryFile.FullName -Raw -Encoding utf8
    }
    if ([string]::IsNullOrWhiteSpace($Query)) {
        throw 'The KQL query must not be empty or whitespace.'
    }
}
else {
    if ($ResourceId -notmatch '^/subscriptions/([^/]+)/(?:resourceGroups/[^/]+/)?providers/[^/]+/[^/]+/[^/]+(?:/[^/]+/[^/]+)*$' -or
        $Matches[1] -ne $SubscriptionId.ToString()) {
        throw 'ResourceId must be a full ARM resource ID in the explicitly selected subscription.'
    }
    if ($ResourceId -match '[?#\\\r\n]' -or $ResourceId -match '(^|/)\.\.?(/|$)' -or
        $ResourceId -match '%') {
        throw 'ResourceId must be an unescaped ARM resource ID without query strings, fragments, or relative path segments.'
    }
    foreach ($metricName in $MetricNames) {
        if ([string]::IsNullOrWhiteSpace($metricName) -or $metricName.Contains(',')) {
            throw 'Supply each metric name as a separate, non-empty MetricNames entry.'
        }
    }
    if (@($MetricNames | Sort-Object -Unique).Count -ne $MetricNames.Count -or
        @($Aggregation | Sort-Object -Unique).Count -ne $Aggregation.Count) {
        throw 'MetricNames and Aggregation must not contain duplicate entries.'
    }
    $requestedInterval = [System.Xml.XmlConvert]::ToTimeSpan($TimeGrain)
    if ($requestedInterval -le [timespan]::Zero) {
        throw 'TimeGrain must be a positive ISO 8601 duration, such as PT1M or PT1H.'
    }
    if ($MetricFilter -and $MetricFilter.Contains('*')) {
        throw 'Wildcard split-by metric filters are not supported because the API can truncate the series list. Use fixed-value filters.'
    }
}

Import-Module Az.Accounts -ErrorAction Stop
$context = Get-AzContext -ErrorAction Stop
if (-not $context -or -not $context.Account -or -not $context.Subscription) {
    throw 'No authenticated Azure context is available. Run Connect-AzAccount with your tenant and subscription first.'
}
if ($context.Subscription.Id -ne $SubscriptionId.ToString()) {
    throw 'The active Azure context does not match SubscriptionId. Select the intended subscription with Set-AzContext first.'
}
if ($PSBoundParameters.ContainsKey('TenantId') -and $context.Tenant.Id -ne $TenantId.ToString()) {
    throw 'The active Azure context does not match TenantId. Sign in to the intended tenant first.'
}
if ($isKql -and $context.Environment.Name -ne 'AzureCloud' -and
    (-not $PSBoundParameters.ContainsKey('LogAnalyticsEndpoint') -or
     -not $PSBoundParameters.ContainsKey('LogAnalyticsAudience'))) {
    throw 'For an Azure cloud other than AzureCloud, explicitly supply its LogAnalyticsEndpoint and LogAnalyticsAudience.'
}

$exportRows = [System.Collections.Generic.List[object]]::new()
if ($isKql) {
    $uri = "$($LogAnalyticsEndpoint.AbsoluteUri.TrimEnd('/'))/v1/workspaces/$WorkspaceId/query"
    $payload = @{ query = $Query; timespan = $timespan } | ConvertTo-Json -Depth 10 -Compress
    $body = Invoke-SnapshotRequest -Uri $uri -Method POST -Context $context `
        -Audience $LogAnalyticsAudience -Payload $payload

    if (@($body.tables).Count -ne 1) {
        throw 'KQL must return exactly one result table. Combine the results in KQL or run separate exports.'
    }
    $table = $body.tables[0]
    if ($table -isnot [System.Collections.IDictionary] -or
        $table.columns -isnot [System.Collections.IList] -or $table.columns.Count -eq 0 -or
        $table.rows -isnot [System.Collections.IList]) {
        throw 'The KQL response does not contain a valid columns/rows schema.'
    }
    $columnNames = @($table.columns | ForEach-Object { [string]$_.name })
    $uniqueNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $columnNames) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $uniqueNames.Add($name)) {
            throw 'KQL column names must be non-empty and unique ignoring case. Rename columns in the query.'
        }
    }
    foreach ($row in $table.rows) {
        if ($row -isnot [System.Collections.IList] -or $row.Count -ne $columnNames.Count) {
            throw 'A KQL result row does not match the returned column schema.'
        }
        $record = [ordered]@{}
        for ($i = 0; $i -lt $columnNames.Count; $i++) {
            $record[$columnNames[$i]] = ConvertTo-SnapshotCell -Value $row[$i] -ColumnType $table.columns[$i].type
        }
        $exportRows.Add([pscustomobject]$record)
    }
}
else {
    $parameters = [ordered]@{
        'api-version'         = '2023-10-01'
        timespan              = $timespan
        interval              = $TimeGrain
        metricnames           = $MetricNames -join ','
        aggregation           = $Aggregation -join ','
        AutoAdjustTimegrain   = 'false'
        ValidateDimensions    = 'true'
    }
    if ($MetricNamespace) {
        $parameters.metricnamespace = $MetricNamespace
    }
    if ($MetricFilter) {
        $parameters['$filter'] = $MetricFilter
    }
    $queryString = ($parameters.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [uri]::EscapeDataString($_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    $managementEndpoint = [uri]$context.Environment.ResourceManagerUrl
    if (-not $managementEndpoint.IsAbsoluteUri -or $managementEndpoint.Scheme -ne 'https') {
        throw 'The active Azure environment does not have a valid HTTPS management endpoint.'
    }
    $uri = "$($managementEndpoint.AbsoluteUri.TrimEnd('/'))$ResourceId/providers/Microsoft.Insights/metrics?$queryString"
    $body = Invoke-SnapshotRequest -Uri $uri -Method GET -Context $context
    if (-not $body.interval -or [System.Xml.XmlConvert]::ToTimeSpan($body.interval) -ne $requestedInterval) {
        throw 'Azure Monitor returned a different or missing time grain; no CSV was published.'
    }
    $returnedNames = @($body.value | ForEach-Object { $_.name.value })
    if ($returnedNames.Count -ne $MetricNames.Count -or
        @($returnedNames | Sort-Object -Unique).Count -ne $MetricNames.Count) {
        throw 'Azure Monitor did not return exactly the requested metrics; no CSV was published.'
    }
    $columnNames = @(
        'ResourceId', 'MetricName', 'Unit', 'Aggregation', 'TimeGrain',
        'SnapshotStartUtc', 'SnapshotEndUtc', 'TimeStampUtc', 'Dimensions', 'Value'
    )
    foreach ($metric in $body.value) {
        if ($MetricNames -notcontains $metric.name.value) {
            throw "Azure Monitor returned an unexpected metric: $($metric.name.value)"
        }
        if ($metric.errorCode -and $metric.errorCode -ne 'Success') {
            throw "Metric '$($metric.name.value)' failed: $($metric.errorCode) $($metric.errorMessage)"
        }
        if ($metric.timeseries -isnot [System.Collections.IList]) {
            throw "Metric '$($metric.name.value)' has an invalid or missing timeseries array."
        }
        if (@($metric.timeseries).Count -gt 1) {
            throw 'Metrics mode requires a single rolled-up series per metric. Remove split-by filters to avoid series truncation.'
        }
        foreach ($series in $metric.timeseries) {
            if ($series.data -isnot [System.Collections.IList]) {
                throw 'A metric series has an invalid or missing data array.'
            }
            $dimensions = [ordered]@{}
            foreach ($dimension in $series.metadatavalues) {
                $name = [string]$dimension.name.value
                if ([string]::IsNullOrWhiteSpace($name) -or $dimensions.Contains($name)) {
                    throw 'A metric series has invalid or duplicate dimension names.'
                }
                $dimensions[$name] = $dimension.value
            }
            $dimensionsJson = ConvertTo-Json -InputObject $dimensions -Compress -Depth 10
            foreach ($point in $series.data) {
                if (-not $point.timeStamp) {
                    throw 'A metric data point has no timestamp.'
                }
                foreach ($aggregate in $Aggregation) {
                    $exportRows.Add([pscustomobject][ordered]@{
                        ResourceId       = $ResourceId
                        MetricName       = $metric.name.value
                        Unit             = $metric.unit
                        Aggregation      = $aggregate
                        TimeGrain        = $body.interval
                        SnapshotStartUtc = $startUtc
                        SnapshotEndUtc   = $endUtc
                        TimeStampUtc     = ConvertTo-SnapshotCell -Value $point.timeStamp -ColumnType datetime
                        Dimensions       = $dimensionsJson
                        Value            = ConvertTo-SnapshotCell -Value $point[$aggregate.ToLowerInvariant()]
                    })
                }
            }
        }
    }
}

if ($exportRows.Count -eq 0) {
    Write-Warning 'Azure Monitor returned no rows for this request. Writing a header-only CSV; no zero values were invented.'
}

$outputDirectory = [IO.Path]::GetDirectoryName($outputFile)
$null = [IO.Directory]::CreateDirectory($outputDirectory)
$temporaryFile = Join-Path $outputDirectory ".$([guid]::NewGuid().ToString('N')).snapshot.tmp"
try {
    if ($exportRows.Count -gt 0) {
        $exportRows | Export-Csv -LiteralPath $temporaryFile -NoTypeInformation -Encoding utf8 -NoClobber
    }
    else {
        $emptyRecord = [ordered]@{}
        foreach ($name in $columnNames) {
            $emptyRecord[$name] = $null
        }
        $header = [pscustomobject]$emptyRecord | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1
        Set-Content -LiteralPath $temporaryFile -Value $header -Encoding utf8
    }
    [IO.File]::Move($temporaryFile, $outputFile, $Force.IsPresent)
}
finally {
    if ([IO.File]::Exists($temporaryFile)) {
        [IO.File]::Delete($temporaryFile)
    }
}

[pscustomobject]@{
    Mode             = if ($isKql) { 'Kql' } else { 'Metrics' }
    OutputPath       = $outputFile
    RowCount         = $exportRows.Count
    SnapshotStartUtc = $startUtc
    SnapshotEndUtc   = $endUtc
}