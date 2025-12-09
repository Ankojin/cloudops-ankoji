#!/usr/bin/env python3
"""
generate-tf-v2.8.py

FINAL generator v2.8 (Option A)

- Supports Windows & Linux VMs
- Supports up to 10 data disks per VM
- Managed disk resources + attachment resources emitted per-VM after VM block
- Order within each VM: NIC -> VM -> Managed Disks -> Attachments -> AMA -> DCR -> Shutdown -> Custom Script (LAST)
- Uses SAS URLs supplied via environment variables (SAS_URL_WINDOWS, SAS_URL_LINUX)
- Tags read from DEFAULT_TAGS_JSON environment variable (stringified JSON)
- Outputs: ./Project/<project>/main-<env>.tf
- CSV default path: ./core/simplified-vms.csv
"""

import csv
import json
import os
import sys
import re
from datetime import datetime
from typing import Dict, List, Optional

# ---- Helpers ----------------------------------------------------------------

def uc(env: dict, key: str, default: Optional[str] = None) -> Optional[str]:
    """Case-insensitive fetch from environment mapping where keys already uppercased."""
    return env.get(key.upper(), default)

def safe(val: Optional[str]) -> str:
    return (val or "").strip()

def choose(*candidates):
    for c in candidates:
        if c is not None and str(c).strip() != "":
            return str(c).strip()
    return None

def validate_vm_name(name: str) -> bool:
    """Validate VM name follows Azure naming conventions"""
    if not name or len(name) > 64:
        return False
    # Azure VM names: alphanumeric and hyphens, can't start/end with hyphen
    pattern = r'^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,62}[a-zA-Z0-9])?$'
    return bool(re.match(pattern, name))

def validate_ip_address(ip: str) -> bool:
    """Validate IP address format"""
    pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
    if not re.match(pattern, ip):
        return False
    # Check octets are 0-255
    octets = ip.split('.')
    return all(0 <= int(octet) <= 255 for octet in octets)

def map_os_template(os_template: str) -> dict:
    """Map CSV os_template to Azure image reference details"""
    template = os_template.lower().strip()
    
    # OS template mappings
    mappings = {
        # RHEL
        "rhel-9": {
            "publisher": "RedHat",
            "offer": "RHEL",
            "sku": "9-lvm-gen2",
            "version": "latest",
            "is_linux": True
        },
        "rhel-9.6": {
            "publisher": "RedHat",
            "offer": "RHEL",
            "sku": "96-gen2",
            "version": "latest",
            "is_linux": True
        },
        "rhel-8": {
            "publisher": "RedHat",
            "offer": "RHEL",
            "sku": "8-lvm-gen2",
            "version": "latest",
            "is_linux": True
        },
        "rhel-7": {
            "publisher": "RedHat",
            "offer": "RHEL",
            "sku": "7-LVM",
            "version": "latest",
            "is_linux": True
        },
        # Ubuntu
        "ubuntu-22": {
            "publisher": "Canonical",
            "offer": "0001-com-ubuntu-server-jammy",
            "sku": "22_04-lts-gen2",
            "version": "latest",
            "is_linux": True
        },
        "ubuntu-20": {
            "publisher": "Canonical",
            "offer": "0001-com-ubuntu-server-focal",
            "sku": "20_04-lts-gen2",
            "version": "latest",
            "is_linux": True
        },
        # Windows Server
        "windows-2022": {
            "publisher": "MicrosoftWindowsServer",
            "offer": "WindowsServer",
            "sku": "2022-Datacenter",
            "version": "latest",
            "is_linux": False
        },
        "windows-2019": {
            "publisher": "MicrosoftWindowsServer",
            "offer": "WindowsServer",
            "sku": "2019-Datacenter",
            "version": "latest",
            "is_linux": False
        },
        "windows-2016": {
            "publisher": "MicrosoftWindowsServer",
            "offer": "WindowsServer",
            "sku": "2016-Datacenter",
            "version": "latest",
            "is_linux": False
        }
    }
    
    if template in mappings:
        return mappings[template]
    
    # Fallback: Try to detect by prefix
    if template.startswith("rhel"):
        print(f"[WARN] Unknown RHEL version '{os_template}', defaulting to RHEL 9")
        return mappings["rhel-9"]
    elif template.startswith("ubuntu"):
        print(f"[WARN] Unknown Ubuntu version '{os_template}', defaulting to Ubuntu 22.04")
        return mappings["ubuntu-22"]
    elif template.startswith("windows"):
        print(f"[WARN] Unknown Windows version '{os_template}', defaulting to Windows Server 2022")
        return mappings["windows-2022"]
    else:
        print(f"[WARN] Unknown os_template '{os_template}', defaulting to Windows Server 2022")
        return mappings["windows-2022"]

# ---- Generator Class -------------------------------------------------------

class TerraformVMGenerator:
    def __init__(self):
        # Normalize env keys to UPPER for easy access
        raw_env = {k.upper(): v for k, v in os.environ.items()}

        self.environment = uc(raw_env, "ENVIRONMENT", "DEV")
        self.project_name = uc(raw_env, "PROJECT_NAME")
        if not self.project_name:
            print("[ERROR] PROJECT_NAME environment variable is required.")
            sys.exit(1)

        # Paths and CSV
        self.csv_file_path = uc(raw_env, "CSV_PATH", "./core/simplified-vms.csv")
        self.output_tf_file = f"./Project/{self.project_name}/main-{self.environment.lower()}.tf"

        # Basic config from environment (pipeline will set these)
        self.config = {
            "subscription_id": uc(raw_env, "SUBSCRIPTION_ID"),
            "location": uc(raw_env, "LOCATION", "swedencentral"),
            "vnet_name": uc(raw_env, "VNET_NAME"),
            "vnet_rg": uc(raw_env, "VNET_RG"),
            "subnet_rg": uc(raw_env, "SUBNET_RG"),
            "keyvault_name": uc(raw_env, "KEYVAULT_NAME"),
            "keyvault_rg": uc(raw_env, "KEYVAULT_RG"),
            "dcr_name": uc(raw_env, "DCR_NAME"),
            "dcr_rg": uc(raw_env, "DCR_RG"),
            "diagnostics_storage": uc(raw_env, "DIAGNOSTICS_STORAGE"),
            "diagnostics_storage_rg": uc(raw_env, "DIAGNOSTICS_STORAGE_RG"),
            # SAS URLs should be produced by the pipeline and passed as env vars
            "sas_url_windows": uc(raw_env, "SAS_URL_WINDOWS"),
            "sas_url_linux": uc(raw_env, "SAS_URL_LINUX"),
            # Tags
            "default_tags_json": uc(raw_env, "DEFAULT_TAGS_JSON") or uc(raw_env, "TAGS_JSON_OVERRIDE"),
            # Shutdown controls
            "shutdown_enabled": (uc(raw_env, "SHUTDOWN_ENABLED", "true").lower() == "true"),
            "shutdown_time": uc(raw_env, "SHUTDOWN_TIME", "2000"),
            "shutdown_timezone": uc(raw_env, "SHUTDOWN_TIMEZONE", "Arab Standard Time"),
        }

        # Collection of resource groups to create (if CSV asks)
        self.resource_groups_to_create = set()

        self.validate_config()

    def validate_config(self):
        required = ["subscription_id", "vnet_name", "keyvault_name", "dcr_name", "location"]
        missing = [r for r in required if not self.config.get(r)]
        if missing:
            print(f"[ERROR] Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)
        # Ensure tags valid JSON
        if not self.config.get("default_tags_json"):
            print("[ERROR] DEFAULT_TAGS_JSON (or pipeline tags_json_override) must be set.")
            sys.exit(1)
        try:
            json.loads(self.config["default_tags_json"])
        except Exception as e:
            print(f"[ERROR] DEFAULT_TAGS_JSON is not valid JSON: {e}")
            sys.exit(1)
        
        # Validate subscription ID format (GUID)
        sub_id = self.config.get("subscription_id", "")
        guid_pattern = r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        if not re.match(guid_pattern, sub_id):
            print(f"[ERROR] Invalid subscription_id format: {sub_id}")
            sys.exit(1)

        print(f"[OK] Generator configuration ready. Environment={self.environment}")
        print(f"[OK] CSV path = {self.csv_file_path}")
        print(f"[OK] Output TF file = {self.output_tf_file}")

    # ----- Tags -----
    def parse_tags(self) -> Dict[str, str]:
        tags = json.loads(self.config["default_tags_json"])
        # Preserve CreationDate if present in existing TF
        creation_date = None
        if os.path.exists(self.output_tf_file):
            try:
                with open(self.output_tf_file, "r", encoding="utf-8") as f:
                    for line in f:
                        if '"CreationDate"' in line:
                            # crude parse
                            parts = line.split("=")
                            if len(parts) >= 2:
                                creation_date = parts[1].strip().strip('", ')
                            break
            except Exception:
                pass

        tags["CreatedBy"] = "Terraform"
        tags["CreationDate"] = creation_date or datetime.now().strftime("%Y-%m-%d")
        tags["Environment"] = self.environment
        tags["Project"] = self.project_name
        return tags

    # ----- Provider / Data sources -----
    def _write_provider_block(self, tf):
        tf.write(f"""terraform {{
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

# Ensure var.location exists so resources can reference var.location in generated TF
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

    # ----- Resource groups collection -----
    def _collect_resource_groups(self):
        try:
            with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                reader = csv.DictReader(csvfile)
                for row in reader:
                    if row.get("create_rg", "").strip().lower() == "true":
                        rg = safe(row.get("resource_group"))
                        if rg:
                            self.resource_groups_to_create.add(rg)
        except FileNotFoundError:
            print(f"[WARN] CSV file not found at {self.csv_file_path} — no VMs will be generated.")
        except Exception as e:
            print(f"[WARN] Error reading CSV for RG collection: {e}")

    def _generate_resource_groups(self, tf):
        if not self.resource_groups_to_create:
            return
        tf.write("\n# ==== Resource Groups to create ====\n")
        tags = self.parse_tags()
        tags_lines = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])
        for rg in sorted(self.resource_groups_to_create):
            safe_rg = rg.replace("-", "_")
            tf.write(f"""
resource "azurerm_resource_group" "{safe_rg}_rg" {{
  name     = "{rg}"
  location = var.location

  tags = {{
    {tags_lines}
  }}
}}
""")

    # ----- VM generator (top-level per-row) -----
    def _generate_vm_from_row(self, tf, row):
        vm_name = safe(row.get("vm_name"))
        if not vm_name:
            return
        
        # Validate VM name
        if not validate_vm_name(vm_name):
            print(f"[ERROR] Invalid VM name: {vm_name}")
            print(f"[ERROR] VM names must be 1-64 chars, alphanumeric and hyphens only")
            sys.exit(1)

        resource_group = safe(row.get("resource_group"))
        subnet_name = safe(row.get("subnet_name"))
        static_ip = safe(row.get("static_ip"))
        vm_size = safe(row.get("vm_size")) or "Standard_D4s_v5"
        os_template = safe(row.get("os_template")) or "windows-2022"
        create_rg = safe(row.get("create_rg")).lower() == "true"
        
        # Validate required fields
        if not all([resource_group, subnet_name, static_ip]):
            print(f"[ERROR] VM {vm_name}: Missing required fields (resource_group, subnet_name, or static_ip)")
            sys.exit(1)
        
        # Validate IP address
        if not validate_ip_address(static_ip):
            print(f"[ERROR] VM {vm_name}: Invalid IP address format: {static_ip}")
            sys.exit(1)

        # Map OS template to image details
        image_details = map_os_template(os_template)
        is_linux = image_details["is_linux"]
        
        print(f"[INFO] VM {vm_name}: Using {os_template} -> {image_details['publisher']}/{image_details['offer']}/{image_details['sku']}")

        tags = self.parse_tags()
        tags_block = ",\n    ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

        # Compute rg reference if create_rg true
        if create_rg and resource_group:
            rg_ref = f'azurerm_resource_group.{resource_group.replace("-", "_")}_rg.name'
            depends_on_rg = True
        else:
            rg_ref = f'"{resource_group}"'
            depends_on_rg = False

        # Build depends_on line if needed
        depends_on_line = ""
        if depends_on_rg:
            depends_on_line = f'  depends_on = [azurerm_resource_group.{resource_group.replace("-", "_")}_rg]\n'

        # ----- NIC & supporting data sources -----
        tf.write(f"""
# =====================================================
# VM: {vm_name} (OS: {'linux' if is_linux else 'windows'})
# =====================================================

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
{depends_on_line}  ip_configuration {{
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.{vm_name}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "{static_ip}"
  }}

  tags = {{
    {tags_block}
  }}
}}
""")

        # ----- VM resource (Linux or Windows) -----
        if is_linux:
            self._emit_linux_vm(tf, vm_name, vm_size, rg_ref, tags_block, image_details)
        else:
            self._emit_windows_vm(tf, vm_name, vm_size, rg_ref, tags_block, image_details)

        # ----- Managed disks & attachments (up to 10) -----
        # Accept CSV fields naming variations: disk_1_size, disk1_size, disk_size_1, disk_1_size_gb
        for i in range(1, 11):
            possible_keys = [
                f"disk_{i}_size", f"disk{i}_size", f"disk_size_{i}",
                f"disk_{i}_size_gb", f"disk_{i}_sizegb", f"disk_{i}_size_gb"
            ]
            size = None
            for k in possible_keys:
                size = row.get(k)
                if size and str(size).strip():
                    size = str(size).strip()
                    break
            if not size:
                # older CSV format maybe disk_1_size (already covered), else skip
                continue

            disk_name = f"{vm_name}-data-{i}"
            safe_rg_ref = rg_ref

            tf.write(f"""
resource "azurerm_managed_disk" "{disk_name.replace('-', '_')}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = {safe_rg_ref}
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = {size}

  tags = {{
    {tags_block}
  }}
}}
""")

            vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
            tf.write(f"""
resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_{disk_name.replace('-', '_')}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{disk_name.replace('-', '_')}.id
  virtual_machine_id = azurerm_{vm_type}.{vm_name}.id
  lun                = {i}
  create_option      = "Attach"
  caching            = "None"
}}
""")

        # ----- Monitoring (AMA), DCR association, Shutdown -----
        self._emit_monitoring_and_shutdown(tf, vm_name, tags_block, is_linux)

        # ----- Custom Script Extension LAST -----
        self._emit_custom_script_extension(tf, vm_name, tags_block, is_linux)

    # ----- Windows VM block -----
    def _emit_windows_vm(self, tf, vm_name, size, rg_ref, tags_block, image_details):
        tf.write("""
resource "azurerm_windows_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  location            = var.location
  resource_group_name = {rg_ref}
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  license_type   = "Windows_Server"

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  source_image_reference {{
    publisher = "{publisher}"
    offer     = "{offer}"
    sku       = "{sku}"
    version   = "{version}"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{diagnostics_storage}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_block}
  }}
}}
""".format(
            vm_name=vm_name,
            rg_ref=rg_ref,
            size=size,
            diagnostics_storage=self.config['diagnostics_storage'],
            tags_block=tags_block,
            publisher=image_details['publisher'],
            offer=image_details['offer'],
            sku=image_details['sku'],
            version=image_details['version']
        ))

    # ----- Linux VM block -----
    def _emit_linux_vm(self, tf, vm_name, size, rg_ref, tags_block, image_details):
        tf.write("""
resource "azurerm_linux_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  location            = var.location
  resource_group_name = {rg_ref}
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm_name}_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  disable_password_authentication = false

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }}

  source_image_reference {{
    publisher = "{publisher}"
    offer     = "{offer}"
    sku       = "{sku}"
    version   = "{version}"
  }}

  boot_diagnostics {{
    storage_account_uri = "https://{diagnostics_storage}.blob.core.windows.net/"
  }}

  tags = {{
    {tags_block}
  }}
}}
""".format(
            vm_name=vm_name,
            rg_ref=rg_ref,
            size=size,
            diagnostics_storage=self.config['diagnostics_storage'],
            tags_block=tags_block,
            publisher=image_details['publisher'],
            offer=image_details['offer'],
            sku=image_details['sku'],
            version=image_details['version']
        ))

    # ----- Monitoring & Shutdown -----
    def _emit_monitoring_and_shutdown(self, tf, vm_name, tags_block, is_linux):
        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
        # choose publisher/type based on OS
        os_label = "Linux" if is_linux else "Windows"
        tf.write(f"""
# Azure Monitor Agent + DCR + Auto-shutdown for {vm_name}
resource "azurerm_virtual_machine_extension" "{vm_name}_ama" {{
  name                       = "AzureMonitorAgent"
  virtual_machine_id         = azurerm_{vm_type}.{vm_name}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitor{os_label}Agent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {{
    {tags_block}
  }}
}}

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}_dcr" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_{vm_type}.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}

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
    {tags_block}
  }}
}}
""")

    # ----- Custom Script Extension (LAST) -----
    def _emit_custom_script_extension(self, tf, vm_name, tags_block, is_linux):
        sas_url = self.config["sas_url_linux"] if is_linux else self.config["sas_url_windows"]
        if not sas_url:
            tf.write(f"# [WARN] Custom Script skipped for {vm_name} — no SAS URL provided in pipeline env.\n")
            return

        # DEBUG: Print the actual SAS URL received
        print(f"[DEBUG] SAS URL for {vm_name}: {sas_url[:100]}..." if len(sas_url) > 100 else f"[DEBUG] SAS URL for {vm_name}: {sas_url}")

        # Extract blob filename: Split on ? first to remove query params, then get filename
        # URL format: https://account.blob.core.windows.net/container/filename.sh?sas_params
        try:
            url_without_query = sas_url.split("?")[0]
            print(f"[DEBUG] URL without query: {url_without_query}")
            # Get everything after the last / (the filename)
            blob_file = url_without_query.split("/")[-1]
            print(f"[DEBUG] Extracted blob_file: {blob_file}")
            
            # Validate we got a filename with extension
            if not blob_file or "." not in blob_file:
                print(f"[WARN] Could not extract valid filename from SAS URL for {vm_name}")
                blob_file = "script.sh" if is_linux else "script.ps1"
        except Exception as e:
            print(f"[ERROR] Failed to parse SAS URL for {vm_name}: {e}")
            blob_file = "script.sh" if is_linux else "script.ps1"
        
        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"
        publisher = "Microsoft.Azure.Extensions" if is_linux else "Microsoft.Compute"
        extension_type = "CustomScript" if is_linux else "CustomScriptExtension"
        handler_version = "2.0" if is_linux else "2.1"

        # Command string (no f-string!)
        if is_linux:
            command = "sh {}".format(blob_file)
        else:
            command = "powershell -ExecutionPolicy Unrestricted -File {}".format(blob_file)

        # Write using .format() to avoid backslash escaping issues
        tf.write("""
# Custom Script Extension (LAST) for {vm_name}
resource "azurerm_virtual_machine_extension" "{vm_name}_customscript" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_{vm_type}.{vm_name}.id
  publisher            = "{publisher}"
  type                 = "{extension_type}"
  type_handler_version = "{handler_version}"

  settings = jsonencode({{
    fileUris        = ["{sas_url}"],
    commandToExecute = "{command}"
  }})

  tags = {{
    {tags_block}
  }}
}}
""".format(
    vm_name=vm_name,
    vm_type=vm_type,
    publisher=publisher,
    extension_type=extension_type,
    handler_version=handler_version,
    sas_url=sas_url,
    command=command,
    tags_block=tags_block
))
    
    # ----- Outputs -----
    def _generate_outputs(self, tf, vm_names: List[str]):
        tf.write("\n# ==== Outputs ====\n")
        tf.write('output "vm_private_ips" {\n  value = {\n')
        for vm in vm_names:
            tf.write(f'    "{vm}" = azurerm_network_interface.{vm}_nic.private_ip_address\n')
        tf.write("  }\n}\n")

    # ----- Main generate method -----
    def generate_terraform(self):
        # ensure output dir exists
        os.makedirs(os.path.dirname(self.output_tf_file), exist_ok=True)

        vm_names = []
        seen_ips = set()
        validation_errors = []

        # Write TF
        try:
            with open(self.output_tf_file, "w", encoding="utf-8") as tf:
                self._write_provider_block(tf)
                self._collect_resource_groups()
                self._generate_resource_groups(tf)

                # Read CSV
                try:
                    with open(self.csv_file_path, newline='', encoding='utf-8') as csvfile:
                        reader = csv.DictReader(csvfile)
                        for row_num, row in enumerate(reader, start=2):  # Start at 2 (header is row 1)
                            if not row.get("vm_name") or not str(row.get("vm_name")).strip():
                                continue
                            
                            vm = safe(row.get("vm_name"))
                            
                            # Check for duplicate VM names
                            if vm in vm_names:
                                validation_errors.append(f"Row {row_num}: Duplicate VM name '{vm}'")
                            else:
                                vm_names.append(vm)
                            
                            # Check for duplicate IPs
                            ip = safe(row.get("static_ip"))
                            if ip in seen_ips:
                                validation_errors.append(f"Row {row_num}: Duplicate IP address '{ip}' for VM '{vm}'")
                            else:
                                seen_ips.add(ip)
                            
                            # Generate VM resources
                            self._generate_vm_from_row(tf, row)
                            
                except FileNotFoundError:
                    print(f"[ERROR] CSV file not found: {self.csv_file_path}")
                    sys.exit(1)
                except Exception as e:
                    print(f"[ERROR] Error reading CSV: {e}")
                    sys.exit(2)

                # Report validation errors
                if validation_errors:
                    print(f"\n[ERROR] CSV Validation Failed:")
                    for error in validation_errors:
                        print(f"  - {error}")
                    sys.exit(2)

                # Outputs
                self._generate_outputs(tf, vm_names)

        except Exception as e:
            print(f"[ERROR] Failed to write TF file {self.output_tf_file}: {e}")
            sys.exit(3)

        print(f"[OK] Terraform file generated: {self.output_tf_file}")
        print(f"[INFO] VMs included: {len(vm_names)}")
        print(f"[INFO] Unique IPs: {len(seen_ips)}")

# ---- Main ------------------------------------------------------------------

def main():
    print("[START] Terraform Generator v2.8")
    gen = TerraformVMGenerator()
    gen.generate_terraform()
    print("[SUCCESS] Completed Terraform Generation")

if __name__ == "__main__":
    main()