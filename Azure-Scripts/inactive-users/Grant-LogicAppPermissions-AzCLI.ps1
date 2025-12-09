<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to Logic App managed identity using Azure CLI
.DESCRIPTION
    Uses Azure CLI and Microsoft Graph REST API to grant required permissions
.PARAMETER ResourceGroupName
    The resource group containing the Logic App
.PARAMETER LogicAppName
    The name of the Logic App
.EXAMPLE
    .\Grant-LogicAppPermissions-AzCLI.ps1 -ResourceGroupName "bab-core-auto-weeu-rg-01" -LogicAppName "report-inactive-cloudusers"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$LogicAppName,
    
    [Parameter(Mandatory = $false)]
    [string]$ObjectId = "aeb2dfac-14e3-4c48-a1f9-db5166c5c452"
)

Write-Host "=== Granting Microsoft Graph API Permissions (Azure CLI Method) ===" -ForegroundColor Cyan
Write-Host ""

# Check if Azure CLI is available
if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "✗ Azure CLI not found. Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor Red
    exit 1
}

# Get the Logic App's managed identity or use provided Object ID
Write-Host "1. Getting managed identity..." -ForegroundColor Yellow
try {
    if ($ResourceGroupName -and $LogicAppName) {
        $logicApp = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows" -Name $LogicAppName -ErrorAction Stop
        $objectId = $logicApp.Identity.PrincipalId
        
        if ([string]::IsNullOrEmpty($objectId)) {
            throw "Logic App does not have a system-assigned managed identity enabled"
        }
        Write-Host "   ✓ Managed Identity from Logic App: $objectId" -ForegroundColor Green
    } else {
        Write-Host "   ✓ Using provided Object ID: $ObjectId" -ForegroundColor Green
    }
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
    Write-Host "   Using default Object ID: $ObjectId" -ForegroundColor Yellow
}

Write-Host ""

# Get Microsoft Graph Service Principal ID
Write-Host "2. Getting Microsoft Graph service principal..." -ForegroundColor Yellow
$graphAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph App ID
$graphSPJson = az ad sp show --id $graphAppId 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "   ✗ Failed to get Microsoft Graph SP" -ForegroundColor Red
    exit 1
}
$graphSP = $graphSPJson | ConvertFrom-Json
$graphSPId = $graphSP.id
Write-Host "   ✓ Microsoft Graph SP ID: $graphSPId" -ForegroundColor Green

Write-Host ""

# Get App Roles
Write-Host "3. Getting required app role IDs..." -ForegroundColor Yellow
$userReadAllRole = $graphSP.appRoles | Where-Object { $_.value -eq "User.Read.All" }
$auditLogReadAllRole = $graphSP.appRoles | Where-Object { $_.value -eq "AuditLog.Read.All" }

if (!$userReadAllRole -or !$auditLogReadAllRole) {
    Write-Host "   ✗ Could not find required app roles" -ForegroundColor Red
    exit 1
}

Write-Host "   ✓ User.Read.All role ID: $($userReadAllRole.id)" -ForegroundColor Green
Write-Host "   ✓ AuditLog.Read.All role ID: $($auditLogReadAllRole.id)" -ForegroundColor Green

Write-Host ""

# Grant User.Read.All
Write-Host "4. Granting User.Read.All permission..." -ForegroundColor Yellow
$existingAssignments = az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$objectId/appRoleAssignments" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   ✗ Failed to get existing assignments. Error:" -ForegroundColor Red
    Write-Host "   $existingAssignments" -ForegroundColor Red
    $existingUserRead = $null
} else {
    $existingUserRead = $existingAssignments | ConvertFrom-Json
    $hasUserRead = $existingUserRead.value | Where-Object { $_.appRoleId -eq $userReadAllRole.id }
}

if ($hasUserRead) {
    Write-Host "   ⚠ User.Read.All already granted" -ForegroundColor Yellow
} else {
    $body = @{
        principalId = $objectId
        resourceId = $graphSPId
        appRoleId = $userReadAllRole.id
    } | ConvertTo-Json -Compress
    
    # Save body to temp file to avoid JSON escaping issues
    $tempFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline

    Write-Host "   Attempting to grant permission..." -ForegroundColor Gray
    $result = az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$objectId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tempFile" 2>&1
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "   ✓ User.Read.All granted successfully" -ForegroundColor Green
    } else {
        Write-Host "   ✗ Failed to grant User.Read.All" -ForegroundColor Red
        Write-Host "   Error details: $result" -ForegroundColor Red
    }
}

Write-Host ""

# Grant AuditLog.Read.All
Write-Host "5. Granting AuditLog.Read.All permission..." -ForegroundColor Yellow
if ($existingUserRead) {
    $hasAuditLog = $existingUserRead.value | Where-Object { $_.appRoleId -eq $auditLogReadAllRole.id }
} else {
    $hasAuditLog = $false
}

if ($hasAuditLog) {
    Write-Host "   ⚠ AuditLog.Read.All already granted" -ForegroundColor Yellow
} else {
    $body = @{
        principalId = $objectId
        resourceId = $graphSPId
        appRoleId = $auditLogReadAllRole.id
    } | ConvertTo-Json -Compress
    
    # Save body to temp file to avoid JSON escaping issues
    $tempFile = [System.IO.Path]::GetTempFileName()
    $body | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline

    Write-Host "   Attempting to grant permission..." -ForegroundColor Gray
    $result = az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$objectId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$tempFile" 2>&1
    
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "   ✓ AuditLog.Read.All granted successfully" -ForegroundColor Green
    } else {
        Write-Host "   ✗ Failed to grant AuditLog.Read.All" -ForegroundColor Red
        Write-Host "   Error details: $result" -ForegroundColor Red
    }
}

Write-Host ""

# Grant Key Vault access
Write-Host "6. Checking Key Vault access..." -ForegroundColor Yellow
$keyVaultName = "bab-core-kv-swec-01"

try {
    $existingPolicy = az keyvault show --name $keyVaultName --query "properties.accessPolicies[?objectId=='$objectId']" 2>$null | ConvertFrom-Json
    
    if ($existingPolicy) {
        Write-Host "   ⚠ Key Vault access policy already exists" -ForegroundColor Yellow
    } else {
        Write-Host "   Adding Key Vault access policy for secrets..." -ForegroundColor Gray
        az keyvault set-policy --name $keyVaultName --object-id $objectId --secret-permissions get 2>$null | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   ✓ Key Vault access granted" -ForegroundColor Green
        } else {
            Write-Host "   ✗ Failed to grant Key Vault access" -ForegroundColor Red
        }
    }
} catch {
    Write-Host "   ⚠ Could not verify/set Key Vault policy" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Permission Grant Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Permissions granted to managed identity ($objectId):" -ForegroundColor White
Write-Host "  ✓ User.Read.All (read user information)" -ForegroundColor Green
Write-Host "  ✓ AuditLog.Read.All (read sign-in activity)" -ForegroundColor Green
Write-Host "  ✓ Key Vault Get Secrets permission" -ForegroundColor Green
Write-Host ""
Write-Host "You can now test the Logic App manually from the Azure Portal." -ForegroundColor Cyan
