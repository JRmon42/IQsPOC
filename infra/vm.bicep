// =============================================================================
// IQs POC - in-VNet test client
// =============================================================================
// A small Linux VM inside snet-app that plays the role of the "customer
// application". Running the same probe from here and from outside the VNet is
// what turns the Private Link story from an assertion into a measurement.
//
// Design notes:
//  * NO public IP and NO inbound rules - all interaction is via
//    `az vm run-command invoke`, which rides the Azure control plane.
//  * Outbound is through an explicit NAT Gateway rather than Azure's
//    (retiring) implicit default outbound access. That also gives the POC a
//    single, stable, auditable egress IP - useful when the customer asks
//    "what source address will Microsoft see?".
//  * System-assigned managed identity, so the VM authenticates to AI Search /
//    Foundry / Storage with Entra tokens and no secrets ever land on disk.
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string = 'iqspoc'
param vnetName string
param subnetName string = 'snet-app'

@description('Address prefix of the app subnet. Must match infra/main.bicep.')
param appSubnetPrefix string = '10.30.1.0/24'
param vmSize string = 'Standard_B2as_v2'
param adminUsername string = 'iqadmin'

@description('SSH public key. Only needed for break-glass; run-command is the normal path.')
param adminPublicKey string

var uniq = uniqueString(resourceGroup().id)

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

// --- Deterministic, auditable egress ----------------------------------------
resource natPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namePrefix}-nat-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGw 'Microsoft.Network/natGateways@2023-11-01' = {
  name: '${namePrefix}-natgw'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: natPip.id } ]
  }
}

// Re-declare snet-app so the NAT gateway can be attached without a full
// re-deploy of main.bicep. Address prefix and NSG must match main.bicep.
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' existing = {
  name: '${namePrefix}-nsg-app'
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: appSubnetPrefix
    networkSecurityGroup: { id: nsgApp.id }
    natGateway: { id: natGw.id }
  }
}

// --- The test client itself --------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: appSubnet.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${namePrefix}-client'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        diskSizeGB: 32
      }
    }
    osProfile: {
      computerName: '${namePrefix}-client'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
      customData: base64('''#cloud-config
package_update: true
packages:
  - dnsutils
  - curl
  - python3-pip
  - jq
runcmd:
  - [ bash, -lc, "curl -sL https://aka.ms/InstallAzureCLIDeb | bash" ]
  - [ bash, -lc, "pip3 install --break-system-packages azure-identity azure-search-documents openai requests" ]
  - [ bash, -lc, "echo iqspoc-client-ready > /var/log/iqspoc-ready" ]
''')
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

// The VM must be able to read data planes with its managed identity.
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
// Listing index *definitions* is a control-plane style operation; the data
// reader role only grants document reads. Both are needed so that a 403 from
// inside the VNet can never be mistaken for a network block.
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = {
  name: '${namePrefix}-search-${uniq}'
}
resource foundry 'Microsoft.CognitiveServices/accounts@2026-07-01' existing = {
  name: '${namePrefix}-foundry-${uniq}'
}
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: toLower('st${namePrefix}${uniq}')
}

resource raVmSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, vm.id, roleSearchIndexDataReader)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raVmSearchCtl 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, vm.id, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raVmFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, vm.id, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource raVmBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, vm.id, roleStorageBlobDataReader)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output vmName string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output natEgressIp string = natPip.properties.ipAddress
output vmPrincipalId string = vm.identity.principalId
