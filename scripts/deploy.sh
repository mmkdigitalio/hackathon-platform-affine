#!/usr/bin/env bash
# Deploys (or updates) AFFiNE on Azure Container Apps.
# Safe to re-run: existing secrets and the SMTP app registration are reused.
set -euo pipefail

EXPECTED_SUBSCRIPTION="MMK DIGITAL - Hackathon 2026"
RESOURCE_GROUP="hackathon-platform-affine"
LOCATION="westeurope"
SMTP_APP_NAME="affine-acs-smtp"
CONTAINER_APP="ca-affine"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$REPO_ROOT/infra"

usage() {
  cat <<EOF
Usage: scripts/deploy.sh [--what-if] [--rotate-smtp-secret]

Deploys AFFiNE into resource group '$RESOURCE_GROUP'
(subscription '$EXPECTED_SUBSCRIPTION', region '$LOCATION').

Options:
  --what-if             Preview changes; creates and changes nothing.
  --rotate-smtp-secret  Issue a new ACS SMTP client secret and restart the app.
  -h, --help            Show this help.

Environment:
  AFFINE_OWNER          Value of the 'owner' tag (default: your UPN).
  AFFINE_OPERATOR_IPS   Comma-separated IPv4s allowed to reach Postgres directly.
EOF
}

WHAT_IF=false
ROTATE_SMTP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --what-if) WHAT_IF=true ;;
    --rotate-smtp-secret) ROTATE_SMTP=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Retries a command while freshly created role assignments propagate.
retry() {
  local attempt=1
  until "$@"; do
    [[ $attempt -ge 20 ]] && return 1
    log "Not authorized yet (role assignment propagating), retrying in 15s… ($attempt/20)"
    sleep 15
    attempt=$((attempt + 1))
  done
}

# --- 1. Preflight: never touch anything outside the hackathon subscription ---
command -v az >/dev/null || die "Azure CLI (az) not found."
command -v openssl >/dev/null || die "openssl not found."
command -v jq >/dev/null || die "jq not found."

current_sub="$(az account show --query name -o tsv 2>/dev/null)" ||
  die "Not logged in. Run: az login"
[[ "$current_sub" == "$EXPECTED_SUBSCRIPTION" ]] ||
  die "Active subscription is '$current_sub', expected '$EXPECTED_SUBSCRIPTION'. Run: az account set --subscription \"$EXPECTED_SUBSCRIPTION\""

deployer_id="$(az ad signed-in-user show --query id -o tsv)"
export AFFINE_OWNER="${AFFINE_OWNER:-$(az ad signed-in-user show --query userPrincipalName -o tsv)}"
log "Subscription: $current_sub | owner tag: $AFFINE_OWNER"

# --- 2. Resource group ---
if ! az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  if $WHAT_IF; then
    log "Resource group '$RESOURCE_GROUP' does not exist: a real run creates it and every resource."
    exit 0
  fi
fi
if ! $WHAT_IF; then
  log "Ensuring resource group '$RESOURCE_GROUP' ($LOCATION)"
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none \
    --tags project=hackathon-platform-affine environment=hackathon owner="$AFFINE_OWNER"
fi

# --- 3. Stage 1: Key Vault + storage ---
bootstrap_params=(--parameters owner="$AFFINE_OWNER" deployerPrincipalId="$deployer_id" location="$LOCATION")
if $WHAT_IF; then
  log "What-if: bootstrap (Key Vault, storage)"
  az deployment group what-if -g "$RESOURCE_GROUP" -n affine-bootstrap \
    -f "$INFRA/bootstrap.bicep" "${bootstrap_params[@]}"
  kv_name="$(az keyvault list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv)"
  if [[ -z "$kv_name" ]]; then
    log "Key Vault not created yet; skipping the main what-if (it needs the vault's secrets)."
    exit 0
  fi
else
  log "Deploying stage 1: Key Vault, storage"
  bootstrap_out="$(az deployment group create -g "$RESOURCE_GROUP" -n affine-bootstrap \
    -f "$INFRA/bootstrap.bicep" "${bootstrap_params[@]}" --query properties.outputs -o json)"
  kv_name="$(jq -r .keyVaultName.value <<<"$bootstrap_out")"
  storage_name="$(jq -r .storageAccountName.value <<<"$bootstrap_out")"
  config_share="$(jq -r .configShareName.value <<<"$bootstrap_out")"
fi

# --- 4. Secrets (generated once, then reused) ---
secret_names() { az keyvault secret list --vault-name "$kv_name" --query '[].name' -o tsv; }

# The value goes through stdin (printf is a builtin), so it never appears in process arguments.
secret_name=""
secret_value=""
put_secret_once() {
  printf '%s' "$secret_value" | az keyvault secret set --vault-name "$kv_name" --name "$secret_name" --file /dev/stdin -o none
}
put_secret() {
  secret_name="$1"
  secret_value="$2"
  retry put_secret_once
  secret_value=""
}

existing_secrets="$(retry secret_names)"
has_secret() { grep -qx "$1" <<<"$existing_secrets"; }

smtp_app_id="$(az ad app list --display-name "$SMTP_APP_NAME" --query '[0].appId' -o tsv)"

if ! $WHAT_IF; then
  if ! has_secret postgres-admin-password; then
    log "Generating Postgres admin password into Key Vault"
    put_secret postgres-admin-password "$(openssl rand -hex 32)"
  fi

  if [[ -z "$smtp_app_id" ]]; then
    log "Creating app registration '$SMTP_APP_NAME' (ACS SMTP login)"
    smtp_app_id="$(az ad app create --display-name "$SMTP_APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  fi
fi

[[ -n "$smtp_app_id" ]] || die "App registration '$SMTP_APP_NAME' not found; run without --what-if first."
smtp_sp_id="$(az ad sp show --id "$smtp_app_id" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$smtp_sp_id" ]] && ! $WHAT_IF; then
  smtp_sp_id="$(az ad sp create --id "$smtp_app_id" --query id -o tsv)"
fi

if ! $WHAT_IF && { $ROTATE_SMTP || ! has_secret acs-smtp-client-secret; }; then
  log "Issuing ACS SMTP client secret (1 year) into Key Vault"
  # Replaces all existing credentials of this dedicated app registration.
  put_secret acs-smtp-client-secret \
    "$(az ad app credential reset --id "$smtp_app_id" --display-name acs-smtp --years 1 --query password -o tsv 2>/dev/null)"
fi

export AFFINE_SMTP_CLIENT_ID="$smtp_app_id"
export AFFINE_SMTP_PRINCIPAL_ID="$smtp_sp_id"

# --- 5. AFFiNE config.json onto the config share (before the app's first start) ---
if ! $WHAT_IF; then
  log "Uploading infra/affine/config.json to share '$config_share'"
  AZURE_STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" -n "$storage_name" --query '[0].value' -o tsv)" \
    az storage file upload --account-name "$storage_name" --share-name "$config_share" \
    --source "$INFRA/affine/config.json" --path config.json -o none
fi

# --- 6. Stage 2: everything else ---
if $WHAT_IF; then
  log "What-if: main (Postgres, ACS, Container Apps, Log Analytics)"
  az deployment group what-if -g "$RESOURCE_GROUP" -n affine-main -p "$INFRA/main.bicepparam"
  exit 0
fi

log "Deploying stage 2: Log Analytics, Postgres, ACS Email, Container Apps (first run ~10 min)"
main_out="$(az deployment group create -g "$RESOURCE_GROUP" -n affine-main \
  -p "$INFRA/main.bicepparam" --query properties.outputs -o json)"

if $ROTATE_SMTP; then
  # Secret changes do not create a new revision; restart so the container reads the new value.
  revision="$(az containerapp show -g "$RESOURCE_GROUP" -n "$CONTAINER_APP" --query properties.latestRevisionName -o tsv)"
  log "Restarting revision $revision to pick up the new SMTP secret"
  az containerapp revision restart -g "$RESOURCE_GROUP" -n "$CONTAINER_APP" --revision "$revision" -o none
fi

app_url="$(jq -r .appUrl.value <<<"$main_out")"
cat <<EOF

AFFiNE is deployed.
  URL:          $app_url
  Admin setup:  $app_url/admin  (first run only: create the administrator)
  Mail sender:  $(jq -r .mailSenderAddress.value <<<"$main_out")
EOF
