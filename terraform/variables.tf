###########################################################################
# VARIABLES.TF
# FINOPS FUNCTION APP INFRASTRUCTURE VARIABLES
###########################################################################

variable "project_name" {
  description = "Base name for all resources (lowercase, no spaces)"
  type        = string
  default     = "finops-scanner"
}

variable "location" {
  description = "Azure region for resource deployment"
  type        = string
  default     = "centralus"
}

variable "scan_scope" {
  description = "Where to grant the function read access. Use 'subscription' to scan only the deploying subscription, or 'tenant' to scan all subscriptions under the tenant root management group."
  type        = string
  default     = "subscription"

  validation {
    condition     = contains(["subscription", "tenant"], var.scan_scope)
    error_message = "scan_scope must be 'subscription' or 'tenant'."
  }
}

variable "management_group_id" {
  description = "Management group ID for tenant-wide scanning. Only used when scan_scope = 'tenant'. Defaults to the tenant root group."
  type        = string
  default     = ""
}

variable "subscription_filter" {
  description = "Optional comma-separated subscription IDs to scan. Leave empty to scan all accessible subscriptions."
  type        = string
  default     = ""
}

variable "additional_rbac_scopes" {
  description = "Extra subscription IDs to grant Reader + Cost Management Reader on (beyond the deploying subscription). Format: list of full resource IDs."
  type        = list(string)
  default     = []
}

variable "finops_hub_storage_account_name" {
  description = "Name of the FinOps Hub storage account holding exported cost data. When set, the Automation managed identity is granted Storage Blob Data Reader so the runbook can read the export (export-first cost sourcing). Leave empty to skip and use the Cost Management API only."
  type        = string
  default     = ""
}

variable "finops_hub_resource_group" {
  description = "Resource group of the FinOps Hub storage account. Required when finops_hub_storage_account_name is set."
  type        = string
  default     = ""
}

variable "scan_schedule" {
  description = "NCRONTAB expression for the timer trigger (default: daily at 6 AM UTC)"
  type        = string
  default     = "0 0 6 * * *"
}

variable "enable_workbook" {
  description = "Deploy the Log Analytics ingestion pipeline (DCE, DCR, custom tables) and Azure Workbook dashboard. Set to true to enable. Disabled by default — the HTML email report is the primary reporting method."
  type        = bool
  default     = false
}

variable "report_recipients" {
  description = "Semicolon-separated email addresses to receive the HTML assessment report. Leave empty to disable email delivery."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    project   = "FinOps-Scanner"
    managedBy = "Terraform"
  }
}
