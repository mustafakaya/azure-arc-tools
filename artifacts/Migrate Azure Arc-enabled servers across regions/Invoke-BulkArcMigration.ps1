<#
.SYNOPSIS
    Bulk-migrates many Azure Arc-enabled servers from one region to another
    (default: Qatar Central -> West Europe) by fanning out to each server over
    PowerShell Remoting and running Migrate-ArcServerRegion.ps1 locally on it.

.DESCRIPTION
    'azcmagent disconnect/connect' must run ON each machine, so this orchestrator:
        1. Reads a server list (-ServerName array or -InputCsv file)
        2. Opens a PowerShell Remoting (WinRM) session to each server
        3. Copies the worker script (Migrate-ArcServerRegion.ps1) to the server
        4. Runs it locally with the shared migration parameters
        5. Continues on error and writes a per-server CSV summary report

    Reference (Microsoft Learn):
    https://learn.microsoft.com/azure/azure-arc/servers/manage-howto-migrate

.NOTES
    Requirements / caveats:
      * Target servers must be reachable via PowerShell Remoting (WinRM).
        Use -Credential and -UseSSL as your environment requires.
      * Each server must have the Connected Machine agent (azcmagent) and
        Azure CLI (az) installed.
      * Use a SERVICE PRINCIPAL for auth - interactive 'az login' cannot
        complete inside an unattended remote session.
      * The migration DELETES and recreates each Azure resource -> downtime and
        loss of Azure-side metadata. Get customer sign-off; pilot Wave 1 first.

    CSV format (headers): ServerName,ResourceName,Tags,Wave
      * ServerName   (required) - hostname / WinRM target
      * ResourceName (optional) - rename the Arc resource on reconnect
      * Tags         (optional) - semicolon-separated, e.g. project=arc-migration;wave=1
      * Wave         (optional) - integer, used with -Wave to run in batches

.EXAMPLE
    # Dry run for wave 1 from a CSV (previews each server, no changes)
    .\Invoke-BulkArcMigration.ps1 -InputCsv .\servers.csv -Wave 1 `
        -SubscriptionId <sub> -TenantId <tenant> `
        -TargetResourceGroup rg-arc-westeurope `
        -ServicePrincipalId <appId> -ServicePrincipalSecret <secret> -DryRun

.EXAMPLE
    # Real run for an explicit list of servers
    .\Invoke-BulkArcMigration.ps1 -ServerName sql-qc-01,sql-qc-02 `
        -SubscriptionId <sub> -TenantId <tenant> `
        -TargetResourceGroup rg-arc-westeurope `
        -ServicePrincipalId <appId> -ServicePrincipalSecret <secret> `
        -Credential (Get-Credential) -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'List')][string[]] $ServerName,
    [Parameter(Mandatory, ParameterSetName = 'Csv')] [string]   $InputCsv,

    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][string] $TenantId,
    [Parameter(Mandatory)][string] $TargetResourceGroup,

    [string]   $SourceRegion           = 'qatarcentral',
    [string]   $TargetRegion           = 'westeurope',
    [string]   $ServicePrincipalId,
    [string]   $ServicePrincipalSecret,
    [string[]] $Tags,
    [string]   $Cloud                  = 'AzureCloud',

    [string]        $WorkerScript      = (Join-Path $PSScriptRoot 'Migrate-ArcServerRegion.ps1'),
    [pscredential]  $Credential,
    [switch]        $UseSSL,
    [int]           $Wave,
    [string]        $RemoteStagePath   = 'C:\Windows\Temp\Migrate-ArcServerRegion.ps1',
    [string]        $ReportPath        = (Join-Path $PSScriptRoot ("arc-migration-report-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]        $DryRun,
    [switch]        $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','STEP')][string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Resolve the work list
# ---------------------------------------------------------------------------
if (-not (Test-Path $WorkerScript)) {
    throw "Worker script not found: $WorkerScript (expected Migrate-ArcServerRegion.ps1 alongside this file)."
}

if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
    $rows = @(Import-Csv -Path $InputCsv)
} else {
    $rows = @($ServerName | ForEach-Object { [pscustomobject]@{ ServerName = $_ } })
}

# Optional wave filter (only rows that actually carry a Wave column)
if ($PSBoundParameters.ContainsKey('Wave')) {
    $rows = @($rows | Where-Object {
        ($_.PSObject.Properties.Name -contains 'Wave') -and ("$($_.Wave)" -ne '') -and ([int]$_.Wave -eq $Wave)
    })
}

$rows = @($rows | Where-Object { "$($_.ServerName)".Trim() -ne '' })
if ($rows.Count -eq 0) { throw "No servers to process (check the list / -Wave filter)." }

if (-not ($ServicePrincipalId -and $ServicePrincipalSecret)) {
    Write-Log "No service principal supplied. Interactive 'az login' will NOT work over remoting - provide -ServicePrincipalId/-ServicePrincipalSecret for unattended bulk runs." 'WARN'
}

# ---------------------------------------------------------------------------
# Confirmation gate (once, up front)
# ---------------------------------------------------------------------------
$mode = if ($DryRun) { 'DRY RUN (no changes)' } else { 'LIVE migration' }
$banner = @"
------------------------------------------------------------------
 Bulk Arc region migration : $SourceRegion -> $TargetRegion
 Mode      : $mode
 Servers   : $($rows.Count)
 Target RG : $TargetResourceGroup
 Each server's Azure resource is DELETED and recreated (downtime +
 loss of Azure-side metadata). Extensions are backed up, removed and
 redeployed on every server.
------------------------------------------------------------------
"@
Write-Host $banner -ForegroundColor Yellow
Write-Log ("Targets: " + (($rows | ForEach-Object { $_.ServerName }) -join ', ')) 'INFO'

if (-not $Force -and -not $DryRun) {
    $answer = Read-Host "Type 'yes' to proceed"
    if ($answer -ne 'yes') { Write-Log "Aborted by user. No changes made." 'WARN'; return }
}

# ---------------------------------------------------------------------------
# Process each server
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {
    $server  = "$($row.ServerName)".Trim()
    $session = $null
    $record  = [ordered]@{
        ServerName = $server
        Status     = 'Pending'
        Detail     = ''
        StartTime  = (Get-Date).ToString('s')
        EndTime    = ''
    }
    Write-Log "==== $server ====" 'STEP'

    try {
        # Build the parameter set for the worker running on the remote machine
        $workerParams = @{
            SubscriptionId      = $SubscriptionId
            TenantId            = $TenantId
            TargetResourceGroup = $TargetResourceGroup
            SourceRegion        = $SourceRegion
            TargetRegion        = $TargetRegion
            Cloud               = $Cloud
        }
        if ($ServicePrincipalId)     { $workerParams.ServicePrincipalId     = $ServicePrincipalId }
        if ($ServicePrincipalSecret) { $workerParams.ServicePrincipalSecret = $ServicePrincipalSecret }
        if (($row.PSObject.Properties.Name -contains 'ResourceName') -and $row.ResourceName) {
            $workerParams.ResourceName = "$($row.ResourceName)".Trim()
        }
        # Per-row tags override the global -Tags
        if (($row.PSObject.Properties.Name -contains 'Tags') -and $row.Tags) {
            $workerParams.Tags = @("$($row.Tags)" -split ';' | Where-Object { $_ -ne '' })
        } elseif ($Tags) {
            $workerParams.Tags = $Tags
        }
        if ($DryRun) { $workerParams.WhatIf = $true } else { $workerParams.Force = $true }

        # Open the remoting session
        $sessionParams = @{ ComputerName = $server; ErrorAction = 'Stop' }
        if ($Credential) { $sessionParams.Credential = $Credential }
        if ($UseSSL)     { $sessionParams.UseSSL     = $true }
        $session = New-PSSession @sessionParams

        # Stage the worker script on the remote machine, then run it locally there
        Copy-Item -Path $WorkerScript -Destination $RemoteStagePath -ToSession $session -Force

        Invoke-Command -Session $session -ScriptBlock {
            param($ScriptPath, $Params)
            & $ScriptPath @Params
        } -ArgumentList $RemoteStagePath, $workerParams

        $record.Status = if ($DryRun) { 'DryRun-OK' } else { 'Succeeded' }
        Write-Log "$server : $($record.Status)" 'INFO'
    }
    catch {
        $record.Status = 'Failed'
        $record.Detail = $_.Exception.Message
        Write-Log "$server : FAILED - $($_.Exception.Message)" 'ERROR'
    }
    finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        $record.EndTime = (Get-Date).ToString('s')
        $results.Add([pscustomobject]$record)
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
Write-Log "Summary:" 'STEP'
$results | Format-Table ServerName, Status, Detail -AutoSize | Out-Host

$ok     = @($results | Where-Object { $_.Status -in 'Succeeded','DryRun-OK' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
Write-Log "Done. Success: $ok  Failed: $failed  Report: $ReportPath" 'STEP'
