###########################################################################
# RUN-FINOPSSCAN.PS1
# AZURE AUTOMATION RUNBOOK — FINOPS SCANNER
###########################################################################
# Purpose: Run the FinOps scan pipeline on a schedule via Azure
#          Automation. Authenticates with Managed Identity, loads scan
#          modules from the Automation Account's files, and writes
#          results to blob storage (JSON + CSV).
#
# Schedule: Daily (configured in Terraform)
# Auth:     System-Assigned Managed Identity
# Output:   Blob container "finops-scans/{date}/"
###########################################################################

$scanStart = Get-Date
Write-Output "=== FinOps Scan starting at $($scanStart.ToString('yyyy-MM-dd HH:mm:ss')) ==="

# ── Configuration from Automation Variables ─────────────────────────────
$tenantId           = Get-AutomationVariable -Name 'FINOPS_TENANT_ID'
$storageAccountName = Get-AutomationVariable -Name 'FINOPS_STORAGE_ACCOUNT'
$containerName      = Get-AutomationVariable -Name 'FINOPS_CONTAINER_NAME'
$subscriptionFilter = Get-AutomationVariable -Name 'FINOPS_SUBSCRIPTION_FILTER' -ErrorAction SilentlyContinue
if (-not $subscriptionFilter) { $subscriptionFilter = '' }
$dceEndpoint = Get-AutomationVariable -Name 'FINOPS_DCE_ENDPOINT' -ErrorAction SilentlyContinue
if (-not $dceEndpoint) { $dceEndpoint = '' }
$dcrImmutableId = Get-AutomationVariable -Name 'FINOPS_DCR_IMMUTABLE_ID' -ErrorAction SilentlyContinue
if (-not $dcrImmutableId) { $dcrImmutableId = '' }

if (-not $tenantId) {
    Write-Error "FINOPS_TENANT_ID automation variable is not set."
    throw "Missing FINOPS_TENANT_ID"
}

# ── Headless helpers (normally loaded from separate files) ──────────────
$script:MgCostScopeFailed = $false

function Test-MgCostScope {
    return (-not $script:MgCostScopeFailed)
}

function Set-MgCostScopeFailed {
    $script:MgCostScopeFailed = $true
    Write-Warning "MG-scope cost access unavailable — using per-subscription queries"
}

# Resolve the management-group scope we can actually query for cost. Many orgs
# assign Cost Management Reader on a CHILD management group rather than the
# tenant-root group (whose id == tenant GUID), so querying managementGroups/
# <tenantId> returns 401. This probes the root first, then every accessible MG,
# and caches the first scope that returns cost data. Falls back to per-sub.
$script:CostMgId = $null

function Resolve-CostMgId {
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    if ($script:MgCostScopeFailed) { return $null }
    if ($script:CostMgId) { return $script:CostMgId }

    # Candidates are the management groups the caller can actually see. Cost
    # access usually lives on a child MG (not the tenant root), so probe the
    # visible MGs first and fall back to the tenant root last. A throttled
    # (429) probe must not abandon discovery - keep trying the rest.
    $candidates = [System.Collections.Generic.List[string]]::new()

    try {
        $listResp = Invoke-AzRestMethodWithRetry -Path '/providers/Microsoft.Management/managementGroups?api-version=2020-05-01' -Method GET
        if ($listResp -and $listResp.StatusCode -eq 200) {
            $mgs = ($listResp.Content | ConvertFrom-Json).value
            foreach ($mg in @($mgs)) {
                $name = $mg.name
                if ($name -and -not $candidates.Contains($name)) {
                    $candidates.Add($name)
                }
                if ($candidates.Count -ge 12) { break }
            }
        }
    }
    catch { }

    # Tenant root as a last-resort candidate (covers orgs where the cost role
    # is assigned at the root management group).
    if (-not $candidates.Contains($TenantId)) {
        $candidates.Add($TenantId)
    }

    $probeBody = @{
        type      = 'ActualCost'
        timeframe = 'MonthToDate'
        dataset   = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
        }
    } | ConvertTo-Json -Depth 10

    # Use a low retry budget per probe so a throttled candidate fails fast and
    # we move on to the next one. The real cost queries keep the full budget.
    foreach ($mgId in $candidates) {
        $path = "/providers/Microsoft.Management/managementGroups/$mgId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        $resp = Invoke-AzRestMethodWithRetry -Path $path -Method POST -Payload $probeBody -MaxRetries 2
        if ($resp -and $resp.StatusCode -eq 200) {
            $script:CostMgId = $mgId
            if ($mgId -ne $TenantId) {
                Write-Warning "Cost scope resolved to management group '$mgId' (no cost role on tenant root)"
            }
            return $mgId
        }
        # 401/403 = no cost role here; 429 = throttled; anything else = unusable
        # at this scope. In every case, keep probing the remaining candidates so
        # a throttled tenant-root probe never blocks reaching the child MG.
    }

    Set-MgCostScopeFailed
    return $null
}

function Send-ToLogAnalytics {
    param(
        [string]$DceEndpoint,
        [string]$DcrImmutableId,
        [string]$StreamName,
        [object[]]$Records
    )
    if (-not $Records -or $Records.Count -eq 0) { return }

    $token = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com').Token
    $uri   = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"

    # Batch in chunks of 500 to stay under API limits
    for ($i = 0; $i -lt $Records.Count; $i += 500) {
        $batch = @($Records[$i..([math]::Min($i + 499, $Records.Count - 1))])
        $body  = $batch | ConvertTo-Json -Depth 10 -Compress
        if ($batch.Count -eq 1) { $body = "[$body]" }

        $resp = Invoke-WebRequest -Uri $uri -Method POST -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -notin @(200, 204)) {
            Write-Warning "  LAW ingestion failed for $StreamName batch: HTTP $($resp.StatusCode)"
        }
    }
}

function Update-ScanStatus {
    param([string]$Message)
    Write-Host "  [SCAN] $Message"
}

function Get-CurrencySymbol {
    param([string]$Code)
    switch ($Code) {
        'USD' { '$' }
        'EUR' { [char]0x20AC }
        'GBP' { [char]0x00A3 }
        'JPY' { [char]0x00A5 }
        'CAD' { 'C$' }
        'AUD' { 'A$' }
        'CHF' { 'CHF ' }
        'INR' { [char]0x20B9 }
        'BRL' { 'R$' }
        'KRW' { [char]0x20A9 }
        'MXN' { 'MX$' }
        default { "$Code " }
    }
}

# ── Import required Az modules (PS 7.2 runtime may not auto-load) ───────
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction SilentlyContinue
Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue
Import-Module Az.Storage -ErrorAction SilentlyContinue

# ── Authenticate via Managed Identity ───────────────────────────────────
Write-Output "Authenticating with Managed Identity..."
try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
    Write-Output "  Authenticated as: $($ctx.Account.Id)"
} catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    throw
}

# ── Scan modules are embedded above this line by Terraform ──────────────
# Do not add dot-source loading here — all module functions are
# concatenated into this runbook at deploy time.

# ── Discover subscriptions ──────────────────────────────────────────────
Write-Output "Discovering subscriptions..."
if ($subscriptionFilter) {
    $subIds = $subscriptionFilter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $subs = @($subIds | ForEach-Object {
        $subId = $_
        try {
            $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
            [PSCustomObject]@{ Id = $sub.Id; Name = $sub.Name }
        } catch {
            Write-Warning "  Subscription $subId not accessible: $($_.Exception.Message)"
        }
    } | Where-Object { $_ })
} else {
    $allSubs = Get-AzSubscription -TenantId $tenantId -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' }
    $subs = @($allSubs | ForEach-Object {
        [PSCustomObject]@{ Id = $_.Id; Name = $_.Name }
    })
}

if ($subs.Count -eq 0) {
    Write-Error "No accessible subscriptions found."
    throw "No subscriptions"
}
Write-Output "  Found $($subs.Count) subscription(s)"

# ── Detect FinOps Hub + load export data (export-first) ─────────────────
# Cost modules prefer hub export rows over the Cost Management API. If a hub
# is found and its export is readable, $hubData carries FOCUS rows that the
# Cost Data, Resource Costs and Cost by Tag steps consume. Any failure here
# leaves $hubData null and the modules transparently fall back to the API.
$hubData = $null
try {
    $subIdList = @($subs | ForEach-Object { $_.Id })
    $hubQuery = @"
Resources
| where type =~ 'microsoft.storage/storageaccounts'
| where tostring(tags['cm-resource-parent']) contains 'Microsoft.Cloud/hubs'
| project name, resourceGroup, subscriptionId, location
"@
    $hubResult = Search-AzGraphSafe -Query $hubQuery -Subscription $subIdList -First 5
    $hub = $null
    if ($hubResult -and $hubResult.Data) { $hub = @($hubResult.Data)[0] }

    if ($hub) {
        Write-Output "  FinOps Hub detected: $($hub.name) ($($hub.resourceGroup)) — reading export data..."
        $hubRows = Read-FinOpsHubData -StorageAccountName $hub.name -ResourceGroupName $hub.resourceGroup -Months 1
        if ($hubRows -and @($hubRows).Count -gt 0) {
            $hubData = $hubRows
            Write-Output "  Loaded $(@($hubData).Count) cost row(s) from hub export — using export-first sourcing"
        }
        else {
            Write-Output "  Hub export returned no rows — cost steps will use the Cost Management API"
        }
    }
    else {
        Write-Output "  No FinOps Hub found — cost steps will use the Cost Management API"
    }
}
catch {
    Write-Warning "  Hub detection/read failed: $($_.Exception.Message) — falling back to Cost Management API"
    $hubData = $null
}

# ── Run scan pipeline ───────────────────────────────────────────────────
$data = @{}

$steps = @(
    @{ Name = 'Management Group Hierarchy'; Script = { $data.Hierarchy     = Get-TenantHierarchy -TenantId $tenantId -Subscriptions $subs } }
    @{ Name = 'Contract Type';              Script = { $data.Contract      = Get-ContractInfo -Subscriptions $subs } }
    @{ Name = 'Cost Data';                  Script = { $data.Costs         = Get-CostData -TenantId $tenantId -Subscriptions $subs -HubData $hubData } }
    @{ Name = 'Resource Costs';             Script = { $data.ResourceCosts = Get-ResourceCosts -TenantId $tenantId -Subscriptions $subs -CostData $data.Costs -HubData $hubData } }
    @{ Name = 'Tag Inventory';              Script = { $data.Tags          = Get-TagInventory -Subscriptions $subs } }
    @{ Name = 'Cost by Tag';                Script = {
        $tagNames = if ($data.Tags) { $data.Tags.TagNames } else { @{} }
        $data.CostByTag = Get-CostByTag -TenantId $tenantId -ExistingTags $tagNames -Subscriptions $subs -HubData $hubData
    }}
    @{ Name = 'Cost Trend';                 Script = { $data.CostTrend     = Get-CostTrend -TenantId $tenantId -Subscriptions $subs } }
    @{ Name = 'AHB Opportunities';          Script = { $data.AHB           = Get-AHBOpportunities -Subscriptions $subs } }
    @{ Name = 'Commitment Utilization';     Script = {
        $agreementType = if ($data.Contract -and $data.Contract[0].AgreementType) { $data.Contract[0].AgreementType } else { '' }
        $data.Commitments = Get-CommitmentUtilization -Subscriptions $subs -AgreementType $agreementType
    }}
    @{ Name = 'Orphaned Resources';         Script = { $data.Orphans       = Get-OrphanedResources -Subscriptions $subs } }
    @{ Name = 'Idle VMs';                   Script = { $data.IdleVMs       = Get-IdleVMs -Subscriptions $subs } }
    @{ Name = 'Storage Tier Advice';        Script = { $data.StorageTier   = Get-StorageTierAdvice -Subscriptions $subs } }
    @{ Name = 'Reservation Advice';         Script = { $data.Reservations  = Get-ReservationAdvice -Subscriptions $subs } }
    @{ Name = 'Optimization Advice';        Script = { $data.Optimization  = Get-OptimizationAdvice -Subscriptions $subs } }
    @{ Name = 'Budget Status';              Script = { $data.Budgets       = Get-BudgetStatus -Subscriptions $subs -CostData $data.Costs } }
    @{ Name = 'Budget History';             Script = {
        if ($data.Budgets -and $data.Budgets.HasData) {
            # Reuse the monthly spend already fetched by Cost Trend so Budget
            # History avoids re-querying the throttle-prone Cost Management API.
            $data.BudgetHistory = Get-BudgetHistory -Budgets $data.Budgets.Budgets -MonthsBack 6 -CostTrend $data.CostTrend
        }
    }}
    @{ Name = 'Anomaly Alerts';             Script = { $data.AnomalyAlerts = Get-AnomalyAlerts -Subscriptions $subs } }
    @{ Name = 'Savings Realized';           Script = { $data.Savings       = Get-SavingsRealized -TenantId $tenantId -Subscriptions $subs -CommitmentData $data.Commitments } }
    @{ Name = 'Tag Recommendations';        Script = {
        $tagNames = if ($data.Tags) { $data.Tags.TagNames } else { @{} }
        $tagLocs  = if ($data.Tags) { $data.Tags.TagLocations } else { @{} }
        $data.TagRecs = Get-TagRecommendations -ExistingTags $tagNames -TagLocations $tagLocs
    }}
    @{ Name = 'Policy Inventory';           Script = { $data.PolicyInv     = Get-PolicyInventory -TenantId $tenantId -Subscriptions $subs } }
    @{ Name = 'Policy Recommendations';     Script = {
        $assignments = if ($data.PolicyInv) { $data.PolicyInv.Assignments } else { @() }
        $data.PolicyRecs = Get-PolicyRecommendations -ExistingAssignments $assignments
    }}
    @{ Name = 'Billing Structure';          Script = { $data.Billing       = Get-BillingStructure -Subscriptions $subs } }
)

$stepCount = $steps.Count
$completed = 0
$failed    = 0

foreach ($step in $steps) {
    $completed++
    Write-Output "[$completed/$stepCount] $($step.Name)..."
    try {
        & $step.Script
    } catch {
        $failed++
        Write-Warning "  $($step.Name) failed: $($_.Exception.Message)"
    }
}

# ── Serialize results ───────────────────────────────────────────────────
$scanDate = $scanStart.ToString('yyyy-MM-dd')
$scanTimestamp = $scanStart.ToString('yyyy-MM-ddTHH-mm-ss')

$result = @{
    scanDate     = $scanDate
    scanTime     = $scanStart.ToString('HH:mm:ss')
    tenantId     = $tenantId
    subCount     = $subs.Count
    stepsRun     = $completed
    stepsFailed  = $failed
    durationSec  = [math]::Round(((Get-Date) - $scanStart).TotalSeconds, 1)
    data         = @{}
}

$dataMap = @{
    'costs'          = { if ($data.Costs -and $data.Costs -is [hashtable]) { $data.Costs.GetEnumerator() | ForEach-Object { @{ SubscriptionId = [string]$_.Key; Actual = [double]($_.Value.Actual ?? 0); Forecast = [double]($_.Value.Forecast ?? 0); Currency = [string]($_.Value.Currency ?? 'USD') } } } }
    'budgets'        = { if ($data.Budgets -and $data.Budgets.Budgets) { $data.Budgets.Budgets } }
    'anomalyAlerts'  = { if ($data.AnomalyAlerts) { $data.AnomalyAlerts.TriggeredAlerts } }
    'anomalyRules'   = { if ($data.AnomalyAlerts) { $data.AnomalyAlerts.ConfiguredRules } }
    'optimization'   = { if ($data.Optimization -and $data.Optimization.Recommendations) { $data.Optimization.Recommendations } }
    'orphans'        = { if ($data.Orphans -and $data.Orphans.Resources) { $data.Orphans.Resources } }
    'idleVMs'        = { if ($data.IdleVMs) { $data.IdleVMs } }
    'storageTier'    = { if ($data.StorageTier) { $data.StorageTier } }
    'ahb'            = { if ($data.AHB -and $data.AHB.Opportunities) { $data.AHB.Opportunities } }
    'tags'           = { if ($data.Tags -and $data.Tags.TagNames) { $data.Tags.TagNames.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ TagName = $_.Key; ResourceCount = ($_.Value.ResourceCount ?? 0); UniqueValues = (($_.Value.Values) ? $_.Value.Values.Count : 0) } } } }
    'tagRecs'        = { if ($data.TagRecs -and $data.TagRecs.Recommendations) { $data.TagRecs.Recommendations } }
    'policyInv'      = { if ($data.PolicyInv -and $data.PolicyInv.Assignments) { $data.PolicyInv.Assignments } }
    'policyRecs'     = { if ($data.PolicyRecs -and $data.PolicyRecs.Analysis) { $data.PolicyRecs.Analysis } }
    'costTrend'      = { if ($data.CostTrend -and $data.CostTrend.Months) { $data.CostTrend.Months } }
    'commitments'    = { if ($data.Commitments -and $data.Commitments.Details) { $data.Commitments.Details } }
    'resourceCosts'  = { if ($data.ResourceCosts) { $data.ResourceCosts | Select-Object -First 500 } }
    'budgetHistory'  = { if ($data.BudgetHistory) { $data.BudgetHistory } }
}

foreach ($key in $dataMap.Keys) {
    try {
        $val = & $dataMap[$key]
        if ($val) { $result.data[$key] = @($val) }
    } catch {
        Write-Warning "  Serialization failed for $key : $($_.Exception.Message)"
    }
}

# ── Write to blob storage ──────────────────────────────────────────────
if ($storageAccountName) {
    Write-Output "Writing results to blob storage ($storageAccountName)..."
    try {
        $saCtx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        if (-not $saCtx) { throw "Failed to create storage context for '$storageAccountName'" }

        $container = Get-AzStorageContainer -Name $containerName -Context $saCtx -ErrorAction SilentlyContinue
        if (-not $container) {
            New-AzStorageContainer -Name $containerName -Context $saCtx -Permission Off | Out-Null
        }

        # Write full JSON scan
        try {
            $jsonBlob = "$scanDate/$scanTimestamp-scan.json"
            $jsonContent = ($result | ConvertTo-Json -Depth 20 -Compress)
            $jsonTmp = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($jsonTmp, $jsonContent, [System.Text.Encoding]::UTF8)
            Set-AzStorageBlobContent -Container $containerName -Blob $jsonBlob -BlobType Block `
                -Context $saCtx -File $jsonTmp -Force | Out-Null
            Remove-Item $jsonTmp -Force
            Write-Output "  Wrote: $jsonBlob ($([math]::Round($jsonContent.Length / 1024, 1)) KB)"
        } catch {
            Write-Warning "JSON blob write failed: $($_.Exception.Message)"
        }

        # Write per-module CSVs
        foreach ($key in $result.data.Keys) {
            $rows = $result.data[$key]
            if ($rows -and $rows.Count -gt 0) {
                try {
                    $csvBlob = "$scanDate/$scanTimestamp-$key.csv"
                    $csvContent = $rows | ConvertTo-Csv -NoTypeInformation | Out-String
                    $csvTmp = [System.IO.Path]::GetTempFileName()
                    [System.IO.File]::WriteAllText($csvTmp, $csvContent, [System.Text.Encoding]::UTF8)
                    Set-AzStorageBlobContent -Container $containerName -Blob $csvBlob -BlobType Block `
                        -Context $saCtx -File $csvTmp -Force | Out-Null
                    Remove-Item $csvTmp -Force
                    Write-Output "  Wrote: $csvBlob ($($rows.Count) rows)"
                } catch {
                    Write-Warning "CSV write failed for $key : $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Error "Blob storage write failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "FINOPS_STORAGE_ACCOUNT not configured. Set the Automation Variable."
}

# ── Push to Log Analytics (for Workbook dashboard) ──────────────────────
if ($dceEndpoint -and $dcrImmutableId) {
    Write-Output "Pushing results to Log Analytics..."
    $now = (Get-Date).ToUniversalTime().ToString('o')
    try {
        # Scan summary
        $totalActual = 0; $totalForecast = 0; $currency = 'USD'
        if ($data.Costs -and $data.Costs -is [hashtable]) {
            foreach ($v in $data.Costs.Values) {
                $totalActual   += $v.Actual
                $totalForecast += $v.Forecast
                $currency       = $v.Currency
            }
        }
        Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
            -StreamName 'Custom-FinOpsScanSummary_CL' -Records @(
                @{
                    TimeGenerated = $now
                    ScanDate      = $scanDate
                    TenantId_s    = $tenantId
                    SubCount      = [int]$subs.Count
                    StepsRun      = [int]$completed
                    StepsFailed   = [int]$failed
                    DurationSec   = [double]$result.durationSec
                    TotalActual   = [double]$totalActual
                    TotalForecast = [double]$totalForecast
                    Currency      = $currency
                }
            )
        Write-Output "  Sent: ScanSummary (1 record)"

        # Per-subscription costs
        if ($result.data.costs) {
            $costRecords = @($result.data.costs | ForEach-Object {
                $costItem = $_
                $subName = ($subs | Where-Object { $_.Id -eq $costItem.SubscriptionId } | Select-Object -First 1).Name
                @{
                    TimeGenerated    = $now
                    ScanDate         = $scanDate
                    SubscriptionId   = [string]$costItem.SubscriptionId
                    SubscriptionName = [string]($subName ?? $costItem.SubscriptionId)
                    Actual           = [double]$costItem.Actual
                    Forecast         = [double]$costItem.Forecast
                    Currency         = [string]$costItem.Currency
                }
            })
            Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName 'Custom-FinOpsCosts_CL' -Records $costRecords
            Write-Output "  Sent: Costs ($($costRecords.Count) records)"
        }

        # Resource costs (top 500)
        if ($result.data.resourceCosts) {
            $daysElapsed = [math]::Max(1, (Get-Date).Day)
            $rcRecords = @($result.data.resourceCosts | ForEach-Object {
                @{
                    TimeGenerated = $now
                    ScanDate      = $scanDate
                    ResourceName  = [string](($_.ResourcePath -split '/')[-1])
                    ResourceType  = [string]$_.ResourceType
                    ResourceGroup = [string]$_.ResourceGroup
                    Subscription  = [string]$_.Subscription
                    MonthlyCost   = [double]($_.Actual ?? 0)
                    DailyCost     = [double]([math]::Round(($_.Actual ?? 0) / $daysElapsed, 2))
                    Currency      = [string]($_.Currency ?? 'USD')
                }
            })
            Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName 'Custom-FinOpsResourceCosts_CL' -Records $rcRecords
            Write-Output "  Sent: ResourceCosts ($($rcRecords.Count) records)"
        }

        # Budgets
        if ($result.data.budgets) {
            $budgetRecords = @($result.data.budgets | ForEach-Object {
                @{
                    TimeGenerated = $now
                    ScanDate      = $scanDate
                    BudgetName    = [string]$_.BudgetName
                    Subscription  = [string]$_.Subscription
                    Amount        = [double]($_.Amount ?? 0)
                    ActualSpend   = [double]($_.ActualSpend ?? 0)
                    Forecast      = [double]($_.Forecast ?? 0)
                    PctUsed       = [double]($_.PctUsed ?? 0)
                    PctForecast   = [double]($_.PctForecast ?? 0)
                    RiskLevel     = [string]($_.RiskLevel ?? 'Unknown')
                    Currency      = [string]($_.Currency ?? 'USD')
                }
            })
            Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName 'Custom-FinOpsBudgets_CL' -Records $budgetRecords
            Write-Output "  Sent: Budgets ($($budgetRecords.Count) records)"
        }

        # Optimization opportunities (orphans, idleVMs, storageTier, ahb, optimization)
        $optRecords = [System.Collections.Generic.List[hashtable]]::new()
        if ($result.data.orphans) {
            foreach ($r in $result.data.orphans) {
                $optRecords.Add(@{
                    TimeGenerated    = $now;  ScanDate = $scanDate
                    Category         = 'Orphaned Resource'
                    ResourceName     = [string]($r.Name ?? $r.ResourceName ?? '')
                    ResourceType     = [string]($r.Type ?? $r.ResourceType ?? '')
                    ResourceGroup    = [string]($r.ResourceGroup ?? '')
                    Subscription     = [string]($r.Subscription ?? '')
                    Recommendation   = [string]($r.Reason ?? 'Orphaned — consider deleting')
                    PotentialSavings = [double]($r.MonthlyCost ?? 0)
                    Currency         = [string]($r.Currency ?? 'USD')
                })
            }
        }
        if ($result.data.idleVMs) {
            foreach ($r in $result.data.idleVMs) {
                $optRecords.Add(@{
                    TimeGenerated    = $now;  ScanDate = $scanDate
                    Category         = 'Idle VM'
                    ResourceName     = [string]($r.Name ?? $r.VMName ?? '')
                    ResourceType     = 'Virtual Machine'
                    ResourceGroup    = [string]($r.ResourceGroup ?? '')
                    Subscription     = [string]($r.Subscription ?? '')
                    Recommendation   = [string]($r.Reason ?? 'Low utilization — consider resizing or deallocating')
                    PotentialSavings = [double]($r.MonthlyCost ?? 0)
                    Currency         = [string]($r.Currency ?? 'USD')
                })
            }
        }
        if ($result.data.storageTier) {
            foreach ($r in $result.data.storageTier) {
                $optRecords.Add(@{
                    TimeGenerated    = $now;  ScanDate = $scanDate
                    Category         = 'Storage Tier'
                    ResourceName     = [string]($r.StorageAccount ?? $r.Name ?? '')
                    ResourceType     = 'Storage Account'
                    ResourceGroup    = [string]($r.ResourceGroup ?? '')
                    Subscription     = [string]($r.Subscription ?? '')
                    Recommendation   = [string]($r.Recommendation ?? 'Review access tier')
                    PotentialSavings = [double]($r.PotentialSavings ?? 0)
                    Currency         = [string]($r.Currency ?? 'USD')
                })
            }
        }
        if ($result.data.ahb) {
            foreach ($r in $result.data.ahb) {
                $optRecords.Add(@{
                    TimeGenerated    = $now;  ScanDate = $scanDate
                    Category         = 'Azure Hybrid Benefit'
                    ResourceName     = [string]($r.Name ?? $r.VMName ?? '')
                    ResourceType     = [string]($r.Type ?? $r.ResourceType ?? 'Virtual Machine')
                    ResourceGroup    = [string]($r.ResourceGroup ?? '')
                    Subscription     = [string]($r.Subscription ?? '')
                    Recommendation   = 'Enable Azure Hybrid Benefit'
                    PotentialSavings = [double]($r.PotentialSavings ?? 0)
                    Currency         = [string]($r.Currency ?? 'USD')
                })
            }
        }
        if ($result.data.optimization) {
            foreach ($r in $result.data.optimization) {
                $optRecords.Add(@{
                    TimeGenerated    = $now;  ScanDate = $scanDate
                    Category         = [string]($r.Category ?? 'Advisor')
                    ResourceName     = [string]($r.ResourceName ?? $r.Name ?? '')
                    ResourceType     = [string]($r.ResourceType ?? '')
                    ResourceGroup    = [string]($r.ResourceGroup ?? '')
                    Subscription     = [string]($r.Subscription ?? '')
                    Recommendation   = [string]($r.Recommendation ?? $r.ShortDescription ?? '')
                    PotentialSavings = [double]($r.PotentialSavings ?? $r.AnnualSavings ?? 0)
                    Currency         = [string]($r.Currency ?? 'USD')
                })
            }
        }
        if ($optRecords.Count -gt 0) {
            Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName 'Custom-FinOpsOptimization_CL' -Records $optRecords
            Write-Output "  Sent: Optimization ($($optRecords.Count) records)"
        }

        # Cost trend
        if ($result.data.costTrend) {
            $trendRecords = @($result.data.costTrend | ForEach-Object {
                @{
                    TimeGenerated = $now
                    ScanDate      = $scanDate
                    Month         = [string]($_.Month ?? '')
                    Amount        = [double]($_.Cost ?? 0)
                    Currency      = [string]($_.Currency ?? 'USD')
                }
            })
            Send-ToLogAnalytics -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId `
                -StreamName 'Custom-FinOpsCostTrend_CL' -Records $trendRecords
            Write-Output "  Sent: CostTrend ($($trendRecords.Count) records)"
        }
    } catch {
        Write-Warning "LAW ingestion failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "FINOPS_DCE_ENDPOINT or FINOPS_DCR_IMMUTABLE_ID not configured. Skipping LAW ingestion."
}

# ── Generate HTML report and upload to blob ─────────────────────────────
if ($storageAccountName) {
    Write-Output "Generating HTML assessment report..."
    try {
        $htmlContent = New-FinOpsHtmlReport -Data $data -Subscriptions $subs -TenantId $tenantId
        Write-Output "  Report generated ($([math]::Round($htmlContent.Length / 1024, 1)) KB)"

        # Upload to blob storage
        $saCtx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        $htmlBlob = "$scanDate/$scanTimestamp-report.html"
        $htmlTmp  = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($htmlTmp, $htmlContent, [System.Text.Encoding]::UTF8)
        Set-AzStorageBlobContent -Container $containerName -Blob $htmlBlob -BlobType Block `
            -Context $saCtx -File $htmlTmp -Force -Properties @{ ContentType = 'text/html' } | Out-Null
        Remove-Item $htmlTmp -Force
        Write-Output "  Uploaded: $htmlBlob"

        # Send email notification with attached report via Logic App webhook
        $webhookUrl = Get-AutomationVariable -Name 'FINOPS_REPORT_WEBHOOK' -ErrorAction SilentlyContinue
        if (-not $webhookUrl) { $webhookUrl = '' }
        if ($webhookUrl) {
            # Compute total spend for email payload
            if (-not $totalActual) {
                $totalActual = 0; $currency = 'USD'
                if ($data.Costs -is [hashtable]) {
                    foreach ($v in $data.Costs.Values) {
                        $totalActual += $v.Actual
                        $currency = $v.Currency
                    }
                }
            }
            # Base64-encode the HTML report for email attachment
            $reportBytes = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
            $reportBase64 = [Convert]::ToBase64String($reportBytes)

            $emailPayload = @{
                scanDate       = $scanDate
                tenantId       = $tenantId
                subCount       = $subs.Count
                totalSpend     = $totalActual
                currency       = $currency
                reportContent  = $reportBase64
                reportFileName = "$scanTimestamp-FinOps-Report.html"
            } | ConvertTo-Json -Compress
            Invoke-WebRequest -Uri $webhookUrl -Method POST -Body $emailPayload `
                -ContentType 'application/json' -UseBasicParsing | Out-Null
            Write-Output "  Email notification sent via webhook"
        } else {
            Write-Output "  FINOPS_REPORT_WEBHOOK not configured — skipping email delivery"
        }
    } catch {
        Write-Warning "HTML report generation failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "Skipping HTML report — no storage account configured."
}

# ── Summary ─────────────────────────────────────────────────────────────
$duration = [math]::Round(((Get-Date) - $scanStart).TotalSeconds, 1)
Write-Output ""
Write-Output "=== FinOps Scan complete ==="
Write-Output "  Subscriptions: $($subs.Count)"
Write-Output "  Steps: $completed run, $failed failed"
Write-Output "  Duration: $duration seconds"
Write-Output "  Data keys: $($result.data.Keys -join ', ')"
