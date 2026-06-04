###########################################################################
# INVOKE-AZRESTMETHODWITHRETRY.PS1
# HEADLESS VERSION - Azure Automation compatible (PS 7.2)
###########################################################################
# Purpose: Wrapper around Invoke-AzRestMethod with 429 throttle retry
#          and exponential backoff. Runs synchronously in the current
#          thread to preserve Az authentication context in PS 7.2.
###########################################################################

function Invoke-AzRestMethodWithRetry {
    param(
        [string]$Path,
        [string]$Method = 'POST',
        [string]$Payload,
        [int]$MaxRetries = 3,
        [int]$TimeoutSeconds = 60
    )
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $resp = $null
        try {
            $params = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
            if ($Payload) { $params['Payload'] = $Payload }
            $r = Invoke-AzRestMethod @params
            $hdrs = @{}
            if ($r.Headers) {
                foreach ($k in $r.Headers.Keys) { $hdrs[$k] = $r.Headers[$k] }
            }
            $resp = [PSCustomObject]@{
                StatusCode = $r.StatusCode
                Content    = $r.Content
                Headers    = $hdrs
            }
        } catch {
            throw
        }

        if (-not $resp) {
            $resp = [PSCustomObject]@{ StatusCode = 0; Content = $null; Headers = @{} }
        }
        if ($null -eq $resp.Content) {
            $resp = [PSCustomObject]@{ StatusCode = $resp.StatusCode; Content = '{}'; Headers = if ($resp.Headers) { $resp.Headers } else { @{} } }
        }

        if ($resp.StatusCode -ne 429) { return $resp }

        # 429 throttle — parse Retry-After or exponential backoff
        $retryAfter = 10
        if ($resp.Headers -and $resp.Headers['Retry-After']) {
            $parsed = 0
            if ([int]::TryParse($resp.Headers['Retry-After'], [ref]$parsed)) {
                $retryAfter = [math]::Max($parsed, 5)
            }
        } else {
            $retryAfter = [math]::Min(10 * [math]::Pow(2, $attempt), 60)
        }
        Write-Host "  [429 Throttled] Waiting $($retryAfter)s before retry ($($attempt+1)/$MaxRetries)..."

        if (Get-Command Update-ScanStatus -ErrorAction SilentlyContinue) {
            Update-ScanStatus "Rate limited - waiting $($retryAfter)s before retry ($($attempt+1)/$MaxRetries)..."
        }

        Start-Sleep -Seconds $retryAfter
    }
    return $resp
}
