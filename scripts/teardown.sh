#!/usr/bin/env bash
# Deletes the whole AFFiNE deployment: the resource group and the SMTP app registration.
# Irreversible. Export data first (see docs/runbook.md, "Before teardown").
set -euo pipefail

EXPECTED_SUBSCRIPTION="MMK DIGITAL - Hackathon 2026"
RESOURCE_GROUP="hackathon-platform-affine"
SMTP_APP_NAME="affine-acs-smtp"

usage() {
  cat <<EOF
Usage: scripts/teardown.sh

Permanently deletes resource group '$RESOURCE_GROUP' (subscription
'$EXPECTED_SUBSCRIPTION') and the Entra app registration '$SMTP_APP_NAME'.
Asks you to type the resource group name to confirm.

Options:
  -h, --help  Show this help.
EOF
}

case "${1:-}" in
  "") ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

current_sub="$(az account show --query name -o tsv 2>/dev/null)" || die "Not logged in. Run: az login"
[[ "$current_sub" == "$EXPECTED_SUBSCRIPTION" ]] ||
  die "Active subscription is '$current_sub', expected '$EXPECTED_SUBSCRIPTION'."

if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resources that will be deleted:"
  az resource list -g "$RESOURCE_GROUP" --query '[].{name:name, type:type}' -o table
else
  echo "Resource group '$RESOURCE_GROUP' does not exist."
fi
smtp_app_id="$(az ad app list --display-name "$SMTP_APP_NAME" --query '[0].appId' -o tsv)"
[[ -n "$smtp_app_id" ]] && echo "App registration: $SMTP_APP_NAME ($smtp_app_id)"

echo
read -r -p "Type the resource group name ('$RESOURCE_GROUP') to delete everything: " answer
[[ "$answer" == "$RESOURCE_GROUP" ]] || die "Confirmation did not match. Nothing was deleted."

if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Deleting resource group '$RESOURCE_GROUP' (takes several minutes)…"
  az group delete -n "$RESOURCE_GROUP" --yes
fi
if [[ -n "$smtp_app_id" ]]; then
  echo "Deleting app registration '$SMTP_APP_NAME'…"
  az ad app delete --id "$smtp_app_id"
fi

echo "Done. The Key Vault stays soft-deleted (no cost) for 7 days, then is purged automatically."
