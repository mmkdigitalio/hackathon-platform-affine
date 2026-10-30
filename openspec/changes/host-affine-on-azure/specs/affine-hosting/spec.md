# Spec Delta

## Purpose

Defines how the self-hosted AFFiNE instance must behave for its users and operators. This covers reachability, collaboration, data durability, access control, secret handling, and upgrades.

## ADDED Requirements

### Requirement: Public HTTPS endpoint
The AFFiNE instance SHALL be reachable by browsers and AFFiNE desktop clients at a stable HTTPS URL, using a certificate trusted by browsers. Plain HTTP requests SHALL NOT serve application content.

#### Scenario: Browser opens the instance
- **WHEN** a user opens the published AFFiNE URL over HTTPS
- **THEN** the AFFiNE web app loads with a valid TLS certificate and no browser security warning

#### Scenario: Plain HTTP request
- **WHEN** a client requests the instance over `http://`
- **THEN** the request is redirected to HTTPS or refused, and no application content is served over plain HTTP

#### Scenario: Desktop client connects
- **WHEN** a user adds the published URL as a self-hosted server in the AFFiNE desktop app
- **THEN** the client connects and can sign in

### Requirement: Correct external URL
The instance SHALL generate every absolute link it emits from its published HTTPS URL. This includes invite links, share links, OAuth callbacks, and email links.

#### Scenario: Share link generated
- **WHEN** a user creates a public share link for a document
- **THEN** the link starts with the published HTTPS URL, not `localhost` or an internal hostname

### Requirement: Real-time collaboration
The instance SHALL support WebSocket connections, so that edits by one user reach other users viewing the same document without a page reload.

#### Scenario: Two users edit one document
- **WHEN** two signed-in users have the same document open and one of them types
- **THEN** the other user sees the change within a few seconds without reloading

### Requirement: Durable workspace data
Workspace documents, users, and metadata SHALL be stored outside the application container. They SHALL survive container restarts, new revisions, and image upgrades.

#### Scenario: Container restart
- **WHEN** the application container is restarted or replaced by a new revision
- **THEN** all previously saved workspaces and documents are still present and unchanged

### Requirement: Durable blob storage
Uploaded files such as images, attachments, and avatars SHALL be stored on persistent storage outside the application container. They SHALL survive container restarts and upgrades.

#### Scenario: Uploaded image after restart
- **WHEN** a user uploads an image to a document and the container is then restarted
- **THEN** the image still renders in the document

### Requirement: Stable server identity
The instance SHALL use the same server private key across restarts and upgrades, so that existing sessions, tokens, and signed links stay valid.

#### Scenario: Session survives revision change
- **WHEN** a new revision is deployed while a user is signed in
- **THEN** the user stays signed in after the revision becomes active

### Requirement: Admin bootstrap
On first start, the instance SHALL let the operator create the initial administrator account through AFFiNE's setup flow. After that it SHALL NOT let anyone else claim the administrator role.

#### Scenario: First-run setup
- **WHEN** the operator opens `/admin` on a freshly deployed instance
- **THEN** the setup wizard lets them create the administrator account

#### Scenario: Setup after bootstrap
- **WHEN** anyone opens the setup flow after the administrator account exists
- **THEN** no additional administrator account can be created through it

### Requirement: Controlled sign-up
Once bootstrap is complete, the instance SHALL disable open self-registration. New users SHALL join only when an administrator or workspace owner invites them.

#### Scenario: Anonymous sign-up attempt
- **WHEN** an unknown visitor tries to create an account after bootstrap
- **THEN** account creation is refused

#### Scenario: Invited user
- **WHEN** an administrator adds a user or sends a workspace invite
- **THEN** that user can create an account and access the invited workspace

### Requirement: Transactional email delivery
The instance SHALL send its transactional email, such as workspace invites, account invites, and password resets, from one configured sender address. The email SHALL reach recipients both inside and outside the MMK DIGITAL organization, and SHALL pass SPF and DKIM checks for the sender's domain.

#### Scenario: Workspace invite email
- **WHEN** a workspace owner invites a person by email address
- **THEN** that person receives an invite email from the configured sender address, and its link points to the published HTTPS URL

#### Scenario: Password reset email
- **WHEN** a registered user requests a password reset
- **THEN** the user receives a reset email from the configured sender address

#### Scenario: Authentication headers
- **WHEN** a recipient inspects the headers of an email sent by the instance
- **THEN** SPF and DKIM both show `pass` for the sender's domain

### Requirement: MMK DIGITAL sender address
Once the MMK DIGITAL custom mail domain is verified, the configured sender address SHALL be an address on that domain, such as `affine@mmkdigital.io`. Until then, a platform-provided sender domain SHALL be used, so that email works from the first deployment.

#### Scenario: Before domain verification
- **WHEN** the MMK DIGITAL domain is not yet verified
- **THEN** email is still delivered, from the platform-provided sender address

#### Scenario: After domain verification
- **WHEN** the MMK DIGITAL domain is verified and the sender setting is switched to it
- **THEN** new emails arrive from the MMK DIGITAL address, with no other change to the instance

#### Scenario: Mail delivery failure is visible
- **WHEN** the mail server rejects a message, for example because of an authentication error
- **THEN** the failure appears in the application logs, and the instance keeps serving requests

### Requirement: Secrets kept out of source control
Credentials SHALL NOT be committed to the repository or stored in plaintext in deployment parameters. This covers the database password, the server private key, and the SMTP password.

#### Scenario: Repository scan
- **WHEN** the repository contents are scanned for credentials
- **THEN** no database password, private key, or SMTP password is found

#### Scenario: Inspecting app configuration
- **WHEN** an operator views the container app's configuration in the Azure portal
- **THEN** credentials appear as secret references, not plaintext environment values

### Requirement: Version-pinned image
The deployment SHALL run an explicitly pinned, released AFFiNE server image version, not a floating tag like `stable` or `latest`. The running version SHALL change only when that pin is changed.

#### Scenario: Redeploy without version change
- **WHEN** the deployment is re-run with unchanged parameters after upstream has published a newer `stable` image
- **THEN** the running AFFiNE version stays the same

### Requirement: Automatic database migrations
Before a new AFFiNE version serves traffic, its database migrations SHALL complete. A failed migration SHALL prevent the new revision from becoming active.

#### Scenario: Upgrade to a newer version
- **WHEN** the operator bumps the pinned AFFiNE version and redeploys
- **THEN** migrations run to completion before the new revision serves requests, and existing workspaces open correctly afterwards

#### Scenario: Migration failure
- **WHEN** the migration step exits with an error
- **THEN** the new revision does not receive traffic and the failure is visible in the logs

### Requirement: Health and self-recovery
The platform SHALL monitor the application's health and restart it automatically when it stops responding.

#### Scenario: Application hangs
- **WHEN** the AFFiNE server stops answering its HTTP port
- **THEN** the platform restarts the container without operator action
