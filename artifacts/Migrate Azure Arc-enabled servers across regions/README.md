# Migrate Azure Arc-enabled servers across regions (qatarcentral → westeurope)

Automates the Microsoft-supported procedure for moving Azure Arc-enabled
servers from one region to another. Because an Arc resource's **name and region
are immutable**, the move is a *delete-and-recreate*: audit extensions → remove
them → `azcmagent disconnect` (deletes the Azure resource) → `azcmagent connect`
to the target region → redeploy extensions.

Reference: [How to rename Azure Arc-enabled servers and migrate across regions](https://learn.microsoft.com/azure/azure-arc/servers/manage-howto-migrate)

---

## ⚠️ Read before running

- The Azure resource is **deleted and recreated** → short **downtime** and
  **loss of Azure-side metadata** (activity log, Azure tags, role assignments
  scoped to the old resource).
- **Protected (secret) extension settings cannot be read back** and are not
  restored automatically — reconfigure those manually after the move.
- Requires **customer sign-off**. **Pilot a single non-critical server first.**
- The reconnect (`azcmagent connect`) always executes **on the server** — either
  you run the worker locally, or you trigger it remotely (Run Command / WinRM).

---

## Which script to use

| Script | Runs from | Reaches the server via | Use when |
|---|---|---|---|
| **`migrate-arc-region-cli.sh`** | Azure CLI (Cloud Shell / any box with `az`) | **Arc Run Command** — no RDP/SSH/WinRM | You want to drive everything from Azure CLI and **not log into the VMs**. Agent must be **v1.33+** and online. |
| **`Invoke-BulkArcMigration.ps1`** | A Windows admin/jump box | **PowerShell Remoting (WinRM)** | You can remote into the servers over WinRM. |
| **`Migrate-ArcServerRegion.ps1`** | The server itself | n/a (local) | Single machine, run interactively on the box. Also the worker invoked by the WinRM orchestrator. |

> **Can it be 100% Azure CLI with no VM login?** Almost. The extension audit,
> removal and redeploy are pure control-plane. The **reconnect must run on the
> machine**, but the CLI script triggers it through **Arc Run Command** so you
> never open RDP/SSH. Because the disconnect deletes the resource (and Run
> Command reports through it), success is confirmed by **polling for the new
> resource in the target region**, not by the Run Command exit code.

---

## Option A — Azure CLI only, no VM login (`migrate-arc-region-cli.sh`)

Runs from Azure Cloud Shell (or any host with `az` + `jq`). CSV columns:
`MachineName,ResourceGroup,NewResourceName` (see `servers.cli.sample.csv`).

```bash
# Dry run (no changes)
./migrate-arc-region-cli.sh \
    --csv servers.cli.sample.csv \
    --subscription <sub-id> --tenant <tenant-id> \
    --target-rg rg-arc-westeurope \
    --spn-id <appId> --spn-secret <secret> \
    --dry-run

# Live run (skip prompt with --yes)
./migrate-arc-region-cli.sh \
    --csv servers.cli.sample.csv \
    --subscription <sub-id> --tenant <tenant-id> \
    --target-rg rg-arc-westeurope \
    --spn-id <appId> --spn-secret <secret> --yes
```

What it does per server: verify source region → back up extensions to
`./arc-migration-backup/` → remove extensions → **Arc Run Command**
(`azcmagent disconnect` + `azcmagent connect --location westeurope`) → poll for
the recreated resource → redeploy extensions → write a CSV report.
Secrets (ARM token + SP secret) are passed as **protected parameters** so they
aren't stored in the Run Command output.

**Prerequisites:** `az` with the `connectedmachine` extension (auto-installs),
`jq`, a service principal with rights to delete the source and create the
target resource, and Connected Machine agent **v1.33+** (online) on each server.

## Option B — Bulk over WinRM (`Invoke-BulkArcMigration.ps1`)

Fans out from a Windows admin box to each server over PowerShell Remoting and
runs `Migrate-ArcServerRegion.ps1` locally on it. CSV columns:
`ServerName,ResourceName,Tags,Wave` (see `servers.sample.csv`).

```powershell
.\Invoke-BulkArcMigration.ps1 -InputCsv .\servers.sample.csv -Wave 1 `
    -SubscriptionId <sub> -TenantId <tenant> `
    -TargetResourceGroup rg-arc-westeurope `
    -ServicePrincipalId <appId> -ServicePrincipalSecret <secret> -DryRun
```

## Option C — Single machine, run locally (`Migrate-ArcServerRegion.ps1`)

```powershell
# Dry run
.\Migrate-ArcServerRegion.ps1 -SubscriptionId <sub> -TenantId <tenant> `
    -TargetResourceGroup rg-arc-westeurope -WhatIf

# Live, unattended
.\Migrate-ArcServerRegion.ps1 -SubscriptionId <sub> -TenantId <tenant> `
    -TargetResourceGroup rg-arc-westeurope `
    -ServicePrincipalId <appId> -ServicePrincipalSecret <secret> -Force
```

---

## Common parameters

| Parameter / flag | Default | Description |
|---|---|---|
| Subscription / Tenant | — | Target subscription and Azure AD tenant |
| Target resource group | — | Resource group in the target region |
| Source region | `qatarcentral` | Safety check — the tools skip machines not in this region |
| Target region | `westeurope` | Destination region |
| New resource name | current name | Optionally rename the Arc resource on reconnect |
| Service principal | — | Required for unattended runs (and for the CLI/WinRM options) |

---

## Recommended rollout

1. **Dry run** first and review the planned actions per server.
2. Migrate **one** pilot server; confirm it reports healthy in the target region
   and that reporting/telemetry is intact.
3. Roll out in small **waves** during a maintenance window.
4. In the target region, enable/deploy the **Arc-enabled SQL Server** extension
   on the SQL hosts — the step that isn't available in the source region.

> Files: `migrate-arc-region-cli.sh`, `Invoke-BulkArcMigration.ps1`,
> `Migrate-ArcServerRegion.ps1`, `servers.cli.sample.csv`, `servers.sample.csv`.
> A Linux/`bash` on-machine worker for Option B/C can be added on request.
