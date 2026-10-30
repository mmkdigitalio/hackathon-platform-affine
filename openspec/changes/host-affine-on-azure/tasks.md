# Tasks

## 1. Azure preflight

- [x] 1.1 Sign in to the MMK DIGITAL tenant and select subscription `MMK DIGITAL - Hackathon 2026`. Verify that `az account show --query name -o tsv` prints exactly that name.
- [x] 1.2 Confirm that the operator has Owner (or Contributor plus User Access Administrator) on the subscription or on RG `hackathon-platform-affine`. Verify with `az role assignment list --assignee <upn> --all`.
- [x] 1.3 Register the providers `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.DBforPostgreSQL`, `Microsoft.Storage`, `Microsoft.KeyVault`, and `Microsoft.Communication`. Verify that `az provider show -n <ns> --query registrationState` returns `Registered` for each.
- [x] 1.4 List the policy assignments on the subscription (`az policy assignment list`). Record any that restrict regions, SKUs, public network access, or storage-key access. Verify that the findings are written into `docs/runbook.md` under "Subscription constraints" and that the design still holds, or update the design.
- [x] 1.5 Confirm that the target region (originally `germanywestcentral`, now `westeurope`) offers Container Apps and PostgreSQL Flexible `Standard_B1ms`. Verify with `az postgres flexible-server list-skus -l <region>` and `az provider show -n Microsoft.App --query "resourceTypes[?resourceType=='managedEnvironments'].locations"`.
- [x] 1.6 Confirm that the operator can create Entra app registrations in the MMK DIGITAL tenant. Verify by creating and then deleting a throwaway registration with `az ad app create --display-name affine-preflight-test`. If this is not allowed, arrange for an Entra admin to create `affine-acs-smtp` (design D12) and record that in the runbook.
- [x] 1.7 Confirm that ACS Email accepts the data location `Germany`, falling back to `Europe` if it does not. Verify with a `what-if` of the communication module from 4.7, and record the chosen value in design.md D12. (Result: `Germany` was accepted.)

## 2. AFFiNE runtime spike (local)

- [x] 2.1 Create a throwaway local compose setup with `ghcr.io/toeverything/affine:0.27.4`, Redis started *after* the migration, and Postgres. Run `self-host-predeploy.js`, and record whether it needs Redis. Verify that the result is noted in design.md D2. If the script does not need Redis, an init container becomes an option.
- [x] 2.2 With `auth.allowSignup: false` in `config.json`, confirm that the `/admin` setup wizard can still create the first administrator and that anonymous sign-up is refused afterwards. Verify that the outcome is recorded in design.md D8.
- [x] 2.3 Identify a lightweight unauthenticated HTTP endpoint for probes, for example `/info`. Verify that `curl -fsS localhost:3010/<path>` returns 2xx once the server is ready, and record the path in design.md D2.

## 3. IaC scaffolding

- [x] 3.1 Create `infra/`, `infra/modules/`, `infra/affine/`, `scripts/`, and `docs/`. Add a `.gitignore` that covers local secrets and `*.local.bicepparam`. Verify that `git status` shows only the intended new paths.
- [x] 3.2 Add `infra/main.bicep`, scoped to the resource group, with common parameters (`location`, `owner`, `environment`, `affineImageTag` defaulting to `0.27.4`, sizing parameters, `operatorIpAddresses`, mail parameters `mailCustomDomain` (default `mmkdigital.io`), `mailSenderUsername` (default `affine`), and `mailUseCustomDomain` (default `false`)) and a shared `tags` object. Verify that `az bicep build -f infra/main.bicep` succeeds.

## 4. Bicep modules

- [x] 4.1 Add `modules/log-analytics.bicep` (PerGB2018, retention ≥ 30 days). Verify that `az bicep build` succeeds and that the retention is a parameter with minimum 30.
- [x] 4.2 Add `modules/keyvault.bicep` (RBAC mode, soft delete 7 days, purge protection off), with a role assignment of "Key Vault Secrets Officer" for the deploying principal. Verify with `az bicep build` and a `what-if` run.
- [x] 4.3 Add `modules/storage.bicep` (StorageV2, Standard_LRS, TLS 1.2, HTTPS only, share soft delete 7 days, shares `affine-storage` and `affine-config`). Verify that `what-if` shows both shares and the soft-delete policy.
- [x] 4.4 Add `modules/postgres.bicep`:
  - Flexible Server, PostgreSQL 16, `Standard_B1ms`, 32 GiB with auto-grow, 7-day backup.
  - Database `affine`.
  - Configuration `azure.extensions=VECTOR` and `require_secure_transport=on`.
  - Firewall rules for Azure services and `operatorIpAddresses`.

  Verify that `what-if` lists the server, the database, the two configurations, and the firewall rules.
- [x] 4.5 Add `modules/containerapp-env.bicep`: a Consumption environment wired to Log Analytics, plus two Azure Files `storages` entries using the account key from `listKeys()`. Verify that `what-if` shows the environment with both storages.
- [x] 4.6 Add `modules/containerapp.bicep`. The app is single-revision with `minReplicas=maxReplicas=1`, external ingress on target port 3010, transport `auto`, and `allowInsecure=false`. It has two containers:
  - `affine`: image pinned by `affineImageTag`, 1 vCPU / 2 GiB, command `sh -c "node ./scripts/self-host-predeploy.js && exec node ./dist/main.js"`, both volume mounts, and the env vars from design D2/D7.
  - `redis`: `redis:7-alpine`, 0.25 vCPU / 0.5 GiB.

  Add the mailer env vars from design D12, and add secrets `database-url` and `mailer-password` as `secretRef`, plus startup, liveness, and readiness probes with the path from 2.3. Verify with `az bicep build`, and confirm that no secret value appears as a plain `value` env var.
- [x] 4.7 Add `modules/communication.bicep` (design D12). It defines:
  - Email service `ecs-affine`, with the `AzureManagedDomain` and the `CustomerManaged` domain `mailCustomDomain`.
  - The sender username `mailSenderUsername` on the custom domain.
  - `acs-affine-<suffix>`, with `linkedDomains` set to the custom domain when `mailUseCustomDomain` is true, and to the Azure-managed domain otherwise.
  - A role assignment of "Communication and Email Service Owner" for the SMTP service principal (parameter `smtpPrincipalId`).
  - Outputs for the SMTP username, the sender address, and the custom domain's DNS `verificationRecords`.

  Verify with `az bicep build` and a `what-if` run showing all of these resources.
- [x] 4.8 Wire all modules into `main.bicep`, passing the communication outputs into the container app's mailer env vars. Output the app URL as `https://${fqdn}` and the DNS records to request. Verify that `az bicep build` and `az bicep lint` report no errors.

## 5. Configuration and parameters

- [x] 5.1 Add `infra/affine/config.json` (`$schema`, `server.name`, `auth.allowSignup:false`, `auth.allowSignupForOauth:false`, `indexer.enabled:false`). Verify that it validates against the upstream `config.schema.json` (for example with `npx ajv-cli validate`).
- [x] 5.2 Add `infra/main.bicepparam` with non-secret values only; secrets are read in `main.bicep` with `keyVault.getSecret()` (design D6). Verify that it contains no literal secrets (`grep -iE 'password|secret' infra/main.bicepparam` shows nothing secret-valued).

## 6. Deploy and teardown scripts

- [x] 6.1 Write `scripts/deploy.sh` with these steps:
  - `set -euo pipefail`
  - Abort unless the active subscription is `MMK DIGITAL - Hackathon 2026`
  - Create the RG with tags if it is missing
  - Deploy the Key Vault module
  - Create secret `postgres-admin-password` (`openssl rand -hex 32`) only if it is missing
  - If secret `acs-smtp-client-secret` is missing: create the app registration `affine-acs-smtp` and its service principal if they don't exist, then pipe a new 1-year client secret straight into Key Vault without printing it
  - Look up the service principal's object ID to pass as `smtpPrincipalId`
  - Deploy `main.bicep` with `main.bicepparam`
  - Upload `config.json` to the `affine-config` share
  - Print the URL

  It also takes the flags `--what-if` and `--rotate-smtp-secret`. Verify with `shellcheck scripts/deploy.sh`, and check that running it against a wrong subscription exits non-zero before any `az ... create` call.
- [x] 6.2 Write `scripts/teardown.sh`. It shows the RG contents, requires typing the RG name to confirm, then runs `az group delete --yes` and deletes the `affine-acs-smtp` app registration. Verify with `shellcheck`, check that a wrong confirmation exits without deleting, and check that `az ad app list --display-name affine-acs-smtp` is empty after a real teardown.
- [x] 6.3 Document deploy, `--what-if`, and teardown usage in `docs/runbook.md`. Verify that the documented commands match the scripts' `--help` output.

## 7. First deployment

- [x] 7.1 Run `scripts/deploy.sh --what-if`, then `scripts/deploy.sh`, against the empty RG `hackathon-platform-affine`. Verify that the deployment succeeds and the printed URL returns the AFFiNE web app over HTTPS with a valid certificate.
- [x] 7.2 Check in Log Analytics (`ContainerAppConsoleLogs_CL`) that the migration output ("running prisma migrations", "running data migrations") was logged before the server started. Verify that a saved KQL query in the runbook returns these lines.
- [ ] 7.3 Open `/admin`, create the administrator account, and store its credentials in the team's password manager. Verify that a second visit to the setup flow does not offer admin creation.
- [ ] 7.4 Send a test email from AFFiNE (for example a password reset for the admin account) using the Azure-managed sender. Verify that it arrives in an MMK inbox and in one external inbox (for example a personal Gmail address).
- [x] 7.5 Re-run `scripts/deploy.sh` with unchanged inputs. Verify that `what-if` reports no changes (or only no-op changes) and that the app keeps the same revision.

## 8. Spec verification on the live instance

- [ ] 8.1 HTTPS and URLs. Verify all of the following:
  - `curl -I http://<fqdn>` redirects to HTTPS or is refused.
  - A share link starts with the published URL.
  - The AFFiNE desktop app connects to the URL as a self-hosted server.
- [ ] 8.2 Collaboration. Verify that two users in different browsers see each other's edits on the same document live, without reloading.
- [ ] 8.3 Durability. Upload an image, then restart the revision (`az containerapp revision restart`). Verify that the document and image are intact and that the signed-in session survives.
- [ ] 8.4 Access control. Verify that anonymous sign-up is refused, and that a user invited or added by the admin can sign in and open the workspace.
- [ ] 8.5 Security. Verify all of the following:
  - The Container App configuration shows credentials only as secret references.
  - `psql` without TLS is refused.
  - A connection from a non-allow-listed IP is refused.
  - A repo-wide secret scan (for example `gitleaks detect`) finds nothing.
- [x] 8.6 Tags and placement. Verify that `az resource list -g hackathon-platform-affine --query "[?tags.project!='hackathon-platform-affine']"` returns an empty list.

- [ ] 8.7 Email. Verify all of the following:
  - A workspace invite and a password reset arrive at an internal and an external address.
  - The links in those emails start with the published URL.
  - The message headers show `spf=pass` and `dkim=pass`.
  - When the `mailer-password` secret is temporarily set to an invalid value, the failure is logged and the app keeps serving requests. Restore the secret afterwards.

## 9. Operations runbook

- [ ] 9.1 Document the upgrade procedure in `docs/runbook.md`: check release notes, note the point-in-time-restore timestamp, bump `affineImageTag`, deploy, and watch logs. Verify it by performing one upgrade, or a dry run with `--what-if` that shows only the image change.
- [ ] 9.2 Document the backup and restore procedures:
  - Postgres point-in-time restore to a new server, then repointing the `database-url` secret.
  - Restoring a file share from soft delete.

  Verify by running a point-in-time restore to a temporary server and connecting with `psql`, then deleting the temporary server.
- [x] 9.3 Document the cost table from design D11, the parameters that change cost, and how to pause (stop Postgres, scale the app to 0). Verify that the costs are cross-checked against the Azure pricing calculator for the chosen region.
- [ ] 9.4 Document SMTP client secret rotation (`deploy.sh --rotate-smtp-secret`) and its expiry date. Verify by running a rotation and sending a test email afterwards.
- [ ] 9.5 Document the pre-teardown export (`pg_dump`, `az storage file download-batch`) and the teardown steps. Verify that the export commands run successfully against the live instance.

## 10. CI/CD pipeline (GitHub Actions)

- [x] 10.1 Extend `scripts/deploy.sh` for CI: take the deployer principal ID and type, the owner, and the SMTP app/SP IDs from environment variables when set, skipping Graph calls; fail clearly in CI if `acs-smtp-client-secret` is missing. Pass the principal type to `bootstrap.bicep`. Verify that `shellcheck` is clean and that a local run behaves as before.
- [x] 10.2 Add `.github/workflows/deploy.yml` with the `validate`, `what-if` (same-repo PRs only), and `deploy` (`production` environment, `main` only) jobs, the `concurrency` group, and the `/info` smoke test (design D13). Verify that `actionlint` reports no errors.
- [ ] 10.3 Add `scripts/setup-cicd.sh`. It creates the app registration `affine-github-deploy` with its service principal and federated credentials, assigns Contributor and the ABAC-conditioned RBAC Administrator role on the RG, and creates the GitHub environment `production` with a `main`-only branch policy and the repository variables. It must be idempotent. Verify with `shellcheck`, run it, and check `az role assignment list --assignee <sp>` (RG scope only) and `gh variable list`.
- [ ] 10.4 Push a feature branch and open a PR. Verify that `validate` and `what-if` succeed and that `what-if` shows no unexpected changes.
- [ ] 10.5 Merge the PR. Verify that the `deploy` job succeeds, including the smoke test, and that a second run reports no resource changes.
- [x] 10.6 Document the pipeline, the one-time bootstrap order, and how to redeploy manually (`workflow_dispatch`) in `docs/runbook.md`. Verify that the documented commands match the workflow and scripts.

## Workflow follow-up

- Archive the change with `/opsx:archive` once the hackathon instance is live and section 8 has passed.
- Possible follow-up changes: Entra ID OIDC sign-in, a custom domain for the app, Azure OpenAI BYOK for AI features, VNet with private Postgres access, and an ACR mirror of the AFFiNE image.
- **Deferred by the user's decision (2026-10-30): send from `@mmkdigital.io`.** The Azure-managed sender is acceptable for now. When it is wanted:
  - Ask MMK's DNS admin for the ACS verification TXT, SPF include, and two DKIM CNAMEs, using the values from the communication module's `verificationRecords` output, after deploying with `mailCustomDomain=mmkdigital.io`.
  - Once ACS shows Verified for the domain, SPF, and DKIM, set `mailUseCustomDomain=true` and redeploy.
  - Check that a test email arrives from `affine@mmkdigital.io` with `dkim=pass`.
