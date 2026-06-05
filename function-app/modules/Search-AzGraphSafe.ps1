###########################################################################
# SEARCH-AZGRAPHSAFE.PS1
# HEADLESS VERSION - Azure Automation compatible (PS 7.2)
###########################################################################
# Purpose: Query Azure Resource Graph via the REST API (Invoke-AzRestMethod)
#          with 429 throttle retry. Runs synchronously in the current thread
#          to preserve the managed-identity Az context in PS 7.2 Automation.
#
# Description:
# Why REST instead of the Search-AzGraph cmdlet:
# In the Azure Automation PS 7.2 sandbox the Search-AzGraph cmdlet returns an
# object array whose row elements deserialize to $null - projected columns are
# unreachable, leaving report fields (resource name, resource group, etc.)
# blank. Calling the Resource Graph REST endpoint with resultFormat=objectArray
# returns clean JSON that ConvertFrom-Json turns into PSCustomObjects with every
# column as a property, including nested values like row.properties.displayName.
#
# Returns a PSCustomObject with Data (row array), SkipToken (string or $null)
# and Count, matching the shape the calling modules already expect.
###########################################################################

function Search-AzGraphSafe {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [string]$SkipToken,
        [int]$TimeoutSeconds = 60,
        [int]$MaxRetries = 3
    )

    $apiVersion = '2022-10-01'
    $uri = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=$apiVersion"

    $options = @{ '$top' = $First; 'resultFormat' = 'objectArray' }
    if ($SkipToken) { $options['$skipToken'] = $SkipToken }

    $bodyObj = @{ query = $Query; options = $options }
    if ($Subscription -and $Subscription.Count -gt 0) {
        $bodyObj['subscriptions'] = @($Subscription)
    }
    $payload = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $resp = Invoke-AzRestMethod -Method POST -Uri $uri -Payload $payload -ErrorAction Stop

            if ($resp.StatusCode -eq 429) {
                $retryAfter = [math]::Min(10 * [math]::Pow(2, $attempt), 30)
                Write-Host "  [429 Throttled - Resource Graph] Waiting $($retryAfter)s before retry ($($attempt+1)/$MaxRetries)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            if ($resp.StatusCode -ge 400) {
                throw "Resource Graph REST error $($resp.StatusCode): $($resp.Content)"
            }

            $parsed = $resp.Content | ConvertFrom-Json
            $data = if ($parsed.data) { @($parsed.data) } else { @() }

            $st = $null
            if ($parsed.PSObject.Properties.Name -contains '$skipToken') {
                $st = [string]$parsed.'$skipToken'
            }

            return [PSCustomObject]@{
                Data      = $data
                SkipToken = $st
                Count     = $data.Count
            }
        }
        catch {
            $msg = $_.Exception.Message
            if (($msg -match '429|throttl|Too Many Requests') -and $attempt -lt $MaxRetries) {
                $retryAfter = [math]::Min(10 * [math]::Pow(2, $attempt), 30)
                Write-Host "  [429 Throttled - Resource Graph] Waiting $($retryAfter)s before retry ($($attempt+1)/$MaxRetries)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            throw
        }
    }
    return $null
}
