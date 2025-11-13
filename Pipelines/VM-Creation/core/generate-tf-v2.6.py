#!/usr/bin/env python3
"""
generate-tf-v2.6.py

FINAL VERSION (Stored in Memory)

✔ Supports Windows & Linux VMs
✔ Supports up to 10 data disks
✔ Custom Script Extension runs LAST (after AMA/DCR/Shutdown)
✔ Uses SAS URLs from pipeline
✔ NO SAS generation inside Python
✔ Fixes var.location not declared issue
"""

import csv
import json
import os
import sys
from datetime import datetime
from typing import Dict, List


class TerraformVMGenerator:
    def __init__(self):
        env = {k.upper(): v for k, v in os.environ.items()}

        self.environment = env.get("ENVIRONMENT", "DEV")
        self.project_name = env.get("PROJECT_NAME", "BaaS-Platform")

        # Config
        self.config = {
            "subscription_id": env.get("SUBSCRIPTION_ID"),
            "location": env.get("LOCATION"),
            "vnet_name": env.get("VNET_NAME"),
            "vnet_rg": env.get("VNET_RG"),
            "subnet_rg": env.get("SUBNET_RG"),
            "keyvault_name": env.get("KEYVAULT_NAME"),
            "keyvault_rg": env.get("KEYVAULT_RG"),
            "dcr_name": env.get("DCR_NAME"),
            "dcr_rg": env.get("DCR_RG"),
            "diagnostics_storage": env.get("DIAGNOSTICS_STORAGE"),
            "diagnostics_storage_rg": env.get("DIAGNOSTICS_STORAGE_RG"),

            # Custom script SAS URLs
            "sas_url_windows": env.get("SAS_URL_WINDOWS"),
            "sas_url_linux": env.get("SAS_URL_LINUX"),

            # Shutdown
            "shutdown_enabled": str(env.get("SHUTDOWN_ENABLED", "true")).lower() == "true",
            "shutdown_time": env.get("SHUTDOWN_TIME", "2000"),
            "shutdown_timezone": env.get("SHUTDOWN_TIMEZONE", "Arab Standard Time"),
        }

        # Paths
        self.csv_file_path = env.get("CSV_PATH", "./core/simplified-vms.csv")
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.resource_groups_to_create = set()

        self.validate_config()

    def validate_config(self):
        required = [
            "subscription_id",
            "location",
            "vnet_name",
            "keyvault_name",
            "dcr_name",
        ]
        missing = [x for x in required if not self.config.get(x)]
        if missing:
            print(f"[ERROR] Missing required variables: {', '.join(missing)}")
            sys.exit(1)

        print(f"[OK] Generator configuration ready. Environment={self.environment}")

    def parse_tags(self) -> Dict[str, str]:
        json_tags = os.getenv("DEFAULT_TAGS_JSON")
        if not json_tags:
            raise ValueError("Missing DEFAULT_TAGS_JSON")

        tags = json.loads(json_tags)

        # Preserve CreationDate
        creation_date = None
        if os.path.exists(self.output_tf_file):
            try:
                with open(self.output_tf_file, "r", encoding="utf-8") as f:
                    for line in f:
                        if '"CreationDate"' in line:
                            parts = line.split("=")
                            if len(parts) >= 2:
                                creation_date = parts[1].replace('"', "").replace(",", "").strip()
                            break
            except:
                pass

        tags["CreatedBy"] = "Terraform"
        tags["CreationDate"] = creation_date or datetime.now().strftime("%Y-%m-%d")
        tags["Environment"] = self.environment
        tags["Project"] = self.project_name

        return tags

    # =======================================
    # Provider Block (fixed var.location)
    # =======================================
    def _write_provider_block(self, tf):
        tf.write(f"""
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

# FIX — Required variable used throughout resources
variable "location" {{
  type    = string
  default = "{self.config['location']}"
}}

data "azurerm_virtual_network" "main_vnet" {{
  name                = "{self.config['vnet_name']}"
  resource_group_name = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault" "main_kv" {{
  name                = "{self.config['keyvault_name']}"
  resource_group_name = "{self.config['keyvault_rg']}"
}}

data "azurerm_monitor_data_collection_rule" "main_dcr" {{
  name                = "{self.config['dcr_name']}"
  resource_group_name = "{self.config['dcr_rg']}"
}}
""")

    # =======================================
    # Resource Groups
    # =======================================
    def _collect_resource_groups(self):
        try:
            with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                for row in csv.DictReader(csvfile):
                    if row.get("create_rg", "").lower() == "true":
                        rg = row.get("resource_group", "").strip()
                        if rg:
                            self.resource_groups_to_create.add(rg)
        except FileNotFoundError:
            pass

    def _generate_resource_groups(self, tf):
        if not self.resource_groups_to_create:
            return

        tf.write("\n# ===== Resource Groups =====\n")
        for rg in sorted(self.resource_groups_to_create):
            tags = self.parse_tags()
            tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
            safe_rg = rg.replace("-", "_")

            tf.write(f"""
resource "azurerm_resource_group" "{safe_rg}_rg" {{
  name     = "{rg}"
  location = var.location
  tags = {{
    {tags_str}
  }}
}}
""")

    # =======================================
    # VM GENERATION
    # =======================================
    def _generate_vm(self, tf, row):
        vm_name = row["vm_name"].strip()
        rg = row["resource_group"].strip()
        subnet_name = row["subnet_name"].strip()
        static_ip = row.get("static_ip", "").strip()
        vm_size = row.get("vm_size", "Standard_D4s_v5")

        tags = self.parse_tags()
        tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

        # -------------------------------------
        # Write NIC
        # -------------------------------------
        tf.write(f"""
# ========================
# VM: {vm_name}
# ========================

data "azurerm_subnet" "{vm_name}_subnet" {{
  name                 = "{subnet_name}"
  resource_group_name  = "{self.config['vnet_rg']}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
}}

data "azurerm_key_vault_secret" "{vm_name}_admin_password" {{
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

resource "azurerm_network_interface" "{vm_name}_nic" {{
  name                = "{vm_name}-nic"
  location            = var.location
  resource_group_name = "{rg}"

  ip_configuration {{
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.{vm_name}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "{static_ip}"
  }}

  tags = {{
    {tags_str}
  }}
}}
""")

        # -------------------------------------
        # OS TYPE
        # -------------------------------------
        os_template = row.get("os_template", "windows-2019").lower()
        is_linux = os_template.startswith("ubuntu") or os_template.startswith("rhel")

        # -------------------------------
        # Write VM block (Windows / Linux)
        # -------------------------------
        if is_linux:
            self._write_linux_vm(tf, vm_name, vm_size, tags_str, rg, os_template)
        else:
            self._write_windows_vm(tf, vm_name, vm_size, tags_str, rg, os_template)

        # -------------------------------
        # Data Disks
        # -------------------------------
        for n in range(1, 11):
            size = row.get(f"disk_{n}_size")
            if not size:
                continue

            disk_name = f"{vm_name}_disk_{n}"

            tf.write(f"""
resource "azurerm_managed_disk" "{disk_name}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = "{rg}"
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = {size}

  tags = {{
    {tags_str}
  }}
}}
""")

            vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"

            tf.write(f"""
resource "azurerm_virtual_machine_data_disk_attachment" "{disk_name}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{disk_name}.id
  virtual_machine_id = azurerm_{vm_type}.{vm_name}.id
  lun                = {n}
  create_option      = "Attach"
  caching            = "None"
}}
""")

        # -------------------------------
        # AMA + DCR + Shutdown
        # -------------------------------
        self._write_monitoring_blocks(tf, vm_name, tags_str, is_linux)

        # -------------------------------
        # Custom Script Extension (LAST)
        # -------------------------------
        self._write_custom_script_extension(tf, vm_name, tags_str, is_linux)

    # ============================================
    # Windows VM
    # ============================================
    def _write_windows_vm(self, tf, vm_name, size, tags_str, rg, os_template):
        tf.write(f"""
resource "azurerm_windows_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = "{rg}"
  location            = var.location
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  license_type = "Windows_Server"

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  source_image_reference {{
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }}

  tags = {{
    {tags_str}
  }}
}}
""")

    # ============================================
    # Linux VM
    # ============================================
    def _write_linux_vm(self, tf, vm_name, size, tags_str, rg, os_template):
        tf.write(f"""
resource "azurerm_linux_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = "{rg}"
  location            = var.location
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  disable_password_authentication = false

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  source_image_reference {{
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }}

  tags = {{
    {tags_str}
  }}
}}
""")

    # ============================================
    # Monitoring (AMA + DCR + Shutdown)
    # ============================================
    def _write_monitoring_blocks(self, tf, vm_name, tags_str, is_linux):
        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"

        tf.write(f"""
# Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorAgent"
  virtual_machine_id         = azurerm_{vm_type}.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitor{ 'Linux' if is_linux else 'Windows'}Agent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {{
    {tags_str}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_{vm_type}.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

# Auto-shutdown
resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}_shutdown" {{
  virtual_machine_id = azurerm_{vm_type}.{vm_name}.id
  location           = var.location
  enabled            = {str(self.config['shutdown_enabled']).lower()}
  daily_recurrence_time = "{self.config['shutdown_time']}"
  timezone              = "{self.config['shutdown_timezone']}"

  notification_settings {{
    enabled = false
  }}

  tags = {{
    {tags_str}
  }}
}}
""")

    # ============================================
    # Custom Script Extension (runs LAST)
    # ============================================
    def _write_custom_script_extension(self, tf, vm_name, tags_str, is_linux):
        sas_url = self.config["sas_url_linux"] if is_linux else self.config["sas_url_windows"]
        if not sas_url:
            tf.write(f"# WARN: Custom Script skipped for {vm_name} — No SAS URL provided\n")
            return

        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
        command = (
            f"sh {os.path.basename(sas_url.split('?')[0])}"
            if is_linux
            else f"powershell -ExecutionPolicy Unrestricted -File {os.path.basename(sas_url.split('?')[0])}"
        )

        tf.write(f"""
# ==============================
# Custom Script Extension (LAST)
# ==============================
resource "azurerm_virtual_machine_extension" "{vm_name}_customscript" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_{vm_type}.{vm_name}.id
  publisher            = "{'Microsoft.Azure.Extensions' if is_linux else 'Microsoft.Compute'}"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = jsonencode({{
    fileUris        = ["{sas_url}"]
    commandToExecute = "{command}"
  }})

  tags = {{
    {tags_str}
  }}
}}
""")

    # ============================================
    # OUTPUTS
    # ============================================
    def _generate_outputs(self, tf, vm_list):
        tf.write("""
# Outputs
output "vm_private_ips" {
  value = {
""")
        for vm_name in vm_list:
            tf.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.private_ip_address\n')

        tf.write("  }\n}\n")

    # ============================================
    # GENERATE MAIN
    # ============================================
    def generate_terraform(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        vm_list = []

        with open(self.output_tf_file, "w", encoding="utf-8") as tf:

            self._write_provider_block(tf)
            self._collect_resource_groups()
            self._generate_resource_groups(tf)

            with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                for row in csv.DictReader(csvfile):
                    if not row.get("vm_name"):
                        continue
                    vm_name = row["vm_name"].strip()
                    vm_list.append(vm_name)
                    self._generate_vm(tf, row)

            self._generate_outputs(tf, vm_list)

        print(f"[OK] Terraform file generated: {self.output_tf_file}")


# ======================================================
# MAIN
# ======================================================
if __name__ == "__main__":
    print("[START] Terraform Generator v2.6")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Completed Terraform Generation")