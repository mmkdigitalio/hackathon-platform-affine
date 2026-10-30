#!/usr/bin/env bash
# One-time (idempotent) setup of GitHub Actions -> Azure deployment via OIDC.
# Run locally as a subscription Owner after the first scripts/deploy.sh.
set -euo pipefail

EXPECTED_SUBSCRIPTION="MMK DIGITAL - Hackathon 2026"
RESOURCE_GROUP="hackathon-platform-affine"
GITHUB_REPO="mmkdigitalio/hackathon-platform-affine"
DEPLOY_APP_NAME="affine-github-deploy"
SMTP_APP_NAME="affine-acs-smtp"
ENVIRONMENT="production"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Roles the templates assign; the pipeline may grant only these (design D13).
KV_SECRETS_OFFICER="b86a8fe4-44ce-4948-aee5-eccb2c155cd7" # gitleaks:allow (public built-in role ID)
EMAIL_SERVICE_OWNER="09976791-48a7-449e-bb21-39d1a415f350"

usage() {
  cat <<EOF
Usage: scripts/setup-cicd.sh

Creates the Entra app registration '$DEPLOY_APP_NAME' with GitHub OIDC
federated credentials for $GITHUB_REPO, grants it access to resource group
'$RESOURCE_GROUP' only, and configures the GitHub environment '$ENVIRONMENT'
and repository variables. Safe to re-run.

Options:
  -h, --help  Show this help.
EOF
}

case "${1:-}" in
  "") ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "Azure CLI (az) not found."
command -v gh >/dev/null || die "GitHub CLI (gh) not found."
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub. Run: gh auth login"

current_sub="$(az account show --query name -o tsv 2>/dev/null)" || die "Not logged in. Run: az login"
[[ "$current_sub" == "$EXPECTED_SUBSCRIPTION" ]] ||
  die "Active subscription is '$current_sub', expected '$EXPECTED_SUBSCRIPTION'."
subscription_id="$(az account show --query id -o tsv)"
tenant_id="$(az account show --query tenantId -o tsv)"
rg_id="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null)" ||
  die "Resource group '$RESOURCE_GROUP' not found. Run scripts/deploy.sh once first."

smtp_app_id="$(az ad app list --display-name "$SMTP_APP_NAME" --query '[0].appId' -o tsv)"
[[ -n "$smtp_app_id" ]] || die "App registration '$SMTP_APP_NAME' not found. Run scripts/deploy.sh once first."
smtp_sp_id="$(az ad sp show --id "$smtp_app_id" --query id -o tsv)"

# --- Entra app registration + service principal for the pipeline ---
app_id="$(az ad app list --display-name "$DEPLOY_APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$app_id" ]]; then
  log "Creating app registration '$DEPLOY_APP_NAME'"
  app_id="$(az ad app create --display-name "$DEPLOY_APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi
sp_id="$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)"
if [[ -z "$sp_id" ]]; then
  log "Creating service principal"
  sp_id="$(az ad sp create --id "$app_id" --query id -o tsv)"
fi

# --- Federated credentials (no client secret is ever created) ---
existing_creds="$(az ad app federated-credential list --id "$app_id" --query '[].name' -o tsv)"
add_federated_credential() {
  local name="$1" subject="$2"
  if grep -qx "$name" <<<"$existing_creds"; then
    return
  fi
  log "Adding federated credential '$name' ($subject)"
  az ad app federated-credential create --id "$app_id" -o none --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
}
add_federated_credential github-production "repo:$GITHUB_REPO:environment:$ENVIRONMENT"
add_federated_credential github-pull-request "repo:$GITHUB_REPO:pull_request"

# --- Role assignments, resource group scope only ---
has_role() {
  [[ -n "$(az role assignment list --assignee "$sp_id" --scope "$rg_id" --role "$1" --query '[0].id' -o tsv)" ]]
}
if ! has_role "Contributor"; then
  log "Granting Contributor on $RESOURCE_GROUP"
  az role assignment create --assignee-object-id "$sp_id" --assignee-principal-type ServicePrincipal \
    --role "Contributor" --scope "$rg_id" -o none
fi
if ! has_role "Role Based Access Control Administrator"; then
  log "Granting constrained RBAC Administrator on $RESOURCE_GROUP"
  condition="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$KV_SECRETS_OFFICER, $EMAIL_SERVICE_OWNER})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$KV_SECRETS_OFFICER, $EMAIL_SERVICE_OWNER}))"
  az role assignment create --assignee-object-id "$sp_id" --assignee-principal-type ServicePrincipal \
    --role "Role Based Access Control Administrator" --scope "$rg_id" \
    --condition "$condition" --condition-version "2.0" -o none
fi

# --- Key Vault access for the pipeline ---
# Same template and parameters CI uses, so the role assignment name matches what CI later re-applies.
log "Granting the pipeline Key Vault Secrets Officer via infra/bootstrap.bicep"
owner="${AFFINE_OWNER:-$(az ad signed-in-user show --query userPrincipalName -o tsv)}"
az deployment group create -g "$RESOURCE_GROUP" -n affine-bootstrap -o none \
  -f "$REPO_ROOT/infra/bootstrap.bicep" \
  --parameters owner="$owner" deployerPrincipalId="$sp_id" deployerPrincipalType=ServicePrincipal \
  location="$(az group show -n "$RESOURCE_GROUP" --query location -o tsv)"

# --- GitHub environment: deployments only from main ---
log "Configuring GitHub environment '$ENVIRONMENT' (main only)"
gh api -X PUT "repos/$GITHUB_REPO/environments/$ENVIRONMENT" --silent --input - <<EOF
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
if ! gh api "repos/$GITHUB_REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$GITHUB_REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    --silent -f name=main -f type=branch
fi

# --- Repository variables (identifiers only, no secrets) ---
log "Setting repository variables"
set_var() { gh variable set "$1" --repo "$GITHUB_REPO" --body "$2"; }
set_var AZURE_CLIENT_ID "$app_id"
set_var AZURE_TENANT_ID "$tenant_id"
set_var AZURE_SUBSCRIPTION_ID "$subscription_id"
set_var AFFINE_OWNER "$owner"
set_var AFFINE_DEPLOYER_PRINCIPAL_ID "$sp_id"
set_var AFFINE_SMTP_CLIENT_ID "$smtp_app_id"
set_var AFFINE_SMTP_PRINCIPAL_ID "$smtp_sp_id"
if [[ -n "${AFFINE_OPERATOR_IPS:-}" ]]; then
  set_var AFFINE_OPERATOR_IPS "$AFFINE_OPERATOR_IPS"
fi

cat <<EOF

CI/CD is configured.
  Pipeline identity: $DEPLOY_APP_NAME (app $app_id, SP $sp_id)
  Scope:             $RESOURCE_GROUP only
  GitHub:            environment '$ENVIRONMENT' (main only) + repository variables
EOF
