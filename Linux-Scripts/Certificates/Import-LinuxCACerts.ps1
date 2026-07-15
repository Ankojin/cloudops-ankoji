<#
.SYNOPSIS
    Import Root, Intermediate and Issuer CA certificates into RHEL Azure VMs.

.DESCRIPTION
    Deploys certificates using Azure VM Run Command.
    Supports RHEL 7.9, 8.x and 9.x.
    Performs certificate chain validation:
        Root CA -> Intermediate CA -> Issuer CA

    Creates backup before modification and rollback on failure.

.PARAMETER CertFolder
    Folder containing:
        RootCA.crt
        IntermediateCA.crt
        IssuerCA.crt

.PARAMETER CSVPath
    CSV file:
        SubscriptionId,ResourceGroupName,VMName

.PARAMETER LogPath
    Log folder

.EXAMPLE
    .\Import-LinuxCACerts.ps1
#>

[CmdletBinding()]
param(
    [string]$CertFolder = "$PSScriptRoot\Certs",
    [string]$CSVPath = "$PSScriptRoot\Servers.csv",
    [string]$LogPath = "$PSScriptRoot\Logs"
)

#------------------------------------------------------------
# Initialization
#------------------------------------------------------------

if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$LogFile = Join-Path $LogPath "CAImport-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$ReportFile = Join-Path $LogPath "CAImport-Report-$(Get-Date -Format yyyyMMdd-HHmmss).csv"


function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","ERROR","WARNING")]
        [string]$Level="INFO"
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Time][$Level] $Message"

    switch($Level)
    {
        "SUCCESS" { Write-Host $Entry -ForegroundColor Green }
        "ERROR"   { Write-Host $Entry -ForegroundColor Red }
        "WARNING" { Write-Host $Entry -ForegroundColor Yellow }
        default   { Write-Host $Entry }
    }

    Add-Content -Path $LogFile -Value $Entry
}


#------------------------------------------------------------
# Check Azure Module
#------------------------------------------------------------

function Initialize-Azure {

    Write-Log "Checking Azure PowerShell modules"

    try {

        if (!(Get-Module -ListAvailable -Name Az.Accounts)) {

            Write-Log "Installing Az module" "WARNING"

            Install-Module Az `
                -Scope CurrentUser `
                -Force `
                -AllowClobber
        }

        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Compute -ErrorAction Stop


        $ctx = Get-AzContext

        if (!$ctx) {

            Write-Log "Azure login required"

            Connect-AzAccount
        }

        $ctx = Get-AzContext

        Write-Log "Connected Azure Account: $($ctx.Account.Id)" "SUCCESS"

        return $true

    }
    catch {

        Write-Log "Azure initialization failed: $_" "ERROR"

        return $false
    }
}


#------------------------------------------------------------
# Certificate Validation
#------------------------------------------------------------

function Test-CertificateFiles {


    $Files = @(
        "RootCA.crt",
        "IntermediateCA.crt",
        "IssuerCA.crt"
    )


    foreach($file in $Files)
    {

        $path = Join-Path $CertFolder $file


        if(!(Test-Path $path))
        {
            Write-Log "Certificate missing: $path" "ERROR"
            return $false
        }


        $size=(Get-Item $path).Length

        if($size -eq 0)
        {
            Write-Log "Certificate empty: $path" "ERROR"
            return $false
        }


        Write-Log "Validated certificate file: $file"
    }


    return $true
}


function Get-CertBase64 {

    param(
        [string]$Path
    )


    return [Convert]::ToBase64String(
        [System.IO.File]::ReadAllBytes($Path)
    )

}


#------------------------------------------------------------
# Build Linux Script
#------------------------------------------------------------

function Get-LinuxCertificateScript {


param(
[string]$RootB64,
[string]$IntermediateB64,
[string]$IssuerB64
)


$script=@"

#!/bin/bash


ANCHOR_DIR="/etc/pki/ca-trust/source/anchors"
BACKUP_DIR="/root/ca_backup_`$(date +%Y%m%d%H%M%S)"
TEMP_DIR="/tmp/ca_import_`$`$"

trap 'rm -rf "`$TEMP_DIR"' EXIT

echo "Starting CA import"


mkdir -p "`$TEMP_DIR"
mkdir -p "`$BACKUP_DIR"


echo "$RootB64" | base64 -d > "`$TEMP_DIR/RootCA.crt"
echo "$IntermediateB64" | base64 -d > "`$TEMP_DIR/IntermediateCA.crt"
echo "$IssuerB64" | base64 -d > "`$TEMP_DIR/IssuerCA.crt"



echo "Checking certificate format and expiry"


openssl x509 \
-in "`$TEMP_DIR/RootCA.crt" \
-noout \
-subject \
-dates


openssl x509 \
-in "`$TEMP_DIR/IntermediateCA.crt" \
-noout \
-subject \
-dates


openssl x509 \
-in "`$TEMP_DIR/IssuerCA.crt" \
-noout \
-subject \
-dates


for cert in RootCA.crt IntermediateCA.crt IssuerCA.crt; do
  if ! openssl x509 -in "`$TEMP_DIR/`$cert" -noout -checkend 0 2>/dev/null; then
    echo "ERROR: `$cert has expired. Aborting."
    exit 1
  fi
done



echo "Backing up existing certificates"


for f in root-ca.crt intermediate-ca.crt issuer-ca.crt
do

 if [ -f "`$ANCHOR_DIR/`$f" ]; then

   cp "`$ANCHOR_DIR/`$f" "`$BACKUP_DIR/"

 fi

done



echo "Installing certificates"


cp "`$TEMP_DIR/RootCA.crt" \
"`$ANCHOR_DIR/root-ca.crt"


cp "`$TEMP_DIR/IntermediateCA.crt" \
"`$ANCHOR_DIR/intermediate-ca.crt"


cp "`$TEMP_DIR/IssuerCA.crt" \
"`$ANCHOR_DIR/issuer-ca.crt"


chmod 644 "`$ANCHOR_DIR/root-ca.crt" "`$ANCHOR_DIR/intermediate-ca.crt" "`$ANCHOR_DIR/issuer-ca.crt"



echo "Updating system trust"


update-ca-trust extract



echo "Validating certificate chain"


openssl verify \
-CAfile "`$TEMP_DIR/RootCA.crt" \
-untrusted "`$TEMP_DIR/IntermediateCA.crt" \
"`$TEMP_DIR/IssuerCA.crt" || {

  echo "Certificate chain validation failed"
  echo "Rolling back"

  rm -f "`$ANCHOR_DIR/root-ca.crt"
  rm -f "`$ANCHOR_DIR/intermediate-ca.crt"
  rm -f "`$ANCHOR_DIR/issuer-ca.crt"

  cp "`$BACKUP_DIR"/* "`$ANCHOR_DIR/" 2>/dev/null || true

  update-ca-trust extract

  exit 1

}


echo "CERTIFICATE_IMPORT_SUCCESS"


exit 0

"@


return $script

}
#------------------------------------------------------------
# Import Certificate To VM
#------------------------------------------------------------

function Import-CertificateToVM {

    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$LinuxScript
    )


    $resultObject = [PSCustomObject]@{
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        VMName            = $VMName
        Status            = "FAILED"
        Message           = ""
        Time              = (Get-Date)
    }


    try {

        Write-Log "Processing VM: $VMName"


        # Set subscription context before querying VM
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

        $vm = Get-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Name $VMName `
            -ErrorAction Stop



        if($vm.StorageProfile.OSDisk.OSType -ne "Linux")
        {

            $msg="VM is not Linux"

            Write-Log "$VMName : $msg" "ERROR"

            $resultObject.Message=$msg

            return $resultObject
        }



        Write-Log "Executing Azure Run Command on $VMName"


    $runResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VMName `
        -CommandId RunShellScript `
        -ScriptString $LinuxScript `
        -ErrorAction Stop

        $output = ""

        foreach($item in $runResult.Value)
        {
            $output += $item.Message
        }


        if($output -match "CERTIFICATE_IMPORT_SUCCESS")
        {

            Write-Log "$VMName certificate import successful" "SUCCESS"

            $resultObject.Status="SUCCESS"
            $resultObject.Message=$output

        }
        else
        {

            Write-Log "$VMName certificate import failed" "ERROR"

            Write-Log $output "ERROR"

            $resultObject.Message=$output

        }


    }
    catch {

        Write-Log "$VMName failed: $_" "ERROR"

        $resultObject.Message=$_.Exception.Message

    }


    return $resultObject

}



#------------------------------------------------------------
# CSV Validation
#------------------------------------------------------------

function Get-ServerList {


    if(!(Test-Path $CSVPath))
    {
        Write-Log "CSV not found: $CSVPath" "ERROR"
        throw "CSV not found: $CSVPath"
    }


    try {

        $servers = Import-Csv $CSVPath


        $required=@(
            "SubscriptionId",
            "ResourceGroupName",
            "VMName"
        )


        foreach($column in $required)
        {

            if($column -notin $servers[0].PSObject.Properties.Name)
            {

                Write-Log "Missing CSV column: $column" "ERROR"

                throw "Missing CSV column: $column"

            }

        }


        Write-Log "Loaded $($servers.Count) servers from CSV" "SUCCESS"


        return $servers


    }
    catch {

        Write-Log "CSV load failed: $_" "ERROR"

        throw
    }

}
#------------------------------------------------------------
# Main Execution
#------------------------------------------------------------


Write-Log "============================================"
Write-Log "Starting Linux CA Certificate Import"
Write-Log "============================================"


if(!(Initialize-Azure))
{
    exit 1
}



if(!(Test-CertificateFiles))
{
    exit 1
}



$RootCert = Get-CertBase64 `
    (Join-Path $CertFolder "RootCA.crt")


$IntermediateCert = Get-CertBase64 `
    (Join-Path $CertFolder "IntermediateCA.crt")


$IssuerCert = Get-CertBase64 `
    (Join-Path $CertFolder "IssuerCA.crt")



$LinuxScript = Get-LinuxCertificateScript `
    -RootB64 $RootCert `
    -IntermediateB64 $IntermediateCert `
    -IssuerB64 $IssuerCert



$Servers = Get-ServerList



$Results=@()



foreach($server in $Servers)
{

    $result = Import-CertificateToVM `
        -SubscriptionId $server.SubscriptionId `
        -ResourceGroupName $server.ResourceGroupName `
        -VMName $server.VMName `
        -LinuxScript $LinuxScript


    $Results += $result

}



$Results | Export-Csv `
    -Path $ReportFile `
    -NoTypeInformation



Write-Log "============================================"
Write-Log "Certificate Import Completed"
Write-Log "Report: $ReportFile"
Write-Log "============================================"


$Results | Format-Table -AutoSize