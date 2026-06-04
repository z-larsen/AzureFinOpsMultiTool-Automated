# Azure FinOps Multitool — Automated

![PowerShell 7.2](https://img.shields.io/badge/PowerShell-7.2-blue?logo=powershell&logoColor=white)
![Terraform >= 1.5](https://img.shields.io/badge/Terraform-%3E%3D1.5-7B42BC?logo=terraform&logoColor=white)
![Azure Automation](https://img.shields.io/badge/Azure-Automation-0078D4?logo=microsoftazure&logoColor=white)
![License MIT](https://img.shields.io/badge/License-MIT-green)

The automated version of the [Azure FinOps Multitool](https://github.com/z-larsen/Azure-FinOps-Multitool). Same 21 scan modules running unattended in Azure Automation on a daily schedule, delivering an HTML assessment report to your inbox every morning.

---

## Deploy in 5 Minutes

### Prerequisites

- [Terraform >= 1.5](https://developer.hashicorp.com/terraform/install)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in)

### Steps

```powershell
# 1. Clone and configure
git clone https://github.com/z-larsen/AzureFinOpsMultiTool-Automated.git
cd AzureFinOpsMultiTool-Automated/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set report_recipients to your email address

# 2. Build the runbook (assembles 24 modules into a single file)
cd ../scripts
./Build-Runbook.ps1
cd ../terraform

# 3. Deploy
terraform init
terraform apply

# 4. Authorize the email connector (one-time, ~30 seconds)
#    Portal > API Connections > office365-finops-scanner > Edit API connection > Authorize

# 5. Run your first scan (or wait for the daily schedule at 6 AM UTC)
az automation runbook start \
  -g rg-finops-scanner \
  --automation-account-name aa-finops-scanner \
  -n Run-FinOpsScan
```

That's it. You'll receive your first FinOps assessment email when the scan completes (~10-15 minutes).

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  Azure Automation Account (Managed Identity)                    │
│                                                                 │
│  Run-FinOpsScan (PS 7.2 Runbook)                                │
│  ├─ 24 scan modules (costs, tags, orphans, budgets, ...)        │
│  ├─ Runs daily at 6 AM UTC (customizable)                       │
│  └─ Authenticates via System-Assigned Managed Identity          │
│                                                                 │
│  Outputs:                                                       │
│  ├─── Blob Storage ──── JSON + per-area CSVs + HTML report      │
│  └─── Email ─────────── HTML report via Logic App + Office 365  │
└─────────────────────────────────────────────────────────────────┘
```

1. **Schedule fires** at 6 AM UTC daily
2. **Managed Identity** authenticates — no credentials stored
3. **24 modules** scan every accessible subscription: costs, tags, orphans, budgets, advisor recommendations, and more
4. **Results** are written to blob storage (JSON + CSV + HTML)
5. **Logic App** sends the HTML report as an email attachment

---

## What Gets Scanned

| Area | What you get |
|------|-------------|
| **Costs** | Actual MTD + forecast per subscription |
| **Cost trend** | 6-month monthly spend history |
| **Resource costs** | Per-resource spend with type, resource group, forecast |
| **Tags** | Every tag name/value in use, untagged resource count |
| **Cost by tag** | Spend broken down by CAF allocation tags |
| **Orphaned resources** | Unattached disks, IPs, NICs, deallocated VMs, empty ASPs, old snapshots |
| **Idle VMs** | Virtual machines with near-zero CPU/network utilization |
| **Azure Hybrid Benefit** | Windows VMs, SQL VMs, and SQL DBs missing AHB |
| **Commitments** | RI and Savings Plan utilization |
| **Reservations & Savings Plans** | Purchase recommendations with projected savings |
| **Advisor** | Cost-category optimization recommendations |
| **Budgets** | Budget vs. actual per subscription, risk levels |
| **Savings realized** | Monthly savings from existing RIs, SPs, and AHB |
| **Policy** | FinOps-related policy inventory and gap analysis |
| **Anomaly alerts** | Configured cost anomaly alert rules |
| **Contract** | EA, MCA, PAYGO, or CSP detection |
| **Tenant hierarchy** | Management group tree with subscription mapping |

---

## Configuration

All configuration is in `terraform/terraform.tfvars`. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `report_recipients` | `""` | Semicolon-separated email addresses for the daily report |
| `scan_scope` | `"subscription"` | `"subscription"` or `"tenant"` for multi-subscription scanning |
| `management_group_id` | `""` | Specific management group to scan (tenant mode only) |
| `subscription_filter` | `""` | Comma-separated subscription IDs to restrict scanning |
| `scan_schedule` | `"0 0 6 * * *"` | NCRONTAB expression (default: 6 AM UTC daily) |
| `project_name` | `"finops-scanner"` | Base name for all resources |
| `location` | `"centralus"` | Azure region |
| `enable_workbook` | `false` | Deploy Log Analytics + Azure Workbook dashboard (advanced) |

### Scan scope options

**Single subscription** (default) — scans only the subscription you deploy into:
```hcl
scan_scope = "subscription"
```

**Entire tenant** — scans all subscriptions:
```hcl
scan_scope = "tenant"
```

**Specific management group** — scans subscriptions under a management group:
```hcl
scan_scope         = "tenant"
management_group_id = "YOUR-MG-ID"
```

See [INSTALL-GUIDE.md](INSTALL-GUIDE.md) for the full deployment walkthrough including tenant-wide RBAC, email authorization, and troubleshooting.

---

## What Gets Deployed

Terraform creates a single resource group (`rg-finops-scanner`) containing:

| Resource | Purpose |
|----------|---------|
| Automation Account | Hosts the runbook + daily schedule |
| Storage Account | Stores scan output (JSON, CSV, HTML) |
| Runbook (PowerShell 7.2) | Orchestrates the 24-module scan |
| Daily schedule | Triggers the scan at the configured time |
| Logic App + Office 365 connector | Sends the HTML email report |
| RBAC role assignments | Reader + Cost Management Reader on the scan scope |

### RBAC (read-only)

The Managed Identity gets **read-only** access:

| Role | Scope | Purpose |
|------|-------|---------|
| Reader | Subscription or management group | Enumerate resources |
| Cost Management Reader | Subscription or management group | Query Cost Management APIs |
| Storage Blob Data Owner | Storage account | Write scan results |

No write access to your resources. The identity can read and report, never modify.

### Cost

| Component | Monthly cost |
|-----------|-------------|
| Azure Automation | Free (within 500 min/month grant) |
| Storage | < $0.01 |
| Logic App | < $0.01 (one trigger/day) |
| **Total** | **< $1/month** (often free) |

---

## Project Structure

```
AzureFinOpsMultiTool-Automated/
├── terraform/
│   ├── main.tf                  # All infrastructure
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Deployment outputs
│   ├── terraform.tfvars.example # Configuration template
│   └── workbook.json            # Azure Workbook definition (optional)
├── function-app/
│   └── modules/                 # 24 PowerShell scan modules
├── runbook/
│   └── Run-FinOpsScan.ps1       # Orchestrator script
├── scripts/
│   └── Build-Runbook.ps1        # Assembles modules into single runbook
├── INSTALL-GUIDE.md             # Full deployment guide
└── README.md
```

### Build process

Azure Automation can't import multiple script files, so `Build-Runbook.ps1` concatenates all 24 modules + the orchestrator into a single `Run-FinOpsScan-Assembled.ps1` that gets uploaded as the runbook. Always run `Build-Runbook.ps1` before `terraform apply` if you've changed any module.

---

## Manual Trigger

Run a scan anytime from the Azure portal (**Automation Account > Runbooks > Run-FinOpsScan > Start**) or CLI:

```powershell
az automation runbook start `
  -g rg-finops-scanner `
  --automation-account-name aa-finops-scanner `
  -n Run-FinOpsScan
```

Monitor job status:
```powershell
az automation job list `
  -g rg-finops-scanner `
  --automation-account-name aa-finops-scanner `
  --query "[].{Status:status, Start:startTime}" -o table
```

---

## Related

- [Azure FinOps Multitool (Desktop)](https://github.com/z-larsen/Azure-FinOps-Multitool) — The interactive WPF version with GUI
- [FinOps Toolkit](https://github.com/microsoft/finops-toolkit) — Microsoft's official FinOps framework
- [INSTALL-GUIDE.md](INSTALL-GUIDE.md) — Full deployment walkthrough

---

## License

MIT
