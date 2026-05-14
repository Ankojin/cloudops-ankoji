<#
.SYNOPSIS
    Verify actual VM state - domain status and user profiles

.DESCRIPTION
    Runs diagnostic checks to show the ACTUAL state of the VM:
    - Domain membership (WMI and Registry)
    - User profiles (loaded and unloaded)
    - Sysprep run count
    - Critical services status
    
    Use this to verify if prep operations actually completed.

.PARAMETER VMName
    Name of the VM to check

.PARAMETER ResourceGroupName
    Resource group containing the VM

.PARAMETER SubscriptionId
    Azure subscription ID

.EXAMPLE
    .\Verify-VMState.ps1 -VMName "BABAVDSHDTA-1-Golden-v2" `
        -ResourceGroupName "bab-vdi-avd-weeu-rg-01" `
        -SubscriptionId "cb801de6-404a-4e76-8e9a-475206cbc2e5"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
)

function Write-Result {
    param($Label, $Value, $Status = 'Info')
    
    $color = switch ($Status) {
        'Good'    { 'Green' }
        'Bad'     { 'Red' }
        'Warning' { 'Yellow' }
        default   { 'Cyan' }
    }
    
    Write-Host "$Label : " -NoNewline
    Write-Host $Value -ForegroundColor $color
}

try {
    Write-Host "`n=== VM STATE VERIFICATION ===" -ForegroundColor Cyan
    Write-Host "VM: $VMName`n" -ForegroundColor White
    
    # Set context
    $null = Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue
    
    # Verification script
    $checkScript = @'
$results = @{}

# Check 1: WMI Domain Status
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
$results['WMI_PartOfDomain'] = $computerInfo.PartOfDomain
$results['WMI_Domain'] = $computerInfo.Domain
$results['WMI_Workgroup'] = $computerInfo.Workgroup

# Check 2: Registry Domain Status
$regDomain = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "Domain" -ErrorAction SilentlyContinue).Domain
$results['Registry_Domain'] = $regDomain

$tcpipDomain = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain" -ErrorAction SilentlyContinue).Domain
$results['TCPIP_Domain'] = $tcpipDomain

# Check 3: User Profiles
$allProfiles = Get-WmiObject -Class Win32_UserProfile -ErrorAction SilentlyContinue
$userProfiles = $allProfiles | Where-Object { 
    -not $_.Special -and 
    $_.LocalPath -notlike "*\Administrator" -and
    $_.LocalPath -notlike "*\Default*" -and
    $_.LocalPath -notlike "*\Public" -and
    $_.LocalPath -notlike "*\systemprofile*" -and
    $_.LocalPath -notlike "*\LocalService*" -and
    $_.LocalPath -notlike "*\NetworkService*"
}

$results['UserProfiles_Count'] = $userProfiles.Count
$results['UserProfiles_Loaded'] = ($userProfiles | Where-Object { $_.Loaded }).Count

if ($userProfiles.Count -gt 0) {
    $profileList = @()
    foreach ($profile in $userProfiles) {
        $profileList += "$($profile.LocalPath) [Loaded: $($profile.Loaded)]"
    }
    $results['UserProfiles_List'] = $profileList -join "`n    "
}
else {
    $results['UserProfiles_List'] = "None"
}

# Check 4: Sysprep Run Count
$sysprepCount = 0
$sysprepRegPath = "HKLM:\SYSTEM\Setup\Status\SysprepStatus"
if (Test-Path $sysprepRegPath) {
    $sysprepCount = (Get-ItemProperty -Path $sysprepRegPath -Name "GeneralizationState" -ErrorAction SilentlyContinue).GeneralizationState
    if ($sysprepCount -eq $null) { $sysprepCount = 0 }
}
$results['Sysprep_RunCount'] = $sysprepCount

# Check 5: Netlogon Service
$netlogon = Get-Service -Name Netlogon -ErrorAction SilentlyContinue
$results['Netlogon_Status'] = $netlogon.Status
$results['Netlogon_StartType'] = $netlogon.StartType

# Check 6: Critical folders exist
$results['Folder_Panther'] = Test-Path "C:\Windows\Panther"
$results['Folder_SysprepPanther'] = Test-Path "C:\Windows\System32\Sysprep\Panther"

# Output as JSON for easy parsing
$results | ConvertTo-Json -Depth 3
'@
    
    Write-Host "Running diagnostics..." -ForegroundColor Yellow
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId 'RunPowerShellScript' `
        -ScriptString $checkScript `
        -ErrorAction Stop
    
    # Parse JSON output
    $output = $result.Value[0].Message
    
    # Extract JSON from output (might have other text)
    $jsonMatch = $output -match '(?s)\{.*\}'
    if ($jsonMatch) {
        $jsonText = $Matches[0]
        $data = $jsonText | ConvertFrom-Json
        
        Write-Host "`n--- DOMAIN STATUS ---" -ForegroundColor Cyan
        
        $domainStatus = if ($data.WMI_PartOfDomain -eq $true) { 'Bad' } else { 'Good' }
        Write-Result "  WMI PartOfDomain" $data.WMI_PartOfDomain $domainStatus
        Write-Result "  WMI Domain      " $data.WMI_Domain $(if ($data.WMI_Domain) { 'Bad' } else { 'Good' })
        Write-Result "  WMI Workgroup   " $data.WMI_Workgroup $(if ($data.WMI_Workgroup -eq 'WORKGROUP') { 'Good' } else { 'Warning' })
        Write-Result "  Registry Domain " $data.Registry_Domain $(if ($data.Registry_Domain -eq 'WORKGROUP' -or !$data.Registry_Domain) { 'Good' } else { 'Bad' })
        Write-Result "  TCP/IP Domain   " $data.TCPIP_Domain $(if (!$data.TCPIP_Domain) { 'Good' } else { 'Bad' })
        
        Write-Host "`n--- USER PROFILES ---" -ForegroundColor Cyan
        $profileStatus = if ($data.UserProfiles_Count -eq 0) { 'Good' } elseif ($data.UserProfiles_Loaded -gt 0) { 'Bad' } else { 'Warning' }
        Write-Result "  Profile Count   " $data.UserProfiles_Count $profileStatus
        Write-Result "  Loaded Profiles " $data.UserProfiles_Loaded $(if ($data.UserProfiles_Loaded -eq 0) { 'Good' } else { 'Bad' })
        if ($data.UserProfiles_Count -gt 0) {
            Write-Host "  Profiles:" -ForegroundColor Yellow
            Write-Host "    $($data.UserProfiles_List)" -ForegroundColor Yellow
        }
        
        Write-Host "`n--- SYSPREP STATUS ---" -ForegroundColor Cyan
        $sysprepStatus = if ($data.Sysprep_RunCount -ge 3) { 'Bad' } elseif ($data.Sysprep_RunCount -ge 1) { 'Warning' } else { 'Good' }
        Write-Result "  Run Count       " $data.Sysprep_RunCount $sysprepStatus
        if ($data.Sysprep_RunCount -ge 3) {
            Write-Host "    ⚠️  WARNING: Sysprep limit (3) reached!" -ForegroundColor Red
        }
        
        Write-Host "`n--- SERVICES ---" -ForegroundColor Cyan
        Write-Result "  Netlogon Status " $data.Netlogon_Status $(if ($data.Netlogon_Status -eq 'Stopped') { 'Good' } else { 'Warning' })
        Write-Result "  Netlogon Start  " $data.Netlogon_StartType $(if ($data.Netlogon_StartType -eq 'Disabled') { 'Good' } else { 'Warning' })
        
        Write-Host "`n--- OVERALL ASSESSMENT ---" -ForegroundColor Cyan
        
        $issues = @()
        if ($data.WMI_PartOfDomain -eq $true) {
            $issues += "❌ VM is still DOMAIN-JOINED (sysprep will fail!)"
        }
        if ($data.UserProfiles_Count -gt 0) {
            $issues += "⚠️  User profiles still exist ($($data.UserProfiles_Count) found)"
        }
        if ($data.UserProfiles_Loaded -gt 0) {
            $issues += "❌ User profiles are LOADED (must log off users!)"
        }
        if ($data.Sysprep_RunCount -ge 3) {
            $issues += "❌ Sysprep limit reached - VM cannot be sysprepped again!"
        }
        
        if ($issues.Count -eq 0) {
            Write-Host "  ✅ VM is ready for sysprep!" -ForegroundColor Green
            Write-Host "     - Not domain-joined" -ForegroundColor Green
            Write-Host "     - No user profiles" -ForegroundColor Green
            Write-Host "     - Sysprep count OK" -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠️  Issues found:" -ForegroundColor Yellow
            foreach ($issue in $issues) {
                Write-Host "     $issue" -ForegroundColor $(if ($issue -like "*❌*") { 'Red' } else { 'Yellow' })
            }
        }
    }
    else {
        Write-Host "`nRaw output:" -ForegroundColor Yellow
        Write-Host $output
    }
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

Write-Host ""
