# ============================================================================
# Batch Configure Multiple AVD Session Hosts
# ============================================================================
#
# This script configures multiple VMs as AVD session hosts in one operation
#
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$VMNames = @("BABAVDSHDTA-5", "BABAVDSHDTA-6", "BABAVDSHDTA-7"),
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "bab-vdi-avd-weeu-rg-01",
    
    [Parameter(Mandatory = $false)]
    [string]$DomainName = "bankalbilad.com.sa",
    
    [Parameter(Mandatory = $false)]
    [string]$DomainJoinUserName = "admin@bankalbilad.com.sa",
    
    [Parameter(Mandatory = $false)]
    [string]$OUPath = "",
    
    [Parameter(Mandatory = $false)]
    [string]$HostPoolName = "bab-avd-hostpool",
    
    [Parameter(Mandatory = $false)]
    [string]$HostPoolResourceGroup = "bab-vdi-avd-weeu-rg-01",
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "cb801de6-404a-4e76-8e9a-475206cbc2e5",
    
    [Parameter(Mandatory = $false)]
    [switch]$Parallel,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxParallelJobs = 3
)

Write-Host "=== Batch AVD Session Host Configuration ===" -ForegroundColor Cyan
Write-Host "VMs to configure: $($VMNames.Count)" -ForegroundColor Yellow
Write-Host "Host Pool: $HostPoolName" -ForegroundColor Yellow
Write-Host ""

# Check prerequisites
$requiredModules = @('Az.Compute', 'Az.DesktopVirtualization')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Force -AllowClobber
    }
    Import-Module $module
}

# Check Azure connection
$context = Get-AzContext
if (-not $context) {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Connect-AzAccount
}

# Get domain password
Write-Host "Enter domain admin password for: $DomainJoinUserName" -ForegroundColor Cyan
$domainPassword = Read-Host "Password" -AsSecureString

# Generate registration token once (valid for 24 hours)
Write-Host "`nGenerating registration token..." -ForegroundColor Cyan
$tokenExpiry = (Get-Date).AddHours(24).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
$tokenResult = New-AzWvdRegistrationInfo `
    -ResourceGroupName $HostPoolResourceGroup `
    -HostPoolName $HostPoolName `
    -ExpirationTime $tokenExpiry

$registrationToken = $tokenResult.Token
Write-Host "✅ Registration token generated (expires: $tokenExpiry)" -ForegroundColor Green
Write-Host ""

# Configuration results tracking
$results = @()
$successCount = 0
$failureCount = 0

if ($Parallel) {
    Write-Host "=== Starting Parallel Configuration (Max $MaxParallelJobs concurrent jobs) ===" -ForegroundColor Green
    Write-Host ""
    
    # Use parallel jobs
    $jobs = @()
    
    foreach ($vmName in $VMNames) {
        # Wait if max jobs reached
        while ((Get-Job -State Running).Count -ge $MaxParallelJobs) {
            Start-Sleep -Seconds 5
            # Check completed jobs
            Get-Job -State Completed | ForEach-Object {
                $jobResult = Receive-Job -Job $_ -Keep
                if ($jobResult -match "SUCCESS") {
                    Write-Host "✅ Job completed: $($_.Name)" -ForegroundColor Green
                } else {
                    Write-Host "❌ Job failed: $($_.Name)" -ForegroundColor Red
                }
                Remove-Job -Job $_
            }
        }
        
        Write-Host "Starting configuration job for: $vmName" -ForegroundColor Cyan
        
        # Start job
        $job = Start-Job -Name "Config-$vmName" -ScriptBlock {
            param($vm, $rg, $domain, $domainUser, $domainPwd, $ou, $hp, $hpRg, $token, $sub, $scriptPath)
            
            Set-Location (Split-Path $scriptPath)
            
            $params = @{
                VMName                  = $vm
                ResourceGroupName       = $rg
                DomainName              = $domain
                DomainJoinUserName      = $domainUser
                DomainJoinPassword      = $domainPwd
                HostPoolName            = $hp
                HostPoolResourceGroup   = $hpRg
                RegistrationToken       = $token
                SubscriptionId          = $sub
            }
            
            if ($ou) { $params['OUPath'] = $ou }
            
            & "$scriptPath\Configure-AVD-SessionHost.ps1" @params
            
        } -ArgumentList $vmName, $ResourceGroupName, $DomainName, $DomainJoinUserName, $domainPassword, $OUPath, $HostPoolName, $HostPoolResourceGroup, $registrationToken, $SubscriptionId, $PSScriptRoot
        
        $jobs += $job
    }
    
    # Wait for all jobs to complete
    Write-Host "`nWaiting for all jobs to complete..." -ForegroundColor Yellow
    $jobs | Wait-Job | Out-Null
    
    # Collect results
    foreach ($job in $jobs) {
        $jobOutput = Receive-Job -Job $job
        $vmName = $job.Name -replace "Config-", ""
        
        if ($job.State -eq 'Completed' -and $jobOutput -match "SUCCESS") {
            Write-Host "✅ $vmName - Configuration succeeded" -ForegroundColor Green
            $successCount++
            $results += [PSCustomObject]@{
                VMName = $vmName
                Status = "Success"
                Message = "Configured successfully"
            }
        } else {
            Write-Host "❌ $vmName - Configuration failed" -ForegroundColor Red
            $failureCount++
            $results += [PSCustomObject]@{
                VMName = $vmName
                Status = "Failed"
                Message = $jobOutput | Select-Object -Last 5 | Out-String
            }
        }
        
        Remove-Job -Job $job
    }
    
} else {
    Write-Host "=== Starting Sequential Configuration ===" -ForegroundColor Green
    Write-Host ""
    
    # Sequential execution
    $current = 0
    foreach ($vmName in $VMNames) {
        $current++
        Write-Host "[$current/$($VMNames.Count)] Configuring: $vmName" -ForegroundColor Cyan
        Write-Host "-------------------------------------------" -ForegroundColor Gray
        
        try {
            $params = @{
                VMName                  = $vmName
                ResourceGroupName       = $ResourceGroupName
                DomainName              = $DomainName
                DomainJoinUserName      = $DomainJoinUserName
                DomainJoinPassword      = $domainPassword
                HostPoolName            = $HostPoolName
                HostPoolResourceGroup   = $HostPoolResourceGroup
                RegistrationToken       = $registrationToken
                SubscriptionId          = $SubscriptionId
                Verbose                 = $true
            }
            
            if ($OUPath) {
                $params['OUPath'] = $OUPath
            }
            
            .\Configure-AVD-SessionHost.ps1 @params
            
            Write-Host "✅ $vmName - Configuration succeeded" -ForegroundColor Green
            $successCount++
            $results += [PSCustomObject]@{
                VMName = $vmName
                Status = "Success"
                Message = "Configured successfully"
            }
            
        } catch {
            Write-Host "❌ $vmName - Configuration failed: $($_.Exception.Message)" -ForegroundColor Red
            $failureCount++
            $results += [PSCustomObject]@{
                VMName = $vmName
                Status = "Failed"
                Message = $_.Exception.Message
            }
        }
        
        Write-Host ""
    }
}

# Summary
Write-Host ""
Write-Host "=== Batch Configuration Complete ===" -ForegroundColor Cyan
Write-Host "Total VMs: $($VMNames.Count)" -ForegroundColor Yellow
Write-Host "✅ Successful: $successCount" -ForegroundColor Green
Write-Host "❌ Failed: $failureCount" -ForegroundColor Red
Write-Host ""

# Display results table
Write-Host "Results Summary:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# Export results
$resultsFile = ".\logs\BatchConfig-Results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $resultsFile -NoTypeInformation
Write-Host "Results exported to: $resultsFile" -ForegroundColor Yellow

# Verify in host pool
Write-Host "`nVerifying session hosts in host pool..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

try {
    $sessionHosts = Get-AzWvdSessionHost `
        -ResourceGroupName $HostPoolResourceGroup `
        -HostPoolName $HostPoolName
    
    Write-Host "`nSession Hosts in '$HostPoolName':" -ForegroundColor Cyan
    $sessionHosts | Select-Object @{N='Name';E={$_.Name -replace '.*/',''}}, Status, LastHeartBeat | Format-Table -AutoSize
    
} catch {
    Write-Host "Could not retrieve session hosts. Check Azure Portal manually." -ForegroundColor Yellow
}

Write-Host "`n=== All Done! ===" -ForegroundColor Green
