[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location = "swedencentral",
    [string]$Publisher = "",
    [string]$Offer = ""
)

<#
.SYNOPSIS
Check available Azure VM images in a specific region

.DESCRIPTION
This script helps you find available VM images in your Azure region.
Useful when getting "PlatformImageNotFound" errors.

.EXAMPLE
.\check-available-images.ps1 -Location "swedencentral" -Publisher "RedHat" -Offer "RHEL"

.EXAMPLE
.\check-available-images.ps1 -Location "swedencentral" -Publisher "Canonical"
#>

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "Info"    = "White"
        "Warning" = "Yellow"
        "Error"   = "Red"
        "Success" = "Green"
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}

try {
    Write-Log "Checking Azure VM images in location: $Location" -Level "Info"
    
    # Ensure we're logged in to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Not logged in to Azure. Please run Connect-AzAccount first." -Level "Error"
        exit 1
    }
    
    Write-Log "Connected to subscription: $($context.Subscription.Name)" -Level "Success"
    
    if ($Publisher -and $Offer) {
        Write-Log "Searching for SKUs: Publisher=$Publisher, Offer=$Offer" -Level "Info"
        
        try {
            $skus = Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer
            
            if ($skus) {
                Write-Log "Available SKUs for ${Publisher}/${Offer} in ${Location}:" -Level "Success"
                foreach ($sku in $skus) {
                    Write-Host "  - $($sku.Skus)" -ForegroundColor Green
                }
                
                # Show some versions for the first few SKUs
                Write-Log "Sample versions for first few SKUs:" -Level "Info"
                $skus | Select-Object -First 3 | ForEach-Object {
                    $skuName = $_.Skus
                    try {
                        $versions = Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $skuName | Select-Object -Last 3
                        Write-Host "  $skuName versions:" -ForegroundColor Cyan
                        foreach ($version in $versions) {
                            Write-Host "    - $($version.Version)" -ForegroundColor Gray
                        }
                    }
                    catch {
                        Write-Host "    - Could not get versions for $skuName" -ForegroundColor Yellow
                    }
                }
            } else {
                Write-Log "No SKUs found for ${Publisher}/${Offer} in ${Location}" -Level "Warning"
            }
        }
        catch {
            Write-Log "Error getting SKUs: $($_.Exception.Message)" -Level "Error"
        }
    }
    elseif ($Publisher) {
        Write-Log "Searching for offers from publisher: $Publisher" -Level "Info"
        
        try {
            $offers = Get-AzVMImageOffer -Location $Location -PublisherName $Publisher
            
            if ($offers) {
                Write-Log "Available offers for ${Publisher} in ${Location}:" -Level "Success"
                foreach ($offer in $offers) {
                    Write-Host "  - $($offer.Offer)" -ForegroundColor Green
                }
            } else {
                Write-Log "No offers found for publisher ${Publisher} in ${Location}" -Level "Warning"
            }
        }
        catch {
            Write-Log "Error getting offers: $($_.Exception.Message)" -Level "Error"
        }
    }
    else {
        Write-Log "Searching for common publishers in ${Location}..." -Level "Info"
        
        $commonPublishers = @(
            "Canonical",
            "RedHat", 
            "MicrosoftWindowsServer",
            "OpenLogic",
            "SUSE"
        )
        
        foreach ($pub in $commonPublishers) {
            try {
                $offers = Get-AzVMImageOffer -Location $Location -PublisherName $pub -ErrorAction SilentlyContinue
                if ($offers) {
                    Write-Log "✓ $pub - Available ($($offers.Count) offers)" -Level "Success"
                } else {
                    Write-Log "✗ $pub - No offers found" -Level "Warning"
                }
            }
            catch {
                Write-Log "✗ $pub - Error checking" -Level "Warning"
            }
        }
        
        Write-Log "Use -Publisher and -Offer parameters for detailed SKU information" -Level "Info"
    }
    
    Write-Log "Image check completed" -Level "Success"
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "Error"
    exit 1
}

# Quick reference for common working images
Write-Host "`n=== COMMONLY WORKING IMAGES ===" -ForegroundColor Yellow
Write-Host "Ubuntu 22.04: Canonical/0001-com-ubuntu-server-jammy/22_04-lts-gen2" -ForegroundColor Green
Write-Host "Ubuntu 20.04: Canonical/0001-com-ubuntu-server-focal/20_04-lts-gen2" -ForegroundColor Green  
Write-Host "Windows 2022: MicrosoftWindowsServer/WindowsServer/2022-Datacenter" -ForegroundColor Green
Write-Host "Windows 2019: MicrosoftWindowsServer/WindowsServer/2019-Datacenter" -ForegroundColor Green
Write-Host "RHEL 8: RedHat/RHEL/8-LVM (if available)" -ForegroundColor Yellow
Write-Host "RHEL 9: RedHat/RHEL/9_4 (if available)" -ForegroundColor Yellow