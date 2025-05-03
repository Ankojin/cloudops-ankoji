# Optional dry run mode
$dryRun = $false
$log = @()

# Load user data
Import-Csv "FilteredUsers.csv" | ForEach-Object {
    $name  = $_.DisplayName
    $upn   = $_.UserPrincipalName
    $first = $_.GivenName
    $last  = $_.Surname
    $sam   = ($upn.Split("@")[0])
    $ou    = "OU=MigratedUsers,DC=DomainB,DC=local"

    # Generate a secure random password
    $chars = 'abcdefghijklmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ123456789@#$%'
    $password = -join ((1..12) | ForEach-Object { $chars | Get-Random })

    # Check for existing user
    $existing = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "User $upn already exists. Skipping."
        $log += [PSCustomObject]@{
            DisplayName = $name
            UPN         = $upn
            Password    = "SKIPPED"
            Status      = "Already exists"
        }
        return
    }

    Write-Host "Creating user: $name ($upn)" -ForegroundColor Cyan

    if (-not $dryRun) {
        try {
            New-ADUser -Name $name `
                       -GivenName $first `
                       -Surname $last `
                       -UserPrincipalName $upn `
                       -SamAccountName $sam `
                       -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
                       -Enabled $true `
                       -Path $ou

            # Force password change at first logon (optional)
            Set-ADUser -Identity $upn -ChangePasswordAtLogon $true

            $log += [PSCustomObject]@{
                DisplayName = $name
                UPN         = $upn
                Password    = $password
                Status      = "Created"
            }
        } catch {
            Write-Error "Failed to create $upn: $_"
            $log += [PSCustomObject]@{
                DisplayName = $name
                UPN         = $upn
                Password    = "ERROR"
                Status      = "Error: $_"
            }
        }
    } else {
        $log += [PSCustomObject]@{
            DisplayName = $name
            UPN         = $upn
            Password    = "(Dry Run)"
            Status      = "Dry Run - Not created"
        }
    }
}

# Export log with passwords
$log | Export-Csv "UserCreationLog.csv" -NoTypeInformation
Write-Host "`n✅ Log saved to UserCreationLog.csv" -ForegroundColor Green