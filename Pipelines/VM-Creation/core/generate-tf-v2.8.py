#!/usr/bin/env python3
"""
generate-tf-v2.8.py

Final TF generator v2.8 (kept in memory)
- Reads SAS_URL_WINDOWS / SAS_URL_LINUX from environment (pipeline supplies)
- Reads DEFAULT_TAGS_JSON from env (pipeline supplies)
- Supports up to 10 data disks
- Places monitoring (AMA) + DCR + Auto-shutdown then Custom Script EXT (last)
- Produces ./Project/{project}/main-{env}.tf
"""

import csv
import json
import os
import sys
from datetime import datetime
from typing import Dict, List

class TerraformVMGeneratorV28:
    def __init__(self):
        env = {k.upper(): v for k, v in os.environ.items()}

        self.environment = env.get("ENVIRONMENT", "DEV")
        self.project_name = env.get("PROJECT_NAME")
        if not self.project_name:
            print("[ERROR] PROJECT_NAME not set")
            sys.exit(1)

        self.config = {
            "subscription_id": env.get("SUBSCRIPTION_ID"),
            "location": env.get("LOCATION", "swedencentral"),
            "vnet_name": env.get("VNET_NAME"),
            "vnet_rg": env.get("VNET_RG"),
            "subnet_rg": env.get("SUBNET_RG"),
            "keyvault_name": env.get("KEYVAULT_NAME"),
            "keyvault_rg": env.get("KEYVAULT_RG"),
            "dcr_name": env.get("DCR_NAME"),
            "dcr_rg": env.get("DCR_RG"),
            "diagnostics_storage": env.get("DIAGNOSTICS_STORAGE"),
            "diagnostics_storage_rg": env.get("DIAGNOSTICS_STORAGE_RG"),
            "sas_url_windows": env.get("SAS_URL_WINDOWS"),
            "sas_url_linux": env.get("SAS_URL_LINUX"),
            "shutdown_enabled": env.get("SHUTDOWN_ENABLED", "true").lower() == "true",
            "shutdown_time": env.get("SHUTDOWN_TIME", "2000"),
            "shutdown_timezone": env.get("SHUTDOWN_TIMEZONE", "Arab Standard Time"),
        }

        self.csv_file_path = env.get("CSV_PATH", "./core/simplified-vms.csv")
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"

        # tags
        tags_json = env.get("DEFAULT_TAGS_JSON", "{}")
        try:
            self.tags = json.loads(tags_json)
        except Exception:
            self.tags = {}
        # add meta tags
        self.tags["CreatedBy"] = "Terraform"
        self.tags["CreationDate"] = datetime.now().strftime("%Y-%m-%d")
        self.tags["Environment"] = self.environment
        self.tags["Project"] = self.project_name

        # simple validations
        required = ["subscription_id", "vnet_name", "keyvault_name", "dcr_name"]
        missing = [r for r in required if not self.config.get(r)]
        if missing:
            print(f"[ERROR] Missing required config: {missing}")
            sys.exit(1)

    def _tags_block(self):
        return ",\n    ".join([f'"{k}" = "{v}"' for k, v in self.tags.items()])

    def _write_provider(self, f):
        f.write(f'''
terraform {{
  required_version = ">= 1.0"
  required_providers {{
    azurerm = {{
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }}
  }}
}}

provider "azurerm" {{
  features {{}}
  subscription_id = "{self.config['subscription_id']}"
}}

variable "location" {{
  type    = string
  default = "{self.config['location']}"
}}

data "azurerm_virtual_network" "main_vnet" {{
  name                = "{self.config['vnet_name']}"
  resource_group_name = "{self.config.get('vnet_rg', '')}"
}}

data "azurerm_key_vault" "main_kv" {{
  name                = "{self.config['keyvault_name']}"
  resource_group_name = "{self.config.get('keyvault_rg', '')}"
}}

data "azurerm_monitor_data_collection_rule" "main_dcr" {{
  name                = "{self.config['dcr_name']}"
  resource_group_name = "{self.config.get('dcr_rg', '')}"
}}
''')

    def generate(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        vm_names = []

        with open(self.output_tf_file, "w", encoding="utf-8") as f:
            self._write_provider(f)

            # read csv
            try:
                with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                    reader = csv.DictReader(csvfile)
                    for row in reader:
                        name = row.get("vm_name", "").strip()
                        if not name:
                            continue
                        vm_names.append(name)
                        self._write_vm_block(f, row)
            except FileNotFoundError:
                print(f"[ERROR] CSV file not found: {self.csv_file_path}")
                sys.exit(1)

            # outputs
            f.write('\noutput "vm_private_ips" {\n  value = {\n')
            for n in vm_names:
                f.write(f'    "{n}" = azurerm_network_interface.{n}_nic.private_ip_address\n')
            f.write('  }\n}\n')

        print(f"[OK] Terraform file generated: {self.output_tf_file}")

    def _write_vm_block(self, f, row):
        vm = row.get("vm_name").strip()
        rg = row.get("resource_group").strip()
        subnet = row.get("subnet_name").strip()
        static_ip = row.get("static_ip", "").strip()
        size = row.get("vm_size", "Standard_D4s_v5").strip()
        os_template = row.get("os_template", "windows-2022").strip().lower()
        is_linux = os_template.startswith("ubuntu") or os_template.startswith("rhel")
        tags_str = self._tags_block()

        # NIC + admin password secret
        f.write(f'''
# ==== {vm} ====
data "azurerm_subnet" "{vm}_subnet" {{
  name                 = "{subnet}"
  resource_group_name  = "{self.config.get('vnet_rg','')}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
}}

data "azurerm_key_vault_secret" "{vm}_admin_password" {{
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

resource "azurerm_network_interface" "{vm}_nic" {{
  name                = "{vm}-nic"
  location            = var.location
  resource_group_name = "{rg}"

  ip_configuration {{
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.{vm}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "{static_ip}"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

        # OS-specific VM resource (Windows or Linux)
        if is_linux:
            f.write(f'''
resource "azurerm_linux_virtual_machine" "{vm}" {{
  name                = "{vm}"
  resource_group_name = "{rg}"
  location            = var.location
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm}_nic.id]
  admin_username      = "azureadmin"
  admin_password      = data.azurerm_key_vault_secret.{vm}_admin_password.value
  disable_password_authentication = false

  os_disk {{
    caching = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  source_image_reference {{
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config.get('diagnostics_storage')}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')
        else:
            f.write(f'''
resource "azurerm_windows_virtual_machine" "{vm}" {{
  name                = "{vm}"
  resource_group_name = "{rg}"
  location            = var.location
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm}_nic.id]
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm}_admin_password.value
  license_type   = "Windows_Server"

  os_disk {{
    caching = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  source_image_reference {{
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config.get('diagnostics_storage')}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

        # Data disks: supports disk_1_size ... disk_10_size (CSV uses disk_1_size style)
        for i in range(1, 11):
            size_key = f"disk_{i}_size"
            size_val = row.get(size_key) or row.get(f"disk_{i}_size")
            if not size_val:
                continue
            disk_name = f"{vm}-data-{i}"
            f.write(f'''
resource "azurerm_managed_disk" "{disk_name.replace('-', '_')}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = "{rg}"
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = {size_val}

  tags = {{
    {tags_str}
  }}
}}
''')
            # attach
            vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
            f.write(f'''
resource "azurerm_virtual_machine_data_disk_attachment" "{vm}_{disk_name.replace('-', '_')}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{disk_name.replace('-', '_')}.id
  virtual_machine_id = azurerm_{vm_type}.{vm}.id
  lun                = {i - 1}
  create_option      = "Attach"
  caching            = "None"
}}
''')

        # Monitoring: AMA + DCR + Shutdown (always before custom script)
        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
        f.write(f'''
# Azure Monitor + DCR + Auto-shutdown for {vm}
resource "azurerm_virtual_machine_extension" "{vm}_ama" {{
  name               = "AzureMonitorAgent"
  virtual_machine_id = azurerm_{vm_type}.{vm}.id
  publisher          = "Microsoft.Azure.Monitor"
  type               = "AzureMonitor{ 'Linux' if is_linux else 'Windows'}Agent"
  type_handler_version = "1.30"
  automatic_upgrade_enabled = true

  tags = {{
    {tags_str}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm}_dcr" {{
  name = "{self.config.get('dcr_name')}"
  target_resource_id = azurerm_{vm_type}.{vm}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm}_shutdown" {{
  virtual_machine_id = azurerm_{vm_type}.{vm}.id
  location = var.location
  enabled = {str(self.config.get('shutdown_enabled')).lower()}
  daily_recurrence_time = "{self.config.get('shutdown_time')}"
  timezone = "{self.config.get('shutdown_timezone')}"
  notification_settings {{
    enabled = false
  }}
  tags = {{
    {tags_str}
  }}
}}
''')

        # Custom script extension (LAST) using SAS URLs passed into env
        sas = self.config['sas_url_linux'] if is_linux else self.config['sas_url_windows']
        if not sas:
            f.write(f'# WARNING: Custom script skipped for {vm} — no SAS URL provided\n')
        else:
            blob_file = os.path.basename(sas.split("?")[0])
            cmd = f"sh {blob_file}" if is_linux else f"powershell -ExecutionPolicy Unrestricted -File {blob_file}"
            publisher = "Microsoft.Azure.Extensions" if is_linux else "Microsoft.Compute"
            f.write(f'''
resource "azurerm_virtual_machine_extension" "{vm}_customscript" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_{vm_type}.{vm}.id
  publisher            = "{publisher}"
  type                 = "CustomScriptExtension"
  type_handler_version = "2.1"

  settings = jsonencode({{
    fileUris = ["{sas}"],
    commandToExecute = "{cmd}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')

def main():
    print("[START] Terraform Generator v2.8")
    gen = TerraformVMGeneratorV28()
    gen.generate()
    print("[SUCCESS] Completed Terraform Generation")

if __name__ == "__main__":
    main()