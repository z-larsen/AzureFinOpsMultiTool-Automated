# FinOps Scanner — Azure Automation Deployment Guide

This guide walks you through deploying the FinOps Scanner as an Azure Automation runbook. By the end, you'll have a runbook that automatically scans your Azure environment every day and drops the results into blob storage as JSON and CSV files — plus optional dashboard and email delivery.

---

## How the Automation Version Differs from the GUI based Scanner

The original FinOps Multitool is a desktop app — you launch it, click Scan, and see results in a GUI. It runs once on your machine when you tell it to.

The Automation version:

- **Runs automatically** on a daily schedule (configurable)
- **No GUI** — it writes structured data (JSON + CSV) to a blob storage container instead of displaying grids
- **Authenticates with Managed Identity** — no interactive login, no stored passwords. Azure handles the credentials.
- **Runs in the cloud** — inside an Azure Automation Account, so there's nothing to host or maintain
- **Same scan modules** — the 21 scan modules are identical to the desktop version. Same APIs, same logic, same results.
- **One-step deployment** — Terraform deploys everything including the runbook code.
- **Two reporting options** — An Azure Workbook dashboard that queries Log Analytics in real time, and/or an HTML assessment report emailed directly to stakeholders after each scan. Enable one or both.

The output lands in a `finops-scans` blob container organized by date. Each run produces a full JSON file, individual CSVs per scan area (budgets, orphans, idle VMs, etc.), and an HTML report — all of which you can connect to Power BI, Excel, or Azure Workbooks.

---

## What Gets Deployed

Terraform creates all resources inside a single new resource group — nothing touches your existing infrastructure:

### Core (always deployed)

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | `rg-finops-scanner` | Container for everything below |
| Storage Account | `stfinopsscanner*` | Scan output blobs (shared key disabled — identity auth only) |
| Blob Container | `finops-scans` | Where scan results (JSON/CSV/HTML) are written |
| Automation Account | `aa-finops-scanner` | Hosts the runbook, schedule, and System Managed Identity |
| Runbook | `Run-FinOpsScan` | PowerShell 7.2 script — 24 modules assembled into a single file |
| Schedule | `daily-finops-scan` | Triggers the runbook daily at 6 AM UTC |
| Job Schedule | *(link)* | Connects the runbook to the schedule |
| Az Module (×1) | Az.ResourceGraph | Installed into PS 7.2 runtime (Az.Accounts, Az.Resources, Az.Storage are pre-installed globally) |
| Automation Variables (×3) | `FINOPS_TENANT_ID`, `FINOPS_STORAGE_ACCOUNT`, `FINOPS_CONTAINER_NAME` | Runtime configuration for the runbook |
| Automation Variable | `FINOPS_SUBSCRIPTION_FILTER` | *(only if `subscription_filter` is set)* Restricts which subs get scanned |
| RBAC: Reader | On scan scope (sub or MG) | Lets the Managed Identity enumerate resources |
| RBAC: Cost Management Reader | On scan scope (sub or MG) | Lets the Managed Identity query Cost Management APIs |
| RBAC: Storage Blob Data Owner | On the storage account | Lets the Managed Identity write scan output |
| RBAC: Storage Blob Data Contributor | On the storage account | Lets *you* (the deployer) browse scan results |

### Workbook Dashboard (`enable_workbook = true`, the default)

| Resource | Name | Purpose |
|----------|------|---------|
| Log Analytics Workspace | `law-finops-scanner` | Stores structured scan data for dashboard queries |
| LAW ↔ Automation Linked Service | *(auto)* | Links the Automation Account to Log Analytics |
| Data Collection Endpoint | `dce-finops-scanner` | Ingestion endpoint for the Logs Ingestion API |
| Custom Tables (×6) | `FinOpsScanSummary_CL`, `FinOpsCosts_CL`, `FinOpsResourceCosts_CL`, `FinOpsBudgets_CL`, `FinOpsOptimization_CL`, `FinOpsCostTrend_CL` | Structured scan data in Log Analytics |
| Data Collection Rule | `dcr-finops-scanner` | Maps 6 data streams to the 6 custom tables |
| Azure Workbook | FinOps Scanner Dashboard | Interactive portal dashboard — cost trends, budgets, optimization |
| Automation Variables (×2) | `FINOPS_DCE_ENDPOINT`, `FINOPS_DCR_IMMUTABLE_ID` | Tells the runbook where to push LAW data |
| RBAC: Monitoring Metrics Publisher | On the DCR | Lets the Managed Identity write to Log Analytics via the Logs Ingestion API |

### HTML Report Email (`report_recipients` is set)

| Resource | Name | Purpose |
|----------|------|---------|
| Office 365 API Connection | `office365-finops-scanner` | OAuth connector for sending email (authorize once in portal) |
| Logic App | `logic-finops-scanner-report` | Receives webhook POST from runbook, sends formatted email |
| HTTP Trigger | `manual-trigger` | Webhook endpoint the runbook calls after each scan |
| Send Email Action | `Send_Report_Email` | Formats scan summary + "View Full Report" button and sends via O365 |
| Automation Variable | `FINOPS_REPORT_WEBHOOK` | Logic App callback URL stored for the runbook |

> **One manual step:** After the first `terraform apply`, you need to authorize the Office 365 API connection once in the Azure portal. See [HTML Report Email](#html-report-email) below for instructions.

The storage account has shared key access **disabled** — everything authenticates through Azure AD and Managed Identity.

---

## Prerequisites

You need two tools installed on your machine.

### 1. Terraform (>= 1.5)

```powershell
winget install HashiCorp.Terraform
```

Verify: `terraform --version`

### 2. Azure CLI

```powershell
winget install Microsoft.AzureCLI
```

Verify: `az --version`

### Required Azure Permissions

Your Azure account needs:
- **Contributor** on the subscription (to create the resource group and resources)
- **User Access Administrator** or **Owner** on the subscription (to create the RBAC role assignments)

For **tenant-wide scanning**, you additionally need:
- **User Access Administrator** or **Owner** on the target management group (to assign Reader + Cost Management Reader at that scope)

If you don't have these, ask your admin to run the Terraform deployment for you, or to grant you these roles temporarily.

---

## Choose Your Scan Scope

Before deploying, decide how much of your environment you want to scan. This is the most important decision and it's controlled by a single setting in `terraform.tfvars`.

### Option A: Single Subscription (default)

The scanner covers only the subscription you deploy into. This is the right choice if:
- You only manage one subscription
- You're part of a larger org tenant but only have access to your own subscription
- You want to start small and expand later

**No configuration needed** — this is the default.

### Option B: Entire Tenant

The scanner covers every subscription in the tenant (or within a specific management group). This is what most FinOps teams want — a single daily scan across the whole organization.

Add this to `terraform.tfvars`:

```hcl
scan_scope = "tenant"
```

Terraform grants Reader + Cost Management Reader at the **tenant root management group**, which inherits down to every subscription. The Automation Account's Managed Identity can then enumerate and scan all of them automatically.

If you want to scope it to a specific management group (instead of the whole tenant), also set:

```hcl
scan_scope          = "tenant"
management_group_id = "YOUR-MANAGEMENT-GROUP-ID"
```

You can find your management group IDs in the Azure Portal under **Management groups**, or run:

```powershell
az account management-group list --output table
```

### What "Tenant-wide" Actually Does

When `scan_scope = "tenant"`, two things change:
1. **RBAC** is assigned at the management group level instead of the subscription level — Reader + Cost Management Reader inherit down to all child subscriptions
2. **The scan** calls `Get-AzSubscription` which returns every enabled subscription the identity can see, then runs all 21 scan modules against each one

The resources still deploy into a single subscription. Only the read-access RBAC scope changes.

---

## Step-by-Step Deployment

### Step 1 — Log in to Azure

Open a terminal and authenticate. This establishes who you are and which subscription Terraform will deploy into.

```powershell
az login
```

If you have multiple subscriptions, pick the one where you want the Automation Account to live:

```powershell
az account set --subscription "YOUR-SUBSCRIPTION-NAME-OR-ID"
```

**Multi-tenant note:** If your subscription lives in a different tenant than your home tenant (common in large orgs), you'll need to log in to that specific tenant:

```powershell
# List all subscriptions across all tenants
az account list --all --query "[].{Name:name, Sub:id, Tenant:tenantId}" -o table

# Login to the tenant that contains your subscription
az login --tenant YOUR-TENANT-ID
az account set --subscription YOUR-SUBSCRIPTION-ID
```

Terraform auto-detects your tenant ID and subscription from this login. No secrets to configure.

### Step 2 — Configure Your Deployment

Navigate to the terraform directory:

```powershell
cd AzureFinOpsFunction/terraform
```

Open `terraform.tfvars` and configure three things: scan scope, reporting mode, and (optionally) email delivery.

#### Scan Scope

**For single subscription** (default — no changes needed):
```hcl
# Everything commented out = scan the deploying subscription only
```

**For tenant-wide scanning:**
```hcl
scan_scope = "tenant"
```

**For a specific management group:**
```hcl
scan_scope          = "tenant"
management_group_id = "mg-production"
```

#### Reporting Mode

You have two independent options — enable one or both:

| Setting | What it adds | Default |
|---------|-------------|--------|
| `enable_workbook = true` | LAW + DCE/DCR pipeline + Azure Workbook dashboard | **enabled** |
| `report_recipients = "..."` | Logic App + HTML email report after each scan | **disabled** |

**Workbook dashboard only** (the default — no changes needed):
```hcl
# enable_workbook defaults to true
```

**HTML email only** (lightweight, no Log Analytics):
```hcl
enable_workbook   = false
report_recipients = "team@example.com"
```

**Both** (recommended for full coverage):
```hcl
# enable_workbook defaults to true
report_recipients = "cfo@example.com;finops-team@example.com"
```

Multiple recipients are separated by semicolons.

### Step 3 — Deploy Everything

This creates all resources, uploads the runbook, imports the Az modules, and links the schedule. Takes about 2-3 minutes.

```powershell
terraform init
terraform plan
```

Review the plan — you should see resources to create, nothing to destroy. If that looks right:

```powershell
terraform apply
```

Type `yes` when prompted. That's the entire deployment. No zip files, no manual uploads, no second step.

### Step 4 — Wait for Module Import

Terraform imports Az.ResourceGraph into the Automation Account's PowerShell 7.2 runtime. This takes **2-5 minutes**. The other Az modules (Az.Accounts, Az.Resources, Az.Storage) are pre-installed globally.

Check progress in the portal: **Automation Account** > **Modules** — Az.ResourceGraph shows "Available" when ready.

Wait until it shows `Succeeded` before running the scan.

### Step 5 — Test It

In the Azure Portal:

1. Navigate to **Automation Accounts** > **aa-finops-scanner**
2. Click **Runbooks** in the left sidebar
3. Click **Run-FinOpsScan**
4. Click **Start**
5. Watch the output in the **Output** tab

Or from the CLI:

```powershell
az automation runbook start -g rg-finops-scanner --automation-account-name aa-finops-scanner -n Run-FinOpsScan
```

The scan runs all 21 modules against your subscription(s) and writes results to `finops-scans/{date}/` in blob storage. A full scan typically takes 5-15 minutes depending on environment size.

---

## Reporting Options

### Azure Workbook Dashboard

When `enable_workbook = true` (the default), Terraform deploys a Log Analytics Workspace with 6 custom tables and an Azure Workbook. After each scan, the runbook pushes structured data to Log Analytics via the Logs Ingestion API. The Workbook queries that data in real time.

To open the dashboard:

1. Navigate to **Resource Groups** > **rg-finops-scanner**
2. Click the **FinOps Scanner Dashboard** workbook
3. Or use the direct link from `terraform output workbook_id`

The dashboard includes tabs for:
- **Scan Summary** — run history, duration, success/failure counts
- **Cost Overview** — per-subscription actual vs. forecast spend
- **Top Resources** — highest-cost resources across all subscriptions
- **Budget Health** — budget utilization and risk levels
- **Optimization** — Advisor recommendations, orphaned resources, idle VMs, AHB candidates
- **Cost Trend** — month-over-month spend trend

Data flows in automatically after each scan — no additional configuration needed.

### HTML Report Email

When `report_recipients` is set, Terraform deploys a Logic App that sends a formatted HTML report via email after each scan. The report is a self-contained 9-section document covering the same areas as the Workbook, but delivered as a portable HTML file.

After each scan, the runbook:
1. Generates a self-contained HTML report
2. Base64-encodes the report
3. POSTs to the Logic App webhook with the encoded report and scan summary
4. The Logic App sends an email with a scan summary table and the HTML report as an attachment

**Important:** The Logic App uses an Office 365 API connection for email. After the first `terraform apply`, you need to authorize it once:

1. Navigate to **Resource Groups** > **rg-finops-scanner** > **logic-finops-scanner-report**
2. Click **API connections** in the left sidebar under Development Tools 
3. Click the **office365** connection > **Edit API connection** > **Authorize**
4. Sign in with the account that should send the emails
5. Click **Save**

This is a one-time step. After authorization, emails flow automatically with each scan.

---

## Checking Scan Output

After a scan completes, browse the results:

```powershell
az storage blob list `
    --account-name STORAGE_ACCOUNT_NAME `
    --container-name finops-scans `
    --auth-mode login `
    --output table
```

Replace `STORAGE_ACCOUNT_NAME` with the value from `terraform output storage_account_name`.

You'll see files like:

```
2026-05-05/2026-05-05T06-00-00-scan.json      (full scan — all data in one file)
2026-05-05/2026-05-05T06-00-00-budgets.csv     (budget status per subscription)
2026-05-05/2026-05-05T06-00-00-orphans.csv     (orphaned resources)
2026-05-05/2026-05-05T06-00-00-idleVMs.csv     (idle virtual machines)
2026-05-05/2026-05-05T06-00-00-optimization.csv (Advisor recommendations)
2026-05-05/2026-05-05T06-00-00-report.html     (self-contained HTML assessment)
...
```

The JSON file contains everything. The CSVs are broken out per scan area for easy Power BI or Excel consumption. The HTML report is a standalone document you can open in any browser or forward to stakeholders.

---

## Updating the Runbook Code

When the scan modules get updated, just re-run Terraform — it reads the script file and updates the runbook automatically:

```powershell
cd AzureFinOpsFunction/terraform
terraform apply
```

---

## Tearing It Down

Everything lives in one resource group. To remove it all:

```powershell
cd AzureFinOpsFunction/terraform
terraform destroy
```

Type `yes` when prompted. This deletes all resources and their data. Nothing else in your subscription is affected.

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Runbook fails immediately | Az.ResourceGraph still importing | Wait for Az.ResourceGraph to show "Available" in the Automation Account's Modules page |
| `Connect-AzAccount -Identity` fails | Managed Identity not enabled or RBAC not propagated | Check identity: Portal > Automation Account > Identity. Wait 1-2 min after deploy for RBAC. |
| `403` during `terraform apply` on storage container | Org policy blocks shared key auth on storage | Already handled — `storage_use_azuread = true` is set on the Terraform provider |
| Scan runs but no blobs appear | `FINOPS_STORAGE_ACCOUNT` variable not set | Check: Portal > Automation Account > Variables |
| Scan shows 0 subscriptions | Wrong tenant or no RBAC | Verify the Automation Account's identity has Reader on the correct scope |
| Schedule doesn't fire | Schedule set to start tomorrow | By design — the first automatic run is 24h after deploy. Use the Start button to test now. |
| Workbook shows no data | DCE/DCR variables missing or RBAC not propagated | Check Automation Variables for `FINOPS_DCE_ENDPOINT` and `FINOPS_DCR_IMMUTABLE_ID`. Verify Monitoring Metrics Publisher role on the DCR. |
| LAW ingestion warning in runbook output | `enable_workbook = false` | Expected — the runbook skips LAW ingestion when the DCE/DCR vars aren't configured. |
| Email not received after scan | Logic App API connection not authorized | Follow the one-time authorization steps under **HTML Report Email** above. |
| Email not received (webhook warning) | `FINOPS_REPORT_WEBHOOK` variable missing | Set `report_recipients` in `terraform.tfvars` and re-run `terraform apply`. |
| HTML report not in email | Report too large to attach | Download the HTML file directly from blob storage. |

---

## Cost

Azure Automation includes a **free tier of 500 minutes per month**. At one scan per day running ~10 minutes:

- **Automation**: ~300 min/month — **free** (within the 500-minute grant)
- **Storage**: < $0.01/month for scan output and HTML reports
- **Log Analytics** (if `enable_workbook = true`): < $1/month for scan data ingestion
- **Logic App** (if `report_recipients` set): < $0.01/month — one trigger per day is well within the free tier

Total: **under $2/month** in most cases, often completely free.
