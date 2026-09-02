// Reusable private endpoint + private DNS zone group.
// Projects an Azure PaaS service into the customer VNet so that traffic never
// traverses the public internet - this is the "Private Link" leg of Figure 1
// in the STMicroelectronics briefing.

@description('Name of the private endpoint.')
param name string

@description('Azure region.')
param location string

@description('Resource ID of the subnet that will host the endpoint NIC.')
param subnetId string

@description('Resource ID of the PaaS resource being privatised.')
param targetResourceId string

@description('Private Link sub-resource (group) name, e.g. searchService, account, blob, Sql.')
param groupId string

@description('Private DNS zone resource IDs to register the endpoint records in.')
param dnsZoneIds array

resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${name}-conn'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [ groupId ]
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneId, i) in dnsZoneIds: {
      name: 'config${i}'
      properties: { privateDnsZoneId: zoneId }
    }]
  }
}

output privateEndpointId string = pe.id
output privateEndpointName string = pe.name
output networkInterfaceId string = pe.properties.networkInterfaces[0].id
