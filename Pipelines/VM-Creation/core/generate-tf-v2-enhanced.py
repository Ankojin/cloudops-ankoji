#!/usr/bin/env python3
"""
Enhanced VM Creation Terraform Generator v3.4
- No cloud-init/custom_data
- Keeps DCR, boot diagnostics, auto-shutdown
- Adds automatic SAS generation for Windows and Linux Custom Script Extensions
- Controlled by ENABLE_CUSTOM_SCRIPT flag (hardcoded to True)
"""

import csv
import json
import os
import sys
from datetime import datetime, timedelta
from typing import Dict, List
from urllib.parse import quote_plus
import hmac
import hashlib
import base64


class TerraformVMGenerator:
    def __init__(self):
        """Initialize generator with environment variables"""
        self.environment = os.getenv('ENVIRONMENT', 'DEV')
        self.project_name = os.getenv('PROJECT_NAME', 'BaaS-Platform')

        # Environment configuration
        self.config = {
            'subscription_id': os.getenv('SUBSCRIPTION_ID'),
            'location': os.getenv('LOCATION', 'swedencentral'),
            'vnet_name': os.getenv('VNET_NAME'),
            'vnet_rg': os.getenv('VNET_RG'),
            'subnet_rg': os.getenv('SUBNET_RG'),
            'keyvault_name': os.getenv('KEYVAULT_NAME'),
            'keyvault_rg': os.getenv('KEYVAULT_RG'),
            'dcr_name': os.getenv('DCR_NAME'),
            'dcr_rg': os.getenv('DCR_RG'),
            'diagnostics_storage': os.getenv('DIAGNOSTICS_STORAGE'),
            'diagnostics_storage_rg': os.getenv('DIAGNOSTICS_STORAGE_RG'),
            'script_storage_account': os.getenv('SCRIPT_STORAGE_ACCOUNT'),
            'script_storage_container': os.getenv('SCRIPT_STORAGE_CONTAINER'),
            'script_blob_name_windows': os.getenv('SCRIPT_BLOB_NAME_WINDOWS'),
            'script_blob_name_linux': os.getenv('SCRIPT_BLOB_NAME_LINUX'),
            'script_storage_key': os.getenv('SCRIPT_STORAGE_KEY'),
            'enable_custom_script': True,  # Always enabled
            'shutdown_enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'shutdown_time': os.getenv('shutdown_time', '2000'),
            'shutdown_timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }

        # OS Templates
        self.os_templates = {
            "windows-2019": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2019-Datacenter", "version": "latest"},
            "windows-2022": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2022-Datacenter", "version": "latest"},
            "ubuntu-22.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2", "version": "latest"},
            "rhel-8": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "8-LVM", "version": "latest"},
            "rhel-9": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "9_4", "version": "latest"}
        }

        # Disk standards
        self.storage_standards = {
            'os_disk_type': 'StandardSSD_LRS',
            'data_disk_type': 'StandardSSD_LRS',
            'disk_caching': 'ReadWrite',
            'data_disk_caching': 'None'
        }

        # Auto shutdown
        self.shutdown_config = {
            'enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'time': os.getenv('shutdown_time', '2000'),
            'timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }

        # Paths
        self.csv_file_path = os.getenv('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.resource_groups_to_create = set()

        self.validate_config()

    # --------------------------
    # Validation
    # --------------------------
    def validate_config(self):
        required = ['subscription_id', 'vnet_name', 'keyvault_name', 'dcr_name']
        missing = [x for x in required if not self.config.get(x)]
        if missing:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)
        print(f"[OK] Configuration validated for {self.environment}")
        print("[INFO] Custom Script Extensions: ENABLED for Windows & Linux (hardcoded)")

    # --------------------------
    # Tags
    # --------------------------
    def parse_tags(self) -> Dict[str, str]:
        json_tags = os.getenv('default_tags_json')
        if not json_tags:
            raise ValueError("Missing default_tags_json environment variable")
        tags = json.loads(json_tags)
        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = datetime.now().strftime('%Y-%m-%d')
        tags['Environment'] = self.environment
        tags['Project'] = self.project_name
        return tags

    # --------------------------
    # OS template
    # --------------------------
    def resolve_os_template(self, name: str) -> Dict[str, str]:
        name = name.strip().lower()
        if name not in self.os_templates:
            print(f"[WARN] Unknown OS template '{name}', defaulting to windows-2019")
            name = "windows-2019"
        return self.os_templates[name]

    # --------------------------
    # SAS Token Generator
    # --------------------------
    def generate_blob_sas_url(self, account: str, container: str, blob: str, key: str, validity_hours: int = 24) -> str:
        """Generate a read-only SAS URL for the blob."""
        if not all([account, container, blob, key]):
            print("[WARN] SAS generation skipped due to missing info")
            return None

        expiry = (datetime.utcnow() + timedelta(hours=validity_hours)).strftime('%Y-%m-%dT%H:%MZ')
        start = (datetime.utcnow() - timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%MZ')
        permissions = "r"
        resource = "b"
        signed_version = "2022-11-02"

        string_to_sign = f"{permissions}\n{start}\n{expiry}\n/blob/{account}/{container}/{blob}\n\n{signed_version}\n\nhttps\n\n"
        decoded_key = base64.b64decode(key)
        signature = base64.b64encode(
            hmac.new(decoded_key, msg=string_to_sign.encode('utf-8'), digestmod=hashlib.sha256).digest()
        ).decode('utf-8')

        sas_token = (
            f"sv={signed_version}&st={quote_plus(start)}&se={quote_plus(expiry)}"
            f"&sr={resource}&sp={permissions}&sig={quote_plus(signature)}"
        )
        return f"https://{account}.blob.core.windows.net/{container}/{blob}?{sas_token}"

    # --------------------------
    # Main Generator
    # --------------------------

  def generate_terraform(self):
    os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
    vm_outputs = []

    # Always force overwrite main.tf file
    try:
      with open(self.output_tf_file, "w") as tf_file:
        self._write_provider_block(tf_file)
        self._collect_resource_groups()
        self._generate_resource_groups(tf_file)

        try:
          with open(self.csv_file_path, newline='') as csvfile:
            reader = csv.DictReader(csvfile)
            for row in reader:
              if not row.get("vm_name", "").strip():
                continue
              vm_name = row["vm_name"].strip()
              vm_outputs.append(vm_name)
              self._generate_vm_resources(tf_file, row)
        except FileNotFoundError:
          print(f"[ERROR] CSV file not found: {self.csv_file_path}")
          sys.exit(1)

        self._generate_outputs(tf_file, vm_outputs)
    except Exception as e:
      print(f"[ERROR] Failed to write Terraform file: {self.output_tf_file} - {e}")
      sys.exit(2)

    # Verification: main.tf exists and contains SAS token
    if not os.path.exists(self.output_tf_file):
      print(f"[ERROR] Terraform file not generated: {self.output_tf_file}")
      sys.exit(2)
    with open(self.output_tf_file, "r") as tf_file:
      content = tf_file.read()
      if "blob.core.windows.net" not in content or "sv=" not in content:
        print(f"[ERROR] SAS token not found in generated Terraform file: {self.output_tf_file}")
        sys.exit(3)
    print(f"[OK] Terraform configuration generated: {self.output_tf_file} (SAS token verified)")

    # --------------------------
    # Provider Block
    # --------------------------
    def _write_provider_block(self, tf_file):
        tf_file.write(f'''
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
  features {{
    virtual_machine {{
      delete_os_disk_on_deletion = true
    }}
  }}
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

    # --------------------------
    # Resource Group Creation
    # --------------------------
    def _collect_resource_groups(self):
        try:
            with open(self.csv_file_path, newline='') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if row.get("create_rg", "").lower() == "true":
                        rg = row.get("resource_group", "").strip()
                        if rg:
                            self.resource_groups_to_create.add(rg)
        except FileNotFoundError:
            pass

    def _generate_resource_groups(self, tf_file):
        for rg in self.resource_groups_to_create:
            tags = self.parse_tags()
            tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
            tf_file.write(f'''
resource "azurerm_resource_group" "{rg.replace('-', '_')}_rg" {{
  name     = "{rg}"
  location = var.location
  tags = {{
    {tags_str}
  }}
}}
''')

    # --------------------------
    # VM Generation (Windows/Linux)
    # --------------------------
    def _generate_vm_resources(self, tf_file, row: Dict[str, str]):
        vm_name = row["vm_name"].strip()
        rg = row["resource_group"].strip()
        subnet = row["subnet_name"].strip()
        static_ip = row["static_ip"].strip()
        vm_size = row.get("vm_size", "Standard_D4s_v5").strip()
        os_template = row.get("os_template", "windows-2019").strip()
        os_config = self.resolve_os_template(os_template)
        os_type = os_config['os_type']
        tags = self.parse_tags()
        tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
        rg_ref = f'"{rg}"'
        create_rg = row.get("create_rg", "false").lower() == "true"

        depends_on_str = ""
        if create_rg:
            depends_on_str = f'  depends_on = [azurerm_resource_group.{rg.replace("-", "_")}_rg]\n'
            rg_ref = f'azurerm_resource_group.{rg.replace("-", "_")}_rg.name'

        tf_file.write(f'''
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
  resource_group_name = {rg_ref}
{depends_on_str}
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
''')

        if os_type == "linux":
            self._generate_linux_vm(tf_file, vm_name, vm_size, tags_str, os_config, rg_ref)
        else:
            self._generate_windows_vm(tf_file, vm_name, vm_size, tags_str, os_config, rg_ref)

        self._generate_dcr_and_shutdown(tf_file, vm_name, os_type, tags_str)

    # --------------------------
    # Linux VM
    # --------------------------
    def _generate_linux_vm(self, tf_file, vm_name, vm_size, tags_str, os_image, rg_ref):
        script_enabled = self.config['enable_custom_script']
        script_sas_url = None

        if script_enabled:
            script_sas_url = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_linux'],
                self.config['script_storage_key']
            )

        tf_file.write(f'''
resource "azurerm_linux_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = {rg_ref}
  location            = var.location
  size                = "{vm_size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]
  admin_username      = "azureadmin"
  admin_password      = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  disable_password_authentication = false

  os_disk {{
    caching              = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}

  source_image_reference {{
    publisher = "{os_image['publisher']}"
    offer     = "{os_image['offer']}"
    sku       = "{os_image['sku']}"
    version   = "{os_image['version']}"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

        if script_enabled and script_sas_url:
            tf_file.write(f'''
# Custom Script Extension (Linux Auto SAS)
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = jsonencode({{
    fileUris = ["{script_sas_url}"]
    commandToExecute = "sh {self.config['script_blob_name_linux']}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
        elif not script_enabled:
            tf_file.write(f"# [INFO] Custom Script Extension disabled globally for {vm_name}\n")
        else:
            tf_file.write(f"# [WARN] Skipped Linux script extension for {vm_name} (SAS generation failed)\n")

    # --------------------------
    # Windows VM
    # --------------------------
    def _generate_windows_vm(self, tf_file, vm_name, vm_size, tags_str, os_image, rg_ref):
        script_enabled = self.config['enable_custom_script']
        script_sas_url = None

        if script_enabled:
            script_sas_url = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_windows'],
                self.config['script_storage_key']
            )

        tf_file.write(f'''
resource "azurerm_windows_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = {rg_ref}
  location            = var.location
  size                = "{vm_size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  license_type   = "Windows_Server"

  os_disk {{
    caching              = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}

  source_image_reference {{
    publisher = "{os_image['publisher']}"
    offer     = "{os_image['offer']}"
    sku       = "{os_image['sku']}"
    version   = "{os_image['version']}"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{self.config['diagnostics_storage']}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_str}
  }}
}}
''')

        if script_enabled and script_sas_url:
            tf_file.write(f'''
# Custom Script Extension (Windows Auto SAS)
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = jsonencode({{
    fileUris = ["{script_sas_url}"]
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File {self.config['script_blob_name_windows']}"
  }})

  tags = {{
    {tags_str}
  }}
}}
''')
        elif not script_enabled:
            tf_file.write(f"# [INFO] Custom Script Extension disabled globally for {vm_name}\n")
        else:
            tf_file.write(f"# [WARN] Skipped Windows script extension for {vm_name} (SAS generation failed)\n")

    # --------------------------
    # DCR + Shutdown
    # --------------------------
    def _generate_dcr_and_shutdown(self, tf_file, vm_name, os_type, tags_str):
        vm_type = "linux_virtual_machine" if os_type == "linux" else "windows_virtual_machine"
        tf_file.write(f'''
# Azure Monitor Agent + DCR
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorAgent"
  virtual_machine_id         = azurerm_{vm_type}.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitor{os_type.capitalize()}Agent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true
  tags = {{
    {tags_str}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr_assoc" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_{vm_type}.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

# Auto Shutdown
resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}_shutdown" {{
  virtual_machine_id = azurerm_{vm_type}.{vm_name}.id
  location           = var.location
  enabled            = {str(self.shutdown_config['enabled']).lower()}
  daily_recurrence_time = "{self.shutdown_config['time']}"
  timezone              = "{self.shutdown_config['timezone']}"
  notification_settings {{
    enabled = false
  }}
  tags = {{
    {tags_str}
  }}
}}
''')

    # --------------------------
    # Outputs
    # --------------------------
    def _generate_outputs(self, tf_file, vm_list: List[str]):
        tf_file.write("\n# ==== Outputs ====\n")
        tf_file.write('output "vm_private_ips" {\n  value = {\n')
        for vm_name in vm_list:
            tf_file.write(f'    "{vm_name}" = azurerm_network_interface.{vm_name}_nic.private_ip_address\n')
        tf_file.write("  }\n}\n")


def main():
    print("[START] Terraform Generator v3.4 (Auto SAS + Windows/Linux Script Toggle)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Terraform configuration generated successfully")


if __name__ == "__main__":
    main()