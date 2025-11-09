[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath = ".\core\simplified-vms.csv",
    
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetName,
    
    [Parameter(Mandatory = $true)]
    [string]$VNetResourceGroup
)

<#
.SYNOPSIS
Validate CSV file subnet configuration against actual Azure subnets

.DESCRIPTION
This script validates that:
1. All subnet_name entries in CSV exist in Azure
2. All static_ip entries belong to the correct subnets
3. No IP conflicts exist

.EXAMPLE
.\validate-csv-subnets.ps1 -CsvPath ".\core\simplified-vms.csv" -SubscriptionId "43cc4f11-ffb1-4a0d-8420-0ba3746b4248" -VNetName "bab-dev-nw-swec-vnet-nonpci-01" -VNetResourceGroup "bab-dev-nw-swec-rg-01"
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

function Test-IPInSubnet {
    param(
        [string]$IPAddress,
        [string]$SubnetCIDR
    )
    
    try {
        $ip = [System.Net.IPAddress]::Parse($IPAddress)
        $subnet = [System.Net.IPAddress]::Parse($SubnetCIDR.Split('/')[0])
        $prefixLength = [int]$SubnetCIDR.Split('/')[1]
        
        $mask = [uint32](0xFFFFFFFF -shl (32 - $prefixLength))
        $ipUint = [BitConverter]::ToUInt32($ip.GetAddressBytes(), 0)
        $subnetUint = [BitConverter]::ToUInt32($subnet.GetAddressBytes(), 0)
        
        return ($ipUint -band $mask) -eq ($subnetUint -band $mask)
    }
    catch {
        return $false
    }
}

try {
    Write-Log "Starting CSV subnet validation..." -Level "Info"
    Write-Log "CSV Path: $CsvPath" -Level "Info"
    Write-Log "Subscription: $SubscriptionId" -Level "Info"
    Write-Log "VNet: $VNetName in RG: $VNetResourceGroup" -Level "Info"

    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        Write-Log "CSV file not found: $CsvPath" -Level "Error"
        exit 1
    }

    # Connect to Azure
    Write-Log "Connecting to Azure..." -Level "Info"
    $context = Get-AzContext
    if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    Write-Log "Connected to subscription: $((Get-AzContext).Subscription.Name)" -Level "Success"

    # Get VNet and subnets
    Write-Log "Retrieving VNet and subnet information..." -Level "Info"
    try {
        $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $VNetResourceGroup -ErrorAction Stop
        $subnets = $vnet.Subnets
        Write-Log "Found VNet with $($subnets.Count) subnets" -Level "Success"
    }
    catch {
        Write-Log "Failed to retrieve VNet: $($_.Exception.Message)" -Level "Error"
        exit 1
    }

    # Display available subnets
    Write-Log "Available subnets:" -Level "Info"
    foreach ($subnet in $subnets) {
        Write-Log "  - $($subnet.Name): $($subnet.AddressPrefix)" -Level "Info"
    }

    # Read and validate CSV
    Write-Log "Reading CSV file..." -Level "Info"
    try {
        $csvData = Import-Csv -Path $CsvPath
        Write-Log "Found $($csvData.Count) VM entries in CSV" -Level "Success"
    }
    catch {
        Write-Log "Failed to read CSV: $($_.Exception.Message)" -Level "Error"
        exit 1
    }

    # Validation results
    $validationResults = @()
    $errorCount = 0
    $warningCount = 0

    # Validate each VM entry
    foreach ($row in $csvData) {
        $vmName = $row.vm_name
        $subnetName = $row.subnet_name
        $staticIP = $row.static_ip

        Write-Log "Validating VM: $vmName" -Level "Info"

        # Find subnet
        $targetSubnet = $subnets | Where-Object { $_.Name -eq $subnetName }
        
        if (-not $targetSubnet) {
            $errorCount++
            $result = [PSCustomObject]@{
                VMName = $vmName
                SubnetName = $subnetName
                StaticIP = $staticIP
                Status = "ERROR"
                Message = "Subnet '$subnetName' not found in VNet"
                Suggestion = "Available subnets: $($subnets.Name -join ', ')"
            }
            Write-Log "❌ $vmName: Subnet '$subnetName' not found" -Level "Error"
        }
        else {
            # Check if IP belongs to subnet
            $subnetCIDR = $targetSubnet.AddressPrefix
            $ipInSubnet = Test-IPInSubnet -IPAddress $staticIP -SubnetCIDR $subnetCIDR
            
            if (-not $ipInSubnet) {
                $errorCount++
                $result = [PSCustomObject]@{
                    VMName = $vmName
                    SubnetName = $subnetName
                    StaticIP = $staticIP
                    Status = "ERROR"
                    Message = "IP $staticIP does not belong to subnet $subnetName ($subnetCIDR)"
                    Suggestion = "Use IP range: $subnetCIDR"
                }
                Write-Log "❌ $vmName: IP $staticIP not in subnet range $subnetCIDR" -Level "Error"
            }
            else {
                $result = [PSCustomObject]@{
                    VMName = $vmName
                    SubnetName = $subnetName
                    StaticIP = $staticIP
                    Status = "OK"
                    Message = "Valid subnet and IP configuration"
                    Suggestion = ""
                }
                Write-Log "✅ $vmName: Valid configuration" -Level "Success"
            }
        }
        
        $validationResults += $result
    }

    # Check for IP conflicts
    Write-Log "Checking for IP conflicts..." -Level "Info"
    $ipGroups = $csvData | Group-Object -Property static_ip | Where-Object { $_.Count -gt 1 }
    if ($ipGroups) {
        foreach ($group in $ipGroups) {
            $warningCount++
            Write-Log "⚠️  IP conflict detected: $($group.Name) used by: $($group.Group.vm_name -join ', ')" -Level "Warning"
        }
    }

    # Display summary
    Write-Log "`n=== VALIDATION SUMMARY ===" -Level "Info"
    Write-Log "Total VMs: $($csvData.Count)" -Level "Info"
    Write-Log "Errors: $errorCount" -Level "Error"
    Write-Log "Warnings: $warningCount" -Level "Warning"
    Write-Log "Valid: $(($csvData.Count - $errorCount))" -Level "Success"

    # Display detailed results
    if ($errorCount -gt 0) {
        Write-Log "`n=== ERRORS TO FIX ===" -Level "Error"
        $validationResults | Where-Object { $_.Status -eq "ERROR" } | ForEach-Object {
            Write-Log "VM: $($_.VMName)" -Level "Error"
            Write-Log "  Issue: $($_.Message)" -Level "Error"
            Write-Log "  Fix: $($_.Suggestion)" -Level "Error"
            Write-Log "" -Level "Error"
        }
    }

    if ($errorCount -eq 0 -and $warningCount -eq 0) {
        Write-Log "`n🎉 All validations passed! Your CSV is ready for deployment." -Level "Success"
        exit 0
    }
    elseif ($errorCount -eq 0) {
        Write-Log "`n⚠️  Validation passed with warnings. Review IP conflicts before deployment." -Level "Warning"
        exit 0
    }
    else {
        Write-Log "`n❌ Validation failed. Please fix the errors above before running the pipeline." -Level "Error"
        exit 1
    }
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "Error"
    exit 1
}