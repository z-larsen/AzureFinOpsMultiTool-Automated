###########################################################################
# MAIN.TF
# FINOPS SCANNER — AZURE AUTOMATION ACCOUNT
###########################################################################
# Deploys: Resource Group, Storage Account (scan output only),
#          Automation Account with Managed Identity,
#          PowerShell 7.2 Runbook on daily schedule,
#          RBAC role assignments (Reader + Cost Management Reader)
#
# Optional (enable_workbook = true, default):
#          Log Analytics Workspace, DCE/DCR pipeline,
#          6 custom tables, Azure Workbook dashboard
#
# Optional (report_recipients != ""):
#          Logic App for HTML report email delivery
###########################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

# ── Auto-detect tenant + subscription from current login ──────────────
data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# ── Naming / Locals ────────────────────────────────────────────────────
locals {
  name_suffix     = replace(var.project_name, "/[^a-z0-9]/", "")
  sa_name         = "st${local.name_suffix}${substr(md5(var.project_name), 0, 6)}"
  tenant_id       = data.azurerm_client_config.current.tenant_id
  mg_id           = var.management_group_id != "" ? var.management_group_id : local.tenant_id
  scan_rbac_scope = var.scan_scope == "tenant" ? "/providers/Microsoft.Management/managementGroups/${local.mg_id}" : data.azurerm_subscription.current.id
  office365_api_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/office365"
}

# ── State migrations (enable_workbook count) ─────────────────────────
# These moved blocks allow Terraform to adopt existing non-indexed
# resources into the new count-based addresses without destroy/recreate.
moved {
  from = azurerm_log_analytics_workspace.main
  to   = azurerm_log_analytics_workspace.main[0]
}
moved {
  from = azurerm_log_analytics_linked_service.automation
  to   = azurerm_log_analytics_linked_service.automation[0]
}
moved {
  from = azurerm_monitor_data_collection_endpoint.main
  to   = azurerm_monitor_data_collection_endpoint.main[0]
}
moved {
  from = azapi_resource.table_scan_summary
  to   = azapi_resource.table_scan_summary[0]
}
moved {
  from = azapi_resource.table_costs
  to   = azapi_resource.table_costs[0]
}
moved {
  from = azapi_resource.table_resource_costs
  to   = azapi_resource.table_resource_costs[0]
}
moved {
  from = azapi_resource.table_budgets
  to   = azapi_resource.table_budgets[0]
}
moved {
  from = azapi_resource.table_optimization
  to   = azapi_resource.table_optimization[0]
}
moved {
  from = azapi_resource.table_cost_trend
  to   = azapi_resource.table_cost_trend[0]
}
moved {
  from = azurerm_monitor_data_collection_rule.finops
  to   = azurerm_monitor_data_collection_rule.finops[0]
}
moved {
  from = azurerm_automation_variable_string.dce_endpoint
  to   = azurerm_automation_variable_string.dce_endpoint[0]
}
moved {
  from = azurerm_automation_variable_string.dcr_id
  to   = azurerm_automation_variable_string.dcr_id[0]
}
moved {
  from = azurerm_role_assignment.metrics_publisher
  to   = azurerm_role_assignment.metrics_publisher[0]
}
moved {
  from = azurerm_application_insights_workbook.finops
  to   = azurerm_application_insights_workbook.finops[0]
}

# ── Resource Group ─────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}"
  location = var.location
  tags     = var.tags
}

# ── Storage Account (scan output blobs — identity-only) ────────────────
resource "azurerm_storage_account" "main" {
  name                            = local.sa_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "scans" {
  name                  = "finops-scans"
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# ── Log Analytics Workspace (for workbook dashboard) ─────────────────
resource "azurerm_log_analytics_workspace" "main" {
  count               = var.enable_workbook ? 1 : 0
  name                = "law-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = var.tags
}

# ── Automation Account ────────────────────────────────────────────────
resource "azurerm_automation_account" "main" {
  name                = "aa-${var.project_name}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Basic"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ── Link Automation to Log Analytics ──────────────────────────────────
resource "azurerm_log_analytics_linked_service" "automation" {
  count               = var.enable_workbook ? 1 : 0
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main[0].id
  read_access_id      = azurerm_automation_account.main.id
}

# ── Az Module imports ────────────────────────────────────────────────
# PowerShell 7.2 runtime has the global Az 11.2.0 bundle pre-installed,
# but Az.ResourceGraph is not auto-loadable from the global bundle.
# Standalone PSGallery versions >= 1.0.0 require Az.Accounts >= 3.0.0,
# which conflicts with the global bundle's Az.Accounts 2.15.0.
# Version 0.9.0 is the last release compatible with Az.Accounts 2.x.
resource "azurerm_automation_powershell72_module" "az_resourcegraph_72" {
  name                  = "Az.ResourceGraph"
  automation_account_id = azurerm_automation_account.main.id

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.ResourceGraph/0.9.0"
  }
}

# ── Automation Variables (passed to runbook as env config) ────────────
resource "azurerm_automation_variable_string" "tenant_id" {
  name                    = "FINOPS_TENANT_ID"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = local.tenant_id
  encrypted               = true
}

resource "azurerm_automation_variable_string" "storage_account" {
  name                    = "FINOPS_STORAGE_ACCOUNT"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_storage_account.main.name
  encrypted               = true
}

resource "azurerm_automation_variable_string" "container_name" {
  name                    = "FINOPS_CONTAINER_NAME"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_storage_container.scans.name
  encrypted               = true
}

resource "azurerm_automation_variable_string" "subscription_filter" {
  count                   = var.subscription_filter != "" ? 1 : 0
  name                    = "FINOPS_SUBSCRIPTION_FILTER"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.subscription_filter
}

# ── Daily Schedule ────────────────────────────────────────────────────
resource "azurerm_automation_schedule" "daily" {
  name                    = "daily-finops-scan"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = "Day"
  interval                = 1
  timezone                = "UTC"
  start_time              = timeadd(timestamp(), "24h")
  description             = "Run FinOps scan daily"

  lifecycle {
    ignore_changes = [start_time]
  }
}

# ── Runbook (pre-assembled with embedded modules) ────────────────────
# Run scripts/Build-Runbook.ps1 before terraform apply to assemble
# all scan modules into a single runbook file.
resource "azurerm_automation_runbook" "scan" {
  name                    = "Run-FinOpsScan"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  location                = azurerm_resource_group.main.location
  log_verbose             = false
  log_progress            = true
  runbook_type            = "PowerShell72"
  content                 = file("${path.module}/../runbook/Run-FinOpsScan-Assembled.ps1")
  tags                    = var.tags
}

# ── Link runbook to schedule ─────────────────────────────────────────
resource "azurerm_automation_job_schedule" "daily_scan" {
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  runbook_name            = azurerm_automation_runbook.scan.name
  schedule_name           = azurerm_automation_schedule.daily.name
}

# ── RBAC: Reader on scan scope ───────────────────────────────────────
resource "azurerm_role_assignment" "reader" {
  scope                = local.scan_rbac_scope
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── RBAC: Cost Management Reader on scan scope ──────────────────────
resource "azurerm_role_assignment" "cost_reader" {
  scope                = local.scan_rbac_scope
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── RBAC: Additional subscriptions (if scanning cross-sub) ──────────
resource "azurerm_role_assignment" "extra_reader" {
  for_each             = toset(var.additional_rbac_scopes)
  scope                = each.value
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "extra_cost_reader" {
  for_each             = toset(var.additional_rbac_scopes)
  scope                = each.value
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── RBAC: Storage Blob Data Owner on scan output storage ────────────
resource "azurerm_role_assignment" "blob_owner" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── RBAC: Deployer gets Blob Data Contributor for scan output ───────
resource "azurerm_role_assignment" "deployer_blob" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── FinOps Hub export storage (export-first cost sourcing) ───────────
# When a hub storage account is provided, grant the Automation managed
# identity data-plane read access so the runbook can read FOCUS cost
# rows from the export. Without this the runbook falls back to the
# Cost Management API. Skipped entirely when the variable is empty.
data "azurerm_storage_account" "finops_hub" {
  count               = var.finops_hub_storage_account_name != "" ? 1 : 0
  name                = var.finops_hub_storage_account_name
  resource_group_name = var.finops_hub_resource_group
}

resource "azurerm_role_assignment" "hub_blob_reader" {
  count                = var.finops_hub_storage_account_name != "" ? 1 : 0
  scope                = data.azurerm_storage_account.finops_hub[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── Data Collection Endpoint (for Logs Ingestion API) ────────────────
resource "azurerm_monitor_data_collection_endpoint" "main" {
  count                         = var.enable_workbook ? 1 : 0
  name                          = "dce-${var.project_name}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  kind                          = "Linux"
  public_network_access_enabled = true
  tags                          = var.tags
}

# ── Custom Log Analytics Tables ──────────────────────────────────────
resource "azapi_resource" "table_scan_summary" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsScanSummary_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsScanSummary_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "TenantId_s", type = "string" },
          { name = "SubCount", type = "int" },
          { name = "StepsRun", type = "int" },
          { name = "StepsFailed", type = "int" },
          { name = "DurationSec", type = "real" },
          { name = "TotalActual", type = "real" },
          { name = "TotalForecast", type = "real" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

resource "azapi_resource" "table_costs" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsCosts_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsCosts_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "SubscriptionId", type = "string" },
          { name = "SubscriptionName", type = "string" },
          { name = "Actual", type = "real" },
          { name = "Forecast", type = "real" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

resource "azapi_resource" "table_resource_costs" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsResourceCosts_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsResourceCosts_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "ResourceName", type = "string" },
          { name = "ResourceType", type = "string" },
          { name = "ResourceGroup", type = "string" },
          { name = "Subscription", type = "string" },
          { name = "MonthlyCost", type = "real" },
          { name = "DailyCost", type = "real" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

resource "azapi_resource" "table_budgets" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsBudgets_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsBudgets_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "BudgetName", type = "string" },
          { name = "Subscription", type = "string" },
          { name = "Amount", type = "real" },
          { name = "ActualSpend", type = "real" },
          { name = "Forecast", type = "real" },
          { name = "PctUsed", type = "real" },
          { name = "PctForecast", type = "real" },
          { name = "RiskLevel", type = "string" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

resource "azapi_resource" "table_optimization" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsOptimization_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsOptimization_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "Category", type = "string" },
          { name = "ResourceName", type = "string" },
          { name = "ResourceType", type = "string" },
          { name = "ResourceGroup", type = "string" },
          { name = "Subscription", type = "string" },
          { name = "Recommendation", type = "string" },
          { name = "PotentialSavings", type = "real" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

resource "azapi_resource" "table_cost_trend" {
  count     = var.enable_workbook ? 1 : 0
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "FinOpsCostTrend_CL"
  parent_id = azurerm_log_analytics_workspace.main[0].id

  body = {
    properties = {
      schema = {
        name = "FinOpsCostTrend_CL"
        columns = [
          { name = "TimeGenerated", type = "dateTime" },
          { name = "ScanDate", type = "string" },
          { name = "Month", type = "string" },
          { name = "Amount", type = "real" },
          { name = "Currency", type = "string" }
        ]
      }
      retentionInDays      = 90
      totalRetentionInDays = 90
    }
  }
}

# ── Data Collection Rule (maps streams → custom tables) ──────────────
resource "azurerm_monitor_data_collection_rule" "finops" {
  count                       = var.enable_workbook ? 1 : 0
  name                        = "dcr-${var.project_name}"
  resource_group_name         = azurerm_resource_group.main.name
  location                    = azurerm_resource_group.main.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.main[0].id
  tags                        = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.main[0].id
      name                  = "law-destination"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsScanSummary_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "TenantId_s"
      type = "string"
    }
    column {
      name = "SubCount"
      type = "int"
    }
    column {
      name = "StepsRun"
      type = "int"
    }
    column {
      name = "StepsFailed"
      type = "int"
    }
    column {
      name = "DurationSec"
      type = "real"
    }
    column {
      name = "TotalActual"
      type = "real"
    }
    column {
      name = "TotalForecast"
      type = "real"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsCosts_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "SubscriptionId"
      type = "string"
    }
    column {
      name = "SubscriptionName"
      type = "string"
    }
    column {
      name = "Actual"
      type = "real"
    }
    column {
      name = "Forecast"
      type = "real"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsResourceCosts_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "ResourceName"
      type = "string"
    }
    column {
      name = "ResourceType"
      type = "string"
    }
    column {
      name = "ResourceGroup"
      type = "string"
    }
    column {
      name = "Subscription"
      type = "string"
    }
    column {
      name = "MonthlyCost"
      type = "real"
    }
    column {
      name = "DailyCost"
      type = "real"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsBudgets_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "BudgetName"
      type = "string"
    }
    column {
      name = "Subscription"
      type = "string"
    }
    column {
      name = "Amount"
      type = "real"
    }
    column {
      name = "ActualSpend"
      type = "real"
    }
    column {
      name = "Forecast"
      type = "real"
    }
    column {
      name = "PctUsed"
      type = "real"
    }
    column {
      name = "PctForecast"
      type = "real"
    }
    column {
      name = "RiskLevel"
      type = "string"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsOptimization_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "Category"
      type = "string"
    }
    column {
      name = "ResourceName"
      type = "string"
    }
    column {
      name = "ResourceType"
      type = "string"
    }
    column {
      name = "ResourceGroup"
      type = "string"
    }
    column {
      name = "Subscription"
      type = "string"
    }
    column {
      name = "Recommendation"
      type = "string"
    }
    column {
      name = "PotentialSavings"
      type = "real"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  stream_declaration {
    stream_name = "Custom-FinOpsCostTrend_CL"
    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "ScanDate"
      type = "string"
    }
    column {
      name = "Month"
      type = "string"
    }
    column {
      name = "Amount"
      type = "real"
    }
    column {
      name = "Currency"
      type = "string"
    }
  }

  data_flow {
    streams       = ["Custom-FinOpsScanSummary_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsScanSummary_CL"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Custom-FinOpsCosts_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsCosts_CL"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Custom-FinOpsResourceCosts_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsResourceCosts_CL"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Custom-FinOpsBudgets_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsBudgets_CL"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Custom-FinOpsOptimization_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsOptimization_CL"
    transform_kql = "source"
  }

  data_flow {
    streams       = ["Custom-FinOpsCostTrend_CL"]
    destinations  = ["law-destination"]
    output_stream = "Custom-FinOpsCostTrend_CL"
    transform_kql = "source"
  }

  depends_on = [
    azapi_resource.table_scan_summary,
    azapi_resource.table_costs,
    azapi_resource.table_resource_costs,
    azapi_resource.table_budgets,
    azapi_resource.table_optimization,
    azapi_resource.table_cost_trend
  ]
}

# ── Automation Variables for LAW ingestion ────────────────────────────
resource "azurerm_automation_variable_string" "dce_endpoint" {
  count                   = var.enable_workbook ? 1 : 0
  name                    = "FINOPS_DCE_ENDPOINT"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_monitor_data_collection_endpoint.main[0].logs_ingestion_endpoint
}

resource "azurerm_automation_variable_string" "dcr_id" {
  count                   = var.enable_workbook ? 1 : 0
  name                    = "FINOPS_DCR_IMMUTABLE_ID"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_monitor_data_collection_rule.finops[0].immutable_id
}

# ── RBAC: Automation MI gets Monitoring Metrics Publisher on DCR ─────
resource "azurerm_role_assignment" "metrics_publisher" {
  count                = var.enable_workbook ? 1 : 0
  scope                = azurerm_monitor_data_collection_rule.finops[0].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ── Azure Workbook ───────────────────────────────────────────────────
resource "azurerm_application_insights_workbook" "finops" {
  count               = var.enable_workbook ? 1 : 0
  name                = "b2c3d4e5-f6a7-4b89-a012-3456789abcde"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "FinOps Scanner Dashboard"
  source_id           = lower(azurerm_log_analytics_workspace.main[0].id)
  tags                = var.tags

  data_json = file("${path.module}/workbook.json")
}

# ── Logic App: Email Report Delivery ─────────────────────────────────
# A Consumption-tier Logic App that receives the HTML report URL from
# the runbook via HTTP POST and sends it as a formatted email.
# Only deployed when report_recipients is set.

# Office 365 API connection (must be authorized in the portal after deploy)
resource "azapi_resource" "office365_connection" {
  count     = var.report_recipients != "" ? 1 : 0
  type      = "Microsoft.Web/connections@2016-06-01"
  name      = "office365-${var.project_name}"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = var.tags

  body = {
    properties = {
      displayName = "Office 365 - FinOps Scanner"
      api = {
        id = local.office365_api_id
      }
    }
  }
}

resource "azurerm_logic_app_workflow" "report_email" {
  count               = var.report_recipients != "" ? 1 : 0
  name                = "logic-${var.project_name}-report"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }

  workflow_parameters = {
    "$connections" = jsonencode({
      type         = "Object"
      defaultValue = {}
    })
  }

  parameters = {
    "$connections" = jsonencode({
      office365 = {
        connectionId   = azapi_resource.office365_connection[0].id
        connectionName = azapi_resource.office365_connection[0].name
        id             = local.office365_api_id
      }
    })
  }
}

resource "azurerm_logic_app_trigger_http_request" "report_webhook" {
  count       = var.report_recipients != "" ? 1 : 0
  name        = "manual-trigger"
  logic_app_id = azurerm_logic_app_workflow.report_email[0].id

  schema = <<-SCHEMA
  {
    "type": "object",
    "properties": {
      "scanDate":       { "type": "string" },
      "tenantId":       { "type": "string" },
      "subCount":       { "type": "integer" },
      "totalSpend":     { "type": "number" },
      "currency":       { "type": "string" },
      "reportContent":  { "type": "string" },
      "reportFileName": { "type": "string" }
    }
  }
  SCHEMA
}

resource "azurerm_logic_app_action_custom" "send_email" {
  count        = var.report_recipients != "" ? 1 : 0
  name         = "Send_Report_Email"
  logic_app_id = azurerm_logic_app_workflow.report_email[0].id

  body = <<-JSON
  {
    "type": "ApiConnection",
    "inputs": {
      "host": {
        "connection": {
          "name": "@parameters('$connections')['office365']['connectionId']"
        }
      },
      "method": "post",
      "path": "/v2/Mail",
      "body": {
        "To": "${var.report_recipients}",
        "Subject": "FinOps Assessment Report — @{triggerBody()?['scanDate']}",
        "Body": "<html><body style='font-family:Segoe UI,sans-serif;color:#333'><h2 style='color:#0078D4'>Azure FinOps Assessment Report</h2><table style='border-collapse:collapse;margin:16px 0'><tr><td style='padding:6px 16px 6px 0;color:#666'>Scan Date</td><td style='padding:6px 0;font-weight:600'>@{triggerBody()?['scanDate']}</td></tr><tr><td style='padding:6px 16px 6px 0;color:#666'>Subscriptions</td><td style='padding:6px 0;font-weight:600'>@{triggerBody()?['subCount']}</td></tr><tr><td style='padding:6px 16px 6px 0;color:#666'>Total Spend (MTD)</td><td style='padding:6px 0;font-weight:600'>@{triggerBody()?['currency']} @{triggerBody()?['totalSpend']}</td></tr></table><p style='margin-top:16px'>Open the attached HTML file to view the full interactive report.</p><p style='font-size:12px;color:#999;margin-top:24px'>Generated by Azure FinOps Scanner.</p></body></html>",
        "IsHtml": true,
        "Attachments": [
          {
            "Name": "@{triggerBody()?['reportFileName']}",
            "ContentBytes": "@{triggerBody()?['reportContent']}"
          }
        ]
      }
    },
    "runAfter": {}
  }
  JSON
}

# ── Automation Variable: Webhook URL for report delivery ─────────────
resource "azurerm_automation_variable_string" "report_webhook" {
  count                   = var.report_recipients != "" ? 1 : 0
  name                    = "FINOPS_REPORT_WEBHOOK"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_logic_app_trigger_http_request.report_webhook[0].callback_url
  encrypted               = true
}
