###########################################################################
# GET-TENANTHIERARCHY.PS1
# AZURE FINOPS MULTITOOL - Management Group & Subscription Hierarchy
###########################################################################
# Purpose: Retrieve the full management group tree with subscriptions
#          nested under their parent groups.
###########################################################################

function Get-TenantHierarchy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter()]
        [object[]]$Subscriptions,

        [Parameter()]
        [int]$TimeoutSeconds = 60
    )

    try {
        # Run synchronously — no runspace needed in headless Azure Automation
        $rootGroup = Get-AzManagementGroup -GroupId $TenantId -Expand -Recurse -ErrorAction Stop

        if ($rootGroup) {
            $actual = if ($rootGroup -is [array]) { $rootGroup[0] } else { $rootGroup }
            $subMap = @{}
            Build-SubMap -Group $actual -Map ([ref]$subMap)
            return [PSCustomObject]@{
                RootGroup       = $actual
                SubscriptionMap = $subMap
            }
        }

        # Fallback
        $subs = if ($Subscriptions) { @($Subscriptions) } else {
            @(Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
        }
        $fallbackRoot = [PSCustomObject]@{
            DisplayName = "Tenant Root"
            Name        = $TenantId
            Children    = @()
        }
        return [PSCustomObject]@{
            RootGroup       = $fallbackRoot
            SubscriptionMap = @{}
            FlatSubs        = $subs
        }
    } catch {
        Write-Warning "Failed to load management group hierarchy: $($_.Exception.Message)"
        Write-Warning "Falling back to flat subscription list."

        $subs = if ($Subscriptions) { @($Subscriptions) } else {
            @(Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })
        }
        $fallbackRoot = [PSCustomObject]@{
            DisplayName = "Tenant Root"
            Name        = $TenantId
            Children    = @()
        }

        return [PSCustomObject]@{
            RootGroup       = $fallbackRoot
            SubscriptionMap = @{}
            FlatSubs        = $subs
        }
    }
}

function Build-SubMap {
    param(
        [object]$Group,
        [ref]$Map
    )

    if ($Group.Children) {
        foreach ($child in $Group.Children) {
            if ($child.Type -eq '/subscriptions') {
                $Map.Value[$child.Name] = $Group.DisplayName
            }
            elseif ($child.Children) {
                Build-SubMap -Group $child -Map $Map
            }
        }
    }
}
