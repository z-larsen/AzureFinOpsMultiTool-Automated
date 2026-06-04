###########################################################################
# OUTPUTS.TF
# FINOPS SCANNER INFRASTRUCTURE OUTPUTS
###########################################################################

output "resource_group_name" {
  description = "Resource group containing all FinOps Scanner resources"
  value       = azurerm_resource_group.main.name
}

output "automation_account_name" {
  description = "Name of the Automation Account"
  value       = azurerm_automation_account.main.name
}

output "automation_identity_principal_id" {
  description = "Principal ID of the Automation Account's Managed Identity"
  value       = azurerm_automation_account.main.identity[0].principal_id
}

output "storage_account_name" {
  description = "Storage account for scan output"
  value       = azurerm_storage_account.main.name
}

output "scan_output_container" {
  description = "Blob container where scan results are written"
  value       = azurerm_storage_container.scans.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (for workbook integration)"
  value       = var.enable_workbook ? azurerm_log_analytics_workspace.main[0].id : "(not deployed — set enable_workbook = true)"
}

output "dce_endpoint" {
  description = "Data Collection Endpoint for Logs Ingestion API"
  value       = var.enable_workbook ? azurerm_monitor_data_collection_endpoint.main[0].logs_ingestion_endpoint : "(not deployed)"
}

output "dcr_immutable_id" {
  description = "Data Collection Rule immutable ID"
  value       = var.enable_workbook ? azurerm_monitor_data_collection_rule.finops[0].immutable_id : "(not deployed)"
}

output "workbook_id" {
  description = "Azure Workbook resource ID (open in portal)"
  value       = var.enable_workbook ? azurerm_application_insights_workbook.finops[0].id : "(not deployed — set enable_workbook = true)"
}

output "logic_app_name" {
  description = "Logic App name for report email delivery"
  value       = var.report_recipients != "" ? azurerm_logic_app_workflow.report_email[0].name : "(not deployed — set report_recipients to enable)"
}

output "logic_app_webhook_url" {
  description = "Logic App HTTP trigger URL (used by runbook)"
  value       = var.report_recipients != "" ? azurerm_logic_app_trigger_http_request.report_webhook[0].callback_url : ""
  sensitive   = true
}
