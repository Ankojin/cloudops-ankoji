param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Write-Host "🔧 Setting up helper functions..."

# Create helper functions content
$functionsContent = @'
function Format-VMNames {
    param([string]$vmNamesString)
    
    if ([string]::IsNullOrWhiteSpace($vmNamesString)) {
        return ""
    }
    
    $vmNames = $vmNamesString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    
    if ($vmNames.Count -eq 0) {
        return ""
    }
    
    return ($vmNames -join ',')
}

function Get-SubscriptionId {
    param([string]$SubscriptionName)
    
    $subId = ""
    switch ($SubscriptionName.Trim()) {
        "BAB_DEV" {
            $subId = $env:BAB_DEV_SUBSCRIPTION_ID -replace '"', ''
        }
        "BAB_SIT" {
            $subId = $env:BAB_SIT_SUBSCRIPTION_ID -replace '"', ''
        }
        "BAB_CORE" {
            $subId = $env:BAB_CORE_SUBSCRIPTION_ID -replace '"', ''
        }
        default {
            return $null
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($subId)) {
        return $null
    }
    
    return $subId
}
'@

# Write functions to output file
$functionsContent | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "✅ Helper functions created at $OutputPath"