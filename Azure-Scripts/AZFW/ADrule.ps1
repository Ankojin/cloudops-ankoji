# Set variables
$resourceGroup = "enz-core-nw-swec-rg-01"
$policyName = "enz-core-nw-azfwpolicy-weeu-01"
$ruleCollectionName = "Allow-AD-Traffic"
$ruleCollectionGroupName = "AD_Network_Rules_Grp"
$priority = 501
$domainMembersSubnet = "10.189.0.0/20"
$domainControllers = @("10.189.2.4", "10.189.2.5")

# AD ports and protocol mapping
$adPorts = @(
    @{ Port = "53"; Protocols = @("TCP", "UDP") },
    @{ Port = "88"; Protocols = @("TCP", "UDP") },
    @{ Port = "389"; Protocols = @("TCP", "UDP") },
    @{ Port = "445"; Protocols = @("TCP") },
    @{ Port = "135"; Protocols = @("TCP") },
    @{ Port = "49152-65535"; Protocols = @("TCP") }
)

# Build rules array
$rules = @()
foreach ($entry in $adPorts) {
    $rules += @{
        name = "Allow-Port-$($entry.Port)"
        ruleType = "NetworkRule"
        ipProtocols = $entry.Protocols
        sourceAddresses = @($domainMembersSubnet)
        destinationAddresses = $domainControllers
        destinationPorts = @($entry.Port)
    }
}

# Full rule collection definition
$ruleCollections = @(
    @{
        name = $ruleCollectionName
        ruleType = "NetworkRule"
        action = @{ type = "Allow" }
        rules = $rules
    }
)

# Output JSON file
$tmpJson = "$env:TEMP\azfw_rules.json"
$ruleCollections | ConvertTo-Json -Depth 10 | Out-File -Encoding UTF8 -FilePath $tmpJson

# Create rule collection group
Write-Host "Creating firewall rule collection group..."
az network firewall policy rule-collection-group create `
    --resource-group $resourceGroup `
    --policy-name $policyName `
    --name $ruleCollectionGroupName `
    --priority $priority `
    --rule-collections "@$tmpJson"

# Clean up
Remove-Item $tmpJson -ErrorAction SilentlyContinue

Write-Host "Firewall rule collection group created successfully."