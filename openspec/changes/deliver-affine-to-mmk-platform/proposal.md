# Proposal

## Why

The MMK platform ([`mmkdigitalio/hackathon-platform-team`](https://github.com/mmkdigitalio/hackathon-platform-team)) runs apps on a shared AKS cluster and operates them with an autonomous operations agent: it alerts on availability, verifies releases with an app-specific smoke test, and may `restart` or `redeploy` an app guided by its runbook. AFFiNE is the platform's only business app. To be deployed and maintained this way, this repository has to deliver a package against the platform's app catalog contract v0.1. The 12-point checklist is in `platform/operations/apps/affine/LIEFERANFORDERUNGEN.md` there.

## What Changes

- Add a Helm chart `charts/affine` that runs the unmodified upstream image under the platform's values contract (image by digest, `envFrom` platform secret, platform PVC, replicas, resources). The chart creates no Secrets, Ingress, PVCs, or databases. Migrations run in an init container.
- Add a smoke-test image `smoke/` that implements the smoke-test contract. It signs in, creates a fixed test document with an attachment on the first run, finds both again on every later run, and proves a fresh write.
- Add the platform runbook `runbook/README.md`: symptoms, diagnosis, the allowed actions `restart` and `redeploy`, and their limits.
- Add `platform-delivery/`: the catalog entry, a proposed staging desired state, and the non-repairable fault value, laid out so the platform validator can check it with `--tree`.
- Add `test/e2e-kind.sh`, which emulates the platform's app path in kind. It checks the first run, persistence across a restart, and the fault value.
- Add `.github/workflows/platform-package.yml`. It checks and end-to-end tests the package on each PR. On `main` it publishes the chart and smoke image to GHCR and creates a release that the platform repository's `app-affine-sync.yml` applies to its `main`.

**Out of scope**: changes to the platform repository itself (catalog PR, ingress annotations, `azure.extensions`), production environment, and retiring the Azure Container Apps deployment from `host-affine-on-azure`. Both deployments can coexist; they share no resources.

## Capabilities

### New Capabilities
- `platform-delivery`: The package AFFiNE delivers to the MMK platform, consisting of the chart contract, smoke test, runbook, catalog data, and their automated publication.

### Modified Capabilities
<!-- None. -->

## Impact

- New directories `charts/`, `smoke/`, `runbook/`, `platform-delivery/`, a new workflow, and a new script. Nothing under `infra/` changes.
- GHCR packages `ghcr.io/mmkdigitalio/charts/affine` and `ghcr.io/mmkdigitalio/affine-smoke`, which must be public.
- Platform-side dependencies: WebSocket-capable ingress (no PostgreSQL extensions are required), and the repository secret `PLATFORM_REPO_TOKEN` for automated handoff.
