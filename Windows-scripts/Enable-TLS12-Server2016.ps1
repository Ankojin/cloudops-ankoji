Write-Host "Enabling TLS 1.2 for Server 2016..." -ForegroundColor Cyan

$base = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"

# TLS 1.2 – Client
New-Item "$base\TLS 1.2\Client" -Force | Out-Null
Set-ItemProperty "$base\TLS 1.2\Client" -Name Enabled -Value 1 -Type DWord
Set-ItemProperty "$base\TLS 1.2\Client" -Name DisabledByDefault -Value 0 -Type DWord

# TLS 1.2 – Server
New-Item "$base\TLS 1.2\Server" -Force | Out-Null
Set-ItemProperty "$base\TLS 1.2\Server" -Name Enabled -Value 1 -Type DWord
Set-ItemProperty "$base\TLS 1.2\Server" -Name DisabledByDefault -Value 0 -Type DWord

# Disable SSL 3.0
New-Item "$base\SSL 3.0\Server" -Force | Out-Null
Set-ItemProperty "$base\SSL 3.0\Server" -Name Enabled -Value 0 -Type DWord

Write-Warning "Reboot REQUIRED for TLS changes to take effect"