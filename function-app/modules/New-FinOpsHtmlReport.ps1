###########################################################################
# NEW-FINOPSHTMLREPORT.PS1
# GENERATES A PROFESSIONAL HTML FINOPS ASSESSMENT REPORT
###########################################################################
# Purpose: Produce a self-contained HTML report from scan pipeline data.
#          Used by the automation runbook to create stakeholder-ready
#          reports that can be emailed or stored in blob storage.
# Author:  Zac Larsen
# Date:    Created for automated report delivery pipeline
#
# Description:
#   1. Computes a FinOps Maturity Score (0-100) across five categories
#   2. Generates a 9-section HTML assessment with CSS-embedded styling
#   3. Returns the HTML string for the caller to persist or deliver
#
# ── Parameters ──────────────────────────────────────────────────
# Data               Hashtable from the scan pipeline ($data)
# Subscriptions      Array of subscription objects (Id, Name)
# TenantId           Azure tenant ID string
#
# Output: [string] Complete HTML document
###########################################################################

function New-FinOpsHtmlReport {
    param(
        [hashtable]$Data,
        [object[]]$Subscriptions,
        [string]$TenantId
    )

    $esc = [System.Security.SecurityElement]

    # ── Currency helper ─────────────────────────────────────────────────
    $sym = '$'
    if ($Data.ResourceCosts -and $Data.ResourceCosts.Count -gt 0) {
        $sym = Get-CurrencySymbol -Code $Data.ResourceCosts[0].Currency
    }

    # ── Compute FinOps Maturity Score (0-100) ───────────────────────────
    # Based on FinOps Foundation Maturity Model + Microsoft CAF
    # Categories: Visibility (25), Allocation (20), Budgeting (15),
    #             Optimization (20), Governance (20)
    $score = 0
    $breakdown = @{}

    # Visibility (25 pts)
    $visScore = 0
    if ($Data.Tags) {
        $visScore += [math]::Min([math]::Floor($Data.Tags.TagCoverage / 10), 10)
    }
    if ($Data.Costs -and $Data.Costs.Count -gt 0) { $visScore += 5 }
    if ($Data.CostTrend -and $Data.CostTrend.HasData) { $visScore += 5 }
    if ($Data.ResourceCosts -and $Data.ResourceCosts.Count -gt 0) { $visScore += 5 }
    $breakdown['Visibility'] = [math]::Min($visScore, 25)
    $score += $breakdown['Visibility']

    # Allocation (20 pts)
    $allocScore = 0
    if ($Data.Tags -and $Data.Tags.TagNames) {
        $lcKeys = $Data.Tags.TagNames.Keys | ForEach-Object { $_.ToLower() }
        $tagWeights = @{
            'CostCenter'          = @{ Weight = 3; Alts = @('costcenter', 'cost-center', 'cost_center', 'cc') }
            'BusinessUnit'        = @{ Weight = 3; Alts = @('businessunit', 'bu', 'business-unit', 'department', 'dept') }
            'ApplicationName'     = @{ Weight = 2; Alts = @('applicationname', 'application', 'app', 'appname') }
            'WorkloadName'        = @{ Weight = 1; Alts = @('workloadname', 'workload', 'workload-name') }
            'OpsTeam'             = @{ Weight = 1; Alts = @('opsteam', 'ops-team', 'ops_team', 'owner', 'technicalowner') }
            'Criticality'         = @{ Weight = 1; Alts = @('criticality', 'sla', 'tier') }
            'DataClassification'  = @{ Weight = 1; Alts = @('dataclassification', 'data-classification', 'classification') }
        }
        foreach ($tag in $tagWeights.Keys) {
            $allNames = @($tag.ToLower()) + $tagWeights[$tag].Alts
            if ($lcKeys | Where-Object { $_ -in $allNames }) {
                $allocScore += $tagWeights[$tag].Weight
            }
        }
    }
    if ($Data.CostByTag -and -not $Data.CostByTag.NoTagsFound -and $Data.CostByTag.CostByTag.Count -gt 0) { $allocScore += 4 }
    if ($Data.Billing -and $Data.Billing.CostAllocationRules -and $Data.Billing.CostAllocationRules.Count -gt 0) { $allocScore += 4 }
    $breakdown['Allocation'] = [math]::Min($allocScore, 20)
    $score += $breakdown['Allocation']

    # Budgeting (15 pts)
    $budgetScore = 0
    if ($Data.Budgets -and $Data.Budgets.HasData) { $budgetScore += 5 }
    if ($Data.Budgets) {
        $budgetScore += [math]::Min([math]::Floor($Data.Budgets.BudgetCoverage / 20), 5)
    }
    if ($Data.Budgets -and $Data.Budgets.HasData) {
        if ($Data.Budgets.OverBudgetCount -eq 0) { $budgetScore += 5 }
        elseif ($Data.Budgets.AtRiskCount -eq 0) { $budgetScore += 3 }
    }
    $breakdown['Budgeting'] = [math]::Min($budgetScore, 15)
    $score += $breakdown['Budgeting']

    # Optimization (20 pts)
    $optScore = 0
    if ($Data.Commitments -and $Data.Commitments.HasData) {
        if ($Data.Commitments.RIAvgUtilization -ge 80) { $optScore += 5 }
        elseif ($Data.Commitments.RIAvgUtilization -ge 60) { $optScore += 3 }
    } else { $optScore += 2 }
    if ($Data.Savings -and $Data.Savings.TotalMonthly -gt 0) { $optScore += 5 }
    if ($Data.Optimization) {
        if ($Data.Optimization.TotalCount -eq 0) { $optScore += 5 }
        elseif ($Data.Optimization.TotalCount -le 3) { $optScore += 3 }
        elseif ($Data.Optimization.TotalCount -le 10) { $optScore += 1 }
    } else { $optScore += 2 }
    if ($Data.Orphans) {
        $orphanTotal = if ($Data.Orphans.TotalCount) { $Data.Orphans.TotalCount } else { 0 }
        if ($orphanTotal -eq 0) { $optScore += 5 }
        elseif ($orphanTotal -le 3) { $optScore += 3 }
        elseif ($orphanTotal -le 10) { $optScore += 1 }
    } else { $optScore += 2 }
    $breakdown['Optimization'] = [math]::Min($optScore, 20)
    $score += $breakdown['Optimization']

    # Governance (20 pts)
    $govScore = 0
    if ($Data.PolicyInv -and $Data.PolicyInv.AssignmentCount -gt 0) { $govScore += 5 }
    if ($Data.PolicyRecs) {
        $policyPct = if ($Data.PolicyRecs.Analysis.Count -gt 0) {
            [math]::Round(($Data.PolicyRecs.Assigned.Count / $Data.PolicyRecs.Analysis.Count) * 100, 0)
        } else { 0 }
        $govScore += [math]::Min([math]::Floor($policyPct / 20), 5)
    }
    if ($Data.PolicyInv -and $Data.PolicyInv.CompliancePct -ge 80) { $govScore += 5 }
    elseif ($Data.PolicyInv -and $Data.PolicyInv.CompliancePct -ge 50) { $govScore += 3 }
    if ($Data.Hierarchy -and $Data.Hierarchy.RootGroup) { $govScore += 5 }
    elseif ($Data.Hierarchy -and $Data.Hierarchy.FlatSubs) { $govScore += 2 }
    $breakdown['Governance'] = [math]::Min($govScore, 20)
    $score += $breakdown['Governance']

    $score = [math]::Min($score, 100)

    $gradeLabel = switch ($true) {
        ($score -ge 85) { 'Excellent'; break }
        ($score -ge 70) { 'Good'; break }
        ($score -ge 50) { 'Developing'; break }
        ($score -ge 30) { 'Foundational'; break }
        default { 'Getting Started' }
    }
    $gradeColor = switch ($true) {
        ($score -ge 85) { '#107C10'; break }
        ($score -ge 70) { '#0078D4'; break }
        ($score -ge 50) { '#8764B8'; break }
        ($score -ge 30) { '#FF8C00'; break }
        default { '#D13438' }
    }

    # ── Total spend ─────────────────────────────────────────────────────
    $totalActual = 0.0; $totalForecast = 0.0
    if ($Data.Costs -is [hashtable]) {
        foreach ($k in $Data.Costs.Keys) {
            $totalActual += [double]($Data.Costs[$k].Actual ?? 0)
            $totalForecast += [double]($Data.Costs[$k].Forecast ?? 0)
        }
    }

    # ── Build HTML ──────────────────────────────────────────────────────
    $sb = [System.Text.StringBuilder]::new(32768)
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>Azure FinOps Assessment Report</title>
<style>
@media print { @page { margin: 0.5in; size: letter; } .no-print { display: none; } .page-break { page-break-before: always; } }
* { box-sizing: border-box; }
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px 40px; color: #333; line-height: 1.5; background: #fff; }
.header { background: linear-gradient(135deg, #0078D4, #005A9E); color: #fff; padding: 30px 40px; margin: -20px -40px 30px -40px; }
.header h1 { margin: 0 0 8px 0; font-size: 28px; font-weight: 600; }
.header p { margin: 0; opacity: 0.9; font-size: 13px; }
.header .subtitle { font-size: 14px; margin-top: 4px; opacity: 0.85; }
h2 { color: #0078D4; font-size: 20px; border-bottom: 2px solid #0078D4; padding-bottom: 6px; margin-top: 35px; }
h3 { color: #333; font-size: 16px; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 20px 0; font-size: 12px; }
th { background: #0078D4; color: #fff; padding: 8px 10px; text-align: left; font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.3px; }
td { padding: 7px 10px; border-bottom: 1px solid #e8e8e8; }
tr:nth-child(even) { background: #f9f9f9; }
tr:hover { background: #EBF5FF; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 15px 0; }
.card { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 16px 20px; min-width: 160px; flex: 1; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.card .label { color: #777; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
.card .value { font-size: 26px; font-weight: 700; margin: 4px 0; }
.card .detail { font-size: 11px; color: #999; }
.score-badge { display: inline-block; background: $gradeColor; color: #fff; padding: 8px 20px; border-radius: 6px; font-size: 28px; font-weight: 700; }
.score-label { display: inline-block; font-size: 18px; color: $gradeColor; font-weight: 600; margin-left: 12px; vertical-align: middle; }
.score-bar { height: 8px; border-radius: 4px; margin: 4px 0; }
.score-bar-bg { background: #e8e8e8; }
.score-bar-fill { background: $gradeColor; }
.status-good { color: #107C10; font-weight: 600; }
.status-warn { color: #D83B01; font-weight: 600; }
.status-info { color: #0078D4; font-weight: 600; }
.status-missing { color: #E81123; }
.status-assigned { color: #107C10; }
.text-right { text-align: right; }
.text-muted { color: #999; font-size: 11px; }
footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #ddd; font-size: 11px; color: #999; text-align: center; }
.toc { background: #f5f8fc; padding: 20px; border-radius: 6px; margin: 15px 0; }
.toc a { color: #0078D4; text-decoration: none; font-size: 13px; display: block; padding: 3px 0; }
.toc a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class="header">
<h1>Azure FinOps Assessment Report</h1>
<p class="subtitle">Tenant: $($esc::Escape($TenantId))</p>
<p>Generated: $(Get-Date -Format 'MMMM d, yyyy h:mm tt') &nbsp;|&nbsp; Subscriptions scanned: $($Subscriptions.Count)</p>
</div>

<div class="toc">
<strong>Contents</strong>
<a href="#executive-summary">1. Executive Summary</a>
<a href="#maturity-score">2. FinOps Maturity Score</a>
<a href="#cost-overview">3. Cost Overview</a>
<a href="#cost-trend">4. 6-Month Cost Trend</a>
<a href="#resource-costs">5. Top Resource Costs</a>
<a href="#tagging">6. Tag Compliance</a>
<a href="#policy">7. Policy Compliance</a>
<a href="#optimization">8. Optimization Opportunities</a>
<a href="#budgets">9. Budget Status</a>
</div>
"@)

    # ── 1. Executive Summary ────────────────────────────────────────────
    [void]$sb.Append(@"
<h2 id="executive-summary">1. Executive Summary</h2>
<div class="cards">
<div class="card"><div class="label">Total Spend (MTD)</div><div class="value" style="color:#0078D4">$sym$($totalActual.ToString('N2'))</div><div class="detail">Forecast: $sym$($totalForecast.ToString('N2'))</div></div>
<div class="card"><div class="label">FinOps Maturity</div><div class="value" style="color:$gradeColor">$score / 100</div><div class="detail">$gradeLabel</div></div>
<div class="card"><div class="label">Subscriptions</div><div class="value" style="color:#0078D4">$($Subscriptions.Count)</div><div class="detail">Scanned</div></div>
"@)
    if ($Data.Tags) {
        $tagCoverageColor = if ($Data.Tags.TagCoverage -ge 80) { '#107C10' } elseif ($Data.Tags.TagCoverage -ge 50) { '#D83B01' } else { '#E81123' }
        [void]$sb.Append("<div class=`"card`"><div class=`"label`">Tag Coverage</div><div class=`"value`" style=`"color:$tagCoverageColor`">$([math]::Round($Data.Tags.TagCoverage,1))%</div><div class=`"detail`">$($Data.Tags.TaggedCount) of $($Data.Tags.TotalResources) resources</div></div>")
    }
    if ($Data.PolicyInv) {
        $polColor = if ($Data.PolicyInv.CompliancePct -ge 80) { '#107C10' } elseif ($Data.PolicyInv.CompliancePct -ge 50) { '#D83B01' } else { '#E81123' }
        [void]$sb.Append("<div class=`"card`"><div class=`"label`">Policy Compliance</div><div class=`"value`" style=`"color:$polColor`">$([math]::Round($Data.PolicyInv.CompliancePct,1))%</div><div class=`"detail`">$($Data.PolicyInv.TotalNonCompliant) non-compliant</div></div>")
    }
    $optTotal = 0
    if ($Data.Orphans) { $optTotal += $Data.Orphans.TotalCount }
    if ($Data.AHB) { $optTotal += $Data.AHB.TotalOpportunities }
    if ($Data.Optimization) { $optTotal += $Data.Optimization.TotalCount }
    [void]$sb.Append("<div class=`"card`"><div class=`"label`">Optimizations Found</div><div class=`"value`" style=`"color:#D83B01`">$optTotal</div><div class=`"detail`">AHB + Orphans + Advisor</div></div>")
    [void]$sb.Append("</div>")

    # ── 2. Maturity Score ───────────────────────────────────────────────
    [void]$sb.Append(@"
<h2 id="maturity-score">2. FinOps Maturity Score</h2>
<div style="margin:15px 0;">
<span class="score-badge">$score</span>
<span class="score-label">$gradeLabel</span>
</div>
<p class="text-muted">Score based on FinOps Foundation Maturity Model and Microsoft Cloud Adoption Framework. Categories: Visibility (25), Allocation (20), Budgeting (15), Optimization (20), Governance (20).</p>
<div style="margin:15px 0;">
"@)
    foreach ($cat in @('Visibility','Allocation','Budgeting','Optimization','Governance')) {
        $catMax = switch ($cat) { 'Visibility' { 25 } 'Allocation' { 20 } 'Budgeting' { 15 } default { 20 } }
        $catVal = if ($breakdown.ContainsKey($cat)) { $breakdown[$cat] } else { 0 }
        $pct = if ($catMax -gt 0) { [math]::Round(($catVal / $catMax) * 100) } else { 0 }
        [void]$sb.Append("<div style=`"margin:8px 0;`"><strong>$cat</strong> <span style=`"color:#0078D4;`">$catVal / $catMax</span><div class=`"score-bar score-bar-bg`"><div class=`"score-bar score-bar-fill`" style=`"width:${pct}%;`"></div></div></div>")
    }
    [void]$sb.Append("</div>")

    # ── 3. Cost Overview ────────────────────────────────────────────────
    [void]$sb.Append(@"
<h2 id="cost-overview">3. Cost Overview by Subscription</h2>
<table>
<tr><th>Subscription</th><th>Subscription ID</th><th class="text-right">Actual (MTD)</th><th class="text-right">Forecast</th><th class="text-right">Tag Coverage</th><th>Budget Status</th><th>Cost Trend</th></tr>
"@)
    foreach ($sub in $Subscriptions | Sort-Object { if ($Data.Costs -is [hashtable] -and $Data.Costs.ContainsKey($_.Id)) { $Data.Costs[$_.Id].Actual } else { 0 } } -Descending) {
        $c = if ($Data.Costs -is [hashtable] -and $Data.Costs.ContainsKey($sub.Id)) { $Data.Costs[$sub.Id] } else { @{ Actual = 0; Forecast = 0 } }

        # Tag coverage per subscription
        $tagPct = '-'
        if ($Data.Tags -and $Data.Tags.RawResults) {
            $subRes = @($Data.Tags.RawResults | Where-Object { $_.subscriptionId -eq $sub.Id })
            if ($subRes.Count -gt 0) {
                $tagged = @($subRes | Where-Object { $_.tags -and $_.tags.PSObject.Properties.Count -gt 0 }).Count
                $tagPct = "$([math]::Round(($tagged / $subRes.Count) * 100, 1))%"
            }
        }

        # Budget status
        $budgetTxt = '-'
        if ($Data.Budgets -and $Data.Budgets.Budgets) {
            $subBudgets = @($Data.Budgets.Budgets | Where-Object { $_.SubscriptionId -eq $sub.Id })
            if ($subBudgets.Count -gt 0) {
                $worstRisk = ($subBudgets | Sort-Object PctUsed -Descending | Select-Object -First 1).Risk
                $budgetTxt = $worstRisk
            } else { $budgetTxt = 'No Budget' }
        }
        $budgetClass = switch ($budgetTxt) { 'Over Budget' { 'status-warn' } 'At Risk' { 'status-warn' } 'On Track' { 'status-good' } default { 'text-muted' } }

        # Cost trend
        $trendTxt = '-'
        if ($Data.CostTrend -and $Data.CostTrend.HasData -and $Data.CostTrend.Months.Count -ge 2) {
            $last = $Data.CostTrend.Months[-1].Cost; $prev = $Data.CostTrend.Months[-2].Cost
            if ($prev -gt 0) {
                $pctChg = [math]::Round((($last - $prev) / $prev) * 100, 1)
                $trendTxt = if ($pctChg -gt 5) { "Up $pctChg%" } elseif ($pctChg -lt -5) { "Down $([math]::Abs($pctChg))%" } else { 'Stable' }
            }
        }

        [void]$sb.Append("<tr><td><strong>$($esc::Escape($sub.Name))</strong></td><td class=`"text-muted`">$($sub.Id)</td>")
        [void]$sb.Append("<td class=`"text-right`">$sym$(([double]($c.Actual ?? 0)).ToString('N2'))</td><td class=`"text-right`">$sym$(([double]($c.Forecast ?? 0)).ToString('N2'))</td>")
        [void]$sb.Append("<td class=`"text-right`">$tagPct</td><td class=`"$budgetClass`">$budgetTxt</td><td>$trendTxt</td></tr>")
    }
    [void]$sb.Append("<tr style=`"font-weight:700;background:#EBF5FF;`"><td>Total</td><td></td><td class=`"text-right`">$sym$($totalActual.ToString('N2'))</td><td class=`"text-right`">$sym$($totalForecast.ToString('N2'))</td><td></td><td></td><td></td></tr>")
    [void]$sb.Append("</table>")

    # ── 4. Cost Trend ───────────────────────────────────────────────────
    [void]$sb.Append('<h2 id="cost-trend">4. 6-Month Cost Trend</h2>')
    if ($Data.CostTrend -and $Data.CostTrend.HasData -and $Data.CostTrend.Months.Count -gt 0) {
        [void]$sb.Append('<h3>All Subscriptions</h3>')
        $months = $Data.CostTrend.Months
        $maxCost = ($months | Measure-Object -Property Cost -Maximum).Maximum
        if ($maxCost -le 0) { $maxCost = 1 }
        [void]$sb.Append("<table><tr><th>Month</th><th class=`"text-right`">Spend</th><th>Bar</th></tr>")
        foreach ($m in $months) {
            $barW = [math]::Round((([double]($m.Cost ?? 0)) / $maxCost) * 100)
            [void]$sb.Append("<tr><td>$($esc::Escape($m.Month))</td><td class=`"text-right`">$sym$(([double]($m.Cost ?? 0)).ToString('N2'))</td>")
            [void]$sb.Append("<td><div style=`"background:linear-gradient(90deg,#0078D4,#005A9E);height:18px;width:${barW}%;border-radius:3px;min-width:2px;`"></div></td></tr>")
        }
        [void]$sb.Append("</table>")

        # Per-subscription trends
        if ($Data.CostTrend.BySubscription -and $Data.CostTrend.BySubscription.Count -gt 0 -and $Subscriptions.Count -gt 1) {
            foreach ($sub in $Subscriptions) {
                if ($Data.CostTrend.BySubscription -is [hashtable] -and $Data.CostTrend.BySubscription.ContainsKey($sub.Id)) {
                    $subMonths = $Data.CostTrend.BySubscription[$sub.Id]
                    if ($subMonths.Count -gt 0) {
                        $subMax = ($subMonths | Measure-Object -Property Cost -Maximum).Maximum
                        if ($subMax -le 0) { $subMax = 1 }
                        [void]$sb.Append("<h3>$($esc::Escape($sub.Name))</h3>")
                        [void]$sb.Append("<table><tr><th>Month</th><th class=`"text-right`">Spend</th><th>Bar</th></tr>")
                        foreach ($sm in $subMonths) {
                            $bw = [math]::Round((([double]($sm.Cost ?? 0)) / $subMax) * 100)
                            [void]$sb.Append("<tr><td>$($esc::Escape($sm.Month))</td><td class=`"text-right`">$sym$(([double]($sm.Cost ?? 0)).ToString('N2'))</td>")
                            [void]$sb.Append("<td><div style=`"background:linear-gradient(90deg,#2B88D8,#0063B1);height:18px;width:${bw}%;border-radius:3px;min-width:2px;`"></div></td></tr>")
                        }
                        [void]$sb.Append("</table>")
                    }
                }
            }
        }
    } else {
        [void]$sb.Append('<p class="text-muted">No cost trend data available.</p>')
    }

    # ── 5. Resource Costs ───────────────────────────────────────────────
    [void]$sb.Append('<div class="page-break"></div><h2 id="resource-costs">5. Top Resource Costs</h2>')
    if ($Data.ResourceCosts -and $Data.ResourceCosts.Count -gt 0) {
        $topResources = $Data.ResourceCosts | Sort-Object Actual -Descending | Select-Object -First 50
        [void]$sb.Append("<p class=`"text-muted`">Showing top $([math]::Min(50, $Data.ResourceCosts.Count)) of $($Data.ResourceCosts.Count) resources by MTD cost.</p>")
        [void]$sb.Append("<table><tr><th>Resource</th><th>Type</th><th>Resource Group</th><th>Subscription</th><th class=`"text-right`">Actual (MTD)</th><th class=`"text-right`">Forecast</th></tr>")
        foreach ($r in $topResources) {
            $resName = ($r.ResourcePath -split '/')[-1]
            [void]$sb.Append("<tr><td><strong>$($esc::Escape($resName))</strong></td><td>$($esc::Escape($r.ResourceType))</td>")
            [void]$sb.Append("<td>$($esc::Escape($r.ResourceGroup))</td><td>$($esc::Escape($r.Subscription))</td>")
            [void]$sb.Append("<td class=`"text-right`">$sym$(([double]($r.Actual ?? 0)).ToString('N2'))</td><td class=`"text-right`">$sym$(([double]($r.Forecast ?? 0)).ToString('N2'))</td></tr>")
        }
        [void]$sb.Append("</table>")
    } else {
        [void]$sb.Append('<p class="text-muted">No resource-level cost data available.</p>')
    }

    # ── 6. Tag Compliance ───────────────────────────────────────────────
    [void]$sb.Append('<h2 id="tagging">6. Tag Compliance</h2>')
    if ($Data.Tags) {
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Tag Coverage</div><div class="value" style="color:#0078D4">$([math]::Round($Data.Tags.TagCoverage,1))%</div><div class="detail">$($Data.Tags.TaggedCount) tagged / $($Data.Tags.TotalResources) total</div></div>
<div class="card"><div class="label">Unique Tags</div><div class="value" style="color:#0078D4">$($Data.Tags.TagCount)</div><div class="detail">Distinct tag names</div></div>
<div class="card"><div class="label">Untagged Resources</div><div class="value" style="color:#D83B01">$($Data.Tags.UntaggedCount)</div></div>
</div>
"@)
        # Tag inventory table
        if ($Data.Tags.TagNames -and $Data.Tags.TagNames.Count -gt 0) {
            [void]$sb.Append("<h3>Tag Inventory ($($Data.Tags.TagNames.Count) tags)</h3>")
            [void]$sb.Append('<table><tr><th>Tag Name</th><th class="text-right">Resources</th><th class="text-right">Unique Values</th><th>Applied In</th><th>Sample Values</th></tr>')
            foreach ($entry in $Data.Tags.TagNames.GetEnumerator() | Sort-Object { $_.Value.TotalResources } -Descending) {
                $allValues = @($entry.Value.Values | ForEach-Object { $_.Value })
                $sampleValues = ($allValues | Select-Object -First 5) -join ', '
                if ($allValues.Count -gt 5) { $sampleValues += ", ... (+$($allValues.Count - 5) more)" }
                # Show where this tag is applied (sub / RG)
                $appliedIn = '-'
                if ($Data.Tags.TagLocations -and $Data.Tags.TagLocations.ContainsKey($entry.Key)) {
                    $locs = @($Data.Tags.TagLocations[$entry.Key])
                    $shown = ($locs | Select-Object -First 3) -join '; '
                    if ($locs.Count -gt 3) { $shown += " (+$($locs.Count - 3) more)" }
                    $appliedIn = $shown
                }
                [void]$sb.Append("<tr><td><strong>$($esc::Escape($entry.Key))</strong></td><td class=`"text-right`">$($entry.Value.TotalResources)</td><td class=`"text-right`">$($allValues.Count)</td><td>$($esc::Escape($appliedIn))</td><td>$($esc::Escape($sampleValues))</td></tr>")
            }
            [void]$sb.Append('</table>')
        }
        # CAF recommended tags
        if ($Data.TagRecs) {
            [void]$sb.Append("<h3>Microsoft CAF Recommended Tags</h3>")
            [void]$sb.Append("<table><tr><th>Tag Name</th><th>Status</th><th>Location</th><th>Purpose</th></tr>")
            foreach ($tr in $Data.TagRecs.Analysis) {
                $statusCls = if ($tr.Status -eq 'Present') { 'status-assigned' } else { 'status-missing' }
                $locText = if ($tr.Location) { $esc::Escape($tr.Location) } else { '-' }
                [void]$sb.Append("<tr><td><strong>$($esc::Escape($tr.TagName))</strong></td><td class=`"$statusCls`">$($tr.Status)</td><td>$locText</td><td>$($esc::Escape($tr.Purpose))</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        # Untagged resources
        if ($Data.Tags.UntaggedResources -and $Data.Tags.UntaggedResources.Count -gt 0) {
            $utShown = $Data.Tags.UntaggedResources.Count
            $utTotal = $Data.Tags.UntaggedCount
            $utNote  = if ($utShown -lt $utTotal) { " (showing $utShown of $utTotal)" } else { "" }
            [void]$sb.Append("<h3>Untagged Resources$utNote</h3>")
            [void]$sb.Append("<table><tr><th>Resource Name</th><th>Resource Type</th><th>Resource Group</th><th>Subscription</th><th>Location</th></tr>")
            foreach ($ur in $Data.Tags.UntaggedResources) {
                [void]$sb.Append("<tr><td>$($esc::Escape($ur.ResourceName))</td><td>$($esc::Escape($ur.ResourceType))</td><td>$($esc::Escape($ur.ResourceGroup))</td><td>$($esc::Escape($ur.Subscription))</td><td>$($esc::Escape($ur.Location))</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    } else {
        [void]$sb.Append('<p class="text-muted">No tag data available.</p>')
    }

    # ── 7. Policy Compliance ────────────────────────────────────────────
    [void]$sb.Append('<div class="page-break"></div><h2 id="policy">7. Policy Compliance</h2>')
    if ($Data.PolicyInv) {
        $polCompColor = if ($Data.PolicyInv.CompliancePct -ge 80) { '#107C10' } else { '#D83B01' }
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Policy Assignments</div><div class="value" style="color:#0078D4">$($Data.PolicyInv.AssignmentCount)</div></div>
<div class="card"><div class="label">Compliance</div><div class="value" style="color:$polCompColor">$([math]::Round($Data.PolicyInv.CompliancePct,1))%</div></div>
<div class="card"><div class="label">Non-Compliant Resources</div><div class="value" style="color:#D83B01">$($Data.PolicyInv.TotalNonCompliant)</div></div>
</div>
"@)
        # Per-subscription compliance
        if ($Data.PolicyInv.ComplianceBySubMap -and $Data.PolicyInv.ComplianceBySubMap.Count -gt 0) {
            [void]$sb.Append("<h3>Per-Subscription Compliance</h3><table><tr><th>Subscription</th><th class=`"text-right`">Compliant</th><th class=`"text-right`">Non-Compliant</th><th class=`"text-right`">Total</th><th class=`"text-right`">Compliance %</th></tr>")
            foreach ($sk in $Data.PolicyInv.ComplianceBySubMap.Keys) {
                $cs = $Data.PolicyInv.ComplianceBySubMap[$sk]
                $cpct = if (($cs.Compliant + $cs.NonCompliant) -gt 0) { [math]::Round(($cs.Compliant / ($cs.Compliant + $cs.NonCompliant)) * 100, 1) } else { 0 }
                [void]$sb.Append("<tr><td>$($esc::Escape($cs.Subscription))</td><td class=`"text-right`">$($cs.Compliant)</td><td class=`"text-right`">$($cs.NonCompliant)</td><td class=`"text-right`">$($cs.TotalResources)</td><td class=`"text-right`">$cpct%</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
        # Policy assignment inventory
        if ($Data.PolicyInv.Assignments -and $Data.PolicyInv.Assignments.Count -gt 0) {
            [void]$sb.Append("<h3>Policy Assignment Inventory ($($Data.PolicyInv.Assignments.Count) assignments)</h3>")
            [void]$sb.Append('<table><tr><th>Assignment Name</th><th>Type</th><th>Effect</th><th>Enforcement</th><th>Origin</th><th>Subscription</th></tr>')
            foreach ($pa in $Data.PolicyInv.Assignments) {
                $paType = if ($pa.PolicyDefId -match '/policySetDefinitions/') { 'Initiative' } else { 'Policy' }
                [void]$sb.Append("<tr><td>$($esc::Escape($pa.AssignmentName))</td><td>$paType</td><td>$($esc::Escape($pa.Effect))</td><td>$($esc::Escape($pa.EnforcementMode))</td><td>$($esc::Escape($pa.Origin))</td><td>$($esc::Escape($pa.Subscription))</td></tr>")
            }
            [void]$sb.Append('</table>')
        }
    }

    # FinOps policy recommendations
    if ($Data.PolicyRecs) {
        [void]$sb.Append("<h3>FinOps Recommended Policies ($($Data.PolicyRecs.Assigned.Count) of $($Data.PolicyRecs.Analysis.Count) assigned)</h3>")
        [void]$sb.Append("<table><tr><th>Policy</th><th>Status</th><th>Category</th><th>Priority</th><th>Pillar</th><th>Purpose</th></tr>")
        foreach ($pr in $Data.PolicyRecs.Analysis | Sort-Object { switch ($_.Priority) { 'Required' { 0 } 'Recommended' { 1 } 'Optional' { 2 } default { 3 } } }) {
            $sCls = if ($pr.Status -eq 'Assigned') { 'status-assigned' } else { 'status-missing' }
            [void]$sb.Append("<tr><td><strong>$($esc::Escape($pr.DisplayName))</strong></td><td class=`"$sCls`">$($pr.Status)</td>")
            [void]$sb.Append("<td>$($esc::Escape($pr.Category))</td><td>$($pr.Priority)</td><td>$($pr.Pillar)</td><td>$($esc::Escape($pr.Purpose))</td></tr>")
        }
        [void]$sb.Append("</table>")
    }

    # ── 8. Optimization Opportunities ───────────────────────────────────
    [void]$sb.Append('<h2 id="optimization">8. Optimization Opportunities</h2>')
    # AHB
    if ($Data.AHB -and $Data.AHB.TotalOpportunities -gt 0) {
        [void]$sb.Append("<h3>Azure Hybrid Benefit Opportunities ($($Data.AHB.TotalOpportunities))</h3>")
        [void]$sb.Append("<p>$($esc::Escape($Data.AHB.Summary))</p>")
        if ($Data.AHB.WindowsVMs.Count -gt 0) {
            [void]$sb.Append("<table><tr><th>VM Name</th><th>Resource Group</th><th>Size</th><th>Location</th><th>Current License</th><th class=`"text-right`">Est. Savings/mo</th></tr>")
            foreach ($vm in $Data.AHB.WindowsVMs) {
                $vmEst = if ($vm.estMonthlySavings) { "$sym$(([double]$vm.estMonthlySavings).ToString('N0'))" } else { '-' }
                [void]$sb.Append("<tr><td>$($esc::Escape($vm.name))</td><td>$($esc::Escape($vm.resourceGroup))</td><td>$($esc::Escape($vm.vmSize))</td><td>$($esc::Escape($vm.location))</td><td>$($esc::Escape($vm.currentLicense))</td><td class=`"text-right`">$vmEst</td></tr>")
            }
            if ($Data.AHB.EstMonthlyVMSavings -gt 0) {
                [void]$sb.Append("<tr style=`"font-weight:700;background:#EBF5FF;`"><td colspan=`"5`">Estimated total monthly savings</td><td class=`"text-right`">$sym$(([double]$Data.AHB.EstMonthlyVMSavings).ToString('N0'))</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    }
    # Orphans
    if ($Data.Orphans -and $Data.Orphans.TotalCount -gt 0) {
        [void]$sb.Append("<h3>Orphaned / Idle Resources ($($Data.Orphans.TotalCount))</h3>")
        [void]$sb.Append("<table><tr><th>Category</th><th>Resource</th><th>Resource Group</th><th>Impact</th><th>Detail</th></tr>")
        foreach ($o in $Data.Orphans.Orphans | Sort-Object Impact -Descending) {
            $impCls = switch ($o.Impact) { 'High' { 'status-warn' } 'Medium' { 'status-info' } default { 'text-muted' } }
            [void]$sb.Append("<tr><td>$($esc::Escape($o.Category))</td><td><strong>$($esc::Escape($o.ResourceName))</strong></td><td>$($esc::Escape($o.ResourceGroup))</td><td class=`"$impCls`">$($o.Impact)</td><td>$($esc::Escape($o.Detail))</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    # Advisor
    if ($Data.Optimization -and $Data.Optimization.TotalCount -gt 0) {
        [void]$sb.Append("<h3>Azure Advisor Cost Recommendations ($($Data.Optimization.TotalCount))</h3>")
        if ($Data.Optimization.EstimatedAnnualSavings -gt 0) {
            [void]$sb.Append("<p>Estimated annual savings: <strong>$sym$($Data.Optimization.EstimatedAnnualSavings.ToString('N2'))</strong>")
            [void]$sb.Append(" <span style=`"font-size:0.85em;color:#999`">(may include overlapping recommendations for the same resource)</span></p>")
        }
        [void]$sb.Append("<table><tr><th>Subscription</th><th>Category</th><th>Impact</th><th>Problem</th><th>Solution</th><th class=`"text-right`">Annual Savings</th></tr>")
        foreach ($rec in $Data.Optimization.Recommendations | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }) {
            $impCls = switch ($rec.Impact) { 'High' { 'status-warn' } 'Medium' { 'status-info' } default { 'text-muted' } }
            $savings = if ($rec.AnnualSavings -and $rec.AnnualSavings -gt 0) { "$sym$($rec.AnnualSavings.ToString('N2'))" } else { '-' }
            [void]$sb.Append("<tr><td>$($esc::Escape($rec.Subscription))</td><td>$($esc::Escape($rec.Category))</td><td class=`"$impCls`">$($rec.Impact)</td>")
            [void]$sb.Append("<td>$($esc::Escape($rec.Problem))</td><td>$($esc::Escape($rec.Solution))</td><td class=`"text-right`">$savings</td></tr>")
        }
        [void]$sb.Append("</table>")
    }
    if ($optTotal -eq 0) {
        [void]$sb.Append('<p class="status-good">No optimization issues found. Well optimized!</p>')
    }

    # ── 9. Budget Status ────────────────────────────────────────────────
    [void]$sb.Append('<div class="page-break"></div><h2 id="budgets">9. Budget Status</h2>')
    if ($Data.Budgets -and $Data.Budgets.HasData) {
        $overColor = if ($Data.Budgets.OverBudgetCount -gt 0) { '#E81123' } else { '#107C10' }
        $riskColor = if ($Data.Budgets.AtRiskCount -gt 0) { '#D83B01' } else { '#107C10' }
        [void]$sb.Append(@"
<div class="cards">
<div class="card"><div class="label">Total Budgets</div><div class="value" style="color:#0078D4">$($Data.Budgets.TotalBudgets)</div></div>
<div class="card"><div class="label">Budget Coverage</div><div class="value" style="color:#0078D4">$([math]::Round($Data.Budgets.BudgetCoverage,0))%</div><div class="detail">$($Data.Budgets.SubsWithBudget) of $($Data.Budgets.SubsWithBudget + $Data.Budgets.SubsWithoutBudget) subscriptions</div></div>
<div class="card"><div class="label">Over Budget</div><div class="value" style="color:$overColor">$($Data.Budgets.OverBudgetCount)</div></div>
<div class="card"><div class="label">At Risk</div><div class="value" style="color:$riskColor">$($Data.Budgets.AtRiskCount)</div></div>
</div>
"@)
        [void]$sb.Append("<table><tr><th>Subscription</th><th>Budget Name</th><th class=`"text-right`">Amount</th><th class=`"text-right`">Actual Spend</th><th class=`"text-right`">% Used</th><th>Risk</th></tr>")
        foreach ($b in $Data.Budgets.Budgets | Sort-Object PctUsed -Descending) {
            $riskCls = switch ($b.Risk) { 'Over Budget' { 'status-warn' } 'At Risk' { 'status-warn' } 'On Track' { 'status-good' } default { 'text-muted' } }
            [void]$sb.Append("<tr><td>$($esc::Escape($b.Subscription))</td><td>$($esc::Escape($b.BudgetName))</td>")
            [void]$sb.Append("<td class=`"text-right`">$sym$($b.Amount.ToString('N2'))</td><td class=`"text-right`">$sym$($b.ActualSpend.ToString('N2'))</td>")
            [void]$sb.Append("<td class=`"text-right`">$([math]::Round($b.PctUsed,1))%</td><td class=`"$riskCls`">$($b.Risk)</td></tr>")
        }
        [void]$sb.Append("</table>")

        # Budget History (6-month lookback)
        if ($Data.BudgetHistory -and $Data.BudgetHistory.Count -gt 0) {
            [void]$sb.Append('<h3>Budget History (Last 6 Months)</h3>')
            [void]$sb.Append('<p>Monthly spend vs. budget amount. Highlights periods where spend exceeded the budget.</p>')
            [void]$sb.Append("<table><tr><th>Subscription</th><th>Budget</th><th>Month</th><th class=`"text-right`">Budget Amount</th><th class=`"text-right`">Actual Spend</th><th class=`"text-right`">% Used</th><th>Status</th></tr>")
            foreach ($h in $Data.BudgetHistory) {
                $hSym = Get-CurrencySymbol $h.Currency
                $statusCls = switch ($h.Status) { 'Over' { 'status-warn' } 'Near Limit' { 'status-warn' } default { 'status-good' } }
                [void]$sb.Append("<tr><td>$($esc::Escape($h.Subscription))</td><td>$($esc::Escape($h.BudgetName))</td><td>$($h.Month)</td>")
                [void]$sb.Append("<td class=`"text-right`">$hSym$($h.BudgetAmount.ToString('N2'))</td><td class=`"text-right`">$hSym$($h.ActualSpend.ToString('N2'))</td>")
                [void]$sb.Append("<td class=`"text-right`">$($h.PctUsed)%</td><td class=`"$statusCls`">$($h.Status)</td></tr>")
            }
            [void]$sb.Append("</table>")
        }
    } else {
        [void]$sb.Append('<p class="text-muted">No budgets configured. Consider creating budgets for all production subscriptions.</p>')
    }

    # ── Footer ──────────────────────────────────────────────────────────
    [void]$sb.Append(@"
<footer>
<p>Generated by <strong>Azure FinOps Scanner</strong> (Automated Report) &mdash; $(Get-Date -Format 'MMMM d, yyyy h:mm tt')</p>
<p>Based on FinOps Foundation Framework and Microsoft Cloud Adoption Framework for Azure.</p>
</footer>
</body>
</html>
"@)

    return $sb.ToString()
}
