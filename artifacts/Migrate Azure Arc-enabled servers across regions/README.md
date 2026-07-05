# Migrate Azure Arc-enabled servers across regions 

Automates the Microsoft-supported procedure for moving an Azure Arc-enabled
server from one region to another. Because an Arc resource's **name and region
are immutable**, the move is a *delete-and-recreate*: audit extensions → remove
them → `azcmagent disconnect` (deletes the Azure resource) → `azcmagent connect`
to the target region → redeploy extensions.

Reference: [How to rename Azure Arc-enabled servers and migrate across regions](https://learn.microsoft.com/azure/azure-arc/servers/manage-howto-migrate)

---

## ⚠️ Read before running

- The Azure resource is **deleted and recreated** → short **downtime** and
  **loss of Azure-side metadata** (activity log, Azure tags, role assignments
  scoped to the old resource).
- **Qatar Central does not support Arc-enabled SQL.** The SQL Server extension
  can only be deployed **after** the machine lands in West Europe.
- **Protected (secret) extension settings cannot be read back** and are not
  restored automatically — reconfigure those manually after the move.
- Requires **customer sign-off**. **Pilot on a single non-critical server first.**
- Run the script **locally on each Arc-enabled server** — it invokes `azcmagent`.

## Prerequisites

| Requirement | Notes |
|---|---|
| Azure Connected Machine agent (`azcmagent`) | Installed and in `Connected` state |
| Azure CLI (`az`) | The script auto-installs the `connectedmachine` extension |
| Azure identity | Service principal recommended; needs rights to delete the source resource and create the target one in the destination resource group |

## Usage

**Dry run** (no changes — prints every step):
```powershell
.\Migrate-ArcServerRegion.ps1 `
    -SubscriptionId  <sub-id> `
    -TenantId        <tenant-id> `
    -TargetResourceGroup rg-arc-westeurope `
    -WhatIf
```

**Unattended migration** with a service principal:
```powershell
.\Migrate-ArcServerRegion.ps1 `
    -SubscriptionId  <sub-id> `
    -TenantId        <tenant-id> `
    -TargetResourceGroup rg-arc-westeurope `
    -ServicePrincipalId     <app-id> `
    -ServicePrincipalSecret  <secret> `
    -Tags @('project=MCIT-SQL-Reclass','wave=1') `
    -Force
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `SubscriptionId` | ✅ | — | Target subscription |
| `TenantId` | ✅ | — | Azure AD tenant |
| `TargetResourceGroup` | ✅ | — | Resource group in the target region |
| `SourceRegion` | | `qatarcentral` | Safety check — script aborts if the machine isn't here |
| `TargetRegion` | | `westeurope` | Destination region |
| `ResourceName` | | current name | Optionally rename the Arc resource on reconnect |
| `ServicePrincipalId` / `ServicePrincipalSecret` | | — | Unattended auth (else interactive login) |
| `Tags` | | — | Tags applied on reconnect, e.g. `@('project=MCIT-SQL-Reclass')` |
| `CorrelationId` | | — | Optional onboarding correlation id |
| `BackupPath` | | `%ProgramData%\ArcMigration` | Where the extension backup JSON is written |
| `Force` | | off | Skip the confirmation prompt |

## What the script does

1. **Pre-flight** — verifies `azcmagent`/`az`, reads current status, and confirms
   the machine is `Connected` and in the expected source region.
2. **Audit + backup** — exports installed extensions to a timestamped JSON file
   under `BackupPath` (your rollback reference).
3. **Confirmation gate** — summarises the impact; skip with `-Force`, preview
   with `-WhatIf`.
4. **Remove extensions** → **disconnect** (deletes source resource) →
   **reconnect** to the target region → **redeploy extensions** from the backup.
5. **Verify** — check **Azure Arc → Machines** in the portal.

## Recommended rollout

1. Run with `-WhatIf` on the pilot server and review the planned actions.
2. Migrate **one** pilot server; confirm it reports healthy in West Europe and
   that reporting/telemetry is intact.
3. Roll out in small waves (tag with `wave=N`) during a maintenance window.
4. In West Europe, enable/deploy the **Arc-enabled SQL Server** extension on the
   SQL hosts — the step that isn't possible in Qatar Central.

> Linux estate: a `bash` equivalent using the same `azcmagent` flow can be added
> on request.
