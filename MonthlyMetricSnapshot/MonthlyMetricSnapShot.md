# Azure Monitor snapshots to CSV

[monthlymetricsnapshot.ps1](./monthlymetricsnapshot.ps1) exports monitoring data
for an explicit time window. It is generic across services; Cosmos DB is the
worked example, not a dependency in the script.

- **KQL:** supply query text or a query file and a Log Analytics workspace ID.
  KQL defines the aggregates and CSV columns.
- **Metrics:** supply a resource ID, metric names, aggregation, and time grain.
  The CSV contains the aggregates returned by Azure Monitor Metrics.

The utility only reads Azure data and writes a local CSV. It does not create
resources, enable diagnostics, change RBAC, generate test traffic, or alter your
Azure context. Review the [implementation plan](./PLAN.md) for scope and the
live-test checklist.

## Important: KQL logs are not the Metrics blade

Service blades can combine platform metrics, diagnostic logs, and other data.
KQL against a workspace does not directly query the platform metrics store.
Copy a blade's KQL only when that chart actually uses Logs.

For Cosmos DB:

- `CDBDataPlaneRequests` contains diagnostic request records when the relevant
  diagnostics have been routed to a workspace using resource-specific tables.
  The example below targets a Cosmos DB for NoSQL account.
- A chart using `TotalRequests` uses platform metrics. The current
  [metric catalog](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics)
  lists `Count` for that metric, and `Total`/sum for `TotalRequestUnits`.
  Do not assume a metric's unit or display name determines its aggregation.
- That catalog currently marks both metrics as unavailable for diagnostic
  settings export. Do not assume that selecting `AllMetrics` makes them
  available in the workspace's `AzureMetrics` table.
- Counts from diagnostic records need not equal platform metric counts.
  Diagnostic coverage, ingestion delays, filters, and collection semantics can
  differ. Validate each source against its corresponding portal view.

## Prerequisites

1. PowerShell **7.2 or later** (`pwsh`), not Windows PowerShell 5.1.
2. `Az.Accounts`, which provides authentication and `Invoke-AzRestMethod`.
   Neither the full Az installation nor Azure CLI is required.
3. An existing sign-in to the intended tenant and subscription.
4. Appropriate read/query permissions:
   - KQL: workspace query permissions and access to the selected tables, for
     example through Log Analytics Reader with the required scope.
   - Metrics: resource metric-read permissions, for example Monitoring Reader
     at the resource or an appropriate parent scope.
5. For the KQL example, existing diagnostic data in `CDBDataPlaneRequests`.
   Enabling diagnostics is a separate operator action, can incur charges, and
   does not backfill earlier activity.

The KQL implementation uses the synchronous workspace `/query` API. Use
Analytics-plan tables for these examples; search jobs and alternative APIs for
other table plans are outside this utility's scope.

If the module is missing, install it locally:

```powershell
Install-Module Az.Accounts -Scope CurrentUser -Repository PSGallery
```

## 1. Sign in locally and supply your configuration

Run the examples from the repository root in PowerShell 7. Replace every
`<...>` placeholder locally. Never put a password, client secret, Cosmos DB
account key, or access token in the script or query.

```powershell
$tenantId = '<tenant-id>'
$subscriptionId = '<subscription-id>'
$workspaceId = '<log-analytics-workspace-id>'
$cosmosResourceId = "/subscriptions/$subscriptionId/resourceGroups/<resource-group-name>/providers/Microsoft.DocumentDB/databaseAccounts/<cosmos-account-name>"

Connect-AzAccount -Tenant $tenantId -Subscription $subscriptionId -Scope Process
```

If you are already signed in, select the intended context explicitly instead:

```powershell
Set-AzContext -Tenant $tenantId -Subscription $subscriptionId -Scope Process
```

For a device-code sign-in, add `-UseDeviceAuthentication` to
`Connect-AzAccount`. Authentication and token caching are managed by
`Az.Accounts`; this script never extracts or saves tokens. `-Scope Process`
controls context scope, not whether an operating-system authentication broker
retains its own sign-in cache.

The script verifies the subscription and, when supplied, tenant against that
context. It does not automatically sign in or switch subscriptions.

**KQL scope is the supplied workspace and the query itself.** `SubscriptionId`
verifies authentication context; it does not add a subscription or resource
filter to your KQL. A shared workspace can contain many resources.

## 2. Export aggregated Cosmos DB diagnostic data

Start with a short window containing known activity. Allow time for ingestion,
and use the exact same custom UTC window when checking the result in Logs:

```powershell
$end = [datetimeoffset]::UtcNow.AddMinutes(-10)
$start = $end.AddHours(-1)

$query = @"
CDBDataPlaneRequests
| where _ResourceId =~ '$cosmosResourceId'
| summarize
    RequestCount = count(),
    TotalRequestUnits = sum(RequestCharge),
    AverageDurationMs = avg(DurationMs),
    P95DurationMs = percentile(DurationMs, 95),
    ThrottledRequests = countif(StatusCode == 429)
  by AccountName, DatabaseName, CollectionName, RegionName
| order by AccountName asc, DatabaseName asc, CollectionName asc, RegionName asc
"@

.\MonthlyMetricSnapshot\monthlymetricsnapshot.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -WorkspaceId $workspaceId `
    -Query $query `
    -StartTime $start `
    -EndTime $end `
    -OutputPath '.\MonthlyMetricSnapshot\output\cosmos-logs.csv'
```

The output directory is created when an export is ready to be written. A
successful invocation returns `Mode`, `OutputPath`, `RowCount`,
`SnapshotStartUtc`, and `SnapshotEndUtc`.

The script sends the start/end range to the query API without rewriting your
KQL. Explicit time predicates in the query can further restrict that range.
For hourly results, add `bin(TimeGenerated, 1h)` to the `summarize ... by` list.
Remove the grouping columns to request a single overall aggregate.

For another service, replace the query with trusted KQL for a table already
available in that workspace. The script never requires a Cosmos DB table.
Legacy diagnostics routed to `AzureDiagnostics` need a query for that schema;
the script does not silently translate table or column names.

A minimal legacy coverage query is:

```kusto
AzureDiagnostics
| where _ResourceId =~ '<cosmos-account-resource-id>'
| summarize RecordCount = count(), LastRecordUtc = max(TimeGenerated) by Category
| order by Category asc
```

This counts diagnostic records by category, not platform metric requests.
Replace the resource placeholder yourself. Request charge and duration fields
in legacy diagnostics require a query for the fields actually present.

### Use a KQL file instead of inline text

Save your own query in
`MonthlyMetricSnapshot\cosmos.local.kql`, replacing resource placeholders in the
file before running it:

```powershell
.\MonthlyMetricSnapshot\monthlymetricsnapshot.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -WorkspaceId $workspaceId `
    -QueryPath '.\MonthlyMetricSnapshot\cosmos.local.kql' `
    -StartTime $start `
    -EndTime $end `
    -OutputPath '.\MonthlyMetricSnapshot\output\cosmos-query-file.csv'
```

Use UTF-8. Supply `Query` or `QueryPath`, never both. Query files are read
literally: PowerShell variables and placeholder strings inside them are not
expanded or replaced. The query must return one result table with non-empty
column names that are unique ignoring case.

### Previous calendar month in UTC

This uses actual calendar boundaries rather than assuming every month has
30 days:

```powershell
$now = [datetimeoffset]::UtcNow
$end = [datetimeoffset]::new($now.Year, $now.Month, 1, 0, 0, 0, [timespan]::Zero)
$start = $end.AddMonths(-1)
$monthFile = ".\MonthlyMetricSnapshot\output\cosmos-$($start.ToString('yyyy-MM')).csv"

.\MonthlyMetricSnapshot\monthlymetricsnapshot.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -WorkspaceId $workspaceId `
    -Query $query `
    -StartTime $start `
    -EndTime $end `
    -OutputPath $monthFile
```

The selected data must still be retained in the workspace.

## 3. Export platform metrics for a blade comparison

Reset to a short test window and choose the resource's REST metric name,
supported aggregation, namespace, and time grain from its metric definitions
or the official service reference:

```powershell
$end = [datetimeoffset]::UtcNow.AddMinutes(-10)
$start = $end.AddHours(-1)

.\MonthlyMetricSnapshot\monthlymetricsnapshot.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -ResourceId $cosmosResourceId `
    -MetricNamespace 'Microsoft.DocumentDB/databaseAccounts' `
    -MetricNames 'TotalRequests' `
    -Aggregation Count `
    -TimeGrain 'PT1M' `
    -StartTime $start `
    -EndTime $end `
    -OutputPath '.\MonthlyMetricSnapshot\output\cosmos-requests-metrics.csv'
```

For consumed request units, use `-MetricNames 'TotalRequestUnits'` and
`-Aggregation Total` with a different output filename. These are separate
measurements; the script does not derive one from the other.

For storage gauges, use `-MetricNames 'DataUsageV2', 'DocumentCountV2'`,
`-Aggregation Average`, and an appropriate grain such as `-TimeGrain 'P1D'`.
These averages describe each returned bucket; summing daily storage sizes or
document-count gauges does not produce a meaningful monthly total.

Every metric in one invocation must support every requested aggregation. Use
separate invocations when the metrics have different aggregation requirements.

An optional fixed-value filter can match a chart filtered to a database and
container:

```powershell
-MetricFilter "DatabaseName eq '<database-name>' and CollectionName eq '<container-name>'"
```

Add that parameter to the preceding invocation, rather than running it on its
own. Match the portal's resource, metric, aggregation, exact UTC start/end,
granularity, and filters. Compare the returned buckets, not a differently
configured chart's headline value. Turn off split-by for this version.

### Metrics CSV schema

| Column | Meaning |
| --- | --- |
| `ResourceId` | Resource requested by the caller |
| `MetricName` | REST metric name |
| `Unit` | Unit returned by Azure Monitor |
| `Aggregation` | Requested API aggregation for this row |
| `TimeGrain` | Interval returned by the API |
| `SnapshotStartUtc`, `SnapshotEndUtc` | Explicit requested UTC window |
| `TimeStampUtc` | UTC timestamp of the returned bucket |
| `Dimensions` | JSON object containing returned series metadata |
| `Value` | Returned aggregate, or blank when no value exists |

There is one row per bucket and requested aggregation, not a second
PowerShell-calculated summary. A zero remains `0`; missing data remains blank.
The utility disables automatic time-grain adjustment and rejects unexpected
intervals or missing requested metrics.

## Parameter reference

| Parameters | Required / scope |
| --- | --- |
| `SubscriptionId` | Required in every mode; non-empty subscription GUID matching the active context |
| `TenantId` | Optional context check; non-empty tenant GUID when provided |
| `StartTime`, `EndTime` | Required `DateTimeOffset` values; start must precede end |
| `OutputPath` | Required `.csv` path; parent directory is created as needed |
| `Force` | Optional; explicitly permits replacement of an existing output |
| `WorkspaceId` | Required for KQL; workspace/customer GUID, not its ARM resource ID |
| `Query` / `QueryPath` | Exactly one is required for KQL |
| `LogAnalyticsEndpoint` | KQL only; public Azure default `https://api.loganalytics.azure.com` |
| `LogAnalyticsAudience` | KQL only; public Azure token audience default `https://api.loganalytics.io` |
| `ResourceId` | Required for Metrics; full unescaped ARM ID in the selected subscription |
| `MetricNames` | Required for Metrics; one to twenty distinct REST names |
| `Aggregation` | Required for Metrics; one or more of `Average`, `Minimum`, `Maximum`, `Total`, `Count` |
| `TimeGrain` | Required for Metrics; positive ISO 8601 duration, for example `PT1M`, `PT1H`, or `P1D` |
| `MetricNamespace` | Optional namespace for the requested metrics |
| `MetricFilter` | Optional fixed-value Azure Monitor dimension filter; wildcard split-by is rejected |

Use timezone-qualified timestamps, such as an ISO 8601 string ending in `Z`,
or explicit `DateTimeOffset` objects. The script normalizes instants to UTC;
it cannot infer which timezone you intended for an unqualified date string.
Requests and exported timestamps use canonical UTC `Z`, avoiding `+00:00`
offset decoding differences in the Metrics API's query string.

For non-public Azure clouds, sign in with the appropriate Azure environment
and explicitly pass its documented HTTPS Logs endpoint **and** token audience.
Do not send queries or authentication to an untrusted endpoint. Metrics mode
obtains its management endpoint from the selected Azure environment.

The fixed public service URLs, REST API version, and CSV field names are
protocol constants, not tenant configuration. Subscription, tenant, resource,
workspace, query, window, and output choices are never embedded in the script.

## Output, safety, and limits

- CSV is UTF-8, comma-delimited, with quoted fields. KQL column order is
  preserved; numeric formatting is culture-independent; datetime values are
  normalized to UTC; structured cells are compact JSON.
- CSV has no native type metadata. Null and empty string cells are both blank.
  Values are not redacted, formula-escaped, or otherwise altered for Excel.
  Treat external strings as untrusted; import them as text rather than enabling
  spreadsheet formulas or external content.
- A valid zero-row response produces a warning and a header-only CSV. A missing
  table, denied permission, malformed response, or query error is not treated
  as "no activity." KQL itself can return a zero-valued summary over no records;
  the utility preserves that query result.
- HTTP errors and partial KQL results terminate the invocation. No partial CSV
  is published, and an existing file is preserved on request/conversion failure.
  Completed data is staged in the destination directory before publication.
- Existing files are never appended to. Use a new filename or `-Force`.
- Metrics mode supports a single rolled-up series per metric. Wildcard
  split-by, `FULL` intervals, pagination, and automatic request partitioning are
  intentionally unsupported rather than silently exporting incomplete data.
- Retention, query size, execution time, metric availability, supported time
  grains, network restrictions, and throttling remain Azure service limits.
  There is no automatic retry or row-limit override. Inspect an error, narrow
  the request or reduce its result in KQL, and retry deliberately.
- Do not average averages, sum percentages, or combine independently calculated
  percentiles to reconstruct a monthly aggregate. Calculate the required
  result in one suitable KQL query or use the metric's supported aggregation.
- Logs ingestion, retention, and some query/table plans can incur charges.
  Read-only does not imply cost-free.
- The documented `MonthlyMetricSnapshot\output` directory and
  `MonthlyMetricSnapshot\*.local.kql` files are ignored by Git as a convenience,
  not as anonymization or a security boundary. Exports can contain customer
  identifiers, resource IDs, or sensitive query-selected fields. Keep live
  exports and private queries out of public commits.

## Validation

Run the credential-free offline tests:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive `
    -File '.\MonthlyMetricSnapshot\tests\Test-MonthlyMetricSnapshot.ps1'
```

The [test harness](./tests/Test-MonthlyMetricSnapshot.ps1) stubs authentication,
module loading, and REST calls. It needs neither Azure access, Az modules, nor
Pester, and it cleans up its generated temporary CSV/query files.

The offline cases cover KQL text/files, scalar and structured cells, CSV
escaping, invariant decimals, UTC conversion, empty results, HTTP/partial
errors, malformed responses, context checks, overwrite protection and races,
metric aggregation fields, missing values, interval checks, and cloud endpoint
selection.

### Live validation performed on 2026-10-26

- Operator-assisted device authentication and real workspace queries succeeded.
  Inline and file-based KQL both returned the exact known aggregate values:
  record count 5, sum 15, and average 3.
- A Cosmos DB storage export returned 120 populated rows across four metrics
  over 30 days; all timestamps and values matched a separate Metrics API call.
- A previous-calendar-month export returned 60 populated daily rows for
  `DataUsageV2` and `DocumentCountV2`. Its exact CSV schema, units, resource,
  UTC window, aggregation, timestamps, and values matched the API response.
- Live testing found and fixed an offset-decoding failure in Metrics requests.
  Canonical UTC `Z` formatting is now covered by a regression case; all
  25 offline tests pass.
- Request metrics had no datapoints in the checked 30-day windows, and the
  existing legacy workspace returned no Cosmos DB diagnostic records for the
  tested scope in the checked 90-day window. Header-only CSV behavior was verified. Populated request/log
  parity still requires a window with known activity.

No resources, diagnostic settings, RBAC, or application traffic were changed.
The API comparisons do not claim that a portal chart was visually inspected.
Follow the [live Cosmos DB checklist](./PLAN.md#live-cosmos-db-test-checklist)
for your own sources and filters; keep live output private.

## References

- [Azure Monitor Logs query request format](https://learn.microsoft.com/azure/azure-monitor/logs/api/request-format)
- [Logs response format and partial errors](https://learn.microsoft.com/azure/azure-monitor/logs/api/response-format)
- [Azure Monitor Metrics REST API](https://learn.microsoft.com/rest/api/monitor/metrics/list?view=rest-monitor-2023-10-01)
- [Cosmos DB platform metric reference](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics)
- [CDBDataPlaneRequests schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/cdbdataplanerequests)