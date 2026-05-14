# Test Azure Monitor Workspace Access
$workspaceId = '/subscriptions/43cc4f11-ffb1-4a0d-8420-0ba3746b4248/resourcegroups/defaultresourcegroup-sec/providers/microsoft.monitor/accounts/defaultazuremonitorworkspace-sec'
$workspace = Get-AzResource -ResourceId $workspaceId

Write-Host "Testing workspace access..." -ForegroundColor Cyan
Write-Host "Workspace: $($workspace.Name)" -ForegroundColor White
Write-Host "Location: $($workspace.Location)" -ForegroundColor White
Write-Host "Status: $($workspace.Properties.provisioningState)" -ForegroundColor Green
Write-Host ""
Write-Host "If you see this output without errors, workspace access is working!" -ForegroundColor Green
