#!/usr/bin/env python3
"""
generate-tf-v2.5.py

Enhanced VM Creation Terraform Generator v2.5
- No cloud-init/custom_data
- Keeps DCR, boot diagnostics, auto-shutdown
- Adds automatic SAS generation for Windows and Linux Custom Script Extensions
- Restores full additional data disk support (up to 10 disks per VM)
- Primary SAS via Azure CLI, fallback to HMAC method if CLI unavailable
- Overwrites main-<env>.tf on each run (modify logic safe)
"""

import csv
import json
import os
import sys
import shutil
import subprocess
from datetime import datetime, timedelta
from typing import Dict, List, Optional
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
            # allow runtime toggle via env if desired — default True
            'enable_custom_script': os.getenv('ENABLE_CUSTOM_SCRIPT', 'true').lower() == 'true',
            'shutdown_enabled': os.getenv('shutdown_enabled', 'true').lower() == 'true',
            'shutdown_time': os.getenv('shutdown_time', '2000'),
            'shutdown_timezone': os.getenv('shutdown_timezone', 'Arab Standard Time')
        }

        # OS Templates (corporate standards)
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

        # Paths
        self.csv_file_path = os.getenv('CSV_PATH', './core/simplified-vms.csv')
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"
        self.resource_groups_to_create = set()

        # Validate
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
        print(f"[INFO] Custom Script Extensions enabled={self.config['enable_custom_script']}")

    # --------------------------
    # Tags
    # --------------------------
    def parse_tags(self) -> Dict[str, str]:
        json_tags = os.getenv('default_tags_json')
        if not json_tags:
            raise ValueError("Missing default_tags_json environment variable")
        tags = json.loads(json_tags)

        # Preserve CreationDate if it exists in previously generated file
        creation_date = None
        if os.path.exists(self.output_tf_file):
            try:
                with open(self.output_tf_file, 'r', encoding='utf-8') as f:
                    for line in f:
                        if '"CreationDate"' in line:
                            # crude extraction: find the "CreationDate" line, extract value between quotes after =
                            parts = line.split('=')
                            if len(parts) >= 2:
                                val_part = parts[1].strip().strip(',').strip().strip('"')
                                creation_date = val_part
                                break
            except Exception:
                pass

        tags['CreatedBy'] = 'Terraform'
        tags['CreationDate'] = creation_date or datetime.now().strftime('%Y-%m-%d')
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
    # SAS Token: Azure CLI primary, HMAC fallback
    # --------------------------
    def _try_az_cli_generate_sas(self, account: str, container: str, blob: str, validity_hours: int = 24) -> Optional[str]:
        """Use az CLI to generate a blob SAS token (preferred). Returns full URL or None."""
        if not shutil.which("az"):
            return None

        expiry_dt = (datetime.utcnow() + timedelta(hours=validity_hours)).strftime("%Y-%m-%dT%H:%MZ")
        cmd = [
            "az", "storage", "blob", "generate-sas",
            "--account-name", account,
            "--container-name", container,
            "--name", blob,
            "--permissions", "r",
            "--expiry", expiry_dt,
            "--auth-mode", "key",
            "--https-only"
        ]

        # If account key provided in env, use it (az will pick up from env/account), otherwise rely on logged-in SP
        # We capture stdout which should be the token only
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            token = result.stdout.strip().strip('"').strip("'")
            if not token:
                return None
            url = f"https://{account}.blob.core.windows.net/{container}/{blob}?{token}"
            print(f"[INFO] SAS via az CLI generated for {blob} (expires {expiry_dt})")
            return url
        except subprocess.CalledProcessError as e:
            print(f"[WARN] az CLI SAS generation failed: {e.stderr.strip() if e.stderr else e}")
            return None
        except Exception as e:
            print(f"[WARN] az CLI SAS generation unexpected error: {e}")
            return None

    def _hmac_generate_sas(self, account: str, container: str, blob: str, key: str, validity_hours: int = 24) -> Optional[str]:
        """Fallback SAS HMAC v2020-02-10 compatible generator. Returns full URL or None."""
        if not all([account, container, blob, key]):
            return None
        try:
            start = (datetime.utcnow() - timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%MZ')
            expiry = (datetime.utcnow() + timedelta(hours=validity_hours)).strftime('%Y-%m-%dT%H:%MZ')
            permissions = "r"
            resource = "b"
            signed_version = "2020-02-10"
            protocol = "https"

            # Build string_to_sign similar to storage SAS doc for service SAS (account key)
            # Order: permissions \n start \n expiry \n canonicalized resource \n signedIdentifier \n signedIP \n signedProtocol \n signedVersion \n rscc \n rscd \n rsce \n rscl \n rsct
            canonicalized_resource = f"/blob/{account}/{container}/{blob}"
            string_to_sign = (
                f"{permissions}\n"
                f"{start}\n"
                f"{expiry}\n"
                f"{canonicalized_resource}\n"
                f"\n"  # signedIdentifier
                f"\n"  # signedIP
                f"{protocol}\n"
                f"{signed_version}\n"
                f"\n" * 5  # rscc, rscd, rsce, rscl, rsct
            )

            decoded_key = base64.b64decode(key)
            signature = base64.b64encode(
                hmac.new(decoded_key, msg=string_to_sign.encode('utf-8'), digestmod=hashlib.sha256).digest()
            ).decode('utf-8')

            sas_token = (
                f"sv={signed_version}"
                f"&st={quote_plus(start)}"
                f"&se={quote_plus(expiry)}"
                f"&sr={resource}"
                f"&sp={permissions}"
                f"&spr={protocol}"
                f"&sig={quote_plus(signature)}"
            )
            url = f"https://{account}.blob.core.windows.net/{container}/{blob}?{sas_token}"
            print(f"[INFO] SAS via HMAC fallback generated for {blob} (expires {expiry})")
            return url
        except Exception as e:
            print(f"[WARN] HMAC SAS generation failed: {e}")
            return None

    def generate_blob_sas_url(self, account: str, container: str, blob: str, key: Optional[str], validity_hours: int = 24) -> Optional[str]:
        """Generate blob SAS: try az CLI first, then fallback to HMAC method using account key."""
        # Prefer az CLI approach
        url = self._try_az_cli_generate_sas(account, container, blob, validity_hours)
        if url:
            return url

        # Fallback to HMAC method if key provided
        if key:
            return self._hmac_generate_sas(account, container, blob, key, validity_hours)

        print("[WARN] No method available to generate SAS token (no az CLI or account key).")
        return None

    # --------------------------
    # Main Generator
    # --------------------------
    def generate_terraform(self):
        # ensure output dir exists
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)
        vm_outputs = []

        # Always overwrite main.tf for apply/modify generation
        try:
            with open(self.output_tf_file, "w", encoding='utf-8') as tf_file:
                self._write_provider_block(tf_file)
                self._collect_resource_groups()
                self._generate_resource_groups(tf_file)

                # Process CSV
                try:
                    with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
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

        # Verification: main.tf exists
        if not os.path.exists(self.output_tf_file):
            print(f"[ERROR] Terraform file not generated: {self.output_tf_file}")
            sys.exit(2)

        # If custom scripts are enabled, verify at least one SAS URL present in file (simple check)
        if self.config['enable_custom_script']:
            with open(self.output_tf_file, "r", encoding='utf-8') as tf_file:
                content = tf_file.read()
            if self.config['script_storage_account'] and (("blob.core.windows.net" not in content) or ("sv=" not in content)):
                print(f"[WARN] No SAS token found in generated Terraform file: {self.output_tf_file} — ensure SCRIPT_* env vars are set or az CLI available")
            else:
                print(f"[OK] Terraform configuration generated: {self.output_tf_file} (SAS tokens presence checked)")

        print(f"[OK] Terraform configuration generated: {self.output_tf_file}")
        print(f"[INFO] VMs included: {len(vm_outputs)}")

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
    # Resource Group Collection & Creation
    # --------------------------
    def _collect_resource_groups(self):
        try:
            with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if row.get("create_rg", "").lower() == "true":
                        rg = row.get("resource_group", "").strip()
                        if rg:
                            self.resource_groups_to_create.add(rg)
        except FileNotFoundError:
            pass

    def _generate_resource_groups(self, tf_file):
        if not self.resource_groups_to_create:
            return
        tf_file.write("\n# ==== Resource Groups ====\n")
        for rg in sorted(self.resource_groups_to_create):
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
    # VM Generation
    # --------------------------
    def _generate_vm_resources(self, tf_file, row: Dict[str, str]):
        vm_name = row["vm_name"].strip()
        resource_group = row["resource_group"].strip()
        subnet_name = row["subnet_name"].strip()
        static_ip = row.get("static_ip", "").strip()
        vm_size = row.get("vm_size", "Standard_D4s_v5").strip()
        os_template = row.get("os_template", "windows-2019").strip()
        os_config = self.resolve_os_template(os_template)
        os_type = os_config['os_type']
        tags = self.parse_tags()
        tags_str = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
        create_rg = row.get("create_rg", "false").lower() == "true"

        rg_ref = f'"{resource_group}"'
        depends_on_str = ""
        if create_rg:
            rg_var = resource_group.replace("-", "_")
            rg_ref = f'azurerm_resource_group.{rg_var}_rg.name'
            depends_on_str = f'  depends_on = [azurerm_resource_group.{rg_var}_rg]\n'

        # Prepare collection of additional disks (up to 10)
        additional_disks = []
        for i in range(1, 11):
            disk_name = row.get(f"disk_name_{i}", "") or row.get(f"disk_{i}_name", "")
            disk_size = row.get(f"disk_size_gb_{i}", "") or row.get(f"disk_{i}_size", "")
            disk_lun = row.get(f"disk_lun_{i}", "") or row.get(f"disk_{i}_lun", "") or row.get(f"disk_{i}_lun", "")
            disk_type = row.get(f"storage_type_{i}", "") or row.get(f"disk_{i}_type", "") or self.storage_standards['data_disk_type']
            if disk_name and disk_size and disk_lun:
                try:
                    lun_int = int(disk_lun)
                except Exception:
                    lun_int = None
                if lun_int is not None:
                    additional_disks.append({
                        "name": disk_name.strip(),
                        "size": disk_size.strip(),
                        "lun": lun_int,
                        "storage_type": disk_type.strip()
                    })

        # Write subnet data source, key vault secret data source and NIC
        tf_file.write(f'''
# ==== {vm_name} ====
data "azurerm_subnet" "{vm_name}_subnet" {{
  name                 = "{subnet_name}"
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

        # Create managed disks resources first (if any)
        if additional_disks:
            for disk in additional_disks:
                disk_resource_name = disk['name'].replace('-', '_')
                tf_file.write(f'''
resource "azurerm_managed_disk" "{disk_resource_name}" {{
  name                 = "{disk['name']}"
  location             = var.location
  resource_group_name  = {rg_ref}
  storage_account_type = "{disk['storage_type']}"
  create_option        = "Empty"
  disk_size_gb         = {disk['size']}

  tags = {{
    {tags_str}
  }}
}}
''')

        # Generate VM resource and attachments by OS type
        if os_type == "linux":
            self._write_linux_vm(tf_file, vm_name, vm_size, tags_str, os_config, rg_ref, additional_disks)
        else:
            self._write_windows_vm(tf_file, vm_name, vm_size, tags_str, os_config, rg_ref, additional_disks)

        # Create azurerm_virtual_machine_data_disk_attachment resources for each disk
        if additional_disks:
            vm_resource_type = "linux_virtual_machine" if os_type == "linux" else "windows_virtual_machine"
            for disk in additional_disks:
                disk_res_name = disk['name'].replace('-', '_')
                attach_name = f"{vm_name}_{disk_res_name}_attach"
                tf_file.write(f'''
resource "azurerm_virtual_machine_data_disk_attachment" "{attach_name}" {{
  managed_disk_id    = azurerm_managed_disk.{disk_res_name}.id
  virtual_machine_id = azurerm_{vm_resource_type}.{vm_name}.id
  lun                = {disk['lun']}
  create_option      = "Attach"
  caching            = "{self.storage_standards['data_disk_caching']}"
}}
''')

        # Add DCR, Monitor Agent and Auto-shutdown
        self._generate_dcr_and_shutdown(tf_file, vm_name, os_type, tags_str)

    # --------------------------
    # Linux VM writer (no custom_data)
    # --------------------------
    def _write_linux_vm(self, tf_file, vm_name, vm_size, tags_str, os_image, rg_ref, additional_disks):
        script_enabled = self.config['enable_custom_script']
        script_sas_url = None
        if script_enabled and self.config['script_storage_account'] and self.config['script_storage_container'] and self.config['script_blob_name_linux']:
            script_sas_url = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_linux'],
                self.config.get('script_storage_key')
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

        # Custom Script Extension for Linux (if SAS available)
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
        elif script_enabled:
            tf_file.write(f"# [WARN] Linux script extension skipped for {vm_name} (SAS generation failed)\n")

    # --------------------------
    # Windows VM writer
    # --------------------------
    def _write_windows_vm(self, tf_file, vm_name, vm_size, tags_str, os_image, rg_ref, additional_disks):
        script_enabled = self.config['enable_custom_script']
        script_sas_url = None
        if script_enabled and self.config['script_storage_account'] and self.config['script_storage_container'] and self.config['script_blob_name_windows']:
            script_sas_url = self.generate_blob_sas_url(
                self.config['script_storage_account'],
                self.config['script_storage_container'],
                self.config['script_blob_name_windows'],
                self.config.get('script_storage_key')
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

        # Custom Script Extension for Windows (if SAS available)
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
        elif script_enabled:
            tf_file.write(f"# [WARN] Windows script extension skipped for {vm_name} (SAS generation failed)\n")

    # --------------------------
    # DCR + Shutdown + AMA
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
    print("[START] Terraform Generator v2.5 (Auto SAS + full multi-disk support)")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Terraform configuration generated successfully")

if __name__ == "__main__":
    main()