# Proposal

## Why

For Hackathon 2026, MMK DIGITAL wants a shared knowledge base and whiteboard that the team controls itself. AFFiNE ([toeverything/affine](https://github.com/toeverything/affine)) is an open-source alternative to Notion and Miro. It ships an official self-host container, but upstream only documents a Docker Compose setup for a single host. We need a reproducible, container-based deployment on our own Azure subscription so that workspace data stays in our tenant, sign-up stays under our control, and the environment can be torn down cleanly after the hackathon.

## What Changes

- Add Infrastructure-as-Code (Bicep) and a deploy script that provision AFFiNE in the resource group `hackathon-platform-affine`. The resource group lives in the subscription `MMK DIGITAL - Hackathon 2026`.
- Run the upstream AFFiNE server image (`ghcr.io/toeverything/affine`, pinned to a released version) as a container on **Azure Container Apps**. Before each new revision starts, the image's own migration script runs first.
- Back AFFiNE with managed or persistent Azure services instead of the Compose-local containers:
  - **Azure Database for PostgreSQL – Flexible Server** (PostgreSQL 16 with the `vector` extension) instead of the `pgvector/pgvector` container.
  - **Azure Files** for uploaded blobs and AFFiNE's `config.json`, instead of host bind mounts.
  - **Redis** as a sidecar container in the same app, since it only serves as a cache and job queue.
- Send AFFiNE's transactional email (invites, password resets) with **Azure Communication Services Email** over SMTP, from an MMK DIGITAL sender address (`affine@mmkdigital.io`) once that custom domain is verified. Until then, an Azure-managed sender domain is used.
- Expose AFFiNE over HTTPS on the Container Apps default domain, with WebSocket support for real-time collaboration.
- Generate credentials at deploy time and keep them in Azure Key Vault, injected as Container App secrets. These are the database password and the ACS SMTP client secret, and none of them go in the repo. AFFiNE's server private key is generated on first start and persisted on the config share.
- Send container and platform logs to a Log Analytics workspace.
- Document the operational runbook: first-run admin setup, upgrading AFFiNE, backup and restore, and teardown.

**Out of scope** for this change: custom domain and certificate, Entra ID (OIDC) single sign-on, AI/Copilot features, full-text search via Elasticsearch or Manticore, private networking (VNet or Private Endpoints), and multi-replica high availability. These are listed as possible follow-ups in `design.md`.

## Capabilities

### New Capabilities
- `affine-hosting`: Behavior of the hosted AFFiNE instance. Covers reachability over HTTPS, real-time collaboration, durable workspace data and blobs, controlled sign-up and admin bootstrap, secret handling, and version-pinned upgrades with automatic migrations.
- `azure-infrastructure`: How the Azure environment is provisioned and operated. Covers placement in the designated subscription and resource group, reproducible declarative provisioning, naming and tagging, observability, backup, and clean teardown.

### Modified Capabilities
<!-- None: there are no existing specs in this repository. -->

## Impact

- **New repository content**: `infra/` (Bicep modules and parameters), `scripts/` (deploy, upgrade, teardown helpers), and `docs/` (runbook). There is no application code. AFFiNE is consumed as an upstream image and is not forked.
- **Azure**: new resources in subscription `MMK DIGITAL - Hackathon 2026` / RG `hackathon-platform-affine`:
  - Container Apps environment and app
  - PostgreSQL Flexible Server
  - Storage account with file shares
  - Key Vault
  - Azure Communication Services and its Email service
  - Log Analytics workspace
- **Cost**: roughly €135–140/month running 24/7 at list prices in `westeurope`, or about €50–55/month if it is paused outside working hours (see design D11). The main costs are a Container App with one always-on replica and a Burstable B1ms PostgreSQL server. Everything is removed by deleting the resource group.
- **External dependencies**:
  - GitHub Container Registry, which must be reachable to pull the AFFiNE image.
  - The MMK DIGITAL Entra ID tenant, for one app registration (`affine-acs-smtp`) that serves as the SMTP login.
  - MMK's DNS for `mmkdigital.io`, which needs one TXT record for verification, an SPF record (likely already present), and two DKIM CNAMEs. These are only needed for the MMK sender address.
- **Security**: a public HTTPS endpoint. Open self-registration is disabled after the admin account is created.
