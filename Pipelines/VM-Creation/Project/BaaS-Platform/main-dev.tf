
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  
  # Local backend - state stored on agent server
  # Path: C:\TerraformState\Project\BaaS-Platform\DEV\terraform.tfstate
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
  subscription_id = "test-sub-id"
}

variable "location" {
  description = "Location for resources"
  type        = string
  default     = "swedencentral"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "DEV"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "BaaS-Platform"
}

# Common data sources
data "azurerm_virtual_network" "main_vnet" {
  name                = "test-vnet"
  resource_group_name = "test-vnet-rg"
}

data "azurerm_key_vault" "main_kv" {
  name                = "test-kv"
  resource_group_name = "test-kv-rg"
}

data "azurerm_monitor_data_collection_rule" "main_dcr" {
  name                = "test-dcr"
  resource_group_name = "test-dcr-rg"
}

# ==== Resource Groups ====

resource "azurerm_resource_group" "bab_dev_baas_swec_rg_01_rg" {
  name     = "bab-dev-baas-swec-rg-01"
  location = var.location

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform"
  }
}

# ==== DABASDBRDDLV01 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASDBRDDLV01_subnet" {
  name                 = "subnet-db-01"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASDBRDDLV01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASDBRDDLV01_nic" {
  name                = "DABASDBRDDLV01-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.bab_dev_baas_swec_rg_01_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASDBRDDLV01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.56.223"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "DABASDBRDDLV01" {
  name                = "DABASDBRDDLV01"
  resource_group_name = azurerm_resource_group.bab_dev_baas_swec_rg_01_rg.name
  location            = var.location
  size                = "Standard_E4s_v5"

  network_interface_ids = [
    azurerm_network_interface.DABASDBRDDLV01_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.DABASDBRDDLV01_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "92-gen2"
    version   = "latest"
  }


  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASDBRDDLV01_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.DABASDBRDDLV01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASDBRDDLV01_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.DABASDBRDDLV01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASDBRDDLV01_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.DABASDBRDDLV01.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "sh test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASDBRDDLV01_DataDisk_0" {
  name                 = "DABASDBRDDLV01_DataDisk_0"
  location             = var.location
  resource_group_name  = azurerm_resource_group.bab_dev_baas_swec_rg_01_rg.name
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 256
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASDBRDDLV01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASDBRDDLV01_DataDisk_0.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASDBRDDLV01.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASDBRDDLV01_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.DABASDBRDDLV01.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== DABASAPKADLV01 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASAPKADLV01_subnet" {
  name                 = "subnet-app-01"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASAPKADLV01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASAPKADLV01_nic" {
  name                = "DABASAPKADLV01-nic"
  location            = var.location
  resource_group_name = "bab-dev-baas-swec-rg-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASAPKADLV01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.56.97"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "DABASAPKADLV01" {
  name                = "DABASAPKADLV01"
  resource_group_name = "bab-dev-baas-swec-rg-01"
  location            = var.location
  size                = "Standard_D4s_v5"

  network_interface_ids = [
    azurerm_network_interface.DABASAPKADLV01_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.DABASAPKADLV01_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "92-gen2"
    version   = "latest"
  }


  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASAPKADLV01_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.DABASAPKADLV01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASAPKADLV01_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.DABASAPKADLV01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASAPKADLV01_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.DABASAPKADLV01.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "sh test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASAPKADLV01_DataDisk_0" {
  name                 = "DABASAPKADLV01_DataDisk_0"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 256
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASAPKADLV01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASAPKADLV01_DataDisk_0.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV01.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASAPKADLV01_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV01.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== DABASAPKADLV02 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASAPKADLV02_subnet" {
  name                 = "subnet-app-02"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASAPKADLV02_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASAPKADLV02_nic" {
  name                = "DABASAPKADLV02-nic"
  location            = var.location
  resource_group_name = "bab-dev-baas-swec-rg-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASAPKADLV02_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.56.98"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "DABASAPKADLV02" {
  name                = "DABASAPKADLV02"
  resource_group_name = "bab-dev-baas-swec-rg-01"
  location            = var.location
  size                = "Standard_D4s_v5"

  network_interface_ids = [
    azurerm_network_interface.DABASAPKADLV02_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.DABASAPKADLV02_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "92-gen2"
    version   = "latest"
  }


  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASAPKADLV02_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.DABASAPKADLV02.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASAPKADLV02_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.DABASAPKADLV02.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASAPKADLV02_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.DABASAPKADLV02.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "sh test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASAPKADLV02_DataDisk_0" {
  name                 = "DABASAPKADLV02_DataDisk_0"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 256
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASAPKADLV02_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASAPKADLV02_DataDisk_0.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV02.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASAPKADLV02_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV02.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== DABASAPKADLV03 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASAPKADLV03_subnet" {
  name                 = "subnet-app-03"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASAPKADLV03_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASAPKADLV03_nic" {
  name                = "DABASAPKADLV03-nic"
  location            = var.location
  resource_group_name = "bab-dev-baas-swec-rg-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASAPKADLV03_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.56.99"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "DABASAPKADLV03" {
  name                = "DABASAPKADLV03"
  resource_group_name = "bab-dev-baas-swec-rg-01"
  location            = var.location
  size                = "Standard_D4s_v5"

  network_interface_ids = [
    azurerm_network_interface.DABASAPKADLV03_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.DABASAPKADLV03_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "92-gen2"
    version   = "latest"
  }


  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASAPKADLV03_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASAPKADLV03_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASAPKADLV03_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "sh test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASAPKADLV03_DataDisk_0" {
  name                 = "DABASAPKADLV03_DataDisk_0"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 256
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASAPKADLV03_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASAPKADLV03_DataDisk_0.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Data Disk 2
resource "azurerm_managed_disk" "DABASAPKADLV03_DataDisk_1" {
  name                 = "DABASAPKADLV03_DataDisk_1"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 512
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASAPKADLV03_disk_2_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASAPKADLV03_DataDisk_1.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  lun                = 1
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASAPKADLV03_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.DABASAPKADLV03.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== DABASWEBSV01 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASWEBSV01_subnet" {
  name                 = "subnet-web-01"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASWEBSV01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASWEBSV01_nic" {
  name                = "DABASWEBSV01-nic"
  location            = var.location
  resource_group_name = "bab-dev-baas-swec-rg-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASWEBSV01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.57.10"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Linux Virtual Machine
resource "azurerm_linux_virtual_machine" "DABASWEBSV01" {
  name                = "DABASWEBSV01"
  resource_group_name = "bab-dev-baas-swec-rg-01"
  location            = var.location
  size                = "Standard_B2s"

  network_interface_ids = [
    azurerm_network_interface.DABASWEBSV01_nic.id
  ]
  
  admin_username                  = "azureadmin"
  admin_password                  = data.azurerm_key_vault_secret.DABASWEBSV01_admin_password.value
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "92-gen2"
    version   = "latest"
  }


  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASWEBSV01_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.DABASWEBSV01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.33"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASWEBSV01_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_linux_virtual_machine.DABASWEBSV01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASWEBSV01_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.DABASWEBSV01.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "sh test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASWEBSV01_DataDisk_0" {
  name                 = "DABASWEBSV01_DataDisk_0"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 128
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASWEBSV01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASWEBSV01_DataDisk_0.id
  virtual_machine_id = azurerm_linux_virtual_machine.DABASWEBSV01.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASWEBSV01_shutdown" {
  virtual_machine_id = azurerm_linux_virtual_machine.DABASWEBSV01.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== DABASWINWEB01 Resources ====

# Subnet data source
data "azurerm_subnet" "DABASWINWEB01_subnet" {
  name                 = "subnet-web-02"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "test-vnet-rg"
}

# Admin password from Key Vault
data "azurerm_key_vault_secret" "DABASWINWEB01_admin_password" {
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}

# Network Interface
resource "azurerm_network_interface" "DABASWINWEB01_nic" {
  name                = "DABASWINWEB01-nic"
  location            = var.location
  resource_group_name = "bab-dev-baas-swec-rg-01"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.DABASWINWEB01_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.189.57.11"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Windows Virtual Machine
resource "azurerm_windows_virtual_machine" "DABASWINWEB01" {
  name                = "DABASWINWEB01"
  resource_group_name = "bab-dev-baas-swec-rg-01"
  location            = var.location
  size                = "Standard_B4ms"

  network_interface_ids = [
    azurerm_network_interface.DABASWINWEB01_nic.id
  ]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.DABASWINWEB01_admin_password.value
  license_type   = "Windows_Server"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }
  
  boot_diagnostics {
    storage_account_uri = "https://testdiagnostics.blob.core.windows.net/"
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "DABASWINWEB01_ama" {
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.DABASWINWEB01.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Collection Rule Association
resource "azurerm_monitor_data_collection_rule_association" "DABASWINWEB01_dcr_assoc" {
  name                    = "test-dcr"
  target_resource_id      = azurerm_windows_virtual_machine.DABASWINWEB01.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}

# Custom Script Extension
resource "azurerm_virtual_machine_extension" "DABASWINWEB01_script" {
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.DABASWINWEB01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({
    fileUris = ["https://testdiagnostics.blob.core.windows.net/scripts/test-script.sh"]
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File test-script.sh"
  })

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# Data Disk 1
resource "azurerm_managed_disk" "DABASWINWEB01_DataDisk_0" {
  name                 = "DABASWINWEB01_DataDisk_0"
  location             = var.location
  resource_group_name  = "bab-dev-baas-swec-rg-01"
  storage_account_type = "StandardSSD_LRS"
  disk_size_gb         = 200
  create_option        = "Empty"
}

resource "azurerm_virtual_machine_data_disk_attachment" "DABASWINWEB01_disk_1_attach" {
  managed_disk_id    = azurerm_managed_disk.DABASWINWEB01_DataDisk_0.id
  virtual_machine_id = azurerm_windows_virtual_machine.DABASWINWEB01.id
  lun                = 0
  create_option      = "Attach"
  caching            = "None"
}

# Auto Shutdown Schedule (Hardcoded Configuration)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "DABASWINWEB01_shutdown" {
  virtual_machine_id = azurerm_windows_virtual_machine.DABASWINWEB01.id
  location           = var.location
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "W. Europe Standard Time"

  notification_settings {
    enabled = false
  }

  tags = {
    "Environment" = "DEV;Project=BaaS-Platform",
    "Application name" = "BaaS Platform",
    "Project Name" = "BaaS Platform"
  }
}

# ==== Outputs ====

output "vm_private_ips" {
  description = "Private IP addresses of all VMs"
  value = {
    "DABASDBRDDLV01" = azurerm_network_interface.DABASDBRDDLV01_nic.private_ip_address
    "DABASAPKADLV01" = azurerm_network_interface.DABASAPKADLV01_nic.private_ip_address
    "DABASAPKADLV02" = azurerm_network_interface.DABASAPKADLV02_nic.private_ip_address
    "DABASAPKADLV03" = azurerm_network_interface.DABASAPKADLV03_nic.private_ip_address
    "DABASWEBSV01" = azurerm_network_interface.DABASWEBSV01_nic.private_ip_address
    "DABASWINWEB01" = azurerm_network_interface.DABASWINWEB01_nic.private_ip_address
  }
}

output "vm_resource_groups" {
  description = "Resource groups containing the VMs"
  value = {
    "DABASDBRDDLV01" = azurerm_network_interface.DABASDBRDDLV01_nic.resource_group_name
    "DABASAPKADLV01" = azurerm_network_interface.DABASAPKADLV01_nic.resource_group_name
    "DABASAPKADLV02" = azurerm_network_interface.DABASAPKADLV02_nic.resource_group_name
    "DABASAPKADLV03" = azurerm_network_interface.DABASAPKADLV03_nic.resource_group_name
    "DABASWEBSV01" = azurerm_network_interface.DABASWEBSV01_nic.resource_group_name
    "DABASWINWEB01" = azurerm_network_interface.DABASWINWEB01_nic.resource_group_name
  }
}

output "deployment_summary" {
  description = "Deployment summary information"
  value = {
    environment     = var.environment
    vm_count       = length(["DABASDBRDDLV01", "DABASAPKADLV01", "DABASAPKADLV02", "DABASAPKADLV03", "DABASWEBSV01", "DABASWINWEB01"])
    project_name   = "BaaS-Platform"
    deployment_time = timestamp()
  }
}
