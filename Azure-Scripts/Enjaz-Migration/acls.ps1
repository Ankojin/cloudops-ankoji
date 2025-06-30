# CONFIGURATION
$SharePath = "Y:\"  # <-- your mounted Azure File Share
$ReportPath = "C:\Temp\FSLogix-Permissions-Audit.csv"
$ExpectedRights = "FullControl"

# Initialize result list
$Results = @()

# Find all FSLogix VHDX files
$VHDXFiles = Get-ChildItem -Path $SharePath -Recurse -Filter "*.vhdx" -File -ErrorAction SilentlyContinue

foreach ($VHDX in $VHDXFiles) {
    $ParentFolder = Split-Path $VHDX.FullName -Parent
    $FolderName = Split-Path $ParentFolder -Leaf

    # Extract username and SID from folder name: Username_SID
    if ($FolderName -match "^(?<Username>.+)_(?<SID>S-1-5-.+)$") {
        $Username = $Matches['Username']
        $SID = $Matches['SID']
        $UserIdentity = "$env:USERDOMAIN\$Username"
    } else {
        $Username = "UNKNOWN"
        $SID = "UNKNOWN"
        $UserIdentity = "UNKNOWN"
    }

    # Track flags
    $MissingUser = $true
    $MissingSystem = $true
    $MissingAdmins = $true

    try {
        $ACL = Get-Acl $VHDX.FullName
        foreach ($Access in $ACL.Access) {
            if ($Access.IdentityReference -like "*$Username" -and $Access.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::$ExpectedRights) {
                $MissingUser = $false
            }
            if ($Access.IdentityReference -match "SYSTEM" -and $Access.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::$ExpectedRights) {
                $MissingSystem = $false
            }
            if ($Access.IdentityReference -match "Administrators" -and $Access.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::$ExpectedRights) {
                $MissingAdmins = $false
            }
        }

        $Results += [PSCustomObject]@{
            VHDXPath        = $VHDX.FullName
            Username        = $Username
            SID             = $SID
            Missing_User    = $MissingUser
            Missing_SYSTEM  = $MissingSystem
            Missing_Admins  = $MissingAdmins
            Notes           = if ($MissingUser -or $MissingSystem -or $MissingAdmins) { "❌ Fix Required" } else { "✅ OK" }
        }
    }
    catch {
        Write-Warning "Failed to read ACL for: $($VHDX.FullName)"
        $Results += [PSCustomObject]@{
            VHDXPath        = $VHDX.FullName
            Username        = $Username
            SID             = $SID
            Missing_User    = "ERROR"
            Missing_SYSTEM  = "ERROR"
            Missing_Admins  = "ERROR"
            Notes           = "❗ Error reading ACL"
        }
    }
}

# Export audit report
$Results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

Write-Host "`n✅ Audit complete."
Write-Host "📄 Results saved to: $ReportPath"