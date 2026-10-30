# Spec Delta

## Purpose

Defines how the Azure environment hosting AFFiNE is placed, provisioned, observed, backed up, and torn down. The goal is an environment that is reproducible, auditable, and cheap to remove.

## ADDED Requirements

### Requirement: Designated subscription and resource group
All Azure resources for the AFFiNE deployment SHALL be created in the subscription `MMK DIGITAL - Hackathon 2026` and in the resource group `hackathon-platform-affine`.

#### Scenario: Resource inventory
- **WHEN** an operator lists the resources that belong to the deployment
- **THEN** every resource is in resource group `hackathon-platform-affine` in subscription `MMK DIGITAL - Hackathon 2026`, and none are in any other resource group or subscription

#### Scenario: Wrong subscription selected
- **WHEN** the deploy script runs while the Azure CLI's active subscription is not `MMK DIGITAL - Hackathon 2026`
- **THEN** the script aborts before creating or changing any resource and names the expected subscription

### Requirement: Declarative, idempotent provisioning
The infrastructure SHALL be defined as code in this repository and deployed with a single documented command. Re-running that command with unchanged inputs SHALL NOT change any resources.

#### Scenario: Fresh deployment
- **WHEN** an operator with sufficient permissions runs the documented deploy command against an empty resource group
- **THEN** all resources are created and AFFiNE becomes reachable at its HTTPS URL, with no manual portal steps beyond the documented first-run admin setup

#### Scenario: Repeated deployment
- **WHEN** the deploy command runs a second time with the same inputs
- **THEN** it completes successfully and reports no resource changes, apart from no-op updates

### Requirement: Automated deployment pipeline
Changes to infrastructure or deployment code merged into `main` SHALL be deployed to Azure by a CI/CD pipeline without manual steps. Deployments SHALL run one at a time and SHALL only start from `main`.

#### Scenario: Merge to main
- **WHEN** a change to `infra/`, `scripts/`, or the pipeline definition is merged into `main`
- **THEN** the pipeline deploys it to the resource group and finishes with a smoke test confirming that the instance answers over HTTPS with the pinned AFFiNE version

#### Scenario: Deployment from another branch
- **WHEN** someone tries to run the deploy job from a branch other than `main`
- **THEN** the deployment is refused and no Azure resources change

#### Scenario: Concurrent merges
- **WHEN** two changes are merged shortly after each other
- **THEN** their deployments run one after the other, never in parallel

### Requirement: Pull request preview
Every pull request that targets `main` SHALL be validated (template build and lint, script lint). Pull requests opened from this repository SHALL also get a preview of the Azure changes they would cause. No pull request SHALL change Azure resources.

#### Scenario: Pull request with an infrastructure change
- **WHEN** a pull request from a branch of this repository changes a Bicep file
- **THEN** the pipeline reports validation results and a change preview, and no Azure resource is created, changed, or deleted

#### Scenario: Pull request from a fork
- **WHEN** a pull request comes from a fork
- **THEN** only validation runs, and the pipeline does not obtain Azure credentials

### Requirement: No long-lived pipeline credentials
The pipeline SHALL authenticate to Azure with short-lived federated tokens. No Azure password, client secret, or storage key SHALL be stored in the repository or in CI settings. The pipeline identity SHALL be limited to the deployment's resource group.

#### Scenario: Inspecting CI configuration
- **WHEN** an operator reviews the repository's Actions secrets and variables
- **THEN** only non-secret identifiers are configured (client, tenant, and subscription IDs), and no Azure secret is present

#### Scenario: Pipeline identity scope
- **WHEN** an operator lists the pipeline identity's role assignments
- **THEN** all of them are scoped to resource group `hackathon-platform-affine`, and the identity can only grant the roles the templates require

### Requirement: Consistent naming and tagging
Every resource SHALL follow one documented naming convention. Every resource SHALL carry tags that identify its owner, the project, and the environment.

#### Scenario: Tag audit
- **WHEN** an operator inspects any resource in the resource group
- **THEN** it has at least the tags `project=hackathon-platform-affine`, `owner`, and `environment`

### Requirement: Centralized logging
Application stdout and stderr, together with platform system logs, SHALL be sent to one Log Analytics workspace in the resource group, with a retention of at least 30 days.

#### Scenario: Investigating an error
- **WHEN** an operator queries the Log Analytics workspace for the AFFiNE container's logs from the past hour
- **THEN** the application's log lines, including migration output, are returned

### Requirement: Database backup and restore
The database SHALL be backed up automatically with point-in-time restore available for at least 7 days. The restore procedure SHALL be documented.

#### Scenario: Restore to a point in time
- **WHEN** an operator follows the documented restore procedure for a timestamp within the retention window
- **THEN** a database server holding the data as of that time is created and can be connected to AFFiNE

### Requirement: Blob storage protection
Persistent blob storage SHALL have soft delete enabled with a retention of at least 7 days, so that an accidentally deleted storage share can be recovered.

#### Scenario: Accidental share deletion
- **WHEN** the blob file share is deleted by mistake
- **THEN** it can be restored from soft delete within the retention window

### Requirement: Encrypted connections to backing services
Connections from the application to the database and to storage SHALL be encrypted in transit. The database SHALL reject unencrypted connections.

#### Scenario: Unencrypted database connection attempt
- **WHEN** a client tries to connect to the database without TLS
- **THEN** the connection is refused

### Requirement: Restricted database network access
The database SHALL accept connections only from Azure-hosted services and from explicitly listed operator IP addresses, never from arbitrary internet addresses.

#### Scenario: Connection from unlisted IP
- **WHEN** a client from an IP address that is not allow-listed tries to connect to the database
- **THEN** the connection is refused at the firewall

### Requirement: Clean teardown
Deleting the resource group SHALL remove the entire deployment. No billable resources SHALL remain outside the resource group. A documented teardown command SHALL exist and SHALL ask for explicit confirmation.

#### Scenario: Post-hackathon cleanup
- **WHEN** the operator runs the documented teardown command and confirms
- **THEN** the resource group and all AFFiNE resources are deleted, and no deployment resources remain in other resource groups

### Requirement: Documented cost envelope
The deployment's expected monthly cost SHALL be documented, and the default sizing SHALL keep it within that envelope.

#### Scenario: Cost review
- **WHEN** an operator reads the runbook
- **THEN** it states the expected monthly cost per resource and the parameters that change it
