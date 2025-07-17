# REGION AND RESOURCES
$ResourceGroup = "my-rg"
$VwanName = "my-vwan"
$HubName = "my-vhub"
$HubResourceId = "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Network/virtualHubs/my-vhub"

# GCP DETAILS
$GcpVpn1Ip = "35.234.100.1"         # External IP of GCP HA VPN interface 0
$GcpVpn2Ip = "35.234.100.2"         # External IP of GCP HA VPN interface 1
$GcpVpn1BgpPeer = "169.254.21.2"    # GCP interface 0 BGP peer IP
$GcpVpn2BgpPeer = "169.254.22.2"    # GCP interface 1 BGP peer IP
$GcpAsn = 65001
$SharedKey = "yourStrongPresharedKey"

# Connect-AzAccount if not already connected
Import-Module Az.Network

# Function to create a VPN Site
function New-GcpVpnSite {
    param (
        [string]$SiteName,
        [string]$LinkName,
        [string]$IpAddress,
        [string]$BgpPeer,
        [int]$BgpAsn
    )

    $link = New-AzVpnSiteLink -Name $LinkName `
        -IpAddress $IpAddress `
        -LinkProviderName "GCP" `
        -LinkSpeedInMbps 1000 `
        -BgpSetting (New-AzVpnSiteLinkBgpSettings -Asn $BgpAsn -BgpPeeringAddress $BgpPeer)

    New-AzVpnSite -Name $SiteName `
        -ResourceGroupName $ResourceGroup `
        -Location "East US" `
        -VirtualWanName $VwanName `
        -VpnSiteLink $link `
        -AddressSpace @("10.0.0.0/16") # Replace with GCP-side ranges
}

# Create VPN Sites for both GCP interfaces
New-GcpVpnSite -SiteName "GCP-Site-1" -LinkName "gcp-link-1" -IpAddress $GcpVpn1Ip -BgpPeer $GcpVpn1BgpPeer -BgpAsn $GcpAsn
New-GcpVpnSite -SiteName "GCP-Site-2" -LinkName "gcp-link-2" -IpAddress $GcpVpn2Ip -BgpPeer $GcpVpn2BgpPeer -BgpAsn $GcpAsn

# Wait a moment for VPN sites to propagate
Start-Sleep -Seconds 30

# Create VPN Connections from VWAN Hub to GCP Sites
function New-GcpVpnConnection {
    param (
        [string]$ConnectionName,
        [string]$SiteName
    )

    New-AzVpnSiteLinkConnection -Name "$ConnectionName-Link" `
        -VpnSiteLinkId "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$SiteName/vpnSiteLinks/gcp-link-1" `
        -SharedKey $SharedKey

    New-AzVpnConnection -ResourceGroupName $ResourceGroup `
        -Name $ConnectionName `
        -RemoteVpnSiteId "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$SiteName" `
        -VpnGatewayId (Get-AzVpnGateway -ResourceGroupName $ResourceGroup -Name "$HubName-vpngw").Id `
        -VpnSiteLinkConnection @(
            New-AzVpnSiteLinkConnection -Name "$ConnectionName-Link" `
                -VpnSiteLinkId "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$SiteName/vpnSiteLinks/gcp-link-1" `
                -SharedKey $SharedKey
        ) `
        -ConnectionType IPsec
}

New-GcpVpnConnection -ConnectionName "AzureToGCP1" -SiteName "GCP-Site-1"
New-GcpVpnConnection -ConnectionName "AzureToGCP2" -SiteName "GCP-Site-2"
