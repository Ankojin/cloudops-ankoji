#requires -Version 5.1

<#
.SYNOPSIS
    Read-only inventory collector for Azure Local + AKS on Azure Local + Azure Arc.

.DESCRIPTION
    Collects Azure, Azure Local, AKS Arc, Azure Arc, Kubernetes and
    local Azure Local information.

    IMPORTANT:
      - READ ONLY
      - Does NOT modify Azure resources
      - Does NOT modify Kubernetes
      - Does NOT renew certificates
      - Does NOT restart services
      - Does NOT collect secrets/tokens from kubeconfig

.NOTES
    Recommended execution:
      PowerShell as Administrator

    Azure CLI:
      az login

    Expected extensions:
      connectedk8s
      aksarc
      stack-hci
      stack-hci-vm
      customlocation
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "",

    [string]$ResourceGroup = "BAB-Azl-AKS-KSA-rg-01",

    [string]$AksClusterName = "BAB-Azl-AKS-KSA-01",

    [string]$OutputRoot = "C:\On-Prem-to-cloud-migration\New-Repo\BAB_CloudOps\BAB_CloudOps-Ankoji\azurelocal\AzureLocal-AKS-Toolkit\Inventory-Output",

    # Applied as --request-timeout to every kubectl call that talks to the
    # API server. Without this, kubectl can hang indefinitely (well beyond
    # any predictable TCP timeout) when a connection is established through
    # a broken Arc proxy/TLS tunnel but never responds. This is what causes
    # the script to appear "stuck" after the API reachability test.
    [ValidateRange(1, 300)]
    [int]$KubectlTimeoutSeconds = 15
)

$KubectlTimeout = "--request-timeout=$($KubectlTimeoutSeconds)s"

# ============================================================
# INITIALIZATION
# ============================================================

$ErrorActionPreference = "Continue"

$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"

$OutputDir = Join-Path $OutputRoot $TimeStamp

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$LogFile = Join-Path $OutputDir "Inventory.log"
$JsonFile = Join-Path $OutputDir "AzureLocal-AKS-Inventory.json"
$SummaryFile = Join-Path $OutputDir "AzureLocal-AKS-Summary.txt"

Start-Transcript -Path $LogFile -Append | Out-Null

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Section {
    param(
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-Info {
    param(
        [string]$Message
    )

    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-OK {
    param(
        [string]$Message
    )

    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param(
        [string]$Message
    )

    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrMsg {
    param(
        [string]$Message
    )

    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    try {

        # Call operator with a real argument array — never build a command
        # string and hand it to Invoke-Expression. That approach depends on
        # backtick line-continuation being the LAST character on the line
        # with zero trailing whitespace; any stray trailing space (easy to
        # introduce via copy/paste or an editor) silently breaks the
        # continuation, and a leading "--" on the next "line" then parses
        # as the unary decrement operator instead of two literal dashes.
        # An argument array sidesteps that whole class of bug and also
        # avoids quoting/injection issues with resource names.
        $result = & az @Arguments 2>$null

        if ([string]::IsNullOrWhiteSpace(($result | Out-String))) {
            return $null
        }

        return ($result | Out-String | ConvertFrom-Json)

    }
    catch {
        return $null
    }
}

function Invoke-AzText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    try {
        return (& az @Arguments 2>$null)
    }
    catch {
        return $null
    }
}

function Save-Json {
    param(
        [object]$Data,
        [string]$FileName
    )

    if ($null -eq $Data) {
        return
    }

    try {
        $Data |
            ConvertTo-Json -Depth 30 |
            Out-File -FilePath (Join-Path $OutputDir $FileName) -Encoding utf8
    }
    catch {
        Write-WarnMsg "Unable to save $FileName"
    }
}

# ============================================================
# INVENTORY OBJECT
# ============================================================

$Inventory = [ordered]@{

    Collection = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Computer  = $env:COMPUTERNAME
        User      = "$env:USERDOMAIN\$env:USERNAME"
        PowerShell = $PSVersionTable.PSVersion.ToString()
    }

    Azure = [ordered]@{}

    AzureLocal = [ordered]@{}

    AKSArc = [ordered]@{}

    ConnectedK8s = [ordered]@{}

    CustomLocations = @()

    ArcResourceBridge = @()

    Extensions = @()

    Kubernetes = [ordered]@{}

    LocalSystem = [ordered]@{}

    Network = [ordered]@{}

    Storage = [ordered]@{}

    Certificates = @()

    Health = [ordered]@{}
}

# ============================================================
# CHECK AZ CLI
# ============================================================

Write-Section "AZURE CLI"

# NOTE: Do NOT look up "az.exe" specifically. On a standard Windows MSI
# install, the PATH entry point is "az.cmd" (a wrapper), and Get-Command
# with an explicit .exe extension will not resolve it via PATHEXT, causing
# a false negative even when Azure CLI is fully functional. Look up "az"
# without an extension so normal PATHEXT resolution (.COM/.EXE/.BAT/.CMD/.PS1)
# applies, and fall back to Get-Module -ListAvailable / direct execution as
# a functional check.

$AzCommand = Get-Command az -ErrorAction SilentlyContinue

if ($null -eq $AzCommand) {

    Write-ErrMsg "Azure CLI not found in PATH."

    Write-Info "If Azure CLI is installed, confirm its install directory is in"
    Write-Info "your PATH environment variable, then open a new PowerShell session."
    Write-Info "Typical install path:"
    Write-Info "  C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
    Write-Info "Install/upgrade from:"
    Write-Info "  https://aka.ms/installazurecliwindows"

    Stop-Transcript | Out-Null

    exit 1
}

Write-Info "Resolved az command: $($AzCommand.Source)"

# Functional check: Get-Command finding the file doesn't guarantee it runs
# (e.g. broken install, missing runtime). Confirm with a real invocation.
$AzVersion = Invoke-AzJson -Arguments @("version", "-o", "json")

if ($null -eq $AzVersion) {

    Write-ErrMsg "Azure CLI was found at $($AzCommand.Source) but did not respond to 'az version'."
    Write-Info "Try running 'az version' manually to see the underlying error."

    Stop-Transcript | Out-Null

    exit 1
}

$Inventory.Azure.AzureCliVersion = $AzVersion

Write-OK "Azure CLI detected"

# ============================================================
# AZURE LOGIN / ACCOUNT
# ============================================================

Write-Section "AZURE ACCOUNT"

$Account = Invoke-AzJson -Arguments @("account", "show", "-o", "json")

if ($null -eq $Account) {

    Write-ErrMsg "Azure CLI is not logged in."

    Write-Info "Run:"
    Write-Host "az login"

}
else {

    $Inventory.Azure.SubscriptionId = $Account.id
    $Inventory.Azure.SubscriptionName = $Account.name
    $Inventory.Azure.TenantId = $Account.tenantId
    $Inventory.Azure.User = $Account.user

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {

        Write-Info "Setting subscription to $SubscriptionId"

        az account set --subscription $SubscriptionId

        $Account = Invoke-AzJson -Arguments @("account", "show", "-o", "json")

        $Inventory.Azure.SubscriptionId = $Account.id
        $Inventory.Azure.SubscriptionName = $Account.name
        $Inventory.Azure.TenantId = $Account.tenantId
    }

    Write-OK "Azure login detected"
    Write-Info "Subscription : $($Inventory.Azure.SubscriptionName)"
    Write-Info "Subscription ID : $($Inventory.Azure.SubscriptionId)"
    Write-Info "Tenant ID : $($Inventory.Azure.TenantId)"
}

# ============================================================
# AZURE RESOURCE GROUP
# ============================================================

Write-Section "RESOURCE GROUP"

$Rg = Invoke-AzJson -Arguments @("group", "show", "--name", $ResourceGroup, "-o", "json")

if ($null -eq $Rg) {

    Write-WarnMsg "Resource group not found or inaccessible: $ResourceGroup"

}
else {

    $Inventory.AzureLocal.ResourceGroup = $Rg

    Write-OK "Resource group found"
}

# ============================================================
# AZURE LOCAL CLUSTERS
# ============================================================

Write-Section "AZURE LOCAL CLUSTERS"

$HciClusters = Invoke-AzJson -Arguments @(
    "stack-hci", "cluster", "list",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -eq $HciClusters) {

    Write-WarnMsg "Unable to retrieve Azure Local clusters using stack-hci."

}
else {

    $Inventory.AzureLocal.Clusters = $HciClusters

    Save-Json $HciClusters "AzureLocal-Clusters.json"

    Write-OK "Azure Local cluster information collected"

    foreach ($Cluster in @($HciClusters)) {

        Write-Host "  Cluster: $($Cluster.name)"
        Write-Host "  Location: $($Cluster.location)"
        Write-Host "  State: $($Cluster.provisioningState)"
    }
}

# ============================================================
# AZURE LOCAL RESOURCE SEARCH
# ============================================================

Write-Section "AZURE LOCAL RESOURCES"

$AzureLocalResources = Invoke-AzJson -Arguments @(
    "resource", "list",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $AzureLocalResources) {

    $Inventory.AzureLocal.Resources = $AzureLocalResources

    Save-Json $AzureLocalResources "Azure-Resource-Inventory.json"

    Write-OK "Azure resource inventory collected"

    $ResourceTypes = @(
        "Microsoft.AzureStackHCI/clusters",
        "Microsoft.AzureStackHCI/virtualMachines",
        "Microsoft.AzureStackHCI/networkInterfaces",
        "Microsoft.AzureStackHCI/storagecontainers",
        "Microsoft.Kubernetes/connectedClusters",
        "Microsoft.KubernetesConfiguration/extensions",
        "Microsoft.ExtendedLocation/customLocations",
        "Microsoft.ResourceConnector/appliances"
    )

    foreach ($Type in $ResourceTypes) {

        $Count = @(
            $AzureLocalResources |
            Where-Object {
                $_.type -ieq $Type
            }
        ).Count

        Write-Host ("  {0,-55} {1}" -f $Type, $Count)
    }
}

# ============================================================
# CONNECTED KUBERNETES
# ============================================================

Write-Section "AZURE ARC - CONNECTED KUBERNETES"

$ConnectedClusters = Invoke-AzJson -Arguments @(
    "connectedk8s", "list",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $ConnectedClusters) {

    $Inventory.ConnectedK8s.Clusters = $ConnectedClusters

    Save-Json $ConnectedClusters "ConnectedK8s-Clusters.json"

    Write-OK "Connected Kubernetes resources collected"

    foreach ($Cluster in @($ConnectedClusters)) {

        Write-Host ""
        Write-Host "  Name              : $($Cluster.name)"
        Write-Host "  Location          : $($Cluster.location)"
        Write-Host "  Connectivity      : $($Cluster.connectivityStatus)"
        Write-Host "  Kubernetes        : $($Cluster.kubernetesVersion)"
        Write-Host "  Agent Version     : $($Cluster.agentVersion)"
        Write-Host "  Last Connectivity : $($Cluster.lastConnectivityTime)"
    }
}

# ============================================================
# TARGET CONNECTED CLUSTER
# ============================================================

Write-Section "TARGET CONNECTED CLUSTER"

$ConnectedCluster = Invoke-AzJson -Arguments @(
    "connectedk8s", "show",
    "--name", $AksClusterName,
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $ConnectedCluster) {

    $Inventory.ConnectedK8s.TargetCluster = $ConnectedCluster

    Save-Json $ConnectedCluster "ConnectedK8s-Target.json"

    Write-OK "Target Connected Cluster found"

    Write-Host ""
    Write-Host "  Name                    : $($ConnectedCluster.name)"
    Write-Host "  Connectivity             : $($ConnectedCluster.connectivityStatus)"
    Write-Host "  Provisioning State       : $($ConnectedCluster.provisioningState)"
    Write-Host "  Kubernetes Version       : $($ConnectedCluster.kubernetesVersion)"
    Write-Host "  Agent Version            : $($ConnectedCluster.agentVersion)"
    Write-Host "  Node Count               : $($ConnectedCluster.totalNodeCount)"
    Write-Host "  Core Count               : $($ConnectedCluster.totalCoreCount)"
    Write-Host "  Infrastructure           : $($ConnectedCluster.infrastructure)"
    Write-Host "  Offering                 : $($ConnectedCluster.offering)"
    Write-Host "  Managed Identity Expiry  : $($ConnectedCluster.managedIdentityCertificateExpirationTime)"
}

# ============================================================
# AKS ARC CLUSTER
# ============================================================

Write-Section "AKS ARC"

$AksCluster = Invoke-AzJson -Arguments @(
    "aksarc", "show",
    "--name", $AksClusterName,
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -eq $AksCluster) {

    Write-WarnMsg "Unable to retrieve AKS Arc cluster."

}
else {

    $Inventory.AKSArc.Cluster = $AksCluster

    Save-Json $AksCluster "AKSArc-Cluster.json"

    Write-OK "AKS Arc cluster information collected"

    Write-Host ""
    Write-Host "  Name                 : $($AksCluster.name)"
    Write-Host "  Provisioning State   : $($AksCluster.provisioningState)"
    Write-Host "  Kubernetes Version   : $($AksCluster.kubernetesVersion)"
    Write-Host "  Location             : $($AksCluster.location)"
}

# ============================================================
# AKS ARC LIST
# ============================================================

$AksClusters = Invoke-AzJson -Arguments @(
    "aksarc", "list",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $AksClusters) {

    $Inventory.AKSArc.Clusters = $AksClusters

    Save-Json $AksClusters "AKSArc-All-Clusters.json"

    Write-OK "All AKS Arc clusters collected"
}

# ============================================================
# AKS NODE POOLS
# ============================================================

Write-Section "AKS NODE POOLS"

$NodePools = Invoke-AzJson -Arguments @(
    "aksarc", "nodepool", "list",
    "--cluster-name", $AksClusterName,
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $NodePools) {

    $Inventory.AKSArc.NodePools = $NodePools

    Save-Json $NodePools "AKSArc-NodePools.json"

    Write-OK "Node pool information collected"
}

# ============================================================
# AKS VERSIONS
# ============================================================

Write-Section "AKS VERSIONS"

$AksVersions = Invoke-AzJson -Arguments @(
    "aksarc", "get-versions",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $AksVersions) {

    $Inventory.AKSArc.SupportedVersions = $AksVersions

    Save-Json $AksVersions "AKSArc-Supported-Versions.json"

    Write-OK "Supported Kubernetes versions collected"
}

# ============================================================
# CUSTOM LOCATIONS
# ============================================================

Write-Section "CUSTOM LOCATIONS"

$CustomLocations = Invoke-AzJson -Arguments @(
    "customlocation", "list",
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $CustomLocations) {

    $Inventory.CustomLocations = $CustomLocations

    Save-Json $CustomLocations "CustomLocations.json"

    Write-OK "Custom Locations collected"

    foreach ($Location in @($CustomLocations)) {

        Write-Host "  Name  : $($Location.name)"
        Write-Host "  State : $($Location.provisioningState)"
    }
}

# ============================================================
# ARC RESOURCE BRIDGE
# ============================================================

Write-Section "ARC RESOURCE BRIDGE"

$Appliances = Invoke-AzJson -Arguments @(
    "resource", "list",
    "--resource-group", $ResourceGroup,
    "--resource-type", "Microsoft.ResourceConnector/appliances",
    "-o", "json"
)

if ($null -ne $Appliances) {

    $Inventory.ArcResourceBridge = $Appliances

    Save-Json $Appliances "Arc-ResourceBridge.json"

    Write-OK "Arc Resource Bridge resources collected"

    foreach ($Appliance in @($Appliances)) {

        Write-Host "  Name  : $($Appliance.name)"
        Write-Host "  State : $($Appliance.provisioningState)"
    }
}

# ============================================================
# AZURE LOCAL EXTENSIONS
# ============================================================

Write-Section "AZURE LOCAL ARC EXTENSIONS"

$Extensions = Invoke-AzJson -Arguments @(
    "stack-hci", "extension", "list",
    "--arc-setting-name", "default",
    "--cluster-name", $AksClusterName,
    "--resource-group", $ResourceGroup,
    "-o", "json"
)

if ($null -ne $Extensions) {

    $Inventory.Extensions = $Extensions

    Save-Json $Extensions "AzureLocal-Extensions.json"

    Write-OK "Azure Local extensions collected"
}

# ============================================================
# KUBERNETES CONFIGURATION
# ============================================================

Write-Section "KUBERNETES"

$Kubectl = Get-Command kubectl -ErrorAction SilentlyContinue

if ($null -eq $Kubectl) {

    Write-WarnMsg "kubectl not found in PATH."

}
else {

    $KubectlVersion = kubectl version --client -o json 2>$null

    $Inventory.Kubernetes.KubectlVersion = $KubectlVersion

    Write-OK "kubectl detected"

    $CurrentContext = kubectl config current-context 2>$null

    $Inventory.Kubernetes.CurrentContext = $CurrentContext

    Write-Info "Current context: $CurrentContext"

    # --------------------------------------------------------
    # DO NOT COLLECT --raw KUBECONFIG
    # --------------------------------------------------------
    # This intentionally avoids collecting credentials/secrets.

    $ClusterInfo = kubectl config view --minify -o json 2>$null

    if ($null -ne $ClusterInfo) {

        $Inventory.Kubernetes.KubeConfig = $ClusterInfo

        Save-Json $ClusterInfo "Kubernetes-KubeConfig-Metadata.json"
    }

    # --------------------------------------------------------
    # API SERVER TEST
    # --------------------------------------------------------

    Write-Info "Testing Kubernetes API (timeout: $($KubectlTimeoutSeconds)s)..."

    $KubeVersion = kubectl version -o json $KubectlTimeout 2>&1

    $Inventory.Kubernetes.VersionTest = $KubeVersion

    $ApiReachable = ($LASTEXITCODE -eq 0)

    if ($ApiReachable) {

        Write-OK "Kubernetes API reachable"

    }
    else {

        Write-WarnMsg "Kubernetes API is NOT reachable (or timed out after $($KubectlTimeoutSeconds)s)."
        Write-WarnMsg "This is expected if the current Arc proxy/TLS problem is still present."
        Write-WarnMsg "Skipping remaining kubectl calls to avoid hanging on the same broken connection."
    }

    if ($ApiReachable) {

        # --------------------------------------------------------
        # NODES
        # --------------------------------------------------------

        $Nodes = kubectl get nodes -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.Nodes = $Nodes

        Save-Json $Nodes "Kubernetes-Nodes.json"

        # --------------------------------------------------------
        # PODS
        # --------------------------------------------------------

        $Pods = kubectl get pods -A -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.Pods = $Pods

        Save-Json $Pods "Kubernetes-Pods.json"

        # --------------------------------------------------------
        # NAMESPACES
        # --------------------------------------------------------

        $Namespaces = kubectl get namespaces -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.Namespaces = $Namespaces

        Save-Json $Namespaces "Kubernetes-Namespaces.json"

        # --------------------------------------------------------
        # SERVICES
        # --------------------------------------------------------

        $Services = kubectl get services -A -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.Services = $Services

        Save-Json $Services "Kubernetes-Services.json"

        # --------------------------------------------------------
        # DAEMONSETS
        # --------------------------------------------------------

        $DaemonSets = kubectl get daemonsets -A -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.DaemonSets = $DaemonSets

        Save-Json $DaemonSets "Kubernetes-DaemonSets.json"

        # --------------------------------------------------------
        # DEPLOYMENTS
        # --------------------------------------------------------

        $Deployments = kubectl get deployments -A -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.Deployments = $Deployments

        Save-Json $Deployments "Kubernetes-Deployments.json"

        # --------------------------------------------------------
        # STORAGE
        # --------------------------------------------------------

        $StorageClasses = kubectl get storageclass -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.StorageClasses = $StorageClasses

        Save-Json $StorageClasses "Kubernetes-StorageClasses.json"

        $PVCs = kubectl get pvc -A -o json $KubectlTimeout 2>&1

        $Inventory.Kubernetes.PersistentVolumeClaims = $PVCs

        Save-Json $PVCs "Kubernetes-PVCs.json"

    }
    else {

        $Inventory.Kubernetes.Nodes = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.Pods = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.Namespaces = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.Services = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.DaemonSets = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.Deployments = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.StorageClasses = "SKIPPED - API unreachable"
        $Inventory.Kubernetes.PersistentVolumeClaims = "SKIPPED - API unreachable"
    }
}

# ============================================================
# LOCAL SYSTEM
# ============================================================

Write-Section "LOCAL WINDOWS SYSTEM"

$ComputerSystem = Get-CimInstance Win32_ComputerSystem

$OS = Get-CimInstance Win32_OperatingSystem

$Inventory.LocalSystem.ComputerSystem = $ComputerSystem |
    Select-Object Manufacturer,
                  Model,
                  Domain,
                  NumberOfLogicalProcessors,
                  TotalPhysicalMemory

$Inventory.LocalSystem.OS = $OS |
    Select-Object Caption,
                  Version,
                  BuildNumber,
                  LastBootUpTime

$Inventory.LocalSystem.PowerShell = $PSVersionTable

Save-Json $Inventory.LocalSystem "Local-System.json"

Write-OK "Local Windows system information collected"

# ============================================================
# LOCAL NETWORK
# ============================================================

Write-Section "LOCAL NETWORK"

$Adapters = Get-NetAdapter |
    Select-Object Name,
                  InterfaceDescription,
                  Status,
                  MacAddress,
                  LinkSpeed

$IPConfiguration = Get-NetIPConfiguration |
    Select-Object InterfaceAlias,
                  InterfaceIndex,
                  IPv4Address,
                  IPv6Address,
                  DNSServer,
                  NetProfile

$Routes = Get-NetRoute |
    Select-Object DestinationPrefix,
                  NextHop,
                  InterfaceAlias,
                  RouteMetric

$Inventory.Network.Adapters = $Adapters
$Inventory.Network.IPConfiguration = $IPConfiguration
$Inventory.Network.Routes = $Routes

Save-Json $Inventory.Network "Local-Network.json"

Write-OK "Local network information collected"

# ============================================================
# LOCAL STORAGE
# ============================================================

Write-Section "LOCAL STORAGE"

$Disks = Get-Disk |
    Select-Object Number,
                  FriendlyName,
                  SerialNumber,
                  BusType,
                  OperationalStatus,
                  HealthStatus,
                  Size

$Volumes = Get-Volume |
    Select-Object DriveLetter,
                  FileSystem,
                  FileSystemLabel,
                  HealthStatus,
                  Size,
                  SizeRemaining

$Inventory.Storage.Disks = $Disks
$Inventory.Storage.Volumes = $Volumes

Save-Json $Inventory.Storage "Local-Storage.json"

Write-OK "Local storage information collected"

# ============================================================
# CERTIFICATE INFORMATION
# ============================================================

Write-Section "CERTIFICATE CHECK"

$CertificateStores = @(
    "Cert:\LocalMachine\My",
    "Cert:\LocalMachine\Root",
    "Cert:\LocalMachine\CA"
)

$Certificates = @()

foreach ($Store in $CertificateStores) {

    try {

        $Certs = Get-ChildItem $Store -ErrorAction Stop

        foreach ($Cert in $Certs) {

            $Certificates += [PSCustomObject]@{
                Store       = $Store
                Subject     = $Cert.Subject
                Issuer      = $Cert.Issuer
                Thumbprint  = $Cert.Thumbprint
                NotBefore   = $Cert.NotBefore
                NotAfter    = $Cert.NotAfter
                HasExpired  = ($Cert.NotAfter -lt (Get-Date))
                DaysToExpiry = [math]::Floor(
                    ($Cert.NotAfter - (Get-Date)).TotalDays
                )
            }
        }

    }
    catch {
        Write-WarnMsg "Unable to read certificate store $Store"
    }
}

$Inventory.Certificates = $Certificates

Save-Json $Certificates "Windows-Certificates.json"

$ExpiredCerts = @(
    $Certificates |
    Where-Object {
        $_.HasExpired -eq $true
    }
)

if ($ExpiredCerts.Count -gt 0) {

    Write-WarnMsg "$($ExpiredCerts.Count) expired Windows certificates found."

}
else {

    Write-OK "No expired certificates found in selected Windows stores."
}

# ============================================================
# AZURE ARC CERTIFICATE EXPIRATION
# ============================================================

Write-Section "AZURE ARC CERTIFICATE EXPIRATION"

if ($null -ne $ConnectedCluster) {

    $ManagedIdentityExpiry =
        $ConnectedCluster.managedIdentityCertificateExpirationTime

    if ($null -ne $ManagedIdentityExpiry) {

        $ExpiryDate = [datetime]$ManagedIdentityExpiry

        $DaysRemaining =
            [math]::Floor(
                ($ExpiryDate.ToUniversalTime() -
                (Get-Date).ToUniversalTime()).TotalDays
            )

        $ArcCertificateInfo = [PSCustomObject]@{

            CertificateType = "ManagedIdentityCertificate"

            Expiration = $ExpiryDate

            DaysRemaining = $DaysRemaining

            Status =
                if ($DaysRemaining -lt 0) {
                    "EXPIRED"
                }
                elseif ($DaysRemaining -le 30) {
                    "EXPIRING_SOON"
                }
                else {
                    "VALID"
                }
        }

        $Inventory.Certificates += $ArcCertificateInfo

        Write-Host ""
        Write-Host "  Managed Identity Certificate"
        Write-Host "  Expiration    : $ExpiryDate"
        Write-Host "  Days Remaining: $DaysRemaining"
        Write-Host "  Status        : $($ArcCertificateInfo.Status)"
    }
}

# ============================================================
# CONNECTIVITY HEALTH
# ============================================================

Write-Section "HEALTH SUMMARY"

$Health = [ordered]@{}

if ($null -ne $ConnectedCluster) {

    $Health.ConnectedK8s =
        $ConnectedCluster.connectivityStatus

    $Health.ArcProvisioningState =
        $ConnectedCluster.provisioningState

    $Health.KubernetesVersion =
        $ConnectedCluster.kubernetesVersion

    $Health.AgentVersion =
        $ConnectedCluster.agentVersion

    $Health.ManagedIdentityExpiration =
        $ConnectedCluster.managedIdentityCertificateExpirationTime
}

if ($null -ne $AksCluster) {

    $Health.AKSProvisioningState =
        $AksCluster.provisioningState

    $Health.AKSKubernetesVersion =
        $AksCluster.kubernetesVersion
}

$Health.KubectlContext =
    $Inventory.Kubernetes.CurrentContext

$Health.Timestamp =
    (Get-Date).ToString("o")

$Inventory.Health = $Health

# ============================================================
# SAVE COMPLETE INVENTORY
# ============================================================

Write-Section "SAVING INVENTORY"

try {

    $Inventory |
        ConvertTo-Json -Depth 30 |
        Out-File -FilePath $JsonFile -Encoding utf8

    Write-OK "Complete inventory saved:"
    Write-Host "  $JsonFile"

}
catch {

    Write-ErrMsg "Failed to save complete inventory."
}

# ============================================================
# HUMAN READABLE SUMMARY
# ============================================================

$Summary = @()

$Summary += "============================================================"
$Summary += " AZURE LOCAL + AKS ARC INVENTORY"
$Summary += "============================================================"
$Summary += ""
$Summary += "Collected : $(Get-Date)"
$Summary += "Computer  : $env:COMPUTERNAME"
$Summary += "User      : $env:USERDOMAIN\$env:USERNAME"
$Summary += ""
$Summary += "Azure"
$Summary += "------------------------------------------------------------"
$Summary += "Subscription : $($Inventory.Azure.SubscriptionName)"
$Summary += "Subscription ID : $($Inventory.Azure.SubscriptionId)"
$Summary += "Tenant ID : $($Inventory.Azure.TenantId)"
$Summary += ""
$Summary += "Azure Local / AKS"
$Summary += "------------------------------------------------------------"
$Summary += "Resource Group : $ResourceGroup"
$Summary += "AKS Cluster    : $AksClusterName"

if ($null -ne $ConnectedCluster) {

    $Summary += "Arc Connectivity : $($ConnectedCluster.connectivityStatus)"
    $Summary += "Arc Agent Version: $($ConnectedCluster.agentVersion)"
    $Summary += "Kubernetes      : $($ConnectedCluster.kubernetesVersion)"
    $Summary += "Node Count      : $($ConnectedCluster.totalNodeCount)"
    $Summary += "Core Count      : $($ConnectedCluster.totalCoreCount)"
    $Summary += "Infrastructure  : $($ConnectedCluster.infrastructure)"
    $Summary += "Offering        : $($ConnectedCluster.offering)"
    $Summary += "Managed Identity Certificate Expiry: $($ConnectedCluster.managedIdentityCertificateExpirationTime)"
}

if ($null -ne $AksCluster) {

    $Summary += ""
    $Summary += "AKS Arc"
    $Summary += "------------------------------------------------------------"
    $Summary += "Provisioning State : $($AksCluster.provisioningState)"
    $Summary += "Kubernetes Version : $($AksCluster.kubernetesVersion)"
}

$Summary += ""
$Summary += "Kubernetes"
$Summary += "------------------------------------------------------------"
$Summary += "kubectl Context : $($Inventory.Kubernetes.CurrentContext)"

if ($null -ne $Inventory.Kubernetes.VersionTest) {

    if ($Inventory.Kubernetes.VersionTest -is [array]) {
        $Summary += "API Test : FAILED/UNREACHABLE"
    }
    else {
        $Summary += "API Test : COMPLETED"
    }
}

$Summary += ""
$Summary += "Certificates"
$Summary += "------------------------------------------------------------"

if ($ExpiredCerts.Count -gt 0) {

    $Summary += "Expired Windows Certificates: $($ExpiredCerts.Count)"

}
else {

    $Summary += "Expired Windows Certificates: 0"
}

$Summary += ""
$Summary += "Output"
$Summary += "------------------------------------------------------------"
$Summary += $OutputDir
$Summary += ""

$Summary |
    Out-File -FilePath $SummaryFile -Encoding utf8

Write-OK "Summary saved:"
Write-Host "  $SummaryFile"

# ============================================================
# FINAL
# ============================================================

Write-Section "INVENTORY COMPLETE"

Write-Host ""
Write-Host "Output directory:" -ForegroundColor Green
Write-Host "  $OutputDir" -ForegroundColor White

Write-Host ""
Write-Host "Important files:" -ForegroundColor Green
Write-Host "  AzureLocal-AKS-Inventory.json"
Write-Host "  AzureLocal-AKS-Summary.txt"
Write-Host "  ConnectedK8s-Target.json"
Write-Host "  AKSArc-Cluster.json"
Write-Host "  Kubernetes-Nodes.json"
Write-Host "  Kubernetes-Pods.json"
Write-Host "  Windows-Certificates.json"
Write-Host "  Inventory.log"

Write-Host ""

Stop-Transcript | Out-Null