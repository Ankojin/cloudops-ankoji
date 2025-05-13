
@description('Name of the Azure Firewall Policy')
param policyName string

@description('Name of the Rule Collection Group')
param ruleCollectionGroupName string

@description('Name of the Rule Collection')
param ruleCollectionName string

@description('Priority for the Rule Collection Group')
param priority int

@description('Source subnet CIDR for domain members')
param domainMembersSubnet string

@description('List of domain controller IPs')
param domainControllers array

// Reference the existing Firewall Policy
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-02-01' existing = {
  name: policyName
}

// Rule Collection Group resource with parent syntax (no 'location' needed)
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-02-01' = {
  name: ruleCollectionGroupName
  parent: firewallPolicy
  properties: {
    priority: priority
    ruleCollections: [
      {
        name: ruleCollectionName
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'Allow-Port-53'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP', 'UDP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['53']
          }
          {
            name: 'Allow-Port-88'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP', 'UDP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['88']
          }
          {
            name: 'Allow-Port-389'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP', 'UDP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['389']
          }
          {
            name: 'Allow-Port-445'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['445']
          }
          {
            name: 'Allow-Port-135'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['135']
          }
          {
            name: 'Allow-Port-49152-65535'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [domainMembersSubnet]
            destinationAddresses: domainControllers
            destinationPorts: ['49152-65535']
          }
        ]
      }
    ]
  }
}
