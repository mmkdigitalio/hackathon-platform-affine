@description('PostgreSQL Flexible Server name (globally unique).')
param name string

param location string
param tags object

param administratorLogin string

@secure()
param administratorPassword string

param skuName string = 'Standard_B1ms'

@allowed([
  'Burstable'
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'Burstable'

param storageSizeGB int = 32

@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

param databaseName string = 'affine'

@description('Public IPv4 addresses of operators allowed to connect directly (psql, pg_dump).')
param operatorIpAddresses array = []

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: '16'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    authConfig: {
      passwordAuth: 'Enabled'
      activeDirectoryAuth: 'Disabled'
    }
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Flexible Server rejects concurrent configuration changes, so the children below are chained.

// AFFiNE's migrations run CREATE EXTENSION for both (verified in the spike, design D4).
resource extensionsAllowList 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'VECTOR,PGCRYPTO'
    source: 'user-override'
  }
}

resource requireTls 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'require_secure_transport'
  properties: {
    value: 'ON'
    source: 'user-override'
  }
  dependsOn: [
    extensionsAllowList
  ]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    requireTls
  ]
}

// 0.0.0.0 is Azure's special rule for "allow Azure services" (design D4).
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [
    database
  ]
}

@batchSize(1)
resource operatorRules 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = [
  for (ip, i) in operatorIpAddresses: {
    parent: server
    name: 'operator-${i}'
    properties: {
      startIpAddress: ip
      endIpAddress: ip
    }
    dependsOn: [
      allowAzureServices
    ]
  }
]

output name string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
