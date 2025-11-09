# Resource Reuse Matrix for "modify" Action

## ✅ REUSED RESOURCES (Stay Unchanged)
- ✅ **Resource Groups**: Existing RGs are preserved if create_rg=TRUE was used before
- ✅ **Managed Disks**: Data disks (disk_1_size, disk_2_size, disk_3_size) remain attached
- ✅ **OS Disks**: Stay with the VM unless VM itself needs recreation
- ✅ **Virtual Network**: VNet and subnets are external resources (not managed by this TF)
- ✅ **Key Vault**: External resource containing admin passwords
- ✅ **Azure Monitor Agents**: Stay configured on the VM
- ✅ **Data Collection Rule Associations**: Monitoring connections preserved
- ✅ **Auto-shutdown Schedules**: Time schedules remain configured

## 🔄 MODIFIED RESOURCES (Updated In-Place)
- 🔄 **Network Interface**: IP address changed to new static_ip value
- 🔄 **Subnet Association**: NIC moved to new subnet (if subnet_name changed)
- 🔄 **VM Tags**: All tags updated with new values from variable groups
- 🔄 **VM Size**: Can be changed if compatible (same VM family)

## ❌ RECREATED RESOURCES (Destroyed + Created)
- ❌ **Virtual Machine**: Only if critical changes like OS type (linux ↔ windows)
- ❌ **OS Disk**: Only if VM gets recreated
- ❌ **Custom Script Extensions**: If VM is recreated

## 📝 TERRAFORM PLAN EXAMPLE
When you run modify with subnet/IP changes, you'll see:

```
Plan: 0 to add, 2 to change, 0 to destroy.

  # azurerm_network_interface.ankoji-test-01_nic will be updated in-place
  ~ resource "azurerm_network_interface" "ankoji-test-01_nic" {
      ~ ip_configuration {
          ~ private_ip_address            = "10.189.57.162" -> "10.189.57.163"
          ~ subnet_id                     = "/subscriptions/.../snet-sit-nonpci-app-01" -> "/subscriptions/.../snet-sit-nonpci-app-02"
        }
    }

  # data.azurerm_subnet.ankoji-test-01_subnet will be read during apply
  <= data "azurerm_subnet" "ankoji-test-01_subnet" {
      ~ name                 = "snet-sit-nonpci-app-01" -> "snet-sit-nonpci-app-02"
    }
```

## 🚨 IMPORTANT STATE MANAGEMENT
The pipeline copies existing state files:

```yaml
# Copy existing state file for modify operations
if (Test-Path "$(TF_STATE_PATH)/terraform.tfstate") {
    Copy-Item "$(TF_STATE_PATH)/terraform.tfstate" "./" -Force
}
```

This ensures Terraform knows what exists and only changes what's different.

## 💡 BEST PRACTICE FOR YOUR SITUATION
1. ✅ **Use action=modify** since RG and disks are already created
2. ✅ **Update CSV** with correct subnet_name and static_ip values  
3. ✅ **Run validation script** first to verify subnet/IP configuration
4. ✅ **Review terraform plan** output before applying to see exactly what changes

## ⚠️ RISK MITIGATION
- **Low Risk**: Changing IP addresses and subnet associations
- **Medium Risk**: Changing VM sizes (may require restart)
- **High Risk**: Changing OS type (will destroy and recreate VM)