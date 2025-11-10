#!/usr/bin/env python3
"""
Enhanced Terraform VM Generator v2 (Final Production)
------------------------------------------------------
- Generates Terraform VM resources (Linux/Windows)
- Handles multiple RGs/subnets
- Auto SAS generation (with retry + blob validation)
- Local backend friendly
"""

import os
import re
import sys
import csv
import json
import time
from datetime import datetime, timedelta
from typing import Dict, List
from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions


class TerraformVMGenerator:
    def __init__(self):
        """Initialize environment and configs"""
        self.environment = os.getenv("ENVIRONMENT", "DEV")
        self.project_name = os.getenv("PROJECT_NAME", "BaaS-Platform")

        self.config = {
            "subscription_id": os.getenv("SUBSCRIPTION_ID"),
            "location": os.getenv("LOCATION", "swedencentral"),
            "vnet_name": os.getenv("VNET_NAME"),
            "vnet_rg": os.getenv("VNET_RG"),
            "keyvault_name": os.getenv("KEYVAULT_NAME"),
            "keyvault_rg": os.getenv("KEYVAULT_RG"),
            "dcr_name": os.getenv("DCR_NAME"),
            "dcr_rg": os.getenv("DCR_RG"),
            "diagnostics_storage": os.getenv("DIAGNOSTICS_STORAGE"),
            "script_storage_account": os.getenv("SCRIPT_STORAGE_ACCOUNT"),
            "script_storage_container": os.getenv("SCRIPT_STORAGE_CONTAINER"),
            "script_blob_name_linux": os.getenv("SCRIPT_BLOB_NAME_LINUX"),
            "script_blob_name_windows": os.getenv("SCRIPT_BLOB_NAME_WINDOWS"),
        }

        self.csv_file_path = os.getenv("CSV_PATH", "./core/simplified-vms.csv")
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.sas_expiry_hours = int(os.getenv("SAS_EXPIRY_HOURS", "6"))
        self.enable_custom_scripts = True

        self.storage_standards = {
            "os_disk_type": "StandardSSD_LRS",
            "data_disk_type": "StandardSSD_LRS",
            "disk_caching": "ReadWrite",
            "data_disk_caching": "None",
        }

        self.validate_config()

    # ---------------- VALIDATION ----------------
    def validate_config(self):
        required = ["subscription_id", "vnet_name", "dcr_name"]
        missing = [k for k in required if not self.config.get(k)]
        if missing:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)
        print(f"[OK] Environment validated for {self.environment}")

    # ---------------- SAS GENERATION ----------------
    def _generate_sas_url(self, os_type: str) -> str:
        """Generate a time-bound SAS URL for a script after validating blob existence"""
        account = self.config["script_storage_account"]
        container = self.config["script_storage_container"]
        key = os.getenv("SCRIPT_STORAGE_KEY")

        if not key or not account or not container:
            print("[ERROR] Missing SCRIPT_STORAGE_KEY or storage account info.")
            sys.exit(1)

        blob = (
            self.config["script_blob_name_windows"]
            if os_type.lower() == "windows"
            else self.config["script_blob_name_linux"]
        )

        # Blob existence validation with retry (in case blob just uploaded)
        blob_service = BlobServiceClient(f"https://{account}.blob.core.windows.net", credential=key)
        blob_client = blob_service.get_blob_client(container=container, blob=blob)

        for attempt in range(1, 4):
            try:
                blob_client.get_blob_properties()
                print(f"[OK] Verified {os_type} script blob '{blob}' exists (attempt {attempt})")
                break
            except Exception as ex:
                if attempt < 3:
                    print(f"[WARN] Blob '{blob}' not found (attempt {attempt}), retrying...")
                    time.sleep(3)
                else:
                    print(f"[ERROR] Blob '{blob}' not accessible after 3 attempts: {ex}")
                    sys.exit(1)

        expiry = datetime.utcnow() + timedelta(hours=self.sas_expiry_hours)
        sas_token = generate_blob_sas(
            account_name=account,
            container_name=container,
            blob_name=blob,
            account_key=key,
            permission=BlobSasPermissions(read=True),
            expiry=expiry,
        )

        sas_url = f"https://{account}.blob.core.windows.net/{container}/{blob}?{sas_token}"
        masked = sas_token[:40] + "...(masked)"
        print(f"[SAS] Generated {os_type} SAS URL (valid {self.sas_expiry_hours}h) → sig={masked}")
        return sas_url

    # ---------------- TAGS ----------------
    def parse_tags(self) -> Dict[str, str]:
        tag_json = os.getenv("default_tags_json")
        if not tag_json:
            print("[ERROR] default_tags_json is required.")
            sys.exit(1)
        try:
            tags = json.loads(tag_json)
        except Exception:
            print("[ERROR] Invalid default_tags_json format.")
            sys.exit(1)

        tags.update({
            "CreatedBy": "Terraform",
            "CreationDate": datetime.now().strftime("%Y-%m-%d"),
            "Environment": self.environment,
            "Project": self.project_name,
        })
        return tags

    def _format_tags(self, tags: Dict[str, str]) -> str:
        return ",\n".join([f'    "{k}" = "{v}"' for k, v in tags.items()])

    # ---------------- OS TEMPLATE ----------------
    def resolve_os_template(self, template: str) -> Dict[str, str]:
        templates = {
            "windows-2019": {"os_type": "windows", "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer", "sku": "2019-Datacenter"},
            "ubuntu-22.04": {"os_type": "linux", "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy", "sku": "22_04-lts-gen2"},
            "rhel-8": {"os_type": "linux", "publisher": "RedHat", "offer": "RHEL", "sku": "8-LVM"},
        }
        return templates.get(template.lower(), templates["windows-2019"])

    # ---------------- TERRAFORM GENERATION ----------------
    def generate_terraform(self):
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        with open(self.output_tf_file, "w") as tf:
            self._write_provider_block(tf)
            self._process_csv(tf)
        print(f"[DONE] Terraform file generated → {self.output_tf_file}")

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

    def _process_csv(self, tf):
        try:
            with open(self.csv_file_path) as csvfile:
                reader = csv.DictReader(csvfile)
                for i, row in enumerate(reader, start=2):
                    vm_name = re.sub(r"[^0-9A-Za-z_]", "_", row.get("vm_name", ""))
                    if not vm_name:
                        continue
                    print(f"[INFO] Processing VM: {vm_name}")
                    self._generate_vm(tf, row, vm_name)
        except FileNotFoundError:
            print(f"[ERROR] CSV file not found: {self.csv_file_path}")
            sys.exit(1)

    def _generate_vm(self, tf, row, vm_name):
        os_template = row.get("os_template", "windows-2019")
        os_cfg = self.resolve_os_template(os_template)
        os_type = os_cfg["os_type"]
        tags = self._format_tags(self.parse_tags())
        subnet = row.get("subnet_name", "")
        ip = row.get("static_ip", "")
        rg = row.get("resource_group", "")
        size = row.get("vm_size", "Standard_D4s_v5")

        # SAS token generation
        sas_url = None
        if self.enable_custom_scripts:
            try:
                sas_url = self._generate_sas_url(os_type)
            except Exception as e:
                print(f"[WARN] SAS generation failed: {e}")

        tf.write(f'''
# ==== {vm_name} Resources ====
data "azurerm_subnet" "{vm_name}_subnet" {{
  name = "{subnet}"
  virtual_network_name = data.azurerm_virtual_network.main_vnet.name
  resource_group_name = "{self.config['vnet_rg']}"
}}

resource "azurerm_network_interface" "{vm_name}_nic" {{
  name = "{vm_name}-nic"
  location = var.location
  resource_group_name = "{rg}"
  ip_configuration {{
    name = "internal"
    subnet_id = data.azurerm_subnet.{vm_name}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address = "{ip}"
  }}
  tags = {{
{tags}
  }}
}}

resource "azurerm_{os_type}_virtual_machine" "{vm_name}" {{
  name = "{vm_name}"
  resource_group_name = "{rg}"
  location = var.location
  size = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  os_disk {{
    caching = "{self.storage_standards['disk_caching']}"
    storage_account_type = "{self.storage_standards['os_disk_type']}"
  }}
  source_image_reference {{
    publisher = "{os_cfg['publisher']}"
    offer = "{os_cfg['offer']}"
    sku = "{os_cfg['sku']}"
    version = "latest"
  }}
  tags = {{
{tags}
  }}
}}
''')

        if sas_url:
            command = (
                f"powershell -ExecutionPolicy Unrestricted -File {self.config['script_blob_name_windows']}"
                if os_type == "windows"
                else f"bash {self.config['script_blob_name_linux']}"
            )
            tf.write(f'''
resource "azurerm_virtual_machine_extension" "{vm_name}_script" {{
  name = "CustomScriptExtension"
  virtual_machine_id = azurerm_{os_type}_virtual_machine.{vm_name}.id
  publisher = "Microsoft.Compute"
  type = "CustomScriptExtension"
  type_handler_version = "1.9"
  settings = jsonencode({{
    fileUris = ["{sas_url}"]
    commandToExecute = "{command}"
  }})
  tags = {{
{tags}
  }}
}}
''')

# ---------------- MAIN ----------------
def main():
    print("[START] Enhanced Terraform VM Generator v2 (Final Production)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Terraform generation completed successfully.")

if __name__ == "__main__":
    main()