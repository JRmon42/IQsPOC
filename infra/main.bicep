// =============================================================================
// IQs POC - Core infrastructure
// Foundry IQ / Web IQ / Fabric IQ / Work IQ security & network-flow validation
// =============================================================================
// Deploys a network-isolated Microsoft Foundry environment so that the claims
// made in the STMicroelectronics briefing can be empirically validated:
//   * Foundry IQ is backed by Azure AI Search
//   * Diagnostic logging is OFF by default (we deliberately do NOT create
//     diagnostic settings for AI Search here - scripts/03-toggle-search-logging.sh
//     turns it on so the "before/after" can be observed)
//   * Private Link / private endpoints keep retrieval off the public internet
//   * Web grounding (Web IQ) must egress to the public internet
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(10)
param namePrefix string = 'iqspoc'

@description('Object ID of the principal (user) that should receive data-plane RBAC for testing.')
param adminPrincipalId string

@description('Address space for the POC virtual network.')
param vnetAddressPrefix string = '10.30.0.0/16'

@description('Set false to keep services publicly reachable (useful to contrast with the isolated posture).')
param enablePrivateNetworking bool = true

@description('Model to deploy for agent testing. Set to empty string to skip model deployment.')
param modelName string = 'gpt-4.1-mini'

@description('Model version for the deployment.')
param modelVersion string = '2025-04-14'

@description('Capacity (thousands of TPM) for the model deployment.')
param modelCapacity int = 10

@description('Deployment SKU. DataZoneStandard keeps inference inside the EU data zone; GlobalStandard may route worldwide.')
@allowed([ 'GlobalStandard', 'DataZoneStandard', 'Standard' ])
param modelSkuName string = 'GlobalStandard'

var uniq = uniqueString(resourceGroup().id)
var saName = toLower('st${namePrefix}${uniq}')
var searchName = '${namePrefix}-search-${uniq}'
var foundryName = '${namePrefix}-foundry-${uniq}'
var cosmosName = '${namePrefix}-cosmos-${uniq}'
var pna = enablePrivateNetworking ? 'Disabled' : 'Enabled'

// -----------------------------------------------------------------------------
// Observability - created FIRST so every later resource can point at it.
// NOTE: we intentionally do not attach a diagnostic setting to Azure AI Search.
// -----------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law-${uniq}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    // 30 days is the Log Analytics default the briefing calls out.
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appi-${uniq}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// Network - the "customer-defined network boundary" from Figure 1
// -----------------------------------------------------------------------------
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-nsg-app'
  location: location
  properties: { securityRules: [] }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-nsg-pe'
  location: location
  properties: { securityRules: [] }
}

resource nsgAgent 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${namePrefix}-nsg-agent'
  location: location
  properties: { securityRules: [] }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        // The "customer application / client" tier.
        name: 'snet-app'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 1)
          networkSecurityGroup: { id: nsgApp.id }
        }
      }
      {
        // Holds the private endpoints that project PaaS services into the VNet.
        name: 'snet-pe'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 2)
          networkSecurityGroup: { id: nsgPe.id }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Delegated subnet for Foundry Agent Service VNet injection.
        // This is the subnet referenced by "outbound from the Agent client".
        name: 'snet-agent'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 3)
          networkSecurityGroup: { id: nsgAgent.id }
          delegations: [
            {
              name: 'foundry-agents'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

resource snetApp 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-app'
}
resource snetPe 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-pe'
}

// -----------------------------------------------------------------------------
// Private DNS - required so privatelink.* names resolve to private IPs
// -----------------------------------------------------------------------------
var dnsZoneNames = [
  'privatelink.search.windows.net'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for z in dnsZoneNames: {
  name: z
  location: 'global'
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (z, i) in dnsZoneNames: {
  name: '${dnsZones[i].name}/link-${namePrefix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

// -----------------------------------------------------------------------------
// Storage - "bring your own" data store for agent files
// MCAPS governance forces publicNetworkAccess=Disabled and
// allowSharedKeyAccess=false, so we declare that posture explicitly.
// -----------------------------------------------------------------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  identity: { type: 'SystemAssigned' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    publicNetworkAccess: pna
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
    }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

resource knowledgeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: 'knowledge'
  properties: { publicAccess: 'None' }
}

// -----------------------------------------------------------------------------
// Cosmos DB - "bring your own" thread/message store for Agent Service
// -----------------------------------------------------------------------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [ { locationName: location, failoverPriority: 0, isZoneRedundant: false } ]
    capabilities: [ { name: 'EnableServerless' } ]
    publicNetworkAccess: pna
    disableLocalAuth: true
    minimalTlsVersion: 'Tls12'
  }
}

// -----------------------------------------------------------------------------
// Azure AI Search - the engine underneath Foundry IQ
// Deliberately NO diagnosticSettings resource here: the POC proves that
// resource logging is off until a customer explicitly enables it.
// -----------------------------------------------------------------------------
resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: location
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: enablePrivateNetworking ? 'disabled' : 'enabled'
    // Entra-only auth - no API keys, matching the briefing's keyless guidance.
    disableLocalAuth: true
    semanticSearch: 'standard'
  }
}

// -----------------------------------------------------------------------------
// Microsoft Foundry account + project
// -----------------------------------------------------------------------------
resource foundry 'Microsoft.CognitiveServices/accounts@2026-07-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: foundryName
    publicNetworkAccess: pna
    disableLocalAuth: true
    allowProjectManagement: true
    networkAcls: {
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-07-01' = {
  parent: foundry
  name: '${namePrefix}-project'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'IQs POC Project'
    description: 'Validates Foundry IQ / Web IQ / Fabric IQ network and privacy behaviour.'
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-07-01' = if (!empty(modelName)) {
  parent: foundry
  name: modelName
  sku: { name: modelSkuName, capacity: modelCapacity }
  properties: {
    model: { format: 'OpenAI', name: modelName, version: modelVersion }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

// -----------------------------------------------------------------------------
// Private endpoints - one per PaaS service, all landing in snet-pe
// -----------------------------------------------------------------------------
module peSearch 'modules/private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-search'
  params: {
    name: '${namePrefix}-pe-search'
    location: location
    subnetId: snetPe.id
    targetResourceId: search.id
    groupId: 'searchService'
    dnsZoneIds: [ dnsZones[0].id ]
  }
}

module peFoundry 'modules/private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-foundry'
  params: {
    name: '${namePrefix}-pe-foundry'
    location: location
    subnetId: snetPe.id
    targetResourceId: foundry.id
    groupId: 'account'
    dnsZoneIds: [ dnsZones[1].id, dnsZones[2].id, dnsZones[3].id ]
  }
}

module peBlob 'modules/private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-blob'
  params: {
    name: '${namePrefix}-pe-blob'
    location: location
    subnetId: snetPe.id
    targetResourceId: sa.id
    groupId: 'blob'
    dnsZoneIds: [ dnsZones[4].id ]
  }
}

module peCosmos 'modules/private-endpoint.bicep' = if (enablePrivateNetworking) {
  name: 'pe-cosmos'
  params: {
    name: '${namePrefix}-pe-cosmos'
    location: location
    subnetId: snetPe.id
    targetResourceId: cosmos.id
    groupId: 'Sql'
    dnsZoneIds: [ dnsZones[5].id ]
  }
}

// -----------------------------------------------------------------------------
// RBAC - keyless, least privilege, for the tester and for Foundry -> Search
// -----------------------------------------------------------------------------
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource raAdminSearchData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, adminPrincipalId, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

resource raAdminSearchControl 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, adminPrincipalId, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

resource raAdminFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, adminPrincipalId, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

resource raAdminBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, adminPrincipalId, roleStorageBlobDataContributor)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

// Foundry's managed identity needs to read the Search index (agentic retrieval)
resource raFoundrySearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, foundry.id, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: foundry.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Search's managed identity needs to read source documents from Blob
resource raSearchBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, search.id, roleStorageBlobDataContributor)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Outputs - consumed by the validation scripts
// -----------------------------------------------------------------------------
output resourceGroupName string = resourceGroup().name
output location string = location
output vnetName string = vnet.name
output vnetId string = vnet.id
output appSubnetId string = snetApp.id
output agentSubnetName string = 'snet-agent'
output logAnalyticsName string = law.name
output logAnalyticsId string = law.id
output logAnalyticsCustomerId string = law.properties.customerId
output appInsightsName string = appi.name
output appInsightsConnectionString string = appi.properties.ConnectionString
output searchName string = search.name
output searchId string = search.id
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output foundryName string = foundry.name
output foundryId string = foundry.id
output foundryEndpoint string = foundry.properties.endpoint
output projectName string = project.name
output storageAccountName string = sa.name
output cosmosName string = cosmos.name
output modelDeploymentName string = empty(modelName) ? '' : modelName
output modelSku string = modelSkuName
output privateNetworkingEnabled bool = enablePrivateNetworking
