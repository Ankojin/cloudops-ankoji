# -------------------------------
# Script: Add-UsersAndGroupsToFSLogixExclusion-Remote.ps1
# Purpose: Add domain users and groups to FSLogix Exclude List on remote session hosts using credentials
# -------------------------------

# Path to text file containing session host IPs or hostnames (one per line)
$HostsFile = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Windows-scripts\avdips.txt"

# List of domain users/groups to add
$DomainUsersAndGroups = @(
    'albtests\BAB Cloud Admins',  # Domain group
    'albtests\admin03'            # Individual user
)

# Local FSLogix group
$LocalGroup = "FSLogix Profile Exclude List"

# Prompt for credentials to connect to remote session hosts
$Cred = Get-Credential -Message "Enter credentials with local admin rights on the session hosts"

# Read hosts from file
$SessionHosts = Get-Content -Path $HostsFile

foreach ($SessionHost in $SessionHosts) {
    Write-Host "`nProcessing host: $SessionHost" -ForegroundColor Cyan

    Invoke-Command -ComputerName $SessionHost -Credential $Cred -ScriptBlock {
        param($LocalGroup, $Entries)

        # Check if the local FSLogix group exists
        $group = Get-LocalGroup -Name $LocalGroup -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "Local group '$LocalGroup' not found. FSLogix may not be installed."
            return
        }

        foreach ($entry in $Entries) {
            try {
                Add-LocalGroupMember -Group $LocalGroup -Member $entry -ErrorAction Stop
                Write-Host "Successfully added $entry to '$LocalGroup'" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to add $entry. It may already be a member or the name is incorrect."
            }
        }

        # Optional: list current members
        Write-Host "`nCurrent members of '$LocalGroup':" -ForegroundColor Cyan
        Get-LocalGroupMember -Group $LocalGroup
    } -ArgumentList $LocalGroup, $DomainUsersAndGroups -ErrorAction Continue
}