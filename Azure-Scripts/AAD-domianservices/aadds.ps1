# Connect
Connect-AzAccount

# Get current domain service resource
$ds = Get-AzResource -ResourceType "Microsoft.AAD/DomainServices" `
      -ResourceGroupName "BAB-Shared-Resources-RG01" `
      -Name "albtests.com"

# View properties
$ds.Properties | ConvertTo-Json -Depth 10
