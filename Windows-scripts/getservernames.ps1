# Path to your IP list
$ipListPath = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Windows-scripts\serverips.txt"
# Optional: output CSV
$outputCsv = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\Windows-scripts\results.csv"

# Credential prompt
$cred = Get-Credential

# Read IPs
$ips = Get-Content $ipListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

$results = foreach ($ip in $ips) {
    try {
        # Query WMI for computer name
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ip -Credential $cred -ErrorAction Stop
        [PSCustomObject]@{
            IP   = $ip
            Name = $cs.Name
        }
    } catch {
        [PSCustomObject]@{
            IP   = $ip
            Name = "Failed: $_"
        }
    }
}

# Display results
$results | Format-Table -AutoSize

# Export to CSV
$results | Export-Csv -Path $outputCsv -NoTypeInformation -Force