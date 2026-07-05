<#
.SYNOPSIS
    Migrates an Azure Arc-enabled server from one Azure region to another
    (default: Qatar Central -> West Europe) using the Microsoft-supported
    disconnect / reconnect procedure.

.DESCRIPTION
    Azure Arc resource names and regions are immutable. To move an Arc-enabled
    server to a new region you must DELETE the Azure resource and RECREATE it in
    the target region. This script automates the supported flow:

        1. Pre-flight checks (agent present + connected, source region matches)
        2. Audit and back up the installed VM extensions to a JSON file
        3. Remove all VM extensions
        4. Disconnect the Connected Machine agent (deletes the Azure resource)
        5. Reconnect the agent to the target region / resource group
        6. Redeploy the extensions from the backup

    Reference (Microsoft Learn):
    https://learn.microsoft.com/azure/azure-arc/servers/manage-howto-migrate

    >>> RUN THIS LOCALLY ON EACH ARC-ENABLED SERVER (it invokes azcmagent). <<<

.NOTES
    IMPORTANT - read before running in production:
      * The Azure resource is DELETED and recreated. Expect a short window of
        downtime and LOSS OF RESOURCE METADATA (activity log, tags applied in
        Azure, role assignments scoped to the old resource, etc.).
      * Extension PROTECTED settings (secrets) cannot be read back and are NOT
        restored automatically - reconfigure those manually after the move.
      * Requires customer sign-off. PILOT on a single non-critical server first.

    Prerequisites on the machine:
      * Azure Connected Machine agent (azcmagent) installed and connected
      * Azure CLI (az) with the 'connectedmachine' extension
        (az extension add --name connectedmachine)
      * An identity (service principal recommended) with rights to delete the
        source Arc resource and create the target one

.EXAMPLE
    # Dry run - shows every step without changing anything
    .\Migrate-ArcServerRegion.ps1 -SubscriptionId <sub> -TenantId <tenant> `
        -TargetResourceGroup rg-arc-westeurope -WhatIf

.EXAMPLE
    # Real migration with a service principal, unattended
    .\Migrate-ArcServerRegion.ps1 -SubscriptionId <sub> -TenantId <tenant> `
        -TargetResourceGroup rg-arc-westeurope `
        -ServicePrincipalId <appId> -ServicePrincipalSecret <secret> -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]  $SubscriptionId,
    [Parameter(Mandatory)][string]  $TenantId,
    [Parameter(Mandatory)][string]  $TargetResourceGroup,

    [string]   $SourceRegion          = 'qatarcentral',
    [string]   $TargetRegion          = 'westeurope',
    [string]   $ResourceName,                       # optional: keep or rename the Arc resource
    [string]   $ServicePrincipalId,
    [string]   $ServicePrincipalSecret,
    [string[]] $Tags,                               # e.g. @('project=MCIT-SQL-Reclass','wave=1')
    [string]   $Cloud                 = 'AzureCloud',
    [string]   $CorrelationId,
    [string]   $BackupPath            = (Join-Path $env:ProgramData 'ArcMigration'),
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $Hint"
    }
}

function Invoke-Azcmagent {
    param([string[]]$Arguments)
    Write-Log ("azcmagent " + ($Arguments -join ' ')) 'INFO'
    & azcmagent @Arguments
    if ($LASTEXITCODE -ne 0) { throw "azcmagent exited with code $LASTEXITCODE" }
}

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
Write-Log "Arc region migration : $SourceRegion -> $TargetRegion" 'STEP'
Assert-Command -Name 'azcmagent' -Hint 'Install the Azure Connected Machine agent first.'
Assert-Command -Name 'az'        -Hint 'Install Azure CLI: https://aka.ms/azcli'

# Confirm the connected-machine CLI extension is present
$null = az extension show --name connectedmachine 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Installing Azure CLI 'connectedmachine' extension..." 'INFO'
    az extension add --name connectedmachine --only-show-errors | Out-Null
}

# Read current agent status (JSON)
$status = (& azcmagent show -j) | ConvertFrom-Json
if (-not $status) { throw "Unable to read azcmagent status. Is the agent installed?" }

$currentName   = $status.resourceName
$currentRegion = $status.location
$currentRg     = $status.resourceGroup
$agentState    = $status.status

Write-Log "Current resource : $currentName" 'INFO'
Write-Log "Current region   : $currentRegion" 'INFO'
Write-Log "Current RG       : $currentRg" 'INFO'
Write-Log "Agent status     : $agentState" 'INFO'

if ($agentState -ne 'Connected') {
    throw "Agent is not connected (status='$agentState'). Nothing to migrate."
}
if ($currentRegion -and ($currentRegion -notlike "*$SourceRegion*")) {
    throw "Machine is in '$currentRegion', not the expected source region '$SourceRegion'. Aborting as a safety check. Override with -SourceRegion if intended."
}

if (-not $ResourceName) { $ResourceName = $currentName }

# ---------------------------------------------------------------------------
# 2. Authenticate to Azure (service principal preferred; else interactive)
# ---------------------------------------------------------------------------
Write-Log "Authenticating to Azure..." 'STEP'
if ($ServicePrincipalId -and $ServicePrincipalSecret) {
    az login --service-principal -u $ServicePrincipalId -p $ServicePrincipalSecret --tenant $TenantId --only-show-errors | Out-Null
} else {
    Write-Log "No service principal supplied - falling back to interactive/device login." 'WARN'
    az login --tenant $TenantId --only-show-errors | Out-Null
}
az account set --subscription $SubscriptionId
$AccessToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
if (-not $AccessToken) { throw "Failed to acquire an Azure Resource Manager access token." }

# ---------------------------------------------------------------------------
# 3. Audit + back up installed extensions
# ---------------------------------------------------------------------------
Write-Log "Auditing installed VM extensions..." 'STEP'
$extensions = az connectedmachine extension list `
    --machine-name $currentName `
    --resource-group $currentRg `
    --subscription $SubscriptionId `
    --only-show-errors -o json | ConvertFrom-Json

if (-not (Test-Path $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }
$stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$backupFile = Join-Path $BackupPath "$currentName-extensions-$stamp.json"
$extensions | ConvertTo-Json -Depth 10 | Set-Content -Path $backupFile -Encoding UTF8

$extCount = @($extensions).Count
Write-Log "Found $extCount extension(s). Backup saved to: $backupFile" 'INFO'
foreach ($e in $extensions) { Write-Log ("  - {0} ({1}/{2})" -f $e.name, $e.properties.publisher, $e.properties.type) 'INFO' }

# ---------------------------------------------------------------------------
# 4. Confirmation gate
# ---------------------------------------------------------------------------
$banner = @"
------------------------------------------------------------------
 This will DELETE the Azure Arc resource '$currentName' in
 '$currentRegion' and RECREATE it in '$TargetRegion'
 (resource group '$TargetResourceGroup').

 * Temporary downtime + loss of Azure-side resource metadata.
 * $extCount extension(s) will be removed and redeployed.
 * Protected (secret) extension settings are NOT restored automatically.
------------------------------------------------------------------
"@
Write-Host $banner -ForegroundColor Yellow
if (-not $Force -and -not $PSCmdlet.ShouldProcess($currentName, "Migrate $currentRegion -> $TargetRegion")) {
    Write-Log "Aborted by user / -WhatIf. No changes made." 'WARN'
    return
}

# ---------------------------------------------------------------------------
# 5. Remove extensions
# ---------------------------------------------------------------------------
if ($extCount -gt 0) {
    Write-Log "Removing extensions..." 'STEP'
    foreach ($e in $extensions) {
        if ($PSCmdlet.ShouldProcess($e.name, "Remove extension")) {
            az connectedmachine extension delete `
                --machine-name $currentName `
                --resource-group $currentRg `
                --subscription $SubscriptionId `
                --name $e.name --yes --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw "Failed to remove extension '$($e.name)'." }
            Write-Log "  removed $($e.name)" 'INFO'
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Disconnect (deletes the Azure resource in the source region)
# ---------------------------------------------------------------------------
Write-Log "Disconnecting from Azure Arc (deletes source resource)..." 'STEP'
if ($PSCmdlet.ShouldProcess($currentName, "azcmagent disconnect")) {
    Invoke-Azcmagent @('disconnect', '--access-token', $AccessToken)
    Write-Log "Disconnected. Source resource removed." 'INFO'
}

# ---------------------------------------------------------------------------
# 7. Reconnect to the target region
# ---------------------------------------------------------------------------
Write-Log "Reconnecting to Azure Arc in '$TargetRegion'..." 'STEP'
$connectArgs = @(
    'connect',
    '--resource-group',  $TargetResourceGroup,
    '--tenant-id',       $TenantId,
    '--location',        $TargetRegion,
    '--subscription-id', $SubscriptionId,
    '--resource-name',   $ResourceName,
    '--cloud',           $Cloud,
    '--access-token',    $AccessToken
)
if ($CorrelationId) { $connectArgs += @('--correlation-id', $CorrelationId) }
if ($Tags)          { $connectArgs += @('--tags', ($Tags -join ',')) }

if ($PSCmdlet.ShouldProcess($ResourceName, "azcmagent connect -> $TargetRegion")) {
    Invoke-Azcmagent $connectArgs
    Write-Log "Reconnected as '$ResourceName' in '$TargetRegion'." 'INFO'
}

# ---------------------------------------------------------------------------
# 8. Redeploy extensions from backup
# ---------------------------------------------------------------------------
if ($extCount -gt 0) {
    Write-Log "Redeploying $extCount extension(s) in the target region..." 'STEP'
    foreach ($e in $extensions) {
        $createArgs = @(
            'connectedmachine','extension','create',
            '--machine-name',   $ResourceName,
            '--resource-group', $TargetResourceGroup,
            '--subscription',   $SubscriptionId,
            '--name',           $e.name,
            '--location',       $TargetRegion,
            '--publisher',      $e.properties.publisher,
            '--type',           $e.properties.type,
            '--only-show-errors'
        )
        if ($e.properties.settings) {
            $settingsJson = ($e.properties.settings | ConvertTo-Json -Depth 10 -Compress)
            $createArgs += @('--settings', $settingsJson)
        }
        if ($e.properties.PSObject.Properties.Name -contains 'protectedSettings') {
            Write-Log "  '$($e.name)' had protected settings - reconfigure secrets manually." 'WARN'
        }
        if ($PSCmdlet.ShouldProcess($e.name, "Redeploy extension")) {
            az @createArgs
            if ($LASTEXITCODE -ne 0) { Write-Log "  WARNING: failed to redeploy $($e.name) - redeploy manually." 'WARN' }
            else { Write-Log "  redeployed $($e.name)" 'INFO' }
        }
    }
}

Write-Log "Migration complete for '$ResourceName'. Verify in the Azure portal (Azure Arc > Machines)." 'STEP'
Write-Log "Extension backup retained at: $backupFile" 'INFO'
