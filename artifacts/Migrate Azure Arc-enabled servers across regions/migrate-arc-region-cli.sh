#!/usr/bin/env bash
# =============================================================================
# migrate-arc-region-cli.sh
#
# Bulk-migrate Azure Arc-enabled servers from one region to another
# (default: qatarcentral -> westeurope) driven ENTIRELY from Azure CLI.
# No RDP / SSH / WinRM into the servers.
#
# The only step that must run on the machine (azcmagent disconnect + connect)
# is delivered via Azure Arc Run Command (az connectedmachine run-command),
# which the Connected Machine agent executes locally.
#
# Reference:
#   https://learn.microsoft.com/azure/azure-arc/servers/manage-howto-migrate
#   https://learn.microsoft.com/cli/azure/connectedmachine/run-command
#
# Requirements (on the machine you run this from - e.g. Azure Cloud Shell):
#   * Azure CLI with the 'connectedmachine' extension (auto-installs) + jq
#   * A service principal with rights to delete the source resource and
#     create the target one
# Requirements (on each server):
#   * Connected Machine agent v1.33+ (Run Command prerequisite), agent ONLINE
#
# CAVEATS:
#   * Each Azure resource is DELETED and recreated -> downtime + loss of
#     Azure-side metadata. Get customer sign-off; pilot Wave 1 first.
#   * The disconnect deletes the resource, so the Run Command can't report
#     back - success is confirmed by POLLING for the new region resource.
#   * Extension PROTECTED settings (secrets) are not restored automatically.
#
# CSV format (header required):  MachineName,ResourceGroup,NewResourceName
#   * MachineName     (required) - current Arc resource name
#   * ResourceGroup   (required) - resource group of the source resource
#   * NewResourceName (optional) - rename on reconnect (blank = keep name)
#
# Usage:
#   ./migrate-arc-region-cli.sh \
#       --csv servers.csv \
#       --subscription <sub-id> --tenant <tenant-id> \
#       --target-rg rg-arc-westeurope \
#       --spn-id <appId> --spn-secret <secret> \
#       [--source-region qatarcentral] [--target-region westeurope] \
#       [--dry-run] [--yes]
# =============================================================================

set -uo pipefail

# ---- defaults --------------------------------------------------------------
SOURCE_REGION="qatarcentral"
TARGET_REGION="westeurope"
CLOUD="AzureCloud"
DRY_RUN=0
ASSUME_YES=0
POLL_TRIES=45          # ~15 min at 20s intervals
POLL_INTERVAL=20
BACKUP_DIR="./arc-migration-backup"
REPORT="./arc-migration-report-$(date +%Y%m%d-%H%M%S).csv"

# ---- parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)            CSV="$2"; shift 2;;
    --subscription)   SUBSCRIPTION="$2"; shift 2;;
    --tenant)         TENANT="$2"; shift 2;;
    --target-rg)      TARGET_RG="$2"; shift 2;;
    --target-region)  TARGET_REGION="$2"; shift 2;;
    --source-region)  SOURCE_REGION="$2"; shift 2;;
    --spn-id)         SPN_ID="$2"; shift 2;;
    --spn-secret)     SPN_SECRET="$2"; shift 2;;
    --dry-run)        DRY_RUN=1; shift;;
    --yes)            ASSUME_YES=1; shift;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ---- validate --------------------------------------------------------------
: "${CSV:?--csv is required}"
: "${SUBSCRIPTION:?--subscription is required}"
: "${TENANT:?--tenant is required}"
: "${TARGET_RG:?--target-rg is required}"
[[ -f "$CSV" ]] || die "CSV not found: $CSV"
command -v jq >/dev/null || die "jq is required (available in Azure Cloud Shell)."
if [[ -z "${SPN_ID:-}" || -z "${SPN_SECRET:-}" ]]; then
  die "A service principal (--spn-id/--spn-secret) is required: the on-machine reconnect runs unattended."
fi

mkdir -p "$BACKUP_DIR"
az account set --subscription "$SUBSCRIPTION" || die "Could not set subscription."
echo "MachineName,Status,Detail" > "$REPORT"

# ---- confirmation ----------------------------------------------------------
MODE="LIVE migration"; [[ "$DRY_RUN" -eq 1 ]] && MODE="DRY RUN (no changes)"
cat <<EOF
------------------------------------------------------------------
 Bulk Arc region migration : $SOURCE_REGION -> $TARGET_REGION
 Mode      : $MODE
 Target RG : $TARGET_RG
 Source    : $CSV
 Each server's Azure resource is DELETED and recreated (downtime +
 loss of Azure-side metadata). Extensions are backed up, removed and
 redeployed. The on-machine reconnect runs via Arc Run Command.
------------------------------------------------------------------
EOF
if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Type 'yes' to proceed: " ans
  [[ "$ans" == "yes" ]] || die "Aborted by user."
fi

# ---- per-machine migration -------------------------------------------------
migrate_one() {
  local machine="$1" rg="$2" newname="$3"
  local target_name="${newname:-$machine}"
  log "==== $machine (rg=$rg) -> $target_name @ $TARGET_REGION ===="

  # 1. Verify the machine exists and is in the expected source region
  local cur_region
  cur_region=$(az connectedmachine show -g "$rg" -n "$machine" --query location -o tsv 2>/dev/null) \
    || { echo "$machine,Failed,resource not found in $rg" >> "$REPORT"; log "  not found"; return; }
  if [[ "$cur_region" != "$SOURCE_REGION" ]]; then
    echo "$machine,Skipped,in $cur_region not $SOURCE_REGION" >> "$REPORT"; log "  skipped (in $cur_region)"; return
  fi

  # 2. Audit + back up extensions
  local backup="$BACKUP_DIR/${machine}-extensions.json"
  az connectedmachine extension list -g "$rg" --machine-name "$machine" -o json > "$backup" 2>/dev/null || echo "[]" > "$backup"
  local ext_names
  ext_names=$(jq -r '.[].name' "$backup")
  log "  extensions: $(echo "$ext_names" | tr '\n' ' ')"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "$machine,DryRun-OK,would remove+disconnect+reconnect+redeploy" >> "$REPORT"
    log "  [dry-run] no changes made"; return
  fi

  # 3. Remove extensions (control plane)
  for ext in $ext_names; do
    az connectedmachine extension delete -g "$rg" --machine-name "$machine" -n "$ext" --yes >/dev/null 2>&1 \
      && log "  removed $ext" || log "  WARN: could not remove $ext"
  done

  # 4. Disconnect + reconnect ON the machine via Arc Run Command.
  #    Secrets (ARM token + SP secret) are passed as PROTECTED parameters so
  #    they aren't stored in the run-command resource output.
  local token
  token=$(az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv) \
    || { echo "$machine,Failed,token acquisition failed" >> "$REPORT"; return; }

  read -r -d '' PS_SCRIPT <<PS || true
param([string]\$Token,[string]\$Secret)
azcmagent disconnect --access-token "\$Token"
azcmagent connect --service-principal-id "$SPN_ID" --service-principal-secret "\$Secret" ``
  --resource-group "$TARGET_RG" --tenant-id "$TENANT" --location "$TARGET_REGION" ``
  --subscription-id "$SUBSCRIPTION" --resource-name "$target_name" --cloud "$CLOUD"
PS

  log "  submitting Run Command (disconnect + reconnect)..."
  az connectedmachine run-command create \
      -g "$rg" --machine-name "$machine" -n "arcmigrate" \
      --location "$SOURCE_REGION" \
      --script "$PS_SCRIPT" \
      --protected-parameters "[{\"name\":\"Token\",\"value\":\"$token\"},{\"name\":\"Secret\",\"value\":\"$SPN_SECRET\"}]" \
      --async-execution true --no-wait >/dev/null 2>&1 || true
  #  ^ the resource is deleted mid-run, so we do NOT rely on this call's status.

  # 5. Poll for the recreated resource in the target region
  local found="" i new_region
  for ((i=1; i<=POLL_TRIES; i++)); do
    new_region=$(az connectedmachine show -g "$TARGET_RG" -n "$target_name" --query location -o tsv 2>/dev/null || true)
    if [[ "$new_region" == "$TARGET_REGION" ]]; then found=1; break; fi
    sleep "$POLL_INTERVAL"
  done
  if [[ -z "$found" ]]; then
    echo "$machine,Pending,reconnect not confirmed after poll window - verify manually" >> "$REPORT"
    log "  reconnect NOT confirmed within poll window"; return
  fi
  log "  reconnected as $target_name in $TARGET_REGION"

  # 6. Redeploy extensions in the target region
  local redeploy_fail=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local name pub type settings
    name=$(jq -r '.name'                <<<"$row")
    pub=$(jq  -r '.publisher'           <<<"$row")
    type=$(jq -r '.type'                <<<"$row")
    settings=$(jq -c '.settings // {}'  <<<"$row")
    local args=(-g "$TARGET_RG" --machine-name "$target_name" -n "$name"
                --publisher "$pub" --type "$type" --location "$TARGET_REGION")
    [[ "$settings" != "{}" ]] && args+=(--settings "$settings")
    if az connectedmachine extension create "${args[@]}" >/dev/null 2>&1; then
      log "  redeployed $name"
    else
      log "  WARN: failed to redeploy $name (redeploy manually)"; redeploy_fail=1
    fi
  done < <(jq -c '.[] | {name,publisher:.properties.publisher,type:.properties.type,settings:.properties.settings}' "$backup")

  if [[ "$redeploy_fail" -eq 0 ]]; then
    echo "$machine,Succeeded,migrated to $TARGET_REGION" >> "$REPORT"
  else
    echo "$machine,PartialSuccess,migrated; some extensions need manual redeploy" >> "$REPORT"
  fi
}

# ---- loop over CSV (skip header) ------------------------------------------
while IFS=, read -r machine rg newname _rest; do
  machine="$(echo "${machine:-}" | tr -d '[:space:]')"
  rg="$(echo "${rg:-}" | tr -d '[:space:]')"
  newname="$(echo "${newname:-}" | tr -d '[:space:]')"
  [[ -z "$machine" ]] && continue
  migrate_one "$machine" "$rg" "$newname"
done < <(tail -n +2 "$CSV")

# ---- summary ---------------------------------------------------------------
log "Done. Report written to: $REPORT"
column -t -s, "$REPORT" 2>/dev/null || cat "$REPORT"
