# Test Parameter Validation Script for VM Clone Pipeline
# This script validates that all parameters are passed correctly from the pipeline

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Skip', 'Overwrite', 'Prompt')]
    [string]$ExistingVhdAction = 'Prompt',
    
    [Parameter(Mandatory=$true)]
    [string]$SourceSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetSubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceVMName,
    
    [Parameter(Mandatory=$true)]
    [string]$NewVMName,
    
    [Parameter(Mandatory=$true)]
    [string]$Location,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetRG,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetName,
    
    [Parameter(Mandatory=$true)]
    [string]$SubnetName,
    
    [Parameter(Mandatory=$true)]
    [string]$VMSize,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory=$true)]
    [string]$StorageAccountRG,
    
    [Parameter(Mandatory=$false)]
    [string]$ContainerName = "vhds",
    
    [Parameter(Mandatory=$true)]
    [string]$StaticIpAddress,
    
    [Parameter(Mandatory=$false)]
    [string]$BootDiagStorageAccount = "babsitvmbootdiag02",
    
    [Parameter(Mandatory=$false)]
    [string]$BootDiagStorageRG = "bab-sit-vm-boot-diag-swec-rg-01"
)

Write-Host "=== VM Clone Pipeline Parameter Test ===" -ForegroundColor Cyan
Write-Host "Testing parameter passing from pipeline to PowerShell script" -ForegroundColor Yellow
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

Write-Host "`n=== RECEIVED PARAMETERS ===" -ForegroundColor Green

# Subscription Information
Write-Host "`n📋 Subscription Information:" -ForegroundColor Cyan
Write-Host "  Source Subscription ID: $SourceSubscriptionId" -ForegroundColor White
Write-Host "  Target Subscription ID: $TargetSubscriptionId" -ForegroundColor White

# Resource Groups
Write-Host "`n📁 Resource Groups:" -ForegroundColor Cyan
Write-Host "  Source Resource Group: $SourceResourceGroup" -ForegroundColor White
Write-Host "  Target Resource Group: $TargetResourceGroup" -ForegroundColor White

# VM Information
Write-Host "`n💻 Virtual Machine Information:" -ForegroundColor Cyan
Write-Host "  Source VM Name: $SourceVMName" -ForegroundColor White
Write-Host "  New VM Name: $NewVMName" -ForegroundColor White
Write-Host "  Target Location: $Location" -ForegroundColor White
Write-Host "  VM Size: $VMSize" -ForegroundColor White
Write-Host "  Static IP Address: $StaticIpAddress" -ForegroundColor White

# Network Configuration
Write-Host "`n🌐 Network Configuration:" -ForegroundColor Cyan
Write-Host "  VNet Resource Group: $VnetRG" -ForegroundColor White
Write-Host "  VNet Name: $VnetName" -ForegroundColor White
Write-Host "  Subnet Name: $SubnetName" -ForegroundColor White

# Storage Configuration
Write-Host "`n💾 Storage Configuration:" -ForegroundColor Cyan
Write-Host "  Storage Account Name: $StorageAccountName" -ForegroundColor White
Write-Host "  Storage Account RG: $StorageAccountRG" -ForegroundColor White
Write-Host "  Container Name: $ContainerName" -ForegroundColor White

# Boot Diagnostics
Write-Host "`n🔧 Boot Diagnostics:" -ForegroundColor Cyan
Write-Host "  Boot Diag Storage: $BootDiagStorageAccount" -ForegroundColor White
Write-Host "  Boot Diag Storage RG: $BootDiagStorageRG" -ForegroundColor White

# Processing Options
Write-Host "`n⚙️ Processing Options:" -ForegroundColor Cyan
Write-Host "  Existing VHD Action: $ExistingVhdAction" -ForegroundColor White

# Parameter Validation
Write-Host "`n=== PARAMETER VALIDATION ===" -ForegroundColor Green

$validationErrors = @()
$validationWarnings = @()

# Check required parameters
if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) { $validationErrors += "Source Subscription ID is empty" }
if ([string]::IsNullOrWhiteSpace($TargetSubscriptionId)) { $validationErrors += "Target Subscription ID is empty" }
if ([string]::IsNullOrWhiteSpace($SourceResourceGroup)) { $validationErrors += "Source Resource Group is empty" }
if ([string]::IsNullOrWhiteSpace($TargetResourceGroup)) { $validationErrors += "Target Resource Group is empty" }
if ([string]::IsNullOrWhiteSpace($SourceVMName)) { $validationErrors += "Source VM Name is empty" }
if ([string]::IsNullOrWhiteSpace($NewVMName)) { $validationErrors += "New VM Name is empty" }
if ([string]::IsNullOrWhiteSpace($Location)) { $validationErrors += "Location is empty" }
if ([string]::IsNullOrWhiteSpace($VnetRG)) { $validationErrors += "VNet Resource Group is empty" }
if ([string]::IsNullOrWhiteSpace($VnetName)) { $validationErrors += "VNet Name is empty" }
if ([string]::IsNullOrWhiteSpace($SubnetName)) { $validationErrors += "Subnet Name is empty" }
if ([string]::IsNullOrWhiteSpace($VMSize)) { $validationErrors += "VM Size is empty" }
if ([string]::IsNullOrWhiteSpace($StorageAccountName)) { $validationErrors += "Storage Account Name is empty" }
if ([string]::IsNullOrWhiteSpace($StorageAccountRG)) { $validationErrors += "Storage Account RG is empty" }
if ([string]::IsNullOrWhiteSpace($StaticIpAddress)) { $validationErrors += "Static IP Address is empty" }

# Validate IP address format
try {
    [System.Net.IPAddress]::Parse($StaticIpAddress) | Out-Null
    Write-Host "✅ Static IP address format is valid" -ForegroundColor Green
} catch {
    $validationErrors += "Static IP address format is invalid: $StaticIpAddress"
}

# Validate subscription IDs are GUIDs
try {
    [System.Guid]::Parse($SourceSubscriptionId) | Out-Null
    Write-Host "✅ Source Subscription ID format is valid" -ForegroundColor Green
} catch {
    $validationErrors += "Source Subscription ID is not a valid GUID: $SourceSubscriptionId"
}

try {
    [System.Guid]::Parse($TargetSubscriptionId) | Out-Null
    Write-Host "✅ Target Subscription ID format is valid" -ForegroundColor Green
} catch {
    $validationErrors += "Target Subscription ID is not a valid GUID: $TargetSubscriptionId"
}

# Check for same source and target names
if ($SourceVMName -eq $NewVMName) {
    $validationWarnings += "Source and target VM names are the same - this may cause conflicts"
}

if ($SourceResourceGroup -eq $TargetResourceGroup -and $SourceSubscriptionId -eq $TargetSubscriptionId) {
    $validationWarnings += "Source and target are in the same subscription and resource group"
}

# Validate VM size format
$validVMSizes = @("Standard_D2s_v5", "Standard_D4s_v5", "Standard_D8s_v5", "Standard_D16s_v5", "Standard_B2s", "Standard_B4ms")
if ($VMSize -notin $validVMSizes) {
    $validationWarnings += "VM Size '$VMSize' is not in the common list. Ensure it's available in target region."
}

# Display validation results
if ($validationErrors.Count -eq 0) {
    Write-Host "`n✅ PARAMETER VALIDATION PASSED" -ForegroundColor Green
    Write-Host "All required parameters are present and valid" -ForegroundColor Green
} else {
    Write-Host "`n❌ PARAMETER VALIDATION FAILED" -ForegroundColor Red
    foreach ($validationError in $validationErrors) {
        Write-Host "  ❌ $validationError" -ForegroundColor Red
    }
}

if ($validationWarnings.Count -gt 0) {
    Write-Host "`n⚠️ VALIDATION WARNINGS:" -ForegroundColor Yellow
    foreach ($warning in $validationWarnings) {
        Write-Host "  ⚠️ $warning" -ForegroundColor Yellow
    }
}

# Environment simulation
Write-Host "`n=== ENVIRONMENT SIMULATION ===" -ForegroundColor Green

Write-Host "`n🔄 Simulated Actions (DRY RUN):" -ForegroundColor Cyan
Write-Host "1. Switch to source subscription: $SourceSubscriptionId" -ForegroundColor Gray
Write-Host "2. Locate source VM: $SourceVMName in $SourceResourceGroup" -ForegroundColor Gray
Write-Host "3. Check VM power state (running VMs supported)" -ForegroundColor Gray
Write-Host "4. Switch to target subscription: $TargetSubscriptionId" -ForegroundColor Gray
Write-Host "5. Validate storage account: $StorageAccountName in $StorageAccountRG" -ForegroundColor Gray
Write-Host "6. Validate target network: $VnetName/$SubnetName in $VnetRG" -ForegroundColor Gray
Write-Host "7. Export disks to VHDs (mode: $ExistingVhdAction)" -ForegroundColor Gray
Write-Host "8. Create managed disks from VHDs in $Location" -ForegroundColor Gray
Write-Host "9. Create NIC with IP: $StaticIpAddress" -ForegroundColor Gray
Write-Host "10. Create VM: $NewVMName with size $VMSize" -ForegroundColor Gray
Write-Host "11. Configure boot diagnostics: $BootDiagStorageAccount" -ForegroundColor Gray

Write-Host "`n=== TEST SUMMARY ===" -ForegroundColor Green
Write-Host "Parameter Count: $($PSBoundParameters.Count)" -ForegroundColor White
Write-Host "Validation Errors: $($validationErrors.Count)" -ForegroundColor $(if ($validationErrors.Count -eq 0) { "Green" } else { "Red" })
Write-Host "Validation Warnings: $($validationWarnings.Count)" -ForegroundColor $(if ($validationWarnings.Count -eq 0) { "Green" } else { "Yellow" })
Write-Host "Test Status: $(if ($validationErrors.Count -eq 0) { "✅ READY FOR EXECUTION" } else { "❌ NEEDS FIXES" })" -ForegroundColor $(if ($validationErrors.Count -eq 0) { "Green" } else { "Red" })

if ($validationErrors.Count -eq 0) {
    Write-Host "`n🎉 Parameter test completed successfully!" -ForegroundColor Green
    Write-Host "The pipeline parameters are properly configured and ready for VM clone execution." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n💥 Parameter test failed!" -ForegroundColor Red
    Write-Host "Please fix the validation errors before running the actual VM clone pipeline." -ForegroundColor Red
    exit 1
}