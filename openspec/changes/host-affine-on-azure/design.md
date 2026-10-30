# Design

## Context

See `proposal.md` (Why) for the motivation. The repository currently contains only the OpenSpec scaffolding. There is no infrastructure code yet.

Upstream AFFiNE (latest release **v0.27.4**, 2026-08-18) ships one server image, `ghcr.io/toeverything/affine`, which bundles the web app, the admin panel, and the API. The image is published with immutable version tags, for example `0.27.4`. Its official self-host `docker-compose.yml` defines four services:

| Compose service | Role | Notes for Azure |
|---|---|---|
| `affine` | Node.js server on port **3010** (HTTP and WebSocket) | Default CMD is `node ./scripts/upgrade-config.js && exec node ./dist/main.js` |
| `affine_migration` | Runs `node ./scripts/self-host-predeploy.js` once before the server starts | Upgrades the config, **generates `~/.affine/config/private.key` if it is missing**, runs `prisma migrate deploy`, then runs `yarn cli run` (data migrations, which boot the app's module graph) |
| `postgres` | `pgvector/pgvector:pg16` | AFFiNE needs the `vector` extension |
| `redis` | Plain `redis` | Cache, job queue, and WebSocket pub/sub. Nothing in Redis is a system of record |

Persistent paths in the container are `/root/.affine/storage` (blobs) and `/root/.affine/config` (`config.json` and `private.key`).

AFFiNE settings relevant to this deployment, all checked against the upstream `config.schema.json`:
- **Environment variables**:
  - `DATABASE_URL`
  - `REDIS_SERVER_HOST` / `_PORT` / `_PASSWORD` / `_URL`
  - `AFFINE_SERVER_EXTERNAL_URL`, `AFFINE_SERVER_HOST`, `AFFINE_SERVER_HTTPS`
  - `AFFINE_PRIVATE_KEY`
  - `MAILER_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_SENDER`
  - `AFFINE_INDEXER_ENABLED`
- **Blob storage providers**: only `fs`, `aws-s3`, and `cloudflare-r2`. There is **no native Azure Blob provider**.
- **OAuth providers**: `google`, `github`, `apple`, and generic `oidc`. Entra ID would use `oidc`, which is a follow-up.
- **Auth flags**: `auth.allowSignup` and `auth.allowSignupForOauth`.

**Constraints**:
- All resources go in subscription `MMK DIGITAL - Hackathon 2026`, resource group `hackathon-platform-affine`.
- Short lifetime (a hackathon), so cost and simplicity outweigh high availability.
- A small, trusted user group.

## Goals / Non-Goals

**Goals:**
- One command deploys AFFiNE from an empty resource group, and re-running it is safe.
- Use the upstream image unmodified, so upgrades are a one-line version bump.
- No secrets in Git or in deployment history.
- Teardown is `az group delete`.

**Non-Goals:**
- Horizontal scaling, zero-downtime upgrades, or a multi-region setup.
- Building or patching AFFiNE images ourselves.

## Decisions

### D1: Azure Container Apps (Consumption) as the compute platform
The app runs in one Container App, `ca-affine`, inside a Consumption-only Container Apps environment.
- **Why**:
  - Managed HTTPS ingress on `*.azurecontainerapps.io` with a trusted certificate, WebSocket support, and an HTTP→HTTPS redirect (`allowInsecure: false`).
  - Multi-container apps (sidecars) and Azure Files volume mounts.
  - Built-in Log Analytics integration.
  - No servers or OS to patch.
- **Alternatives considered**:
  - *App Service for Containers*: no sidecar parity, and the Azure Files mount story is weaker.
  - *AKS*: far too heavy for one app.
  - *An Azure VM running docker compose*: the closest match to upstream, but it means OS patching, a hand-built TLS setup, and backups of a VM disk.
  - *Azure Container Instances*: no managed TLS or ingress.

### D2: Migrations run in the app container's entrypoint, not as an init container or Job
The `affine` container's command is overridden to:
`sh -c "node ./scripts/self-host-predeploy.js && exec node ./dist/main.js"`
- **Why**:
  - `self-host-predeploy.js` boots AFFiNE's module graph (`yarn cli run`), which may need Redis.
  - Container Apps *init containers* start before sidecars, so they cannot reach a sidecar Redis on `localhost`.
  - A Container Apps *Job* cannot reach a sidecar either.
  - Chaining in the entrypoint keeps upstream's order: migrate, then serve.
  - If a migration fails, the container exits before it listens on port 3010. The new revision never passes its startup probe, so in single-revision mode traffic stays on the previous revision. This meets the spec's *Automatic database migrations* requirement.
- **Alternatives considered**:
  - An init container with a managed Redis: adds cost and the TLS wiring for Redis.
  - A Container Apps Job triggered by the deploy script: needs a reachable Redis and a two-step deploy.
- **Probe**: an HTTP startup probe on port 3010 with the largest budget Container Apps allows (`failureThreshold` ≤ 10): 15 s initial delay + 10 × 30 s ≈ 5 minutes. Migrations took about 6 s on an empty database in the spike. After that, liveness and readiness probes. The probe path is **`/info`**. The spike confirmed it returns 200 with `{"compatibility":"0.27.4",...}` without authentication, about 6 s after migrations finish; `/` and `/admin` return 302.
- **Spike result (task 2.1)**: `self-host-predeploy.js` finished successfully (exit 0, about 6 s on an empty database) *without* Redis. It only logs non-fatal `ENOTFOUND redis` errors from the Cache/Queue/Session/SocketIo Redis clients. An init container would therefore also work. We keep the entrypoint chain anyway, because it is one container definition instead of two and the sidecar Redis is already up, so the logs stay clean.

### D3: Redis as a sidecar container
The sidecar is `redis:7-alpine` with 0.25 vCPU / 0.5 GiB, and `affine` reaches it on `localhost:6379`.
- **Why**: AFFiNE only uses Redis for cache, queues, and pub/sub. Losing it on a restart costs at most in-flight jobs and cached data. A sidecar avoids extra cost and avoids TLS and auth setup.
- **Alternatives considered**: Azure Managed Redis or Azure Cache for Redis cost an extra €15+ per month and need `rediss://` on port 6380. They are worth adopting only together with multi-replica scaling.
- **Spike result**: login sessions are stored in Postgres, not Redis. A signed-in session survived `FLUSHALL` on Redis followed by an app restart, so the ephemeral sidecar does not log users out.
- **Consequence**: the app must stay at **exactly 1 replica** (`minReplicas = maxReplicas = 1`). Two replicas with separate Redis sidecars would break WebSocket fan-out. This is recorded under Risks.

### D4: Azure Database for PostgreSQL – Flexible Server
- **Sizing**:
  - PostgreSQL 16, tier Burstable `Standard_B1ms`, 32 GiB storage with auto-grow.
  - 7-day backup retention.
  - No high availability.
- **Settings**:
  - Server parameter `azure.extensions = VECTOR,PGCRYPTO`. The spike showed that AFFiNE 0.27.4's migrations create both `vector` and `pgcrypto`.
  - `require_secure_transport = on`.
  - Connection string: `postgresql://<admin>@<server>.postgres.database.azure.com:5432/affine?sslmode=require`.
- **Network**: public access with two kinds of firewall rules. One is the "Allow Azure services" rule (0.0.0.0). The others are optional operator IPs (parameter `operatorIpAddresses`) for `psql` and `pg_dump`.
- **Why**: a managed service with point-in-time restore. Running Postgres on Azure Files in a container is unsafe because SMB does not meet Postgres' fsync and locking requirements.
- **Alternatives considered**:
  - *VNet-integrated environment with private access*: it is more secure. It also brings a delegated subnet, private DNS, and a workload-profile environment, which is too much for a hackathon. It is listed as a follow-up.
  - *Cosmos DB for PostgreSQL*: not compatible with AFFiNE.

### D5: Azure Files (SMB) for blobs and configuration
- **Storage account**:
  - Standard LRS, `StorageV2`.
  - Minimum TLS 1.2, HTTPS only.
  - Share soft delete with 7 days of retention.
- **Shares**, both registered as environment storages and mounted in the `affine` container:
  - `affine-storage`, mounted at `/root/.affine/storage`.
  - `affine-config`, mounted at `/root/.affine/config`.
- **Why**: AFFiNE has no Azure Blob provider. The `fs` provider on a mounted share needs no AFFiNE configuration and matches upstream's volume layout.
- **Alternatives considered**: Azure Blob through an S3-compatible gateway (for example MinIO in gateway mode): this is an extra moving part, and the MinIO gateway is deprecated.

### D6: Secrets and server identity
- **Key Vault**: `kv-affine-<suffix>`, in RBAC mode, with 7-day soft delete and purge protection **off** so the name can be reused after teardown. It holds the generated Postgres admin password and the ACS SMTP client secret (`acs-smtp-client-secret`, see D12). The deploy script creates the password once (`openssl rand -hex 32`, which is URL-safe) only if the secret is missing. After that it reuses the stored value, which keeps deployments idempotent.
- **Bicep parameters**: `main.bicep` references the existing vault and passes `keyVault.getSecret(...)` into `@secure()` module parameters, so the values never appear in the repo or in the deployment history. This is used instead of `az.getSecret()` in `main.bicepparam`, because the vault name contains `uniqueString(resourceGroup().id)`, which a parameter file cannot compute. The vault has `enabledForTemplateDeployment: true`.
- **Container App secrets**: Bicep builds the Container App secrets `database-url` and `mailer-password`, and the containers reference them with `secretRef`. No managed identity is needed for this.
- **Server private key**: `self-host-predeploy.js` generates `private.key` on first start. It is persisted on the `affine-config` share, so it stays stable across revisions. `AFFINE_PRIVATE_KEY` is therefore not set.
- **Alternative considered**: Key Vault references in Container App secrets through a managed identity. They are useful for rotation but need a role assignment and gain little here.

### D7: External URL derived from the environment's default domain
Bicep sets:
- `AFFINE_SERVER_EXTERNAL_URL = https://ca-affine.${environment.properties.defaultDomain}`
- `AFFINE_SERVER_HOST` to the same FQDN
- `AFFINE_SERVER_HTTPS = true`

All of these are resolved in the same deployment. A custom domain later only changes this value and adds an ingress custom domain with a managed certificate.

### D8: AFFiNE configuration file
`infra/affine/config.json` is committed and contains no secrets. The deploy script uploads it to the `affine-config` share. It sets:
- `server.name`
- `auth.allowSignup: false` and `auth.allowSignupForOauth: false`
- `indexer.enabled: false`, which matches the upstream compose default. Full-text search through Elasticsearch or Manticore is out of scope.

The first administrator is created through AFFiNE's `/admin` setup wizard, which is not blocked by `allowSignup`. The spike verified this with `allowSignup: false`:
- `POST /api/setup/create-admin-user` created the admin.
- A second call returned `403 First user already created`.
- An anonymous `POST /api/auth/sign-in` for an unknown email returned `403 SIGN_UP_FORBIDDEN`.

### D9: Infrastructure as Code with Bicep and a thin bash wrapper
Layout:

```
infra/main.bicep          # resource-group-scoped entry point
infra/main.bicepparam     # non-secret params + az.getSecret() refs
infra/modules/*.bicep     # log-analytics, keyvault, storage, postgres, communication, containerapp-env, containerapp
infra/affine/config.json  # AFFiNE runtime config (no secrets)
scripts/deploy.sh         # preflight → RG → KV + secret bootstrap (Postgres password, ACS SMTP app registration) → main deployment → upload config → print URL
scripts/teardown.sh       # confirmation prompt → az group delete → delete the affine-acs-smtp app registration
docs/runbook.md
```

`deploy.sh` asserts that the active subscription is `MMK DIGITAL - Hackathon 2026` and exits before making any change if it is not. It creates the resource group with tags if it is missing. It deploys in two stages: `infra/bootstrap.bicep` (Key Vault and storage account), then the secrets and the `config.json` upload, then `infra/main.bicep` (everything else). This ensures `getSecret` can resolve, and that `config.json` with `allowSignup: false` is on the share before AFFiNE starts for the first time. It also supports `--what-if`.
- **Why Bicep**: native to Azure, no state file to manage, and `what-if` previews changes.
- **Alternative considered**: Terraform needs a remote state backend, which is not worth it for a single short-lived resource group.

### D10: Naming, tagging, and region
- **Naming**: Cloud Adoption Framework abbreviations, with `uniqueString(resourceGroup().id)` as the suffix for globally unique names:
  - `log-affine`, `cae-affine`, `ca-affine`
  - `psql-affine-<suffix>`, `staffine<suffix>`, `kv-affine-<suffix>`, `ecs-affine-<suffix>`, `acs-affine-<suffix>`
- **Tags** on every resource: `project=hackathon-platform-affine`, `environment=hackathon`, `owner=<param>`.
- **Region**: **`westeurope`**, kept as a parameter. The original choice was `germanywestcentral`, but the preflight check on 2026-10-30 found that PostgreSQL Flexible Server provisioning is *restricted* there for this subscription ("Provisioning is restricted in this region…", support request needed). West Europe has Container Apps and PostgreSQL Flexible `Standard_B1ms` with PG 16, and the user chose to run everything there. The data stays in the EU.

### D12: Email through Azure Communication Services (ACS) Email over SMTP
AFFiNE's mailer supports only SMTP with a username and password. It has no Graph API or OAuth2 option. ACS Email provides an SMTP endpoint whose username and password come from a Microsoft Entra app registration, so it fits AFFiNE without any changes to AFFiNE.

**Resources**: all of these live in the RG and are defined in `infra/modules/communication.bicep`.
- `Microsoft.Communication/emailServices` `ecs-affine`. Data location `Germany`, or `Europe` if Germany is not offered; the preflight check confirms which.
- **Domains**:
  - `AzureManagedDomain`, which works immediately and sends from `DoNotReply@<guid>.azurecomm.net`.
  - The custom domain `mmkdigital.io` (`CustomerManaged`), for the sender `AFFiNE <affine@mmkdigital.io>`. Its domain is a parameter.
- A sender username `affine` on the custom domain.
- `Microsoft.Communication/communicationServices` `acs-affine`, with `linkedDomains`. The custom domain is linked only once it is verified. Until then, the Azure-managed domain is used.

**SMTP credentials**:
- **App registration**: `deploy.sh` creates an Entra app registration `affine-acs-smtp` with a service principal, *only if* the Key Vault secret `acs-smtp-client-secret` is missing. It writes a new client secret straight into Key Vault with `az ad app credential reset` piped into `az keyvault secret set`, so the secret is never printed.
- **Role**: Bicep grants the service principal the role "Communication and Email Service Owner" on `acs-affine`.
- **Username**: an ACS SMTP Username resource `affine`, or the classic `<acs-name>.<app-client-id>.<tenant-id>` form.

**AFFiNE mailer settings**:

| Setting | Value |
|---|---|
| `MAILER_HOST` | `smtp.azurecomm.net` |
| `MAILER_PORT` | `587` (STARTTLS) |
| `MAILER_IGNORE_TLS` | `false` |
| `MAILER_USER` | the SMTP username above |
| `MAILER_PASSWORD` | `secretRef: mailer-password`, read from the Key Vault secret `acs-smtp-client-secret` |
| `MAILER_SENDER` | `AFFiNE <affine@mmkdigital.io>` once the domain is verified, otherwise the `DoNotReply@…azurecomm.net` address (parameter `mailSender`) |

**Custom-domain DNS**: ACS shows the exact values; MMK's DNS admin adds them once.
- **TXT** `ms-domain-verification=…` on `mmkdigital.io`. This can coexist with the existing Microsoft 365 `MS=…` record.
- **SPF**: `include:spf.protection.outlook.com`. The domain's existing Microsoft 365 SPF record most likely already contains it, so no change may be needed.
- **DKIM**: two CNAMEs, `selector1-azurecomm-prod-net._domainkey` and `selector2-azurecomm-prod-net._domainkey`. These do not collide with Microsoft 365's `selector1`/`selector2`.

Verifying the domain in ACS does not affect MMK's existing Microsoft 365 mail flow.

**Why ACS over a Microsoft 365 mailbox**:
- No legacy-auth or MFA exception is needed for a user account.
- It is not affected by Exchange Online retiring Basic Auth for SMTP AUTH (disabled by default from the end of December 2026).
- The credentials are a service principal secret that we control and can rotate.
- Everything is in IaC and is removed with the RG, apart from the app registration, which `teardown.sh` deletes.

**Alternatives considered**:
- *Exchange Online SMTP AUTH with a dedicated mailbox*: needs Microsoft 365 admin work and a legacy-auth exception, and Basic Auth is being retired.
- *Exchange connector relay on port 25*: needs a static outbound IP, and Azure blocks outbound port 25.
- *A third-party SMTP service such as SendGrid*: an extra vendor and contract.

### D13: CI/CD with GitHub Actions and OIDC
The repository `mmkdigitalio/hackathon-platform-affine` is public, so the pipeline must not depend on stored credentials.

**Workflow** (`.github/workflows/deploy.yml`) runs on PRs to `main`, on pushes to `main` that touch `infra/**`, `scripts/**`, or the workflow itself, and on manual dispatch. It has three jobs:
- **`validate`** (every run, no Azure access): `az bicep build` and `lint` on both templates, `build-params`, and `shellcheck`.
- **`what-if`** (PRs only, and only if the head repo is this repo): `azure/login` via OIDC, then `scripts/deploy.sh --what-if`. GitHub does not issue OIDC tokens to fork PRs anyway.
- **`deploy`** (pushes to `main` and manual dispatch on `main`):
  - Runs in the GitHub environment `production`, whose deployment-branch policy allows only `main`.
  - Calls `scripts/deploy.sh`, then runs a smoke test: `GET https://<fqdn>/info` must report `compatibility == affineImageTag`.
  - A workflow-level `concurrency: affine-azure` with `cancel-in-progress: false` serializes runs.

**Azure identity**: the app registration `affine-github-deploy` has a service principal and two federated credentials. The subjects are `repo:mmkdigitalio/hackathon-platform-affine:environment:production` and `…:pull_request`. The **immutable-ID variants** `repo:mmkdigitalio@77622120/hackathon-platform-affine@1439566435:…` are registered too. The `mmkdigitalio` org issues that format, and the first PR run failed with `AADSTS700213` until they were added. It has two roles on the RG, and none at subscription level:
- `Contributor`.
- `Role Based Access Control Administrator`, with an ABAC condition that allows granting or removing **only** Key Vault Secrets Officer and Communication and Email Service Owner. These are the two roles the templates assign.

`scripts/setup-cicd.sh` creates this once (idempotent), along with the GitHub environment and the repository variables.

**Changes to `deploy.sh` for CI**:
- The service principal has no Microsoft Graph permissions, so the IDs that need Graph are passed as repository **variables** (they are not secrets): `AFFINE_OWNER`, `AFFINE_DEPLOYER_PRINCIPAL_ID` (plus `AFFINE_DEPLOYER_PRINCIPAL_TYPE=ServicePrincipal`), `AFFINE_SMTP_CLIENT_ID`, and `AFFINE_SMTP_PRINCIPAL_ID`.
- Steps that need Graph, which are creating `affine-acs-smtp` and issuing its secret, remain **operator-only**. In CI, `deploy.sh` fails with a clear message if `acs-smtp-client-secret` is missing.
- The Postgres password can still be generated in CI, because the service principal gets Key Vault Secrets Officer through `bootstrap.bicep`.

**Bootstrap order**: run `scripts/deploy.sh` locally once to create the RG, the Key Vault secrets, and the SMTP app registration. Then run `scripts/setup-cicd.sh`. From then on, every change goes through a PR into `main`.

**Alternatives considered**:
- *A client secret stored in GitHub secrets*: a long-lived credential in a public repository's settings.
- *Subscription-scoped Owner for CI*: far broader than needed.
- *Azure DevOps*: the code already lives on GitHub.

### D11: Sizing and cost
These are pay-as-you-go list prices for **`westeurope`** from the Azure Retail Prices API (2026-10-30), with no enterprise discount. The month is 730 h. The Container Apps free monthly allowance (180k vCPU-s, 360k GiB-s) is already deducted. Container Apps meters round to €0 in the EUR feed, so they are converted from USD ($0.000034 per vCPU-s active, $0.000004 per vCPU-s idle, $0.000004 per GiB-s) at the EUR/USD ratio of the PostgreSQL meter (0.88).

| Resource | Size | 24/7 ≈ €/month | Working hours only¹ ≈ €/month |
|---|---|---|---|
| Container App, 1 replica, billed as *active*² | `affine` 1 vCPU / 2 GiB + `redis` 0.25 vCPU / 0.5 GiB | ~115 | ~37 |
| PostgreSQL Flexible B1ms | €0.0175/h compute; 32 GiB storage (billed even when the server is stopped) | ~13 + ~4 | ~5 + ~4 |
| Storage account (Files, LRS, €0.053/GiB) | < 10 GiB plus transactions | ~2 | ~2 |
| Log Analytics (€2.63/GB) | ~1–3 GB/month (the first 5 GB per billing account are free) | 0–5 | 0–3 |
| Key Vault, ACS Email, egress (< 100 GB is free) | | < 2 | < 2 |
| **Total** | | **≈ 135–140** | **≈ 50–55** |

¹ About 12 h on weekdays (~260 h/month). Outside those hours the app is scaled to 0 replicas and the Postgres server is stopped (`scripts/pause.sh` / `resume.sh`, a possible follow-up). Note that Azure restarts a stopped Flexible Server automatically after 7 days.
² Container Apps bills at the much lower *idle* vCPU rate only when a replica uses almost no CPU and network. If AFFiNE turns out to be idle half the time, the 24/7 figure drops to about €75. The real figure becomes visible in Cost Management after a few days.

**Cost levers**:
- Reduce `affine` to 0.75 vCPU / 1.5 GiB: about €90/month for the app 24/7, a saving of about €25.
- Pause outside working hours.
- Keep `logRetentionDays` at 30.

A budget alert on the RG is recommended (see Open Questions).

## Risks / Trade-offs

- **[Single replica, sidecar Redis]**: no high availability, and a few seconds of downtime on restart. → Acceptable for a hackathon. To scale, move Redis to Azure Managed Redis and set `maxReplicas > 1`.
- **[Revision overlap during upgrades]**: while a new revision migrates, the old one still serves on the same database. → Upgrades are planned for quiet periods. Migrations are upstream's responsibility. Take a Postgres backup point before upgrading (see the runbook).
- **[Rollback after a migration]**: reverting the image pin does not undo schema migrations. → Roll back by point-in-time restore to a new server and repoint `DATABASE_URL`, as documented.
- **[The "Allow Azure services" firewall rule]**: this admits traffic from any Azure tenant's IP ranges. → TLS is enforced, the 64-hex-character password is never exposed, and a VNet with private access is a follow-up.
- **[SMB latency for blobs]**: Azure Files is slower than local disk. → Blob reads are cacheable and the user count is small. Premium Files is an option if needed.
- **[Custom-domain DNS depends on MMK's DNS admin]**: until `mmkdigital.io` is verified in ACS, mail comes from `DoNotReply@<guid>.azurecomm.net`, which looks unfamiliar and is more likely to be filtered as spam. → Mail still works from day one. Switching to the MMK address later only changes the `mailSender` parameter and links the domain.
- **[ACS sending limits]**: new ACS resources start with low per-minute and per-hour quotas, especially on the Azure-managed domain. → That is plenty for invites and password resets for a hackathon team. A quota increase can be requested if needed.
- **[App registration permission]**: `deploy.sh` must be able to create an Entra app registration in the MMK DIGITAL tenant. → The preflight check confirms this. If users are not allowed to register apps, an Entra admin creates `affine-acs-smtp` once and stores its secret in Key Vault, and the script then skips creation.
- **[Client secret expiry]**: Entra client secrets expire. → The secret is created with a 1-year lifetime. Rotation is a re-run of `deploy.sh --rotate-smtp-secret`, as documented in the runbook.
- **[Upstream image from GHCR]**: if GHCR has an outage or rate-limits, new revisions cannot start. → Revisions that are already running are unaffected. Mirroring to an Azure Container Registry is a follow-up.
- **[Public repository]**: workflow logs are public. → Logs only contain non-secret identifiers (resource names, the owner UPN, the app URL). Secrets never pass through the workflow, because they stay in Key Vault and are read by ARM via `getSecret`. Fork PRs never get Azure credentials.
- **[Powerful CI identity]**: Contributor on the RG can change or delete anything in it. → It is scoped to this RG only, its role-granting is limited by an ABAC condition, the `production` environment allows only `main`, and federated credentials are restricted to this repository.
- **[Unknown subscription policies]**: Azure Policy in the hackathon subscription may deny public network access, regions, or SKUs. → The preflight task checks policy assignments and provider registrations before the first deploy.

## Migration Plan

1. **Preflight**:
   - Sign in to the MMK DIGITAL tenant and select subscription `MMK DIGITAL - Hackathon 2026`.
   - Check permissions: Contributor plus User Access Administrator, or Owner, on the resource group.
   - Check that the resource providers are registered: `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.DBforPostgreSQL`, `Microsoft.Storage`, `Microsoft.KeyVault`.
   - Check policy assignments and regional availability.
   - Confirm that you can create Entra app registrations, and that ACS Email offers the `Germany` data location.
   - In parallel, ask MMK's DNS admin to add the ACS verification, SPF, and DKIM records for `mmkdigital.io` (D12).
2. **Spike** (local or throwaway): confirm the probe path, Redis use during `self-host-predeploy.js`, and admin setup with `allowSignup: false`.
3. **First deploy**: `scripts/deploy.sh`. Open the printed URL, then `/admin`, and create the administrator.
4. **Verification**: run the spec scenarios: HTTPS, two-user collaboration, image upload with a restart, sign-up blocked.
5. **Upgrades**: bump `affineImageTag` in `main.bicepparam`, note the time for point-in-time restore, run `deploy.sh`, and watch the logs.
6. **Rollback**: if a revision fails before migrating, traffic stays on the old revision automatically. If data is broken after a migration, do a point-in-time restore and repoint (see the runbook).
7. **Teardown**:
   - Optionally export first: `pg_dump` plus copies of the file shares.
   - Then run `scripts/teardown.sh`.

## Open Questions

- **Sender address and domain**: the default is `affine@mmkdigital.io` on the root domain. A subdomain such as `notify.mmkdigital.io` is also possible if MMK prefers to keep the root domain's DNS untouched. This is a parameter only.
- **Budget alert**: add an Azure budget on the RG (for example €150/month, alerting at 80% and 100%) as part of the IaC? The amount and the recipients are still to be decided.
- **Running hours**: 24/7, or paused outside working hours? This decides whether the pause/resume scripts are added.
- **Follow-ups worth planning after the hackathon**:
  - Entra ID sign-in through AFFiNE's `oidc` provider.
  - A custom domain.
  - AI features through BYOK with Azure OpenAI.
  - A VNet with private Postgres access.
