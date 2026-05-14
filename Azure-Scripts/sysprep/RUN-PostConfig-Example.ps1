# ============================================================================
# Quick Start Example - Configure AVD Session Host
# ============================================================================
#
# INSTRUCTIONS:
# 1. Update the variables below with your actual values
# 2. Run the script in PowerShell as Administrator
# 3. Review the logs in .\logs\ folder
#
# ============================================================================

# -----------------------
# CONFIGURATION - UPDATE THESE VALUES
# -----------------------

# VM Details
$vmName = "BABAVDSHDTA-5"  # ← UPDATE: VM name to configure
$resourceGroup = "bab-vdi-avd-weeu-rg-01"

# Domain Details
$domainName = "bankalbilad.com.sa"  # ← UPDATE: Your domain name
$domainUser = "admin@bankalbilad.com.sa"  # ← UPDATE: Domain admin username
# Optional: Specify OU path where computer should be placed
$ouPath = ""  # Example: "OU=AVD,OU=Servers,DC=bankalbilad,DC=com,DC=sa"

# AVD Host Pool Details
$hostPoolName = "bab-avd-hostpool"  # ← UPDATE: Your host pool name
$hostPoolResourceGroup = "bab-vdi-avd-weeu-rg-01"

# Azure Subscription
$subscriptionId = "cb801de6-404a-4e76-8e9a-475206cbc2e5"  # ← UPDATE THIS

# -----------------------
# STEP 1: PREREQUISITES CHECK
# -----------------------

Write-Host "`n=== Checking Prerequisites ===" -ForegroundColor Cyan

# Check if Az modules are installed
$requiredModules = @('Az.Compute', 'Az.DesktopVirtualization')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Force -AllowClobber
    }
    Import-Module $module
    Write-Host "✅ $module loaded" -ForegroundColor Green
}

# Check Azure connection
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not connected to Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
        Connect-AzAccount
    }
    Write-Host "✅ Connected to Azure: $($context.Account.Id)" -ForegroundColor Green
}
catch {
    Write-Host "❌ Azure connection failed. Please run: Connect-AzAccount" -ForegroundColor Red
    exit 1
}

# -----------------------
# STEP 2: GET DOMAIN CREDENTIALS
# -----------------------

Write-Host "`n=== Domain Credentials ===" -ForegroundColor Cyan
Write-Host "Domain: $domainName" -ForegroundColor Yellow
Write-Host "User: $domainUser" -ForegroundColor Yellow

# Prompt for password securely
$domainPassword = Read-Host "Enter domain admin password for $domainUser" -AsSecureString

# -----------------------
# STEP 3: CONFIRM CONFIGURATION
# -----------------------

Write-Host "`n=== Configuration Summary ===" -ForegroundColor Cyan
Write-Host "VM to configure: $vmName" -ForegroundColor Yellow
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Yellow
Write-Host "Domain: $domainName" -ForegroundColor Yellow
Write-Host "Domain User: $domainUser" -ForegroundColor Yellow
if ($ouPath) {
    Write-Host "OU Path: $ouPath" -ForegroundColor Yellow
}
Write-Host "Host Pool: $hostPoolName" -ForegroundColor Yellow
Write-Host "Host Pool RG: $hostPoolResourceGroup" -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Proceed with configuration? (yes/no)"

if ($confirmation -ne 'yes') {
    Write-Host "`n❌ Operation cancelled by user." -ForegroundColor Red
    exit 0
}

# -----------------------
# STEP 4: EXECUTE CONFIGURATION
# -----------------------

Write-Host "`n=== Starting Configuration ===" -ForegroundColor Green
Write-Host "This will take approximately 5-10 minutes..." -ForegroundColor Yellow
Write-Host ""

try {
    # Build parameters
    $params = @{
        VMName                  = $vmName
        ResourceGroupName       = $resourceGroup
        DomainName              = $domainName
        DomainJoinUserName      = $domainUser
        DomainJoinPassword      = $domainPassword
        HostPoolName            = $hostPoolName
        HostPoolResourceGroup   = $hostPoolResourceGroup
        SubscriptionId          = $subscriptionId
        Verbose                 = $true
    }
    
    # Add OU path if specified
    if ($ouPath) {
        $params['OUPath'] = $ouPath
    }
    
    # Execute the configuration script
    .\Configure-AVD-SessionHost.ps1 @params
    
    Write-Host "`n✅ SUCCESS! AVD Session Host configured successfully." -ForegroundColor Green
    Write-Host "`nConfiguration Complete:" -ForegroundColor Cyan
    Write-Host "✅ VM joined to domain: $domainName" -ForegroundColor Green
    Write-Host "✅ AVD Agent installed" -ForegroundColor Green
    Write-Host "✅ AVD Bootloader installed" -ForegroundColor Green
    Write-Host "✅ Registered with host pool: $hostPoolName" -ForegroundColor Green
    
    Write-Host "`nNext Steps:" -ForegroundColor Cyan
    Write-Host "1. Review logs in .\logs\ folder"
    Write-Host "2. Verify in Azure Portal: AVD → Host Pools → $hostPoolName → Session Hosts"
    Write-Host "3. Check session host status (should be 'Available')"
    Write-Host "4. Test user login via AVD client"
    Write-Host ""
}
catch {
    Write-Host "`n❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nPlease review the logs in .\logs\ folder for details." -ForegroundColor Yellow
    Write-Host "Common issues:" -ForegroundColor Yellow
    Write-Host "  - Domain credentials incorrect" -ForegroundColor Yellow
    Write-Host "  - VM cannot reach domain controllers" -ForegroundColor Yellow
    Write-Host "  - VM doesn't have internet connectivity" -ForegroundColor Yellow
    Write-Host "  - Registration token expired" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# -----------------------
# STEP 5: VERIFICATION
# -----------------------

Write-Host "`n=== Verification ===" -ForegroundColor Cyan

try {
    Write-Host "Checking session host registration..." -ForegroundColor Yellow
    
    Start-Sleep -Seconds 10
    
    $sessionHost = Get-AzWvdSessionHost `
        -ResourceGroupName $hostPoolResourceGroup `
        -HostPoolName $hostPoolName |
        Where-Object { $_.Name -like "*$vmName*" }
    
    if ($sessionHost) {
        Write-Host "`n✅ Session Host Verified!" -ForegroundColor Green
        Write-Host "Name: $($sessionHost.Name)" -ForegroundColor Cyan
        Write-Host "Status: $($sessionHost.Status)" -ForegroundColor Cyan
        Write-Host "Last Heart Beat: $($sessionHost.LastHeartBeat)" -ForegroundColor Cyan
        Write-Host "Allow New Session: $($sessionHost.AllowNewSession)" -ForegroundColor Cyan
    }
    else {
        Write-Host "`n⚠️  Session host not visible yet (this can take a few minutes)" -ForegroundColor Yellow
        Write-Host "Check Azure Portal in 5-10 minutes" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`n⚠️  Could not verify session host (check manually in Azure Portal)" -ForegroundColor Yellow
}

Write-Host "`n=== Configuration Complete ===" -ForegroundColor Green
