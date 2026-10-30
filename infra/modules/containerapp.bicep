@description('Container App name. Also the first label of its public FQDN.')
param name string

param location string
param tags object

param environmentId string
param environmentDefaultDomain string
param blobStorageName string
param configStorageName string

@description('Pinned AFFiNE release tag on ghcr.io/toeverything/affine (never "stable"/"latest").')
param affineImageTag string

param affineCpu string = '1.0'
param affineMemory string = '2Gi'
param redisCpu string = '0.25'
param redisMemory string = '0.5Gi'

param postgresFqdn string
param postgresDatabase string
param postgresAdminLogin string

@secure()
param postgresAdminPassword string

param smtpHost string = 'smtp.azurecomm.net'
param smtpPort string = '587'
param smtpUsername string
param mailSenderAddress string

@secure()
param smtpPassword string

var externalHost = '${name}.${environmentDefaultDomain}'
var externalUrl = 'https://${externalHost}'

// Migrations (and private.key generation) run before the server starts (design D2).
var startCommand = 'node ./scripts/self-host-predeploy.js && exec node ./dist/main.js'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3010
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: [
        {
          name: 'database-url'
          // Built from the @secure() password; Container Apps never returns secret values.
          #disable-next-line use-secure-value-for-secure-inputs
          value:'postgresql://${postgresAdminLogin}:${postgresAdminPassword}@${postgresFqdn}:5432/${postgresDatabase}?sslmode=require'
        }
        {
          name: 'mailer-password'
          value: smtpPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'affine'
          image: 'ghcr.io/toeverything/affine:${affineImageTag}'
          command: [
            'sh'
            '-c'
            startCommand
          ]
          resources: {
            cpu: json(affineCpu)
            memory: affineMemory
          }
          env: [
            { name: 'DATABASE_URL', secretRef: 'database-url' }
            { name: 'REDIS_SERVER_HOST', value: 'localhost' }
            { name: 'REDIS_SERVER_PORT', value: '6379' }
            { name: 'AFFINE_SERVER_EXTERNAL_URL', value: externalUrl }
            { name: 'AFFINE_SERVER_HOST', value: externalHost }
            { name: 'AFFINE_SERVER_HTTPS', value: 'true' }
            { name: 'AFFINE_INDEXER_ENABLED', value: 'false' }
            { name: 'MAILER_HOST', value: smtpHost }
            { name: 'MAILER_PORT', value: smtpPort }
            { name: 'MAILER_IGNORE_TLS', value: 'false' }
            { name: 'MAILER_USER', value: smtpUsername }
            { name: 'MAILER_PASSWORD', secretRef: 'mailer-password' }
            { name: 'MAILER_SENDER', value: 'AFFiNE <${mailSenderAddress}>' }
          ]
          volumeMounts: [
            {
              volumeName: 'affine-storage'
              mountPath: '/root/.affine/storage'
            }
            {
              volumeName: 'affine-config'
              mountPath: '/root/.affine/config'
            }
          ]
          probes: [
            {
              // Container Apps caps failureThreshold at 10: 15 s + 10 x 30 s ~ 5 min for migrations.
              type: 'Startup'
              httpGet: {
                path: '/info'
                port: 3010
              }
              initialDelaySeconds: 15
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 10
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/info'
                port: 3010
              }
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/info'
                port: 3010
              }
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
        {
          // Cache, queue and pub/sub only; sessions live in Postgres (design D3).
          name: 'redis'
          image: 'docker.io/library/redis:7-alpine'
          resources: {
            cpu: json(redisCpu)
            memory: redisMemory
          }
        }
      ]
      scale: {
        // Exactly one replica: the Redis sidecar is per replica (design D3).
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        {
          name: 'affine-storage'
          storageType: 'AzureFile'
          storageName: blobStorageName
        }
        {
          name: 'affine-config'
          storageType: 'AzureFile'
          storageName: configStorageName
        }
      ]
    }
  }
}

output name string = app.name
output url string = externalUrl
output latestRevisionName string = app.properties.latestRevisionName
