# Install Microsoft Graph if not already installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Group.ReadWrite.All","User.Read.All"

# Import CSVs and remove completely blank rows
$groups = Import-Csv "C:\Ankoji\scripts\groups-abic.csv" | Where-Object { $_.GroupName -and $_.GroupName.Trim() -ne "" }
$users  = Import-Csv "C:\Ankoji\scripts\abic-users-upn.csv"

# Prepare log array
$log = @()

foreach ($g in $groups) {
    $groupName = $g.GroupName.Trim()

    # Find the group
    $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Warning "Group not found: ${groupName}"
        foreach ($u in $users) {
            if ($u.PSObject.Properties.Match('UserPrincipalName') -and $u.UserPrincipalName) {
                $log += [PSCustomObject]@{
                    GroupName = $groupName
                    UserUPN   = $u.UserPrincipalName.Trim()
                    Status    = "Group not found"
                }
            }
        }
        continue
    }

    $groupId = $group.Id

    # Get existing members once
    $existingMembers = (Get-MgGroupMember -GroupId $groupId -All).Id

    foreach ($u in $users) {
        # Skip if property is missing or null/empty
        if (-not $u.PSObject.Properties.Match('UserPrincipalName') -or -not $u.UserPrincipalName) {
            continue
        }

        $upn = $u.UserPrincipalName.Trim()
        if (-not $upn) { continue }

        try {
            $user = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
            if (-not $user) {
                Write-Warning "User not found: ${upn}"
                $log += [PSCustomObject]@{
                    GroupName = $groupName
                    UserUPN   = $upn
                    Status    = "User not found"
                }
                continue
            }

            if ($user.Id -notin $existingMembers) {
                New-MgGroupMemberByRef -GroupId $groupId -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"
                Write-Host "Added ${upn} to ${groupName}"
                $log += [PSCustomObject]@{
                    GroupName = $groupName
                    UserUPN   = $upn
                    Status    = "Added"
                }
            }
            else {
                Write-Host "${upn} already in ${groupName}"
                $log += [PSCustomObject]@{
                    GroupName = $groupName
                    UserUPN   = $upn
                    Status    = "Already member"
                }
            }
        }
        catch {
            Write-Warning "Error adding ${upn} to ${groupName}: $_"
            $log += [PSCustomObject]@{
                GroupName = $groupName
                UserUPN   = $upn
                Status    = "Error"
            }
        }
    }
}

# Export log to CSV
$log | Export-Csv "C:\Ankoji\scripts\group-members-log.csv" -NoTypeInformation -Encoding UTF8
Write-Host "✅ Log exported to C:\Ankoji\scripts\group-members-log.csv"
