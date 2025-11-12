#!/usr/bin/env python3
"""
generate-tf-v2.6.py

Terraform VM Creation Generator v2.6
------------------------------------
✅ Supports Windows and Linux VMs
✅ Supports up to 10 data disks per VM
✅ Includes DCR, boot diagnostics, and auto-shutdown
✅ Custom Script Extension runs last (after AMA + shutdown)
✅ SAS URLs are injected securely from Azure DevOps pipeline (no inline generation)
"""

import csv
import json
import os
import sys
from datetime import datetime
from typing import Dict, List

class TerraformVMGenerator:
    def __init__(self):
        """Initialize generator from environment variables (case-insensitive)"""
        env = {k.upper(): v for k, v in os.environ.items()}

        self.environment = env.get("ENVIRONMENT") or "DEV"
        self.project_name = env.get("PROJECT_NAME") or "BaaS-Platform"

        # Core environment configuration
        self.config = {
            'subscription_id': env.get('SUBSCRIPTION_ID'),
            'location': env.get('LOCATION'),
            'vnet_name': env.get('VNET_NAME'),
            'vnet_rg': env.get('VNET_RG'),
            'subnet_rg': env.get('SUBNET_RG'),
            'keyvault_name': env.get('KEYVAULT_NAME'),
            'keyvault_rg': env.get('KEYVAULT_RG'),
            'dcr_name': env.get('DCR_NAME'),
            'dcr_rg': env.get('DCR_RG'),
            'diagnostics_storage': env.get('DIAGNOSTICS_STORAGE'),
            'diagnostics_storage_rg': env.get('DIAGNOSTICS_STORAGE_RG'),

            # Script storage metadata
            'script_storage_account': env.get('SCRIPT_STORAGE_ACCOUNT'),
            'script_storage_container': env.get('SCRIPT_STORAGE_CONTAINER'),
            'script_blob_name_windows': env.get('SCRIPT_BLOB_NAME_WINDOWS'),
            'script_blob_name_linux': env.get('SCRIPT_BLOB_NAME_LINUX'),

            # Injected SAS URLs from pipeline
            'sas_url_windows': env.get('SAS_URL_WINDOWS'),
            'sas_url_linux': env.get('SAS_URL_LINUX'),

            # Shutdown and control flags
            'shutdown_enabled': env.get('SHUTDOWN_ENABLED', 'true').lower() == 'true',
            'shutdown_time': env.get('SHUTDOWN_TIME', '2000'),
            'shutdown_timezone': env.get('SHUTDOWN_TIMEZONE', 'Arab Standard Time'),
        }

        # OS templates
        self.os_templates = {
            "windows-2019": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2019-Datacenter", "version": "latest"},
            "windows-2022": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2022-Datacenter", "version": "latest"},
            "ubuntu-22.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest"},
            "rhel-8": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "8-LVM", "version": "latest"},
            "rhel-9": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "9_4", "version": "latest"},
        }

        # Disk defaults
        self.storage_standards = {
            'os_disk_type': 'StandardSSD_LRS',
            'data_disk_type': 'StandardSSD_LRS',
            'disk_caching': 'ReadWrite',
            'data_disk_caching': 'None'
        }

        # Paths
        self.csv_file_path = env.get('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"

        self._validate_env()

    # ------------------------------------------------------------------
    def _validate_env(self):
        missing = [k for k, v in self.config.items() if k in ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name'] and not v]
        if missing:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)
        print(f"[OK] Configuration validated for {self.environment}")
        print(f"[INFO] SAS Injection Mode: Windows={bool(self.config['sas_url_windows'])}, Linux={bool(self.config['sas_url_linux'])}")

    # ------------------------------------------------------------------
    def parse_tags(self) -> Dict[str, str]:
        json_tags = os.getenv('DEFAULT_TAGS_JSON')
        tags = json.loads(json_tags) if json_tags else {}
        tags['Environment'] = self.environment
        tags['Project'] = self.project_name
        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = datetime.now().strftime('%Y-%m-%d')
        return tags

    # ------------------------------------------------------------------
    def generate_terraform(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        vms = []

        with open(self.output_tf_file, "w", encoding="utf-8") as tf:
            self._write_provider_block(tf)

            try:
                with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                    reader = csv.DictReader(csvfile)
                    for row in reader:
                        if not row.get("vm_name"): continue
                        vms.append(row["vm_name"])
                        self._write_vm(tf, row)
            except FileNotFoundError:
                print(f"[ERROR] CSV file not found: {self.csv_file_path}")
                sys.exit(1)

            self._write_outputs(tf, vms)

        print(f"[SUCCESS] Terraform configuration generated: {self.output_tf_file}")

    # ------------------------------------------------------------------
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

    # ------------------------------------------------------------------
    def _write_vm(self, tf, row):
        vm_name = row["vm_name"].strip()
        resource_group = row["resource_group"].strip()
        subnet = row["subnet_name"].strip()
        static_ip = row.get("static_ip", "").strip()
        vm_size = row.get("vm_size", "Standard_D4s_v5").strip()
        os_template = row.get("os_template", "windows-2019").strip().lower()
        os_data = self.os_templates.get(os_template, self.os_templates["windows-2019"])
        os_type = os_data["os_type"]
        tags = self.parse_tags()
        tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

        # Write common NIC + subnet + password data sources
        tf.write(f"""
# ==== {vm_name} ====
data "azurerm_subnet" "{vm_name}_subnet" {{
  name                 = "{subnet}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault_secret" "{vm_name}_admin_password" {{
  name         = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

resource "azurerm_network_interface" "{vm_name}_nic" {{
  name                = "{vm_name}-nic"
  location            = var.location
  resource_group_name = "{resource_group}"
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

        # Build data disks dynamically (up to 10)
        disks = []
        for i in range(1, 11):
            size = row.get(f"disk_{i}_size")
            if size:
                disks.append((f"{vm_name}-data-{i}", size, i))

        for disk_name, disk_size, lun in disks:
            tf.write(f"""
resource "azurerm_managed_disk" "{vm_name}_disk_{lun}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = "{resource_group}"
  storage_account_type = "{self.storage_standards['data_disk_type']}"
  create_option        = "Empty"
  disk_size_gb         = {disk_size}
  tags = {{
    {tags_str}
  }}
}}
""")

        # Main VM block
        vm_type = "azurerm_windows_virtual_machine" if os_type == "windows" else "azurerm_linux_virtual_machine"
        tf.write(f"""
resource "{vm_type}" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = "{resource_group}"
  location            = var.location
  size                = "{vm_size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]
  admin_username      = "azureadmin"
  admin_password      = data.azurerm_key_vault_secret.{vm_name}_admin_password.value

  os_disk {{
    caching              = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}

  source_image_reference {{
    publisher = "{os_data['publisher']}"
    offer     = "{os_data['offer']}"
    sku       = "{os_data['sku']}"
    version   = "{os_data['version']}"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}
""")

        # Attach data disks
        for _, _, lun in disks:
            tf.write(f"""
resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_attach_{lun}" {{
  managed_disk_id    = azurerm_managed_disk.{vm_name}_disk_{lun}.id
  virtual_machine_id = {vm_type}.{vm_name}.id
  lun                = {lun}
  create_option      = "Attach"
  caching            = "{self.storage_standards['data_disk_caching']}"
}}
""")

        # DCR + Auto Shutdown
        self._write_monitor_and_shutdown(tf, vm_name, vm_type, tags_str)

        # Custom Script Extension (LAST)
        self._write_custom_script(tf, vm_name, vm_type, os_type, tags_str)

    # ------------------------------------------------------------------
    def _write_monitor_and_shutdown(self, tf, vm_name, vm_type, tags_str):
        tf.write(f"""
# Azure Monitor Agent + DCR
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                 = "AzureMonitorAgent"
  virtual_machine_id   = {vm_type}.{vm_name}.id
  publisher            = "Microsoft.Azure.Monitor"
  type                 = "AzureMonitor{('Windows' if 'windows' in vm_type else 'Linux')}Agent"
  type_handler_version = "1.30"
  automatic_upgrade_enabled = true
  tags = {{
    {tags_str}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = {vm_type}.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}_shutdown" {{
  virtual_machine_id = {vm_type}.{vm_name}.id
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

    # ------------------------------------------------------------------
    def _write_custom_script(self, tf, vm_name, vm_type, os_type, tags_str):
        """Inject pre-generated SAS URLs from pipeline"""
        sas_url = self.config['sas_url_windows'] if os_type == "windows" else self.config['sas_url_linux']
        blob_name = self.config['script_blob_name_windows'] if os_type == "windows" else self.config['script_blob_name_linux']

        if sas_url:
            command = (
                f"powershell -ExecutionPolicy Unrestricted -File {blob_name}"
                if os_type == "windows"
                else f"sh {blob_name}"
            )
            tf.write(f"""
# Custom Script Extension (Injected SAS)
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = {vm_type}.{vm_name}.id
  publisher            = "{'Microsoft.Compute' if os_type == 'windows' else 'Microsoft.Azure.Extensions'}"
  type                 = "CustomScript"
  type_handler_version = "{'1.9' if os_type == 'windows' else '2.0'}"
  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "{command}"
  }})
  tags = {{
    {tags_str}
  }}
}}
""")
        else:
            tf.write(f"# [WARN] No SAS URL provided for {os_type} script on {vm_name}, skipping extension.\n")

    # ------------------------------------------------------------------
    def _write_outputs(self, tf, vms: List[str]):
        tf.write("\n# ==== Outputs ====\n")
        tf.write('output "vm_private_ips" {\n  value = {\n')
        for name in vms:
            tf.write(f'    "{name}" = azurerm_network_interface.{name}_nic.private_ip_address\n')
        tf.write("  }\n}\n")

# ------------------------------------------------------------------
def main():
    print("[START] Terraform Generator v2.6 (Pre-injected SAS mode)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[DONE] Terraform configuration generated successfully.")

if __name__ == "__main__":
    main()