###########################################################################
# SEARCH-AZGRAPHSAFE.PS1
# HEADLESS VERSION - Azure Automation compatible (PS 7.2)
###########################################################################
# Purpose: Wrapper around Search-AzGraph with 429 throttle retry.
#          Runs synchronously in the current thread to preserve Az
#          authentication context in PS 7.2 Azure Automation.
###########################################################################

function Search-AzGraphSafe {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Subscription,
        [int]$First = 1000,
        [string]$SkipToken,
        [int]$TimeoutSeconds = 60,
        [int]$MaxRetries = 2
    )
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $result = $null
        $is429  = $false
        try {
            $p = @{ Query = $Query; Subscription = $Subscription; First = $First; ErrorAction = 'Stop' }
            if ($SkipToken) { $p['SkipToken'] = [string]$SkipToken }
            $r = Search-AzGraph @p

            # v0.9.0 returns data directly; newer versions use .Data property
            $data = if ($null -ne $r.Data) { @($r.Data) }
                    elseif ($r -is [System.Collections.IEnumerable] -and $r -isnot [string]) { @($r) }
                    else { @() }

            # SkipToken may be string or object — coerce to string
            $st = $null
            if ($r.SkipToken) { $st = [string]$r.SkipToken }

            $result = [PSCustomObject]@{
                Data      = $data
                SkipToken = $st
                Count     = $data.Count
            }
        } catch {
            if ($_.Exception.Message -match '429|throttl|Too Many Requests') {
                $is429 = $true
            } else {
                throw
            }
        }

        if (-not $is429) { return $result }

        # 429 retry with exponential backoff
        $retryAfter = [math]::Min(10 * [math]::Pow(2, $attempt), 30)
        Write-Host "  [429 Throttled - Resource Graph] Waiting $($retryAfter)s before retry ($($attempt+1)/$MaxRetries)..."
        if (Get-Command Update-ScanStatus -ErrorAction SilentlyContinue) {
            Update-ScanStatus "Resource Graph rate limited - waiting $($retryAfter)s..."
        }
        Start-Sleep -Seconds $retryAfter
    }
    return $null
}
