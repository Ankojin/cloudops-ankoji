#!/usr/bin/env python3
"""
generate-tf-v2.6.py

Terraform VM Generator (CLI-only SAS, Multi-Disk, Strict Ordering)
------------------------------------------------------------------
- Supports Windows and Linux VMs (separate VM blocks)
- Supports up to 10 data disks per VM
- Includes DCR, AMA, Boot Diagnostics, Auto-Shutdown
- Custom Script Extension runs *last* (after AMA + Shutdown)
- SAS generation via Azure CLI only
"""

import csv
import json
import os
import sys
import shutil
import subprocess
from datetime import datetime, timedelta
from typing import Dict, List, Optional

# ============================================================
#  CLASS: TerraformVMGenerator
# ============================================================
class TerraformVMGenerator:
    def __init__(self):
        env = {k.upper(): v for k, v in os.environ.items()}

        self.environment = env.get('ENVIRONMENT') or env.get('environment') or 'DEV'
        self.project_name = env.get('PROJECT_NAME') or env.get('project_name') or 'BaaS-Platform'

        print(f"[INFO] Starting generation for Project='{self.project_name}' Environment='{self.environment}'")

        # Required config
        self.config = {
            'subscription_id': env.get('SUBSCRIPTION_ID'),
            'location': env.get('LOCATION', 'Sweden Central'),
            'vnet_name': env.get('VNET_NAME'),
            'vnet_rg': env.get('VNET_RG'),
            'subnet_rg': env.get('SUBNET_RG'),
            'keyvault_name': env.get('KEYVAULT_NAME'),
            'keyvault_rg': env.get('KEYVAULT_RG'),
            'dcr_name': env.get('DCR_NAME'),
            'dcr_rg': env.get('DCR_RG'),
            'diagnostics_storage': env.get('DIAGNOSTICS_STORAGE'),
            'script_storage_account': env.get('SCRIPT_STORAGE_ACCOUNT'),
            'script_storage_container': env.get('SCRIPT_STORAGE_CONTAINER'),
            'script_blob_name_windows': env.get('SCRIPT_BLOB_NAME_WINDOWS'),
            'script_blob_name_linux': env.get('SCRIPT_BLOB_NAME_LINUX'),
            'enable_custom_script': str(env.get('ENABLE_CUSTOM_SCRIPT', 'true')).lower() == 'true',
            'shutdown_enabled': str(env.get('SHUTDOWN_ENABLED', 'true')).lower() == 'true',
            'shutdown_time': env.get('SHUTDOWN_TIME', '2000'),
            'shutdown_timezone': env.get('SHUTDOWN_TIMEZONE', 'Arab Standard Time'),
        }

        self.os_templates = {
            "windows-2019": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2019-Datacenter", "version": "latest"},
            "windows-2022": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2022-Datacenter", "version": "latest"},
            "ubuntu-22.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest"},
            "rhel-8": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "8-LVM", "version": "latest"},
            "rhel-9": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "9_4", "version": "latest"},
        }

        self.storage_standards = {
            'os_disk_type': 'StandardSSD_LRS',
            'data_disk_type': 'StandardSSD_LRS',
            'disk_caching': 'ReadWrite',
            'data_disk_caching': 'None'
        }

        self.csv_file_path = env.get('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.resource_groups_to_create = set()
        self.validate_config()

    # ============================================================
    #  Validation
    # ============================================================
    def validate_config(self):
        required = ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name']
        missing = [k for k in required if not self.config.get(k)]
        if missing:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)

    # ============================================================
    #  SAS via Azure CLI
    # ============================================================
    def generate_blob_sas_url(self, account, container, blob, validity_hours=24) -> Optional[str]:
        if not shutil.which("az"):
            print("[WARN] az CLI not found on PATH.")
            return None
        expiry_dt = (datetime.utcnow() + timedelta(hours=validity_hours)).strftime("%Y-%m-%dT%H:%MZ")
        cmd = [
            "az", "storage", "blob", "generate-sas",
            "--account-name", account,
            "--container-name", container,
            "--name", blob,
            "--permissions", "r",
            "--expiry", expiry_dt,
            "--auth-mode", "login",
            "--https-only"
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            token = res.stdout.strip().strip('"').strip("'")
            if not token:
                print(f"[WARN] Empty SAS token returned for {blob}")
                return None
            return f"https://{account}.blob.core.windows.net/{container}/{blob}?{token}"
        except subprocess.CalledProcessError as e:
            print(f"[WARN] SAS generation failed for {blob}: {e.stderr.strip()}")
            return None
        except Exception as e:
            print(f"[WARN] Unexpected error during SAS generation for {blob}: {e}")
            return None
        # try:
        #     res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        #     token = res.stdout.strip().strip('"').strip("'")
        #     if not token:
        #         return None
        #     return f"https://{account}.blob.core.windows.net/{container}/{blob}?{token}"
        # except Exception as e:
        #     print(f"[WARN] SAS generation failed for {blob}: {e}")
        #     return None

    # ============================================================
    #  Tags
    # ============================================================
    def parse_tags(self):
        raw = os.getenv('TAGS_JSON_OVERRIDE') or os.getenv('DEFAULT_TAGS_JSON') or '{}'
        try:
            tags = json.loads(raw)
        except Exception:
            tags = {}
        tags.update({
            "CreatedBy": "Terraform",
            "CreationDate": datetime.now().strftime("%Y-%m-%d"),
            "Environment": self.environment,
            "Project": self.project_name
        })
        return tags

    # ============================================================
    #  Main generator
    # ============================================================
    def generate_terraform(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        vm_list = []

        with open(self.output_tf_file, "w", encoding="utf-8") as tf:
            self._write_provider_block(tf)

            with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    vm_name = row.get("vm_name", "").strip()
                    if not vm_name:
                        continue
                    vm_list.append(vm_name)
                    os_tmpl = self.os_templates.get(row.get("os_template", "windows-2019").lower(), self.os_templates["windows-2019"])
                    if os_tmpl["os_type"] == "linux":
                        self._write_linux_vm(tf, row, os_tmpl)
                    else:
                        self._write_windows_vm(tf, row, os_tmpl)

            self._write_outputs(tf, vm_list)

        print(f"[SUCCESS] Terraform file generated: {self.output_tf_file}")

    # ============================================================
    #  Provider header
    # ============================================================
    def _write_provider_block(self, tf):
        tf.write(f'''
terraform {{
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
''')

    # ============================================================
    #  Shared helpers
    # ============================================================
    def _collect_disks(self, vm_name, row):
        """Collect up to 10 disks from CSV columns disk_1_size ... disk_10_size"""
        disks = []
        for i in range(1, 11):
            size = (row.get(f"disk_{i}_size") or "").strip()
            if size:
                disks.append({
                    "name": f"{vm_name}-data-{i}",
                    "size": size,
                    "lun": i - 1,
                    "type": self.storage_standards['data_disk_type']
                })
        return disks

    def _write_data_disks(self, tf, rg, vm_name, disks, tags):
        for d in disks:
            tf.write(f'''
resource "azurerm_managed_disk" "{d['name'].replace('-', '_')}" {{
  name                 = "{d['name']}"
  location             = var.location
  resource_group_name  = "{rg}"
  storage_account_type = "{d['type']}"
  create_option        = "Empty"
  disk_size_gb         = {d['size']}
  tags = {{
    {tags}
  }}
}}

resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_{d['name'].replace('-', '_')}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{d['name'].replace('-', '_')}.id
  virtual_machine_id = azurerm_{'windows' if 'win' in vm_name.lower() else 'linux'}_virtual_machine.{vm_name}.id
  lun                = {d['lun']}
  caching            = "{self.storage_standards['data_disk_caching']}"
  create_option      = "Attach"
}}
''')

    # ============================================================
    #  Windows VM
    # ============================================================
    def _write_windows_vm(self, tf, row, os_tmpl):
        vm = row["vm_name"]
        rg = row["resource_group"]
        subnet = row["subnet_name"]
        ip = row.get("static_ip", "")
        size = row.get("vm_size", "Standard_D4s_v5")
        disks = self._collect_disks(vm, row)
        tags = self.parse_tags()
        tag_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

        # Core VM
        tf.write(f'''
# ==== WINDOWS VM: {vm} ====
data "azurerm_subnet" "{vm}_subnet" {{
  name = "{subnet}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault_secret" "{vm}_pwd" {{
  name = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

resource "azurerm_network_interface" "{vm}_nic" {{
  name = "{vm}-nic"
  location = var.location
  resource_group_name = "{rg}"
  ip_configuration {{
    name = "internal"
    subnet_id = data.azurerm_subnet.{vm}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address = "{ip}"
  }}
  tags = {{
    {tag_str}
  }}
}}

resource "azurerm_windows_virtual_machine" "{vm}" {{
  name = "{vm}"
  location = var.location
  resource_group_name = "{rg}"
  size = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm}_nic.id]
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm}_pwd.value
  license_type = "Windows_Server"
  os_disk {{
    caching = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}
  source_image_reference {{
    publisher = "{os_tmpl['publisher']}"
    offer = "{os_tmpl['offer']}"
    sku = "{os_tmpl['sku']}"
    version = "{os_tmpl['version']}"
  }}
  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}
  tags = {{
    {tag_str}
  }}
}}
''')

        # Data disks
        if disks:
            self._write_data_disks(tf, rg, vm, disks, tag_str)

        # AMA + Shutdown
        self._write_monitor_shutdown(tf, vm, "windows", tag_str)

        # Custom Script LAST
        if self.config['enable_custom_script'] and self.config['script_blob_name_windows']:
            sas = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_windows']
            )
            if sas:
                tf.write(f'''
# Custom Script (Windows) - Runs Last
resource "azurerm_virtual_machine_extension" "{vm}_script" {{
  name = "CustomScriptExtension"
  virtual_machine_id = azurerm_windows_virtual_machine.{vm}.id
  publisher = "Microsoft.Compute"
  type = "CustomScriptExtension"
  type_handler_version = "1.9"
  settings = jsonencode({{
    fileUris = ["{sas}"],
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File {self.config['script_blob_name_windows']}"
  }})
  tags = {{
    {tag_str}
  }}
}}
''')

    # ============================================================
    #  Linux VM
    # ============================================================
    def _write_linux_vm(self, tf, row, os_tmpl):
        vm = row["vm_name"]
        rg = row["resource_group"]
        subnet = row["subnet_name"]
        ip = row.get("static_ip", "")
        size = row.get("vm_size", "Standard_D4s_v5")
        disks = self._collect_disks(vm, row)
        tags = self.parse_tags()
        tag_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

        tf.write(f'''
# ==== LINUX VM: {vm} ====
data "azurerm_subnet" "{vm}_subnet" {{
  name = "{subnet}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name  = "{self.config['vnet_rg']}"
}}

data "azurerm_key_vault_secret" "{vm}_pwd" {{
  name = "azureadmin"
  key_vault_id = data.azurerm_key_vault.main_kv.id
}}

resource "azurerm_network_interface" "{vm}_nic" {{
  name = "{vm}-nic"
  location = var.location
  resource_group_name = "{rg}"
  ip_configuration {{
    name = "internal"
    subnet_id = data.azurerm_subnet.{vm}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address = "{ip}"
  }}
  tags = {{
    {tag_str}
  }}
}}

resource "azurerm_linux_virtual_machine" "{vm}" {{
  name = "{vm}"
  location = var.location
  resource_group_name = "{rg}"
  size = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm}_nic.id]
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm}_pwd.value
  disable_password_authentication = false
  os_disk {{
    caching = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}
  source_image_reference {{
    publisher = "{os_tmpl['publisher']}"
    offer = "{os_tmpl['offer']}"
    sku = "{os_tmpl['sku']}"
    version = "{os_tmpl['version']}"
  }}
  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}
  tags = {{
    {tag_str}
  }}
}}
''')

        # Data disks
        if disks:
            self._write_data_disks(tf, rg, vm, disks, tag_str)

        # AMA + Shutdown
        self._write_monitor_shutdown(tf, vm, "linux", tag_str)

        # Custom Script LAST
        if self.config['enable_custom_script'] and self.config['script_blob_name_linux']:
            sas = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_linux']
            )
            if sas:
                tf.write(f'''
# Custom Script (Linux) - Runs Last
resource "azurerm_virtual_machine_extension" "{vm}_script" {{
  name = "CustomScriptExtension"
  virtual_machine_id = azurerm_linux_virtual_machine.{vm}.id
  publisher = "Microsoft.Azure.Extensions"
  type = "CustomScript"
  type_handler_version = "2.0"
  settings = jsonencode({{
    fileUris = ["{sas}"],
    commandToExecute = "sh {self.config['script_blob_name_linux']}"
  }})
  tags = {{
    {tag_str}
  }}
}}
''')

    # ============================================================
    #  AMA + Shutdown
    # ============================================================
    def _write_monitor_shutdown(self, tf, vm, os_type, tags):
        tf.write(f'''
# Azure Monitor Agent + DCR + Auto-Shutdown
resource "azurerm_virtual_machine_extension" "{vm}_ama" {{
  name = "AzureMonitorAgent"
  virtual_machine_id = azurerm_{os_type}_virtual_machine.{vm}.id
  publisher = "Microsoft.Azure.Monitor"
  type = "AzureMonitor{os_type.capitalize()}Agent"
  type_handler_version = "1.30"
  automatic_upgrade_enabled = true
  tags = {{
    {tags}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm}_dcr" {{
  name = "{self.config['dcr_name']}"
  target_resource_id = azurerm_{os_type}_virtual_machine.{vm}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm}_shutdown" {{
  virtual_machine_id = azurerm_{os_type}_virtual_machine.{vm}.id
  location = var.location
  enabled = {str(self.config['shutdown_enabled']).lower()}
  daily_recurrence_time = "{self.config['shutdown_time']}"
  timezone = "{self.config['shutdown_timezone']}"
  notification_settings {{
    enabled = false
  }}
  tags = {{
    {tags}
  }}
}}
''')

    # ============================================================
    #  Outputs
    # ============================================================
    def _write_outputs(self, tf, vms):
        tf.write("\n# ==== Outputs ====\n")
        tf.write('output "vm_private_ips" {\n  value = {\n')
        for v in vms:
            tf.write(f'    "{v}" = azurerm_network_interface.{v}_nic.private_ip_address\n')
        tf.write("  }\n}\n")


# ============================================================
#  MAIN
# ============================================================
def main():
    print("[START] Terraform Generator v2.6 (Multi-disk + Ordered Extensions)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[DONE] Terraform file generated successfully.")

if __name__ == "__main__":
    main()