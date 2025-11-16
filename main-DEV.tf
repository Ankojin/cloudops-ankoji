
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "43cc4f11-ffb1-4a0d-8420-0ba3746b4248"
}

# FIX — Required variable used throughout resources
variable "location" {
  type    = string
  default = "swedencentral"
}

data "azurerm_virtual_network" "main_vnet" {
  name                = "bab-dev-nw-swec-vnet-nonpci-01"
  resource_group_name = "bab-dev-nw-swec-rg-01"
}

data "azurerm_key_vault" "main_kv" {
  name                = "bab-dev-ssl-kv-swec-01"
  resource_group_name = "bab-dev-keyvault-swec-rg-01"
}

data "azurerm_monitor_data_collection_rule" "main_dcr" {
  name                = "MSVMI-bab-dev-vm-monitoring-dcr"
  resource_group_name = "bab-dev-wrkspace-swec-rg-01"
}

# ===== Resource Groups =====

resource "azurerm_resource_group" "ankoji_test_01_rg" {
  name     = "ankoji-test-01"
  location = var.location
  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

# ========================
# VM: ankoji-linux-test-01
# ========================

data "azurerm_subnet" "ankoji-linux-test-01_subnet" {
  name                 = "snet-dev-nonpci-app-02"
  resource_group_name  = "bab-dev-nw-swec-rg-01"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
}

data "azurerm_key_vault_secret" "ankoji-linux-test-01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

resource "azurerm_network_interface" "ankoji-linux-test-01_nic" {
  name                = "ankoji-linux-test-01-nic"
  location            = var.location
  resource_group_name = "ankoji-test-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.ankoji-linux-test-01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.57.162"
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

resource "azurerm_linux_virtual_machine" "ankoji-linux-test-01" {
  name                = "ankoji-linux-test-01"
  resource_group_name = "ankoji-test-01"
  location            = var.location
  size                = "Standard_D2s_v5"
  network_interface_ids = [azurerm_network_interface.ankoji-linux-test-01_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.ankoji-linux-test-01_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  boot_diagnostics {
    storage_account_uri = "https://babdevvmbootdiag02.blob.core.windows.net/"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

resource "azurerm_managed_disk" "ankoji-linux-test-01_disk_1" {
  name                 = "ankoji-linux-test-01_disk_1"
  location             = var.location
  resource_group_name  = azurerm_resource_group.ankoji_test_01_rg.name
  depends_on = [azurerm_resource_group.ankoji_test_01_rg]
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 16

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "ankoji-linux-test-01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.ankoji-linux-test-01_disk_1.id
  virtual_machine_id = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  lun                = 1
  create_option      = "Attach"
  caching            = "None"
}

resource "azurerm_managed_disk" "ankoji-linux-test-01_disk_2" {
  name                 = "ankoji-linux-test-01_disk_2"
  location             = var.location
  resource_group_name  = azurerm_resource_group.ankoji_test_01_rg.name
  depends_on = [azurerm_resource_group.ankoji_test_01_rg]
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 8

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "ankoji-linux-test-01_disk_2_attach" {
  managed_disk_id    = azurerm_managed_disk.ankoji-linux-test-01_disk_2.id
  virtual_machine_id = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  lun                = 2
  create_option      = "Attach"
  caching            = "None"
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "ankoji-linux-test-01_ama" {
  name                       = "AzureMonitorAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

resource "azurerm_monitor_data_collection_rule_association" "ankoji-linux-test-01_dcr" {
  name                    = "MSVMI-bab-dev-vm-monitoring-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Auto-shutdown
resource "azurerm_dev_test_global_vm_shutdown_schedule" "ankoji-linux-test-01_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  location           = var.location
  enabled            = true
  daily_recurrence_time = "2000"
  timezone              = "Arab Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

# ==============================
# Custom Script Extension (LAST)
# ==============================
resource "azurerm_virtual_machine_extension" "ankoji-linux-test-01_customscript" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.ankoji-linux-test-01.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = jsonencode({
    fileUris        = ["https://babdevvmbootdiag02.blob.core.windows.net/scripts/linuxpostconf.sh?se=2025-11-17T13%3A44Z&sp=r&spr=https&sv=2022-11-02&sr=b&sig=VETjjPXPVkhEX%2BqrLk5UlbU%2FXqQ%2F5pKicps9GLguWjo%3D"]
    commandToExecute = "sh linuxpostconf.sh"
  })

  tags = {
    "Company" = "BAB",
    "Department" = "Information Technology",
    "ProjectName" = "pilot-test",
    "ApplicationName" = "pilot-test",
    "Region" = "Sweden Central",
    "ApproverName" = "pilot-test",
    "RequesterName" = "CloudOps Team",
    "BusinessOwner" = "pilot-test",
    "TechnicalOwner" = "pilot-test",
    "CostCenter" = "pilot-test",
    "ServiceClass" = "pilot-test",
    "ManagedBy" = "CloudOps Team",
    "CreatedBy" = "Terraform",
    "CreationDate" = "2025-11-16",
    "Environment" = "DEV",
    "Project" = "pilot-test"
  }
}

# Outputs
output "vm_private_ips" {
  value = {
    "ankoji-linux-test-01" = azurerm_network_interface.ankoji-linux-test-01_nic.private_ip_address
  }
}
