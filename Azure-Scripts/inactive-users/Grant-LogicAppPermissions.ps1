#Requires -Modules Microsoft.Graph.Applications

<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Logic App's managed identity
.DESCRIPTION
    This script grants the required Microsoft Graph API permissions (User.Read.All and AuditLog.Read.All) 
    to the Logic App's system-assigned managed identity for querying inactive users.
.PARAMETER ResourceGroupName
    The resource group containing the Logic App
.PARAMETER LogicAppName
    The name of the Logic App
.EXAMPLE
    .\Grant-LogicAppPermissions.ps1 -ResourceGroupName "bab-core-auto-weeu-rg-01" -LogicAppName "report-inactive-cloudusers"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$LogicAppName
)

Write-Host "=== Granting Microsoft Graph API Permissions to Logic App ===" -ForegroundColor Cyan
Write-Host ""

# Get the Logic App's managed identity
Write-Host "1. Getting Logic App managed identity..." -ForegroundColor Yellow
try {
    $logicApp = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Logic/workflows" -Name $LogicAppName -ErrorAction Stop
    $objectId = $logicApp.Identity.PrincipalId
    
    if ([string]::IsNullOrEmpty($objectId)) {
        throw "Logic App does not have a system-assigned managed identity enabled"
    }
    
    Write-Host "   ✓ Logic App Object ID: $objectId" -ForegroundColor Green
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Connect to Microsoft Graph
Write-Host "2. Connecting to Microsoft Graph..." -ForegroundColor Yellow
try {
    Connect-MgGraph -Scopes 'Application.Read.All','AppRoleAssignment.ReadWrite.All' -NoWelcome -ErrorAction Stop
    Write-Host "   ✓ Connected to Microsoft Graph" -ForegroundColor Green
} catch {
    Write-Host "   ✗ Error connecting to Graph: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Get Microsoft Graph Service Principal
Write-Host "3. Getting Microsoft Graph service principal..." -ForegroundColor Yellow
try {
    $graphSP = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'" -ErrorAction Stop
    Write-Host "   ✓ Microsoft Graph SP ID: $($graphSP.Id)" -ForegroundColor Green
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Get the Logic App Service Principal
Write-Host "4. Getting Logic App service principal..." -ForegroundColor Yellow
try {
    $logicAppSP = Get-MgServicePrincipal -Filter "id eq '$objectId'" -ErrorAction Stop
    Write-Host "   ✓ Logic App SP found: $($logicAppSP.DisplayName)" -ForegroundColor Green
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Grant User.Read.All permission
Write-Host "5. Granting User.Read.All permission..." -ForegroundColor Yellow
try {
    $userReadRole = $graphSP.AppRoles | Where-Object { $_.Value -eq 'User.Read.All' }
    
    if ($null -eq $userReadRole) {
        throw "User.Read.All role not found"
    }
    
    # Check if permission already exists
    $existingAssignment = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $objectId -ErrorAction SilentlyContinue | 
        Where-Object { $_.AppRoleId -eq $userReadRole.Id }
    
    if ($existingAssignment) {
        Write-Host "   ⚠ User.Read.All already granted" -ForegroundColor Yellow
    } else {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $objectId `
            -PrincipalId $objectId `
            -ResourceId $graphSP.Id `
            -AppRoleId $userReadRole.Id -ErrorAction Stop | Out-Null
        Write-Host "   ✓ User.Read.All granted successfully" -ForegroundColor Green
    }
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
}

Write-Host ""

# Grant AuditLog.Read.All permission
Write-Host "6. Granting AuditLog.Read.All permission..." -ForegroundColor Yellow
try {
    $auditLogRole = $graphSP.AppRoles | Where-Object { $_.Value -eq 'AuditLog.Read.All' }
    
    if ($null -eq $auditLogRole) {
        throw "AuditLog.Read.All role not found"
    }
    
    # Check if permission already exists
    $existingAssignment = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $objectId -ErrorAction SilentlyContinue | 
        Where-Object { $_.AppRoleId -eq $auditLogRole.Id }
    
    if ($existingAssignment) {
        Write-Host "   ⚠ AuditLog.Read.All already granted" -ForegroundColor Yellow
    } else {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $objectId `
            -PrincipalId $objectId `
            -ResourceId $graphSP.Id `
            -AppRoleId $auditLogRole.Id -ErrorAction Stop | Out-Null
        Write-Host "   ✓ AuditLog.Read.All granted successfully" -ForegroundColor Green
    }
} catch {
    Write-Host "   ✗ Error: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Permission Grant Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "The Logic App can now:" -ForegroundColor White
Write-Host "  • Read user information (User.Read.All)" -ForegroundColor Gray
Write-Host "  • Read sign-in activity logs (AuditLog.Read.All)" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: Also ensure the managed identity has Key Vault 'Get' permission for secrets." -ForegroundColor Yellow

# Disconnect
Disconnect-MgGraph | Out-Null
