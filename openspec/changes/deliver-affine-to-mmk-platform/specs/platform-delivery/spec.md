# Spec Delta

## Purpose

Defines what this repository delivers to the MMK platform so that AFFiNE can be deployed, verified, and operated by the platform's app path and operations agent.

## ADDED Requirements

### Requirement: Chart honours the platform values contract
The chart SHALL run the image `{{image.repository}}@{{image.digest}}` unmodified, SHALL use `imagePullSecretName` for all pods, SHALL load `secretName` via `envFrom`, and SHALL mount `platform.persistentVolumeClaim`. It SHALL size the Deployment from `platform.replicas` and `platform.resources`. It SHALL NOT create Secrets, Ingress rules, PVCs, or databases, and SHALL NOT use `rolloutMarker` or `platform.release` in pod templates.

#### Scenario: Platform installs the chart
- **WHEN** the app path installs release `affine` with its values in `affine-staging`
- **THEN** a Deployment `affine` with strategy `Recreate` and label `app.kubernetes.io/instance: affine`, and a Service `affine` on port 3010 exist, and no Secret, Ingress, or PVC is part of the release

#### Scenario: Forced upgrade without changes
- **WHEN** the app path upgrades with only a new `rolloutMarker`
- **THEN** the pod template is unchanged and AFFiNE is not restarted

### Requirement: Schema accepts platform keys and rejects unsafe sizes
`values.schema.json` SHALL accept `platform` and other unknown top-level keys, SHALL reject an image digest that is not `sha256:<64 hex>`, and SHALL reject more than one replica.

#### Scenario: Two replicas requested
- **WHEN** `platform.replicas` is 2
- **THEN** rendering fails with a schema error

### Requirement: Unauthenticated availability path
`/info` SHALL return HTTP 200 without authentication while AFFiNE serves requests.

#### Scenario: Server ready
- **WHEN** the readiness probe passes
- **THEN** `GET /info` returns 200

### Requirement: Smoke test follows the contract and proves persistence
The smoke image SHALL read `TARGET_URL`, `SMOKE_USER_EMAIL`, and `SMOKE_USER_PASSWORD`. It SHALL exit 0 only on success and SHALL print one JSON line with `success`, `startedAt`, `finishedAt`, and `evidence` as its last line, without secrets. It SHALL check sign-in, a fixed document, a write to that document, and an attachment. It SHALL create the fixture only when the smoke user has no workspace.

#### Scenario: First run on a fresh instance
- **WHEN** the smoke test runs against an uninitialized AFFiNE
- **THEN** it creates the smoke user, workspace, document `mmk-smoke-persistence`, and attachment, and reports success with references to both

#### Scenario: Later run
- **WHEN** the smoke test runs again after a restart or redeploy
- **THEN** it finds the same document and attachment, reports them as found again, and succeeds

#### Scenario: Attachment lost
- **WHEN** the attachment blob is missing from the volume
- **THEN** the `attachment` check fails and the exit code is non-zero

#### Scenario: Smoke user missing on an initialized instance
- **WHEN** the instance has an administrator but no smoke user
- **THEN** the `login` check fails with a pointer to the runbook and nothing is created

### Requirement: Documented non-repairable fault value
The delivery SHALL name a path and value under `values` that pass the chart schema, prevent AFFiNE from starting regardless of restarts and redeploys, and touch neither data nor secrets.

#### Scenario: Fault value rolled out
- **WHEN** `values.affine.nodeOptions` is `--max-old-space-size=16`
- **THEN** the rollout fails, a restart does not recover it, and after reverting the value the smoke test finds the original fixture again

### Requirement: Automated publication and handoff
Every change to the package SHALL be checked and tested end to end before publication. Publication from `main` SHALL produce a versioned OCI chart and a smoke image addressed by digest. It SHALL propose the catalog entry and desired state to the platform repository with the runbook pinned to the publishing commit.

#### Scenario: Merge to main
- **WHEN** a change to `charts/`, `smoke/`, `runbook/`, or `platform-delivery/` is merged
- **THEN** the workflow publishes chart `0.1.<run>` and the smoke image, and opens a PR in the platform repository carrying the new chart version, smoke digest, and runbook commit
