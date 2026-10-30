@description('Azure Communication Services resource name (globally unique).')
param acsName string

@description('Email Communication Service name.')
param emailServiceName string

param tags object

@description('Where ACS stores data at rest.')
param dataLocation string = 'Germany'

@description('Optional custom mail domain, e.g. mmkdigital.io. Empty = only the Azure-managed domain is created.')
param customDomain string = ''

@description('Link the custom domain instead of the Azure-managed one. Only set after the domain shows Verified in ACS.')
param useCustomDomain bool = false

@description('Local part of the sender address on the custom domain.')
param senderUsername string = 'affine'

@description('Object ID of the service principal used as SMTP login (app registration affine-acs-smtp).')
param smtpPrincipalId string

@description('Application (client) ID of that app registration.')
param smtpClientId string

// Built-in role: Communication and Email Service Owner
var emailOwnerRoleId = '09976791-48a7-449e-bb21-39d1a415f350'
var hasCustomDomain = !empty(customDomain)

resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = {
  name: emailServiceName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
  }
}

resource managedDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  tags: tags
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource customMailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (hasCustomDomain) {
  parent: emailService
  name: hasCustomDomain ? customDomain : 'unused'
  location: 'global'
  tags: tags
  properties: {
    domainManagement: 'CustomerManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource customSender 'Microsoft.Communication/emailServices/domains/senderUsernames@2023-04-01' = if (hasCustomDomain) {
  parent: customMailDomain
  name: senderUsername
  properties: {
    username: senderUsername
    displayName: 'AFFiNE'
  }
}

var linkCustom = hasCustomDomain && useCustomDomain

resource acs 'Microsoft.Communication/communicationServices@2023-04-01' = {
  name: acsName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
    linkedDomains: [
      linkCustom ? customMailDomain.id : managedDomain.id
    ]
  }
}

resource smtpRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acs.id, smtpPrincipalId, emailOwnerRoleId)
  scope: acs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', emailOwnerRoleId)
    principalId: smtpPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output acsName string = acs.name
@description('SMTP login for smtp.azurecomm.net: <acs name>.<app client id>.<tenant id>.')
output smtpUsername string = '${acs.name}.${smtpClientId}.${tenant().tenantId}'
output senderAddress string = linkCustom
  ? '${senderUsername}@${customDomain}'
  : 'DoNotReply@${managedDomain.properties.mailFromSenderDomain}'
@description('DNS records to request for the custom domain (empty if none configured).')
output customDomainVerificationRecords object = hasCustomDomain ? customMailDomain!.properties.verificationRecords : {}
