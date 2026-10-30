# Tasks

## 1. Contract research and AFFiNE spike

- [x] 1.1 Read `LIEFERANFORDERUNGEN.md`, the app-catalog README (values and smoke-test contracts), `program.ts`, `blocks.ts`, `smoke-job.sh`, and `app-update-desired-state.yml` in the platform repository. Verify that design.md "Context" matches them.
- [x] 1.2 Run `self-host-predeploy.js` of `ghcr.io/toeverything/affine:0.27.4` against Postgres 16, using a login that owns its database but is not a superuser. Verify that migrations succeed, that only `pgcrypto` is created, and that `vector` is skipped.
- [x] 1.3 Find the endpoints for setup, sign-in, GraphQL, the Socket.IO events, and the doc and blob reads. Verify that the password limit is 32 characters (`serverConfig.credentialsRequirement`).

## 2. Chart

- [x] 2.1 Add `charts/affine`, which consists of a Deployment (init container `migrate`, `Recreate`, probes on `/info`), a Service on port 3010, and ConfigMap `affine-config`. Verify that `helm lint` passes and that `helm template` with the platform values renders only those three objects.
- [x] 2.2 Add `values.schema.json`. Verify that a bad digest, an unknown `affine.*` key, and `platform.replicas: 2` are rejected, and that the fault value and unknown top-level keys are accepted.

## 3. Smoke test

- [x] 3.1 Add `smoke/` (Node 22, `yjs`, `socket.io-client`, pinned). Run it against a fresh local AFFiNE. Verify these outcomes:
  - The first run creates the fixture.
  - A run after a restart finds it again.
  - A wrong password fails `login`.
  - A deleted blob fails `attachment`.
- [ ] 3.2 Build the image in CI and publish it to GHCR. Verify that the package is public and that `docker pull` works without signing in.

## 4. Delivery data

- [x] 4.1 Add `platform-delivery/catalog/affine/app.yaml`, `environments/staging/affine.yaml`, and `fault-invalid-config.yaml`. Verify that `npx tsx src/cli.ts validate --tree platform-delivery` in the platform repository passes. Use the validator fixtures until strand A's conventions are on `main`; the only expected warning is the smoke digest placeholder.
- [x] 4.2 Write `runbook/README.md`, covering symptoms, diagnosis, `restart`/`redeploy`, limits, the smoke user, data procedures, and upgrades.

## 5. End-to-end and automation

- [x] 5.1 Run `test/e2e-kind.sh --fault` locally. Verify these outcomes:
  - The first run passes.
  - The run after a restart finds the fixture again.
  - The fault value fails the rollout, and a restart does not fix it.
  - After the revert, the fixture is found again.
- [ ] 5.2 Merge `platform-package.yml`. Verify that the PR runs `check` and `e2e` and that `main` runs `publish`.
- [ ] 5.3 Set the repository secret `PLATFORM_REPO_TOKEN`. Verify that `handoff` opens the PR in the platform repository with the real smoke digest, chart version, and runbook commit.

## 6. Platform-side follow-ups (other strands)

- [x] 6.1 Check whether the foundation server needs extensions. Verify that with a login lacking `CREATE` on its database, migrations warn but succeed and both smoke runs pass (no `PGCRYPTO`/`VECTOR` allowlist needed).
- [ ] 6.2 Strand B: create `platform/environments/staging/affine.yaml` from the proposal, and review the ingress body limit for attachments.
- [ ] 6.3 Copy the fault value into `platform/operations/apps/affine/fault-invalid-config.yaml`, and update the handoff table in `LIEFERANFORDERUNGEN.md`.
