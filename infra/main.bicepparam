using 'main.bicep'

// No secrets here: main.bicep reads them from Key Vault via getSecret().
// Values that differ per operator come from environment variables set by scripts/deploy.sh.

param location = 'westeurope'
param owner = readEnvironmentVariable('AFFINE_OWNER', 'unset')
param environmentName = 'hackathon'

param affineImageTag = '0.27.4'
param affineCpu = '1.0'
param affineMemory = '2Gi'

param postgresSkuName = 'Standard_B1ms'
param postgresSkuTier = 'Burstable'
param postgresStorageGb = 32

// Comma-separated list, e.g. AFFINE_OPERATOR_IPS=203.0.113.10,198.51.100.7
param operatorIpAddresses = empty(readEnvironmentVariable('AFFINE_OPERATOR_IPS', ''))
  ? []
  : split(readEnvironmentVariable('AFFINE_OPERATOR_IPS', ''), ',')

param logRetentionDays = 30

param mailDataLocation = 'Germany'
param mailCustomDomain = ''
param mailUseCustomDomain = false

param smtpClientId = readEnvironmentVariable('AFFINE_SMTP_CLIENT_ID', '')
param smtpPrincipalId = readEnvironmentVariable('AFFINE_SMTP_PRINCIPAL_ID', '')
