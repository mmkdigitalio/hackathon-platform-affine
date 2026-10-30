# AFFiNE on Azure: Runbook

This runbook covers operating the self-hosted AFFiNE instance in subscription **MMK DIGITAL - Hackathon 2026**, resource group **`hackathon-platform-affine`**. The design and requirements are in [`openspec/changes/host-affine-on-azure/`](../openspec/changes/host-affine-on-azure/).

## Subscription constraints

Recorded during preflight on 2026-10-30:

| Check | Result |
|---|---|
| Subscription | `MMK DIGITAL - Hackathon 2026` (`e74d4729-d5f5-4fd4-ab22-17005555593e`), tenant `04871c4e-334d-41d3-986b-175b6ae0ce4c` |
| Operator permissions | Owner on the subscription, so role assignments in Bicep work |
| Resource providers | `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.DBforPostgreSQL`, `Microsoft.Storage`, and `Microsoft.KeyVault` were already registered. `Microsoft.Communication` was registered during preflight |
| Policy assignments | Only `ASC Default` (Microsoft Defender for Cloud's default initiative, audit only). Nothing denies regions, SKUs, public network access, or storage shared-key access |
| Region | **PostgreSQL Flexible Server provisioning is restricted in `germanywestcentral`** for this subscription, and lifting that needs a support request. Everything is therefore deployed to **`westeurope`**, where Container Apps and PostgreSQL B1ms with PG 16 are available |
| Entra app registrations | The operator can create app registrations, which is needed for the ACS SMTP credentials |

## Architecture at a glance

| Resource | Name | Purpose |
|---|---|---|
| Container Apps environment | `cae-affine` | Consumption workload profile, logs go to `log-affine` |
| Container App | `ca-affine` | Containers `affine` (`ghcr.io/toeverything/affine:<tag>`) and `redis` (sidecar). Exactly 1 replica |
| PostgreSQL Flexible Server | `psql-affine-<suffix>` | PG 16, B1ms, database `affine`, TLS required |
| Storage account | `staffine<suffix>` | File shares `affine-storage` (blobs) and `affine-config` (`config.json`, `private.key`) |
| Key Vault | `kv-affine-<suffix>` | `postgres-admin-password`, `acs-smtp-client-secret` |
| Communication Services | `acs-affine-<suffix>` + `ecs-affine-<suffix>` | Email over `smtp.azurecomm.net:587` |
| Log Analytics | `log-affine` | 30-day retention |
| Entra app registration | `affine-acs-smtp` | SMTP login for ACS. Lives outside the RG and is removed by `teardown.sh` |

`<suffix>` is `uniqueString(resourceGroup().id)`, which is stable for this RG.

## Deploy and update

Prerequisites: Azure CLI (with Bicep), `jq`, `openssl`, and a signed-in user with Owner on the subscription.

```bash
az login
az account set --subscription "MMK DIGITAL - Hackathon 2026"

scripts/deploy.sh --what-if   # preview only, changes nothing
scripts/deploy.sh             # create or update everything
```

Optional environment variables:
- `AFFINE_OWNER`: value of the `owner` tag. The default is your UPN.
- `AFFINE_OPERATOR_IPS`: comma-separated IPv4 addresses allowed to reach Postgres directly, for example `AFFINE_OPERATOR_IPS=$(curl -s https://api.ipify.org)`.

What `deploy.sh` does, in order:
1. Aborts unless the active subscription is `MMK DIGITAL - Hackathon 2026`.
2. Creates or updates RG `hackathon-platform-affine` in `westeurope`, with tags.
3. **Stage 1** (`infra/bootstrap.bicep`): Key Vault and storage account with both shares.
4. Generates `postgres-admin-password` if it is missing. Creates the app registration `affine-acs-smtp` and its service principal if they are missing, and issues `acs-smtp-client-secret` if it is missing. Secret values only ever go into Key Vault.
5. Uploads `infra/affine/config.json` to the `affine-config` share, before AFFiNE's first start.
6. **Stage 2** (`infra/main.bicep` + `infra/main.bicepparam`): Log Analytics, Postgres, ACS Email, the Container Apps environment, and the app.
7. Prints the URL and the mail sender.

Re-running with unchanged inputs is safe. Existing secrets are reused and Bicep makes no changes.

> After CI/CD is set up, run `deploy.sh` locally only for the bootstrap and for the local-only operations below. Normal changes go through a PR.

### First-run admin setup

1. Open `https://<app-url>/admin`. The first visit shows the setup wizard.
2. Create the administrator and store the credentials in the team's password manager.
3. Self-registration is already disabled by `config.json` (`auth.allowSignup: false`). Add users from **Admin → Accounts**, or invite them to a workspace.
4. The setup wizard does **not** send a verification email. To verify the admin address, go to **Settings → Account → Verify email**.

### Email troubleshooting

- Mail is queued in the `mail_deliveries` table. A worker drains the queue every minute and logs `[MailSender] Mail [<name>] sent successfully.` (debug) or `Failed to send mail` (error). If neither line appears, no email was requested.
- Mail comes from `DoNotReply@<guid>.azurecomm.net`. Microsoft 365 recipients should check **Junk** and **Quarantine** (security.microsoft.com → Quarantine) if nothing arrives.
- To test the SMTP login without sending anything:

  ```bash
  RG=hackathon-platform-affine
  KV=$(az keyvault list -g $RG --query '[0].name' -o tsv)
  SMTPU=$(az containerapp show -g $RG -n ca-affine --query "properties.template.containers[?name=='affine'].env[] | [?name=='MAILER_USER'].value | [0]" -o tsv)
  SMTP_PW=$(az keyvault secret show --vault-name $KV -n acs-smtp-client-secret --query value -o tsv) SMTP_USER=$SMTPU \
    python3 -c 'import os,smtplib; s=smtplib.SMTP("smtp.azurecomm.net",587); s.starttls(); print(s.login(os.environ["SMTP_USER"],os.environ["SMTP_PW"]))'
  ```

  A working login prints `235 Authentication successful`. A `535` means the secret expired or the role assignment is missing (see [SMTP secret rotation](#smtp-secret-rotation)).

## CI/CD (GitHub Actions)

After the one-time bootstrap below, **every change goes through a pull request into `main`**. The workflow [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) runs on PRs and pushes that touch `infra/**`, `scripts/**`, or the workflow itself:

| Trigger | Jobs | Touches Azure? |
|---|---|---|
| PR to `main` (from this repo) | `validate` (Bicep build and lint, shellcheck) → `what-if` (`deploy.sh --what-if`) | Read-only preview |
| PR from a fork | `validate` only | No credentials at all |
| Push or merge to `main` | `validate` → `deploy` (`deploy.sh` + `/info` smoke test) | Yes, in environment `production` |
| *Run workflow* (`workflow_dispatch`) on `main` | `validate` → `deploy` | Yes, for redeploying without a code change |

Runs are serialized (`concurrency: affine-azure`), and a running deployment is never cancelled.

**Authentication**: GitHub OIDC is exchanged for a token of the app registration `affine-github-deploy`. No client secret exists, so there is nothing to rotate. The service principal has two roles, both on RG `hackathon-platform-affine` only:
- `Contributor`.
- `Role Based Access Control Administrator`, limited by an ABAC condition to granting Key Vault Secrets Officer and Communication and Email Service Owner.

**Repository variables** (identifiers only, set by `setup-cicd.sh`): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AFFINE_OWNER`, `AFFINE_DEPLOYER_PRINCIPAL_ID`, `AFFINE_SMTP_CLIENT_ID`, `AFFINE_SMTP_PRINCIPAL_ID`, and optionally `AFFINE_OPERATOR_IPS`.

### One-time bootstrap (operator, locally)

1. `scripts/deploy.sh`: creates the RG, the Key Vault secrets, and the SMTP app registration `affine-acs-smtp`. Creating that registration needs Microsoft Graph rights, which the pipeline deliberately does not have.
2. `scripts/setup-cicd.sh`: creates `affine-github-deploy`, its federated credentials and role assignments, the GitHub environment `production` (deployments only from `main`), and the repository variables. It is idempotent.

### Operations that stay local

- `scripts/deploy.sh --rotate-smtp-secret` (needs Graph to issue the secret).
- `scripts/teardown.sh`.
- Restores and exports (see below).

To redeploy without a code change, go to **Actions → deploy → Run workflow** on `main`, or run `gh workflow run deploy.yml --ref main`.

## Upgrading AFFiNE

1. Read the release notes: <https://github.com/toeverything/affine/releases>.
2. Note the current time (UTC). It is your point-in-time-restore target if the upgrade goes wrong.
3. On a branch, set `affineImageTag` in `infra/main.bicepparam` to the new version, for example `0.27.5`, and open a PR.
4. The PR's `what-if` job should show only the image change on `ca-affine`.
5. Merge. The `deploy` job rolls out a new revision, which runs migrations and only receives traffic once `/info` answers. The smoke test then checks that `/info` reports the new version.
6. Watch the logs (see [Logs](#logs)) and open a few documents.

If the new revision never becomes healthy, traffic stays on the old one. Revert the tag and redeploy. If data is broken *after* migrations ran, restore Postgres (below). Reverting the image does not undo schema migrations.

## Backup and restore

**Postgres**: automatic backups with 7-day point-in-time restore.

```bash
RG=hackathon-platform-affine
SRC=$(az postgres flexible-server list -g $RG --query '[0].name' -o tsv)
az postgres flexible-server restore -g $RG --source-server $SRC \
  --name ${SRC}-restore --restore-time "2026-11-02T09:30:00Z"
```

Then point AFFiNE at the restored server. Update the Container App secret `database-url` so the host is `${SRC}-restore.postgres.database.azure.com`. The password is unchanged, so read it from Key Vault:

```bash
KV=$(az keyvault list -g $RG --query '[0].name' -o tsv)
PW=$(az keyvault secret show --vault-name $KV -n postgres-admin-password --query value -o tsv)
az containerapp secret set -g $RG -n ca-affine \
  --secrets "database-url=postgresql://affineadmin:${PW}@${SRC}-restore.postgres.database.azure.com:5432/affine?sslmode=require"
az containerapp revision restart -g $RG -n ca-affine \
  --revision $(az containerapp show -g $RG -n ca-affine --query properties.latestRevisionName -o tsv)
```

To make the restored server permanent, either rename the parameters in Bicep or restore back onto the original name after deleting the broken server. Otherwise the next `deploy.sh` points the app back at the original server.

**File shares**: share soft delete keeps deleted shares for 7 days. In the Azure portal, open Storage account → File shares → *Show deleted shares* → Undelete. Alternatively:

```bash
SA=$(az storage account list -g $RG --query '[0].name' -o tsv)
az storage share-rm list --storage-account $SA --include-deleted -o table
az storage share-rm restore --storage-account $SA -n affine-storage --deleted-version <version>
```

## SMTP secret rotation

The ACS SMTP client secret is valid for **1 year** from issue. Check its expiry with `az ad app credential list --id $(az ad app list --display-name affine-acs-smtp --query '[0].appId' -o tsv) -o table`.

```bash
scripts/deploy.sh --rotate-smtp-secret
```

This issues a new secret, which replaces the old one. It writes the new secret to Key Vault, redeploys, and restarts the revision. Send a test email afterwards, for example with "Forgot password" on the sign-in page.

## Logs

The Log Analytics workspace is `log-affine`. Open it in Portal → Logs, and run:

```kusto
// AFFiNE container output, including migrations, from the last hour
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-affine" and ContainerName_s == "affine"
| project TimeGenerated, RevisionName_s, Log_s
| order by TimeGenerated asc
```

```kusto
// Migration markers for the current revision
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == "ca-affine"
| where Log_s contains "running prisma migrations" or Log_s contains "running data migrations"
    or Log_s contains "creating config file" or Log_s contains "Listening on"
| project TimeGenerated, RevisionName_s, Log_s
```

```kusto
// Platform events: probe failures, restarts, image pulls
ContainerAppSystemLogs_CL
| where ContainerAppName_s == "ca-affine"
| project TimeGenerated, Reason_s, Log_s
| order by TimeGenerated desc
```

For live tailing: `az containerapp logs show -g hackathon-platform-affine -n ca-affine --container affine --follow`.

## Cost

These are list prices in `westeurope` as of 2026-10-30 (full derivation in design D11):

| Resource | 24/7 ≈ €/month | Working hours only ≈ €/month |
|---|---|---|
| Container App (1.25 vCPU / 2.5 GiB, active rate) | ~115 | ~37 |
| PostgreSQL B1ms + 32 GiB storage | ~17 | ~9 |
| Storage account, Log Analytics, Key Vault, ACS Email | ~5 | ~5 |
| **Total** | **≈ 135–140** | **≈ 50–55** |

**Parameters that change cost** (in `infra/main.bicepparam`):
- `affineCpu` / `affineMemory`: 0.75 / `1.5Gi` saves about €25/month.
- `postgresSkuName`, `postgresStorageGb`.
- `logRetentionDays`.

If the app is mostly idle, Azure bills the cheaper idle rate. Check the real figure in Cost Management after a few days.

**Pausing between hackathon days**:

```bash
RG=hackathon-platform-affine
PG=$(az postgres flexible-server list -g $RG --query '[0].name' -o tsv)
# pause
az containerapp update -g $RG -n ca-affine --min-replicas 0 --max-replicas 0
az postgres flexible-server stop -g $RG -n $PG
# resume
az postgres flexible-server start -g $RG -n $PG
az containerapp update -g $RG -n ca-affine --min-replicas 1 --max-replicas 1
```

A stopped Flexible Server starts again automatically after 7 days. The next `deploy.sh` also resets the replicas to 1.

## Before teardown: export

```bash
RG=hackathon-platform-affine
mkdir -p exports
SA=$(az storage account list -g $RG --query '[0].name' -o tsv)
export AZURE_STORAGE_KEY=$(az storage account keys list -g $RG -n $SA --query '[0].value' -o tsv)
az storage file download-batch --account-name $SA -s affine-storage -d exports/affine-storage
az storage file download-batch --account-name $SA -s affine-config  -d exports/affine-config

# Database dump: your IP must be in AFFINE_OPERATOR_IPS (redeploy), or add a temporary firewall rule
PG=$(az postgres flexible-server list -g $RG --query '[0].name' -o tsv)
KV=$(az keyvault list -g $RG --query '[0].name' -o tsv)
PGPASSWORD=$(az keyvault secret show --vault-name $KV -n postgres-admin-password --query value -o tsv) \
  pg_dump "host=$PG.postgres.database.azure.com port=5432 dbname=affine user=affineadmin sslmode=require" \
  -Fc -f exports/affine.dump
```

`exports/` is git-ignored and contains personal data, so store it accordingly.

## Teardown

```bash
scripts/teardown.sh
```

The script lists every resource in the RG and asks you to type `hackathon-platform-affine` to confirm. It then deletes the RG and the `affine-acs-smtp` app registration. The Key Vault stays soft-deleted, at no cost, for 7 days.
