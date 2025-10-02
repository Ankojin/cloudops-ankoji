# Path to your PFX
$pfxPath = "C:\cert\albtest-ldaps\albwc.pfx"

# Convert to Base64 string
$base64Pfx = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pfxPath))

# Optional: output to file
$base64Pfx | Out-File -FilePath "C:\cert\albtest-ldaps\albwc-base64.txt"
