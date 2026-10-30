// Stage 1 of the deployment (see scripts/deploy.sh):
// the stateful foundations that must exist before the app starts —
// Key Vault (for generated secrets) and the storage account whose
// config share receives config.json before AFFiNE's first start.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Owner tag value (UPN of the responsible person).')
param owner string

param environmentName string = 'hackathon'

@description('Object ID of the user or pipeline identity running deploy.sh.')
param deployerPrincipalId string

@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

var suffix = uniqueString(resourceGroup().id)
var tags = {
  project: 'hackathon-platform-affine'
  environment: environmentName
  owner: owner
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: 'kv-affine-${suffix}'
    location: location
    tags: tags
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    name: 'staffine${suffix}'
    location: location
    tags: tags
  }
}

output keyVaultName string = keyVault.outputs.name
output storageAccountName string = storage.outputs.name
output configShareName string = storage.outputs.configShareName
