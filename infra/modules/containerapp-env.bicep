@description('Container Apps environment name.')
param name string

param location string
param tags object

param logAnalyticsWorkspaceName string
param storageAccountName string
param blobShareName string
param configShareName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

resource blobStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: environment
  name: blobShareName
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: blobShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource configStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: environment
  name: configShareName
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: configShareName
      accessMode: 'ReadWrite'
    }
  }
}

output id string = environment.id
output defaultDomain string = environment.properties.defaultDomain
output blobStorageName string = blobStorage.name
output configStorageName string = configStorage.name
