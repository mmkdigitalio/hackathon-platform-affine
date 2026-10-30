@description('Storage account name (globally unique, 3-24 lowercase alphanumerics).')
@minLength(3)
@maxLength(24)
param name string

param location string
param tags object

@description('Quota of the blob share in GiB.')
param blobShareQuotaGb int = 100

@description('Days a deleted file share can be restored from soft delete.')
@minValue(7)
param shareSoftDeleteDays int = 7

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Container Apps mounts Azure Files over SMB with the account key.
    allowSharedKeyAccess: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: account
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: shareSoftDeleteDays
    }
  }
}

// Uploaded blobs (AFFiNE fs storage provider), mounted at /root/.affine/storage.
resource blobShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'affine-storage'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: blobShareQuotaGb
  }
}

// config.json + private.key, mounted at /root/.affine/config.
resource configShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'affine-config'
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 1
  }
}

output name string = account.name
output blobShareName string = blobShare.name
output configShareName string = configShare.name
