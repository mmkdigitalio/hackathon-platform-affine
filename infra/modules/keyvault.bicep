@description('Key Vault name (globally unique, max 24 characters).')
@maxLength(24)
param name string

param location string
param tags object

@description('Object ID of the user running the deployment. Granted "Key Vault Secrets Officer" so deploy.sh can create secrets.')
param deployerPrincipalId string

@description('Principal type of the deployer.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param deployerPrincipalType string = 'User'

// Built-in role: Key Vault Secrets Officer
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    // Lets main.bicep pass secrets into modules via getSecret() without exposing them in deployment history.
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Purge protection intentionally left off so the name can be reused after teardown (design D6).
    publicNetworkAccess: 'Enabled'
  }
}

resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployerPrincipalId, secretsOfficerRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

output name string = vault.name
output id string = vault.id
