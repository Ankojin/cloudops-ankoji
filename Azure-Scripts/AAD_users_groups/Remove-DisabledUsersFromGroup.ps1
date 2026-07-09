<#
.SYNOPSIS
    Removes disabled Azure AD (Entra ID) users belonging to a specific domain from one or more groups.

.DESCRIPTION
    Connects to Microsoft Graph, iterates over all specified groups, enumerates members,
    filters for accounts that are disabled AND whose UserPrincipalName matches the specified domain,
    then removes them. Supports -WhatIf for dry-run validation.
    A single combined CSV report is produced covering all groups.

.PARAMETER GroupName
    One or more display names of Azure AD groups to process. Mutually exclusive with -GroupId.

.PARAMETER GroupId
    One or more Object IDs of Azure AD groups to process. Mutually exclusive with -GroupName.

.PARAMETER Domain
    Domain suffix to filter users (e.g. "contoso.com"). Only UPNs ending in @<Domain> are evaluated.

.PARAMETER OutputPath
    Optional path for the CSV report. Defaults to the script directory.

.PARAMETER WhatIf
    Dry-run mode: reports what would be removed without making any changes.

.EXAMPLE
    # Single group by name
    .\Remove-DisabledUsersFromGroup.ps1 -GroupName "VPN-Users" -Domain "bankalbilad.com.sa" -WhatIf

.EXAMPLE
    # Multiple groups by name
    .\Remove-DisabledUsersFromGroup.ps1 -GroupName "VPN-Users","ALB Test FSX Share Contributor","HR-Staff" -Domain "bankalbilad.com.sa"

.EXAMPLE
    # Multiple groups by Object ID
    .\Remove-DisabledUsersFromGroup.ps1 -GroupId "guid-1","guid-2" -Domain "bankalbilad.com.sa"

.EXAMPLE
    # With custom output path
    .\Remove-DisabledUsersFromGroup.ps1 -GroupName "VPN-Users","IT-Staff" -Domain "bankalbilad.com.sa" -OutputPath ".\Reports\"
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
param (
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$GroupName,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [string[]]$GroupId,

    [Parameter(Mandatory)]
    [string]$Domain,

    [Parameter()]
    [string]$OutputPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

#region ---------- Helpers ----------

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error   $line }
        default { Write-Host    $line }
    }
    # Use .NET directly so -WhatIf on the script does not suppress log writes
    [System.IO.File]::AppendAllText($script:LogFile, "$line`n", [System.Text.Encoding]::UTF8)
}

#endregion

#region ---------- Setup ----------

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile = Join-Path $OutputPath "RemoveDisabledUsers_$timestamp.log"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -WhatIf:$false | Out-Null
}

#endregion

#region ---------- Graph Connection ----------

# Requires Microsoft.Graph module: Install-Module Microsoft.Graph -Scope CurrentUser
$requiredScopes = @('GroupMember.ReadWrite.All', 'User.Read.All')

Write-Log "Connecting to Microsoft Graph (scopes: $($requiredScopes -join ', '))"
try {
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    Write-Log "Authenticated as: $($context.Account)"
}
catch {
    Write-Log -Level ERROR "Failed to connect to Microsoft Graph: $_"
    exit 1
}

#endregion

#region ---------- Resolve Groups ----------

$domainSuffix = "@$($Domain.TrimStart('@'))"
$results      = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalMembers = 0
$totalFound   = 0

# Build list of group identifiers to iterate
$groupIdentifiers = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $GroupName } else { $GroupId }

Write-Log "Groups to process: $($groupIdentifiers.Count)"

foreach ($groupIdentifier in $groupIdentifiers) {

    Write-Log "--- Resolving group: '$groupIdentifier' ---"

    try {
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $group = Get-MgGroup -Filter "displayName eq '$groupIdentifier'" -ConsistencyLevel eventual -ErrorAction Stop |
                     Select-Object -First 1
            if (-not $group) {
                Write-Log -Level WARN "No group found with displayName '$groupIdentifier' — skipping."
                continue
            }
        }
        else {
            $group = Get-MgGroup -GroupId $groupIdentifier -ErrorAction Stop
        }
    }
    catch {
        Write-Log -Level WARN "Error resolving group '$groupIdentifier': $_ — skipping."
        continue
    }

    Write-Log "Target group: '$($group.DisplayName)' [ID: $($group.Id)]"

    #region --- Enumerate Members ---
    try {
        $members = Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop
    }
    catch {
        Write-Log -Level WARN "Failed to retrieve members of '$($group.DisplayName)': $_ — skipping."
        continue
    }

    Write-Log "  Members found: $($members.Count)"
    $totalMembers += $members.Count
    #endregion

    #region --- Filter Disabled Users in Domain ---
    $toRemove = [System.Collections.Generic.List[object]]::new()

    Write-Log "  Filtering for disabled users with UPN ending in '$domainSuffix'..."

    foreach ($member in $members) {
        if ($member.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.user') { continue }

        $userId = $member.Id
        try {
            $user = Get-MgUser -UserId $userId -Property 'Id,DisplayName,UserPrincipalName,AccountEnabled' -ErrorAction Stop
        }
        catch {
            Write-Log -Level WARN "  Could not retrieve user $userId – skipping. Error: $_"
            continue
        }

        $upn = $user.UserPrincipalName
        if ($upn -notlike "*$domainSuffix") { continue }
        if ($user.AccountEnabled -ne $false)  { continue }

        Write-Log "  Found disabled user: $($user.DisplayName) [$upn]"
        $toRemove.Add($user)
    }

    Write-Log "  Disabled '$domainSuffix' users to remove from '$($group.DisplayName)': $($toRemove.Count)"
    $totalFound += $toRemove.Count
    #endregion

    #region --- Remove Members ---
    if ($toRemove.Count -eq 0) {
        Write-Log "  No matching disabled users in '$($group.DisplayName)'. Nothing to do."
    }
    else {
        foreach ($user in $toRemove) {
            $row = [PSCustomObject]@{
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                UserId            = $user.Id
                GroupName         = $group.DisplayName
                GroupId           = $group.Id
                Action            = ''
                Timestamp         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            }

            if ($PSCmdlet.ShouldProcess("$($user.DisplayName) [$($user.UserPrincipalName)]",
                                        "Remove from group '$($group.DisplayName)'")) {
                try {
                    Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                    Write-Log "  Removed: $($user.DisplayName) [$($user.UserPrincipalName)] from '$($group.DisplayName)'"
                    $row.Action = 'Removed'
                }
                catch {
                    Write-Log -Level ERROR "  Failed to remove $($user.UserPrincipalName) from '$($group.DisplayName)': $_"
                    $row.Action = "Error: $_"
                }
            }
            else {
                $row.Action = 'WhatIf - Would Remove'
            }

            $results.Add($row)
        }
    }
    #endregion

} # end foreach group

#endregion

#region ---------- Export Report ----------

$csvFile = Join-Path $OutputPath "RemoveDisabledUsers_$timestamp.csv"
if ($results.Count -gt 0) {
    $results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-Log "Report saved: $csvFile"
}

#endregion

#region ---------- Summary ----------

$removed = ($results | Where-Object { $_.Action -eq 'Removed' }).Count
$whatIf  = ($results | Where-Object { $_.Action -like 'WhatIf*' }).Count
$errors  = ($results | Where-Object { $_.Action -like 'Error*' }).Count

Write-Log "--- Summary ---"
Write-Log "  Groups processed                      : $($groupIdentifiers.Count)"
Write-Log "  Total group members evaluated         : $totalMembers"
Write-Log "  Disabled '$domainSuffix' users found : $totalFound"
Write-Log "  Successfully removed                  : $removed"
Write-Log "  WhatIf (would remove)                 : $whatIf"
Write-Log "  Errors                                : $errors"
Write-Log "  Log file                              : $script:LogFile"

Disconnect-MgGraph | Out-Null
Write-Log "Disconnected from Microsoft Graph."

#endregion
