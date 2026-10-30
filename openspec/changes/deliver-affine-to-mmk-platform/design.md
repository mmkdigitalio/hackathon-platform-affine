# Design

## Context

The platform's app path (Pulumi, `platform/infra/app-runtime` in the platform repository) creates, per app and environment, the following: namespace `affine-<env>`, secret `affine-platform`, pull secret `acr-pull`, PVC `affine-data` (RWO, `managed-csi`), `affine-redis` (no persistence), database and login `affine` on the shared Azure PostgreSQL Flexible Server, and the ingress `affine.<baseDomain>`. It then installs the chart as Helm release `affine` with `atomic: false` and `--wait`, and runs the smoke image as a Job. These facts were verified against `program.ts`, `blocks.ts`, and `smoke-job.sh` on `main`.

## Decisions

### D1: Migrations in an init container
`self-host-predeploy.js` runs as init container `migrate` with the same mounts as the server, so it also creates `config/private.key` on the PVC on first start. A Helm hook was rejected because a hook Job could not mount the RWO volume next to the running pod. Running the script in the server's start command was rejected because migration logs and failures should be distinguishable for the agent (`-c migrate`).

### D2: One PVC, two subPaths, config from a ConfigMap
`affine-data` is mounted twice: `storage` → `/root/.affine/storage` (blobs) and `config` → `/root/.affine/config` (private key). `config.json` comes from ConfigMap `affine-config` as a read-only file mounted over it. The defaults are sign-up off and indexer off. `values.affine.config` is deep-merged over them, and a checksum annotation rolls the pod when the config changes.

### D3: Pod template carries only selector labels
Chart version and app version labels stay on the Deployment, not on the pod template. Otherwise every chart release would restart AFFiNE, and with `Recreate` that means an outage. `rolloutMarker` and `platform.release` are not used in templates.

### D4: `platform.replicas` capped at 1 by the schema
Blobs live on an RWO volume. `values.schema.json` allows 0 or 1. The top level stays open for `platform` and future keys.

### D5: Smoke test in Node with `yjs` and `socket.io-client`
AFFiNE accepts document writes only over Socket.IO (`space:push-doc-update`) as Yjs updates. Reads are plain HTTP (`/api/workspaces/:id/docs/:docId`, `/blobs/:key`). Blob upload uses the GraphQL multipart `setBlob`. The server stores blobs under the upload's filename, so the test uploads under the SHA-256 (base64url) as AFFiNE clients do. Dependencies are pinned in `package-lock.json`, and the base image is pinned by digest.

### D6: Smoke user bootstrap and password length
The catalog generates `smoke-user-password` (40 characters), but AFFiNE allows at most 32, so the test uses the first 32. On an uninitialized instance the test creates the smoke user via `/api/setup/create-admin-user`, which makes it the first administrator. Humans then create their own accounts from `/admin` (runbook). On an initialized instance without the smoke user the test fails with a pointer to the runbook. It does not try to work around disabled sign-up.

### D7: Never recreate the fixture over data loss
The fixture (workspace, doc `mmk-smoke-persistence`, attachment) is created only if the smoke user has no workspace at all. If workspaces exist but the doc is missing, or the blob returns 404, the test fails. This makes the failure visible for acceptance scenario 9 instead of silently passing.

### D8: Fault value `affine.nodeOptions = --max-old-space-size=16`
`NODE_OPTIONS` is a legitimate tuning value, and the staging default is `1536`. With 16 MB of heap, AFFiNE 0.27.4 aborts on every start with a V8 OOM (exit 133). This was verified twice locally and in kind. The value applies only to the server container, so migrations, the database, the PVC, and secrets are untouched, and neither `restart` nor `redeploy` changes the outcome.

### D9: Publication to GHCR, handoff by PR
The chart is published as `0.1.<run number>` to `oci://ghcr.io/mmkdigitalio/charts`, and the smoke image as `ghcr.io/mmkdigitalio/affine-smoke@<digest>`, both with `GITHUB_TOKEN`. The handoff job writes the catalog entry with the real smoke digest and `runbook.commit = github.sha`. It then sets image and chart version in the staging desired state with the platform's own `set-desired` CLI and opens a PR. The PR auto-merges only when the catalog entry is unchanged.

## Risks / Trade-offs

- [`pgcrypto` not allowlisted on the foundation server] → migrations fail in `migrate`. The runbook names the symptom, and this was handed to strand A.
- [Ingress body limit of 1 MB] → larger uploads fail with 413. The smoke attachment is small, so this is not detected by the test. Handed to strand B.
- [No backup of attachments and `private.key`] → accepted staging risk, documented in `dataProcedures`.
- [Socket.IO protocol drift in future AFFiNE releases] → the kind end-to-end test runs the smoke test against every proposed version before handoff.
