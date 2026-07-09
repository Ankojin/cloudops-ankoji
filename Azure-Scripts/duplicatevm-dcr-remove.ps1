<#
.SYNOPSIS
    Cleans duplicate DCR associations and adds only running Azure VMs to a DCR.

.DESCRIPTION
    1. Connects to Azure and selects a subscription.
    2. Gets all existing DCR associations.
    3. Detects and removes duplicate associations.
    4. Adds only running VMs to the DCR.
    5. Excludes specified resource groups.
    6. Skips VMs already associated with the DCR.
    7. Generates CSV reports.

.REQUIREMENTS
    Az.Accounts
    Az.Compute
    Az.Monitor
#>

#----------------------------------------------------------
# Variables
#----------------------------------------------------------
$SubscriptionId = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
$ResourceGroup  = "bab-dev-wrkspace-swec-rg-01"
$DCRName        = "msvmi-bab-dev-vm-monitoring-dcr"

# Resource groups to exclude
$ExcludedRGs = @(
    "ARO-INFRA-LX29KZ5C-BAB-DEV-ARO-01"
    
)

# Report location
$ReportFolder = "C:\Temp\DCRReports"
New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null

#----------------------------------------------------------
# Connect to Azure
#----------------------------------------------------------
Connect-AzAccount
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

#----------------------------------------------------------
# Get DCR
#----------------------------------------------------------
$DCR = Get-AzDataCollectionRule `
    -ResourceGroupName $ResourceGroup `
    -Name $DCRName `
    -ErrorAction Stop

Write-Host ""
Write-Host "DCR Name : $($DCR.Name)"
Write-Host "DCR ID   : $($DCR.Id)"
Write-Host ""

#----------------------------------------------------------
# Get Existing DCR Associations
#----------------------------------------------------------
Write-Host "Getting DCR associations..." -ForegroundColor Cyan

$Associations = @()

$VMs = Get-AzVM

foreach ($VM in $VMs)
{
    try
    {
        $Assoc = Get-AzDataCollectionRuleAssociation `
            -ResourceUri $VM.Id `
            -ErrorAction SilentlyContinue

        if ($Assoc)
        {
            $Associations += $Assoc
        }
    }
    catch
    {
    }
}

Write-Host "Total Associations Found: $($Associations.Count)"
Write-Host ""

#----------------------------------------------------------
# Export Existing Associations
#----------------------------------------------------------
$Associations |
Select-Object Name,
              ResourceId,
              DataCollectionRuleId |
Export-Csv `
    "$ReportFolder\DCR_Associations.csv" `
    -NoTypeInformation

#----------------------------------------------------------
# Find Duplicate Associations
#----------------------------------------------------------
Write-Host "Checking for duplicate associations..." -ForegroundColor Cyan

$Duplicates = $Associations |
Where-Object {
    $_.DataCollectionRuleId -eq $DCR.Id
} |
Group-Object ResourceId |
Where-Object {
    $_.Count -gt 1
}

if ($Duplicates)
{
    foreach ($Dup in $Duplicates)
    {
        Write-Host ""
        Write-Host "Duplicate found:" -ForegroundColor Yellow
        Write-Host $Dup.Name

        $Dup.Group |
        Select Name, ResourceId |
        Format-Table -AutoSize
    }
}
else
{
    Write-Host "No duplicate associations found." -ForegroundColor Green
}

#----------------------------------------------------------
# Remove Duplicate Associations
#----------------------------------------------------------
foreach ($Dup in $Duplicates)
{
    $RemoveList = $Dup.Group | Select-Object -Skip 1

    foreach ($Assoc in $RemoveList)
    {
        try
        {
            Write-Host "Removing duplicate association $($Assoc.Name)" `
                -ForegroundColor Yellow

            Remove-AzDataCollectionRuleAssociation `
                -AssociationName $Assoc.Name `
                -ResourceUri $Assoc.ResourceId `
                -Force `
                -ErrorAction Stop
        }
        catch
        {
            Write-Host "Failed to remove association $($Assoc.Name)" `
                -ForegroundColor Red
        }
    }
}

#----------------------------------------------------------
# Get Running VMs
#----------------------------------------------------------
Write-Host ""
Write-Host "Getting running VMs..." -ForegroundColor Cyan

$RunningVMs = Get-AzVM -Status |
Where-Object {
    $_.PowerState -eq "VM running"
}

Write-Host "Running VMs Found: $($RunningVMs.Count)"
Write-Host ""

#----------------------------------------------------------
# Add Running VMs to DCR
#----------------------------------------------------------
$Added = @()
$Skipped = @()
$Failed = @()

foreach ($VM in $RunningVMs)
{
    $RG = $VM.ResourceGroupName

    # Exclude resource groups
    $Exclude = $false

    foreach ($Pattern in $ExcludedRGs)
    {
        if ($RG -like $Pattern)
        {
            $Exclude = $true
            break
        }
    }

    if ($Exclude)
    {
        Write-Host "Skipping $($VM.Name) (Excluded RG: $RG)" `
            -ForegroundColor DarkYellow

        $Skipped += [PSCustomObject]@{
            VMName = $VM.Name
            ResourceGroup = $RG
            Reason = "Excluded Resource Group"
        }

        continue
    }

    Write-Host "Checking $($VM.Name)..."

    try
    {
        $Existing = Get-AzDataCollectionRuleAssociation `
            -ResourceUri $VM.Id `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DataCollectionRuleId -eq $DCR.Id
            }

        if ($Existing)
        {
            Write-Host "Already associated." `
                -ForegroundColor Yellow

            $Skipped += [PSCustomObject]@{
                VMName = $VM.Name
                ResourceGroup = $RG
                Reason = "Already Associated"
            }

            continue
        }

        $AssociationName = "dcr-$($VM.Name)"

        New-AzDataCollectionRuleAssociation `
            -AssociationName $AssociationName `
            -ResourceUri $VM.Id `
            -DataCollectionRuleId $DCR.Id `
            -ErrorAction Stop

        Write-Host "Added successfully." `
            -ForegroundColor Green

        $Added += [PSCustomObject]@{
            VMName = $VM.Name
            ResourceGroup = $RG
        }
    }
    catch
    {
        Write-Host "Failed : $($_.Exception.Message)" `
            -ForegroundColor Red

        $Failed += [PSCustomObject]@{
            VMName = $VM.Name
            ResourceGroup = $RG
            Error = $_.Exception.Message
        }
    }
}

#----------------------------------------------------------
# Export Reports
#----------------------------------------------------------
$Added |
Export-Csv `
    "$ReportFolder\AddedToDCR.csv" `
    -NoTypeInformation

$Skipped |
Export-Csv `
    "$ReportFolder\SkippedVMs.csv" `
    -NoTypeInformation

$Failed |
Export-Csv `
    "$ReportFolder\FailedVMs.csv" `
    -NoTypeInformation

Write-Host ""
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "DCR Processing Completed"
Write-Host "Added   : $($Added.Count)"
Write-Host "Skipped : $($Skipped.Count)"
Write-Host "Failed  : $($Failed.Count)"
Write-Host "Reports : $ReportFolder"
Write-Host "==================================" -ForegroundColor Cyan