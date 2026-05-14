# ============================================================================
# Quick Start Example - Clone and Generalize AVD VM
# ============================================================================
# 
# INSTRUCTIONS:
# 1. Update the variables below with your actual values
# 2. Run the script in PowerShell as Administrator
# 3. Review the logs in .\logs\ folder
#
# IMPORTANT: Your source VM will NOT be modified!
# - Snapshot is created FIRST (original state preserved)
# - Only the CLONE is prepared and generalized
# - Source VM remains operational throughout the entire process
#
# ============================================================================

# -----------------------
# CONFIGURATION - UPDATE THESE VALUES
# -----------------------

# Your Azure subscription ID
$subscriptionId = "your-subscription-id-here"  # ← UPDATE THIS

# Source VM details (the VM with provisioning issues - will NOT be modified)
$sourceVMName = "BABAVDSHDTA-2"
$sourceResourceGroup = "bab-vdi-avd-weeu-rg-01"

# Target VM details (the clone that will be prepared and generalized)
$targetVMName = "BABAVDSHDTA-2-Clone"

# Image gallery details
$galleryName = "bab_avd_shared_win10_gallery"
$imageDefinitionName = "bab-w10-avd-img"

# Regions
$primaryLocation = "westeurope"
$replicaRegions = @("swedencentral")  # Add more regions if needed

# -----------------------
# STEP 1: PREREQUISITES CHECK
# -----------------------

Write-Host "`n=== Checking Prerequisites ===" -ForegroundColor Cyan

# Check if Az modules are installed
$requiredModules = @('Az.Compute', 'Az.Resources', 'Az.Network')
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
# STEP 2: DRY RUN (WHATIF)
# -----------------------

Write-Host "`n=== Running Dry Run (WhatIf) ===" -ForegroundColor Cyan
Write-Host "This will show what changes would be made without actually making them.`n" -ForegroundColor Yellow

$params = @{
    SourceVMName             = $sourceVMName
    SourceResourceGroupName  = $sourceResourceGroup
    TargetVMName             = $targetVMName
    GalleryName              = $galleryName
    ImageDefinitionName      = $imageDefinitionName
    Location                 = $primaryLocation
    ReplicaRegions           = $replicaRegions
    SubscriptionId           = $subscriptionId
    WhatIf                   = $true
    Verbose                  = $true
}

.\Clone-And-Generalize-AVD.ps1 @params

# -----------------------
# STEP 3: CONFIRMATION
# -----------------------

Write-Host "`n=== Ready to Execute ===" -ForegroundColor Cyan
Write-Host "The dry run is complete. Review the output above.`n" -ForegroundColor Yellow

$confirmation = Read-Host "Do you want to proceed with the actual execution? (yes/no)"

if ($confirmation -ne 'yes') {
    Write-Host "`n❌ Operation cancelled by user." -ForegroundColor Red
    exit 0
}

# -----------------------
# STEP 4: EXECUTE
# -----------------------

Write-Host "`n=== Starting Actual Execution ===" -ForegroundColor Green
Write-Host "This will take approximately 15-30 minutes..." -ForegroundColor Yellow
Write-Host "`n🔒 REMINDER: Source VM '$sourceVMName' will NOT be modified!" -ForegroundColor Green
Write-Host "   - Snapshot created FIRST (unmodified backup)"
Write-Host "   - Only the clone '$targetVMName' will be prepared and generalized"
Write-Host "   - Source VM stays operational throughout`n" -ForegroundColor Green

try {
    # Remove WhatIf, keep Verbose
    $params.Remove('WhatIf')
    
    # Execute the script
    .\Clone-And-Generalize-AVD.ps1 @params
    
    Write-Host "`n✅ SUCCESS! AVD VM has been cloned and generalized." -ForegroundColor Green
    Write-Host "`n🔒 Important: Your source VM '$sourceVMName' is UNCHANGED and still operational!" -ForegroundColor Cyan
    Write-Host "`nNext Steps:" -ForegroundColor Cyan
    Write-Host "1. Review logs in .\logs\ folder"
    Write-Host "2. Verify image in Shared Image Gallery (Azure Portal)"
    Write-Host "3. Deploy new AVD session hosts using the new image"
    Write-Host "4. Test the new session hosts thoroughly"
    Write-Host "5. Clean up clone VM and snapshots after verification"
    Write-Host "6. Source VM '$sourceVMName' can stay running - it was never modified!`n"
}
catch {
    Write-Host "`n❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nPlease review the logs in .\logs\ folder for details." -ForegroundColor Yellow
    Write-Host "You can retry with -SkipPreparation or -SkipSnapshot flags if needed.`n" -ForegroundColor Yellow
    exit 1
}

# -----------------------
# STEP 5: POST-EXECUTION INFO
# -----------------------

Write-Host "`n=== Deployment Information ===" -ForegroundColor Cyan

# Get the created image version
try {
    $latestVersion = Get-AzGalleryImageVersion `
        -ResourceGroupName $sourceResourceGroup `
        -GalleryName $galleryName `
        -GalleryImageDefinitionName $imageDefinitionName |
        Sort-Object -Property PublishingProfile.PublishedDate -Descending |
        Select-Object -First 1
    
    Write-Host "`nImage Details:" -ForegroundColor Green
    Write-Host "  Name: $($latestVersion.Name)"
    Write-Host "  ID: $($latestVersion.Id)"
    Write-Host "  Published: $($latestVersion.PublishingProfile.PublishedDate)"
    
    # Copy to clipboard for easy use
    $imageId = $latestVersion.Id
    Set-Clipboard -Value $imageId
    Write-Host "`n✅ Image ID copied to clipboard!" -ForegroundColor Green
}
catch {
    Write-Host "`n⚠️  Could not retrieve image version details." -ForegroundColor Yellow
}

Write-Host "`n=== All Done! ===" -ForegroundColor Green
