#!/usr/bin/env python3
"""
generate-tf-v2.7.py
----------------------------------------

FINAL VERSION (Option A — Recommended)

✔ Clean grouping per VM:
    NIC → VM → Data Disks → AMA → DCR → Shutdown → CustomScript (LAST)
✔ Supports Windows + Linux
✔ Supports up to 10 data disks
✔ No blocks outside VM grouping
✔ No duplicate resources
✔ No SAS generation inside Python
✔ Uses pipeline-provided SAS URLs
✔ Correct tag merging with CreationDate preservation
✔ Stable for Modify mode (no forced destroy)
✔ Compatible with v2.6 Azure DevOps pipeline

"""

import csv
import json
import os
import sys
from datetime import datetime


class TerraformVMGenerator:

    def __init__(self):
        env = {k.upper(): v for k, v in os.environ.items()}

        # -------------------------
        # Core environment context
        # -------------------------
        self.environment = env.get("ENVIRONMENT", "DEV")
        self.project_name = env.get("PROJECT_NAME")
        if not self.project_name:
            raise Exception("ERROR: PROJECT_NAME is missing!")

        # -------------------------
        # Configuration from pipeline
        # -------------------------
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

            # SAS URLs from pipeline (Option A)
            "sas_url_windows": env.get("SAS_URL_WINDOWS"),
            "sas_url_linux": env.get("SAS_URL_LINUX"),

            # Shutdown
            "shutdown_enabled": str(env.get("SHUTDOWN_ENABLED", "true")).lower() == "true",
            "shutdown_time": env.get("SHUTDOWN_TIME", "2000"),
            "shutdown_timezone": env.get("SHUTDOWN_TIMEZONE", "Arab Standard Time"),
        }

        # -------------------------
        # Paths
        # -------------------------
        self.csv_path = env.get("CSV_PATH", "./core/simplified-vms.csv")
        self.output_tf = f"./Project/{self.project_name}/main-{self.environment}.tf"

        # Resource group creation tracking
        self.resource_groups_to_create = set()

        # Default tags from pipeline variable
        self.default_tags = self.load_default_tags()

        # Validate minimal config
        self.validate()


    # =============================================================================
    # TAGS
    # =============================================================================
    def load_default_tags(self):
        raw = os.getenv("DEFAULT_TAGS_JSON")
        if not raw:
            raise Exception("DEFAULT_TAGS_JSON missing")

        tags = json.loads(raw)

        # Preserve "CreationDate" if already present
        creation_date = None
        if os.path.exists(self.output_tf):
            with open(self.output_tf, "r", encoding="utf-8") as f:
                for line in f:
                    if '"CreationDate"' in line:
                        parts = line.split("=")
                        if len(parts) >= 2:
                            creation_date = parts[1].replace('"', "").replace(",", "").strip()
                        break

        tags["CreatedBy"] = "Terraform"
        tags["CreationDate"] = creation_date or datetime.now().strftime("%Y-%m-%d")
        tags["Environment"] = self.environment
        tags["Project"] = self.project_name

        return tags

    def tags_to_hcl(self):
        return ",\n    ".join([f'"{k}" = "{v}"' for k, v in self.default_tags.items()])


    # =============================================================================
    # VALIDATION
    # =============================================================================
    def validate(self):
        required = ["subscription_id", "location", "vnet_name", "keyvault_name", "dcr_name"]
        missing = [x for x in required if not self.config.get(x)]
        if missing:
            print(f"[ERROR] Missing variables: {', '.join(missing)}")
            sys.exit(1)

        print(f"[OK] Generator v2.7 config loaded. ENV={self.environment}")


    # =============================================================================
    # PROVIDER + DATA SOURCES
    # =============================================================================
    def write_provider_block(self, tf):
        tf.write(f"""
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


    # =============================================================================
    # RESOURCE GROUP CREATION
    # =============================================================================
    def collect_resource_groups(self):
        try:
            with open(self.csv_path, newline='', encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    if row.get("create_rg", "").lower() == "true":
                        rg = row.get("resource_group", "").strip()
                        if rg:
                            self.resource_groups_to_create.add(rg)
        except FileNotFoundError:
            pass

    def write_resource_groups(self, tf):
        if not self.resource_groups_to_create:
            return

        tags = self.tags_to_hcl()

        tf.write("\n# =====================================================\n")
        tf.write("# RESOURCE GROUPS\n")
        tf.write("# =====================================================\n")

        for rg in sorted(self.resource_groups_to_create):
            safe = rg.replace("-", "_")
            tf.write(f"""
resource "azurerm_resource_group" "{safe}_rg" {{
  name     = "{rg}"
  location = var.location
  tags = {{
    {tags}
  }}
}}
""")


    # =============================================================================
    # VM BLOCKS
    # =============================================================================
    def write_vm_block(self, tf, row):
        vm = row["vm_name"].strip()
        rg = row["resource_group"].strip()
        subnet = row["subnet_name"].strip()
        static_ip = row.get("static_ip", "").strip()
        size = row.get("vm_size", "Standard_D4s_v5")

        os_template = row.get("os_template", "windows-2019").lower()
        is_linux = os_template.startswith("ubuntu") or os_template.startswith("rhel")

        tags = self.tags_to_hcl()

        tf.write(f"""
# ======================================================
# VM: {vm}
# ======================================================

## NIC
data "azurerm_subnet" "{vm}_subnet" {{
  name                 = "{subnet}"
  resource_group_name  = "{self.config['vnet_rg']}"
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
    {tags}
  }}
}}
""")

        # ---------------------------------------------------------
        # WINDOWS / LINUX VM
        # ---------------------------------------------------------
        if is_linux:
            self.write_linux_vm(tf, vm, size, rg, tags)
        else:
            self.write_windows_vm(tf, vm, size, rg, tags)

        # ---------------------------------------------------------
        # DATA DISKS
        # ---------------------------------------------------------
        for n in range(1, 11):
            size_gb = row.get(f"disk_{n}_size")
            if not size_gb:
                continue

            disk_name = f"{vm}_disk_{n}"

            create_rg = row.get("create_rg", "false").lower() == "true"
            safe_rg = rg.replace("-", "_")

            rg_ref = (
                f'azurerm_resource_group.{safe_rg}_rg.name'
                if create_rg else
                f'"{rg}"'
            )

            depends = (
                f'depends_on = [azurerm_resource_group.{safe_rg}_rg]'
                if create_rg else
                ""
            )

            tf.write(f"""
## Data Disk {n}
resource "azurerm_managed_disk" "{disk_name}" {{
  name                 = "{disk_name}"
  location             = var.location
  resource_group_name  = {rg_ref}
  {depends}
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = {size_gb}

  tags = {{
    {tags}
  }}
}}

resource "azurerm_virtual_machine_data_disk_attachment" "{disk_name}_attach" {{
  managed_disk_id    = azurerm_managed_disk.{disk_name}.id
  virtual_machine_id = azurerm_{'linux' if is_linux else 'windows'}_virtual_machine.{vm}.id
  lun                = {n}
  create_option      = "Attach"
  caching            = "None"
}}
""")

        vm_type = "linux_virtual_machine" if is_linux else "windows_virtual_machine"

        # ---------------------------------------------------------
        # AMA
        # ---------------------------------------------------------
        tf.write(f"""
## Azure Monitor Agent
resource "azurerm_virtual_machine_extension" "{vm}_ama" {{
  name                       = "AzureMonitorAgent"
  virtual_machine_id         = azurerm_{vm_type}.{vm}.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitor{'Linux' if is_linux else 'Windows'}Agent"
  type_handler_version       = "1.30"
  automatic_upgrade_enabled  = true

  tags = {{
    {tags}
  }}
}}
""")

        # ---------------------------------------------------------
        # DCR association
        # ---------------------------------------------------------
        tf.write(f"""
## DCR Association
resource "azurerm_monitor_data_collection_rule_association" "{vm}_dcr" {{
  name                    = "{self.config['dcr_name']}"
  target_resource_id      = azurerm_{vm_type}.{vm}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.main_dcr.id
}}
""")

        # ---------------------------------------------------------
        # Shutdown
        # ---------------------------------------------------------
        tf.write(f"""
## Auto Shutdown
resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm}_shutdown" {{
  virtual_machine_id    = azurerm_{vm_type}.{vm}.id
  location              = var.location
  enabled               = {str(self.config['shutdown_enabled']).lower()}
  daily_recurrence_time = "{self.config['shutdown_time']}"
  timezone              = "{self.config['shutdown_timezone']}"

  notification_settings {{
    enabled = false
  }}

  tags = {{
    {tags}
  }}
}}
""")

        # ---------------------------------------------------------
        # Custom Script Extension (LAST)
        # ---------------------------------------------------------
        sas_url = self.config["sas_url_linux"] if is_linux else self.config["sas_url_windows"]
        if sas_url:
            blob_file = os.path.basename(sas_url.split("?")[0])
            command = (
                f"sh {blob_file}" if is_linux else
                f"powershell -ExecutionPolicy Unrestricted -File {blob_file}"
            )

            tf.write(f"""
## Custom Script Extension (LAST)
resource "azurerm_virtual_machine_extension" "{vm}_customscript" {{
  name                       = "CustomScriptExtension"
  virtual_machine_id         = azurerm_{vm_type}.{vm}.id
  publisher                  = "{'Microsoft.Azure.Extensions' if is_linux else 'Microsoft.Compute'}"
  type                       = "CustomScriptExtension"
  type_handler_version       = "2.1"

  settings = jsonencode({{
    fileUris         = ["{sas_url}"]
    commandToExecute = "{command}"
  }})

  tags = {{
    {tags}
  }}
}}
""")
        else:
            tf.write(f"# WARNING: Custom Script skipped for {vm} — No SAS URL provided\n")


    # =============================================================================
    # WINDOWS / LINUX VM BLOCKS
    # =============================================================================
    def write_windows_vm(self, tf, vm, size, rg, tags):
        tf.write(f"""
## Windows VM
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
    {tags}
  }}
}}
""")

    def write_linux_vm(self, tf, vm, size, rg, tags):
        tf.write(f"""
## Linux VM
resource "azurerm_linux_virtual_machine" "{vm}" {{
  name                = "{vm}"
  resource_group_name = "{rg}"
  location            = var.location
  size                = "{size}"
  network_interface_ids = [azurerm_network_interface.{vm}_nic.id]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm}_admin_password.value
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
    {tags}
  }}
}}
""")

    # =============================================================================
    # FILE OUTPUT
    # =============================================================================
    def generate(self):
        os.makedirs(os.path.dirname(self.output_tf), exist_ok=True)

        print("[START] Terraform Generator v2.7")

        with open(self.output_tf, "w", encoding="utf-8") as tf:

            self.write_provider_block(tf)
            self.collect_resource_groups()
            self.write_resource_groups(tf)

            vm_list = []
            with open(self.csv_path, newline='', encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    if not row.get("vm_name"):
                        continue
                    vm_list.append(row["vm_name"].strip())
                    self.write_vm_block(tf, row)

        print(f"[OK] Terraform file generated: {self.output_tf}")
        print("[SUCCESS] Completed Terraform Generation")


# =============================================================================
# MAIN
# =============================================================================
if __name__ == "__main__":
    gen = TerraformVMGenerator()
    gen.generate()