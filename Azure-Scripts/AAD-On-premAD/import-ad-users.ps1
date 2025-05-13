param (
    [string]$CsvPath = "C:\AD-script\FilteredUsers.csv",
    [string]$LogPath = "C:\AD-script\UserCreationLog.csv",
    [string]$OuPath = "OU=MigratedUsers,DC=njztests,DC=com",
    [int]$PasswordLength = 12,
    [switch]$DryRun,
    [switch]$StopOnError,
    [string]$DomainController = $null
)

# Initialize
$log = @()
$passwordLogPath = "C:\AD-script\TempPasswords.csv"
$logDirectory = Split-Path $LogPath -Parent
$chars = 'abcdefghijklmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ123456789@#$%'.ToCharArray()

# Validate character set
if (-not $chars -or $chars.Count -eq 0) {
    Write-Error "Character set for password generation is empty."
    exit
}
Write-Host "Character Set Length: $($chars.Count)"

# Validate prerequisites
if (-Not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "ActiveDirectory module not found."
    exit
}
Import-Module ActiveDirectory

# Select domain controller
$dc = if ($DomainController) { $DomainController } else { (Get-ADDomain -Identity "njztests.com").PDCEmulator }
Write-Host "Primary Domain Controller: $dc"

if (-Not (Get-ADDomain -Identity "njztests.com" -Server $dc -ErrorAction SilentlyContinue)) {
    Write-Error "Domain njztests.com not found on $dc."
    exit
}

# Get list of domain controllers for debugging
$dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
Write-Host "Available Domain Controllers: $($dcs -join ', ')"

if (-Not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Force -Path $logDirectory
}
if (-Not (Test-Path $CsvPath)) {
    Write-Error "FilteredUsers.csv not found."
    exit
}

# Validate CSV headers
$csv = Import-Csv $CsvPath
$requiredColumns = @("DisplayName", "UserPrincipalName", "GivenName", "Surname")
$csvHeaders = $csv[0].PSObject.Properties.Name
Write-Host "CSV Headers: $($csvHeaders -join ', ')"
Write-Host "Row Count: $($csv.Count)"
if (-Not ($requiredColumns | ForEach-Object { $_ -in $csvHeaders })) {
    Write-Error "CSV missing required columns: $requiredColumns"
    exit
}

# Filter valid rows
$csv = $csv | Where-Object { $_.UserPrincipalName -and $_.UserPrincipalName -match "^[^@]+@[^@]+\.[^@]+" }
Write-Host "Valid Rows: $($csv.Count)"
if (-not $csv) {
    Write-Error "No valid rows with UPNs found in CSV."
    exit
}

# Validate OU
if (-Not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OuPath'" -Server $dc -ErrorAction SilentlyContinue)) {
    Write-Host "Creating OU $OuPath..." -ForegroundColor Yellow
    try {
        New-ADOrganizationalUnit -Name "MigratedUsers" -Path "DC=njztests,DC=com" -Server $dc -ErrorAction Stop
    } catch {
        Write-Error "Failed to create OU ${OuPath}: $($_.Exception.Message)"
        exit
    }
}

# Validate UPN suffixes
$validUpnSuffixes = (Get-ADForest -Server $dc).UPNSuffixes + "njztests.com"

# Process users
$csv | ForEach-Object {
    Write-Host "Processing: DisplayName=$($_.DisplayName), UPN=$($_.UserPrincipalName)"
    $name = $_.DisplayName
    $upn = $_.UserPrincipalName
    $first = $_.GivenName
    $last = $_.Surname
    $sam = if ($upn) { ($upn.Split("@")[0]) } else { "" }

    if (-not $upn) {
        Write-Warning "Skipping user with no UPN: $name"
        $log += [PSCustomObject]@{ DisplayName = $name; UPN = "N/A"; Password = "N/A"; Status = "No UPN" }
        return
    }

    # Validate UPN domain
    $upnDomain = $upn.Split("@")[1]
    if ($upnDomain -notin $validUpnSuffixes) {
        Write-Warning "UPN domain $upnDomain not valid for $upn. Skipping."
        $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "N/A"; Status = "Invalid UPN domain" }
        return
    }

    # Validate SamAccountName
    if ($sam.Length -gt 20) {
        Write-Warning "SamAccountName $sam exceeds 20 characters for $upn. Truncating."
        $sam = $sam.Substring(0, 20)
    }
    if ($sam -match '[^a-zA-Z0-9\-]') {
        Write-Warning "SamAccountName $sam contains invalid characters for $upn. Replacing with underscore."
        $sam = $sam -replace '[^a-zA-Z0-9\-]', '_'
    }

    try {
        $password = -join ((1..$PasswordLength) | ForEach-Object { $chars | Get-Random })
    } catch {
        Write-Error "Failed to generate password for ${upn}: $($_.Exception.Message)"
        $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "ERROR"; Status = "Password generation failed" }
        if ($StopOnError) { exit }
        return
    }

    $existing = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Server $dc -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Warning "User $upn already exists. Skipping."
        $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "SKIPPED"; Status = "Already exists" }
    } else {
        Write-Host "Creating user: $name ($upn)" -ForegroundColor Cyan
        Write-Host "Attributes: Name=$name, DisplayName=$name, SamAccountName=$sam, GivenName=$first, Surname=$last, Path=$OuPath"
        if (-not $DryRun) {
            try {
                New-ADUser -Name $name -DisplayName $name -GivenName $first -Surname $last -UserPrincipalName $upn `
                           -SamAccountName $sam -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
                           -Enabled $true -Path $OuPath -Server $dc -ErrorAction Stop
                # Log password immediately after user creation
                [PSCustomObject]@{ UPN = $upn; Password = $password; Status = "Created" } | Export-Csv -Path $passwordLogPath -Append -NoTypeInformation
                # Single attempt to verify user and log DisplayName
                try {
                    $newUser = Get-ADUser -Identity $upn -Server $dc -Properties DisplayName -ErrorAction Stop
                    Write-Host "User $upn verified on $dc. DisplayName: $($newUser.DisplayName)"
                } catch {
                    Write-Warning "Failed to verify $upn on $dc: $($_.Exception.Message). Proceeding with user creation."
                }
                # Set ChangePasswordAtLogon
                try {
                    Set-ADUser -Identity $upn -ChangePasswordAtLogon $true -Server $dc -ErrorAction Stop
                    $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "SECURE"; Status = "Created" }
                } catch {
                    Write-Warning "Failed to set ChangePasswordAtLogon for ${upn}: $($_.Exception.Message)"
                    $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "SECURE"; Status = "Created but ChangePasswordAtLogon failed: $($_.Exception.Message)" }
                }
            } catch {
                Write-Error "Failed to create ${upn}: $($_.Exception.Message)"
                $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "ERROR"; Status = "Error: $($_.Exception.Message)" }
                if ($StopOnError) { exit }
                return
            }
        } else {
            Write-Verbose "Dry Run: Would create $upn with SamAccountName $sam"
            $log += [PSCustomObject]@{ DisplayName = $name; UPN = $upn; Password = "(Dry Run)"; Status = "Dry Run - Not created" }
        }
    }
}

# Secure log file
$log | Export-Csv $LogPath -NoTypeInformation
$acl = Get-Acl $LogPath
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
$acl.AddAccessRule($rule)
Set-Acl -Path $LogPath -AclObject $acl

# Secure password log file
if (Test-Path $passwordLogPath) {
    $acl = Get-Acl $passwordLogPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $passwordLogPath -AclObject $acl
    Write-Host "⚠ Passwords saved to $passwordLogPath. Secure and delete after delivery." -ForegroundColor Yellow
}

Write-Host "`n✅ Log saved to $LogPath" -ForegroundColor Green