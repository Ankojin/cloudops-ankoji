<#
.SYNOPSIS
    Diagnose and fix Azure Monitor Workspace permissions for VM Insights

.DESCRIPTION
    This script checks and assigns required RBAC roles on Azure Monitor Workspace
    to resolve "Access Denied" errors when viewing metrics in Azure Portal.

.PARAMETER WorkspaceResourceId
    Full resource ID of the Azure Monitor Workspace

.PARAMETER UserPrincipalName
    Optional. User email to grant permissions. If not provided, uses current user.

.EXAMPLE
    .\Fix-Workspace-Permissions.ps1 -WorkspaceResourceId "/subscriptions/.../vminsights-bab-dev-awm-workspace" -Verbose

.NOTES
    Version: 1.0
    Author: BAB CloudOps Team
    Requires: Owner or User Access Administrator role on workspace
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceResourceId,
    
    [Parameter(Mandatory=$false)]
    [string]$UserPrincipalName
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{
        'INFO' = 'Cyan'
        'SUCCESS' = 'Green'
        'WARNING' = 'Yellow'
        'ERROR' = 'Red'
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}

try {
    Write-Log "========================================================" -Level INFO
    Write-Log "Azure Monitor Workspace Permissions Diagnostic & Fix" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Get current user context
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in to Azure. Run Connect-AzAccount first."
    }
    
    $currentUserId = $context.Account.Id
    Write-Log "Current User: $currentUserId" -Level INFO
    
    # Parse workspace details
    Write-Log "Workspace: $WorkspaceResourceId" -Level INFO
    $workspace = Get-AzResource -ResourceId $WorkspaceResourceId -ErrorAction Stop
    Write-Log "Workspace Name: $($workspace.Name)" -Level SUCCESS
    Write-Log "Resource Group: $($workspace.ResourceGroupName)" -Level SUCCESS
    Write-Log "Location: $($workspace.Location)" -Level SUCCESS
    
    # Determine target user
    $targetUser = if ($UserPrincipalName) { $UserPrincipalName } else { $currentUserId }
    Write-Log "Target User for Permissions: $targetUser" -Level INFO
    
    # Get user object ID
    Write-Log "Resolving user object ID..." -Level INFO
    $userObjectId = (Get-AzADUser -UserPrincipalName $targetUser).Id
    if (-not $userObjectId) {
        throw "Could not resolve user: $targetUser"
    }
    Write-Log "User Object ID: $userObjectId" -Level SUCCESS
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 1: Check Current Role Assignments" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Check existing role assignments on workspace
    $existingRoles = Get-AzRoleAssignment -Scope $WorkspaceResourceId -ObjectId $userObjectId
    
    if ($existingRoles) {
        Write-Log "Current roles assigned:" -Level SUCCESS
        foreach ($role in $existingRoles) {
            Write-Log "  - $($role.RoleDefinitionName)" -Level INFO
        }
    } else {
        Write-Log "No roles currently assigned on workspace!" -Level WARNING
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 2: Assign Required Roles" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Required roles for viewing metrics
    $requiredRoles = @(
        "Monitoring Reader",
        "Monitoring Data Reader"
    )
    
    foreach ($roleName in $requiredRoles) {
        Write-Log "Checking role: $roleName" -Level INFO
        
        $hasRole = $existingRoles | Where-Object { $_.RoleDefinitionName -eq $roleName }
        
        if ($hasRole) {
            Write-Log "  ✓ Already assigned: $roleName" -Level SUCCESS
        } else {
            Write-Log "  Assigning role: $roleName" -Level WARNING
            
            try {
                New-AzRoleAssignment -ObjectId $userObjectId `
                    -RoleDefinitionName $roleName `
                    -Scope $WorkspaceResourceId `
                    -ErrorAction Stop | Out-Null
                
                Write-Log "  ✓ Successfully assigned: $roleName" -Level SUCCESS
            }
            catch {
                if ($_.Exception.Message -like "*already exists*") {
                    Write-Log "  ✓ Role already exists (race condition): $roleName" -Level SUCCESS
                } else {
                    Write-Log "  ✗ Failed to assign $roleName : $_" -Level ERROR
                }
            }
        }
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 3: Verify Public Network Access" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Check workspace configuration
    $workspaceProps = (Get-AzResource -ResourceId $WorkspaceResourceId -ExpandProperties).Properties
    
    if ($workspaceProps.publicNetworkAccess) {
        Write-Log "✓ Public Network Access: $($workspaceProps.publicNetworkAccess)" -Level SUCCESS
    } else {
        Write-Log "⚠ Public Network Access: Not explicitly set (defaults to Enabled)" -Level WARNING
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Step 4: Check Data Collection Rule Associations" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    # Find DCR in same resource group
    $dcrs = Get-AzDataCollectionRule -ResourceGroupName $workspace.ResourceGroupName | 
            Where-Object { $_.Name -like "MSVMOtel*" }
    
    if ($dcrs) {
        foreach ($dcr in $dcrs) {
            Write-Log "Found DCR: $($dcr.Name)" -Level SUCCESS
            
            # Check for associated VMs
            $associations = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRuleAssociations" `
                | Where-Object { $_.Properties.dataCollectionRuleId -eq $dcr.Id }
            
            $vmCount = $associations.Count
            Write-Log "  VMs Associated: $vmCount" -Level $(if($vmCount -gt 0){'SUCCESS'}else{'WARNING'})
            
            if ($vmCount -eq 0) {
                Write-Log "  ⚠ No VMs associated with this DCR yet!" -Level WARNING
                Write-Log "  Run the migration script to associate VMs." -Level INFO
            }
        }
    } else {
        Write-Log "⚠ No DCR found in resource group $($workspace.ResourceGroupName)" -Level WARNING
    }
    
    Write-Log "========================================================" -Level INFO
    Write-Log "Summary & Next Steps" -Level INFO
    Write-Log "========================================================" -Level INFO
    
    Write-Log "✓ Permissions have been configured" -Level SUCCESS
    Write-Log "" -Level INFO
    Write-Log "If you still see 'Access Denied':" -Level INFO
    Write-Log "  1. Wait 5-10 minutes for permission propagation" -Level INFO
    Write-Log "  2. Log out and back into Azure Portal (clear session)" -Level INFO
    Write-Log "  3. Clear browser cache and cookies" -Level INFO
    Write-Log "  4. Try incognito/private browsing mode" -Level INFO
    Write-Log "  5. Ensure VMs are associated with DCR and sending data" -Level INFO
    Write-Log "" -Level INFO
    Write-Log "Portal URL to test:" -Level INFO
    Write-Log "  https://portal.azure.com/#@bankalbilad.onmicrosoft.com/resource$WorkspaceResourceId/overview" -Level INFO
    Write-Log "========================================================" -Level INFO
    
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
