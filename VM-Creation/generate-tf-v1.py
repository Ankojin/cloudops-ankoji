import base64
import csv

# Define paths for the CSV file and output Terraform file
csv_file_path = "./VM-Creation/Project/BaaS-Platform/baas-vms.csv"
output_tf_file = "./VM-Creation/Project/BaaS-Platform/main-v1.tf"
cloud_init_file = "./VM-Creation/Deployment-Cloud-init.yaml"  # Path to cloud-init file
# Function to read the cloud-init YAML file
def read_and_encode_cloud_init_yaml(file_path):
    try:
        with open(file_path, 'r') as f:
            # Read file and encode in Base64
            content = f.read()
            encoded_content = base64.b64encode(content.encode()).decode()
            return encoded_content
    except FileNotFoundError:
        print(f"Cloud-init file {file_path} not found.")
        return ""

# Read and encode the cloud-init file
cloud_init_content = read_and_encode_cloud_init_yaml(cloud_init_file)

# Function to parse tags from CSV
def parse_tags(tags_str):
    tags = {}
    if tags_str:
        tag_pairs = tags_str.split(';')
        for pair in tag_pairs:
            if '=' in pair:  # Ensure there's an '=' in each pair
                key, value = pair.split('=', 1)  # Split by `=`
                # Strip spaces and extra quotes
                tags[key.strip().strip('"')] = value.strip().strip('"')
    return tags

# Open the output Terraform file to write the configuration
with open(output_tf_file, "w") as tf_file:
    # Write the provider block with environment-based authentication
    tf_file.write("""
        
variable "location" {
  description = "Location for resources."
  type        = string
  default     = "Sweden Central"
}
""")

    # Dictionary to store unique provider aliases
    provider_aliases = {}

    # Read the CSV file and generate Terraform configuration for each VM
    with open(csv_file_path, newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            vm_name = row["vm_name"]
            vm_location=row["vm_location"]
            resource_group = row["resource_group"]
            vnet = row["vnet"]
            vnet_rg = row["vnet_rg"]
            subnet = row["subnet"]
            subnet_rg = row["subnet_rg"]
            subscription = row["subscription"]
            vm_size = row["vm_size"]
            os_publisher = row["os_publisher"]
            os_offer = row["os_offer"]
            os_sku = row["os_sku"]
            os_version = row["os_version"]
            custom_data = row["custom_data"]
            is_windows = row["is_windows"].lower() == "true"
            storage_account = row["storage_account"]  # Storage account for boot diagnostics and Post Conf script
            storage_container_name= row["storage_account_container_name"]  # Storage account Container for Post Conf script
            storage_blob_name= row["storage_account_blob_name"]  # Storage blob for Post Conf script
            storage_sas_token= row["storage_account_sas_token"]  # Storage sas token for Post Conf script
            azure_key_vault_rg=row["Azure_Key_Vault_rg"] # Azure Key Vault Resource group
            azure_key_vault_name=row["Azure_Key_Vault_Name"] # Azure Key Vault Name
            admin_password=row["admin_password"] # Azure Key Vault Admin Password
            dcr_rg          = row["dcr_rg"]  # Data collection Rule resource group
            dcr_associate   = row["dcr_associate"]  # Data collection Rule associat to the VM
            cloud_init_path = row["cloud_init_path"]
            static_ip = row["static_ip"]
            tags = parse_tags(row["tags"])           		


            # Collect additional disks information
            additional_disks = []
            for idx in range(1, 10):  # Assuming a maximum of 10 additional disks per VM
                lun = row.get(f"disk_lun_{idx}")
                disk_name = row.get(f"disk_name_{idx}")
                storage_type = row.get(f"storage_type_{idx}")
                disk_size_gb = row.get(f"disk_size_gb_{idx}")
                if lun and disk_name and storage_type and disk_size_gb:
                    additional_disks.append({
                        "lun": lun,
                        "disk_name": disk_name,
                        "storage_type": storage_type,
                        "disk_size_gb": disk_size_gb
                    })
                 # Construct the SAS URL
                sas_url = f"https://{storage_account}.blob.core.windows.net/{storage_container_name}/{storage_blob_name}?{storage_sas_token}"

                  # Set up a provider alias for each subscription if not already done
            if subscription not in provider_aliases:
                provider_aliases[subscription] = f"provider_{subscription.replace('-', '_')}"
                tf_file.write(f"""
                             
provider "azurerm"{{
  features {{}}
  subscription_id = "{subscription}"
}}

    # Provider alias for subscription
provider "azurerm" {{
  alias           = "{provider_aliases[subscription]}"
  features        {{}}
  subscription_id = "{subscription}"
}}
""")
            # Apply tags dynamically
            tags_str = ",\n  ".join([f'"{k}" = "{v}"' for k, v in tags.items()])

            # Data sources for resource group, VNet, subnet, Azure Key Vault and Data Collection rule for VM insights using provider alias
            tf_file.write(f"""
      resource "azurerm_resource_group" "{vm_name}_rg" {{
        name     = "{resource_group}"
        location = "{vm_location}"
        provider = azurerm.{provider_aliases[subscription]}
        tags = {{
        {tags_str}
        }}
      }}

      data "azurerm_resource_group" "{vm_name}_vnet_rg" {{
        name     = "{vnet_rg}"
        provider = azurerm.{provider_aliases[subscription]}
      }}

      data "azurerm_virtual_network" "{vm_name}_vnet" {{
        name                = "{vnet}"
        resource_group_name = data.azurerm_resource_group.{vm_name}_vnet_rg.name
        provider            = azurerm.{provider_aliases[subscription]}
      }}

      data "azurerm_subnet" "{vm_name}_subnet" {{
        name                 = "{subnet}"
        virtual_network_name = data.azurerm_virtual_network.{vm_name}_vnet.name
        resource_group_name  = data.azurerm_resource_group.{vm_name}_vnet_rg.name
        provider             = azurerm.{provider_aliases[subscription]}
      }}

      data "azurerm_monitor_data_collection_rule" "{vm_name}_dcr_associate" {{
        name                 = "{dcr_associate}"
        resource_group_name  = "{dcr_rg}"
        provider             = azurerm.{provider_aliases[subscription]}              
      }}

      data "azurerm_key_vault" "{vm_name}_key_vault_name" {{
        name                 = "{azure_key_vault_name}"
        resource_group_name  = "{azure_key_vault_rg}"
        provider             = azurerm.{provider_aliases[subscription]}
      }}

      data "azurerm_key_vault_secret" "{vm_name}_admin_password" {{
        name           = "{admin_password}"
        key_vault_id   = data.azurerm_key_vault.{vm_name}_key_vault_name.id
        provider       = azurerm.{provider_aliases[subscription]}
      }}

      """)
            
            # Configure the network interface with a static IP
            tf_file.write(f"""
resource "azurerm_network_interface" "{vm_name}_nic" {{
  name                = "{vm_name}-nic"
  location            = "{vm_location}"
  resource_group_name = resource.azurerm_resource_group.{vm_name}_rg.name
  provider            = azurerm.{provider_aliases[subscription]}

  ip_configuration {{
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.{vm_name}_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "{static_ip}"
  }}

}}
""")

           
            # Configure the Linux or Windows VM with respective settings
            if not is_windows:
                tf_file.write(f"""
resource "azurerm_linux_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = resource.azurerm_resource_group.{vm_name}_rg.name
  location            = "{vm_location}"
  size                = "{vm_size}"
  provider            = azurerm.{provider_aliases[subscription]}

  network_interface_ids = [
    azurerm_network_interface.{vm_name}_nic.id
  ]
  
  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  disable_password_authentication = "false"

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }}

  source_image_reference {{
    publisher = "{os_publisher}"
    offer     = "{os_offer}"
    sku       = "{os_sku}"
    version   = "{os_version}"
  }}
  tags = {{
    {tags_str}
  }}
  
  custom_data = "{cloud_init_content}"
  
  boot_diagnostics {{
   storage_account_uri = "https://{storage_account}.blob.core.windows.net/"
  }}
  
  }}
  
  # Auto Shutdown for Linux VM
resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}" {{
  virtual_machine_id = azurerm_linux_virtual_machine.{vm_name}.id
  location           = "{vm_location}"
  provider           = azurerm.{provider_aliases[subscription]}
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "Arab Standard Time"

    notification_settings {{
     enabled = false

  }}

}}
               
""")  
                            
                # Add additional data disks for Linux VM
                for disk in additional_disks:
                    tf_file.write(f"""
resource "azurerm_managed_disk" "{disk['disk_name']}" {{
  name                 = "{disk['disk_name']}"
  location             = "{vm_location}"
  resource_group_name  = resource.azurerm_resource_group.{vm_name}_rg.name
  provider             = azurerm.{provider_aliases[subscription]}
  storage_account_type = "{disk['storage_type']}"
  disk_size_gb         = {disk['disk_size_gb']}
  create_option        = "Empty"  
}}

resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_{disk['disk_name']}_attachment" {{
  managed_disk_id    = azurerm_managed_disk.{disk['disk_name']}.id
  virtual_machine_id = azurerm_linux_virtual_machine.{vm_name}.id
  lun                = {disk['lun']}
  create_option      = "Attach"
  caching            = "None"
}}

""")
          # Extensions for Linux VM
          
                tf_file.write(f"""
   
                # DependencyAgent

# resource "azurerm_virtual_machine_extension" "DependencyAgentLinux_{vm_name}" {{
#   name                 = "DependencyAgentLinux"
#   virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
#   publisher            = "Microsoft.Azure.Monitoring.DependencyAgent"
#   type                 = "DependencyAgentLinux"
#   type_handler_version = "9.10"
#   auto_upgrade_minor_version = true
#   settings  = <<SETTINGS
#     {{
#         "enableama": ["true"]
#     }}
#   SETTINGS
# }}
           # AzureMonitor Agent

# resource "azurerm_virtual_machine_extension" "AzureMonitorLinuxAgent_{vm_name}" {{
#   name                 = "AzureMonitorLinuxAgent"
#   virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
#   publisher            = "Microsoft.Azure.Monitor"
#   type                 = "AzureMonitorLinuxAgent"
#   type_handler_version = "1.33"
#   automatic_upgrade_enabled =  true
# }}

 
                # Enable VM Insights

resource "azurerm_monitor_data_collection_rule_association" "{vm_name}" {{
  name                    = "{dcr_associate}"
  target_resource_id      = azurerm_linux_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.{vm_name}_dcr_associate.id
  provider                = azurerm.{provider_aliases[subscription]}

  }}

                  # Custom Script for Disks initiliaze

resource "azurerm_virtual_machine_extension" "Custom_Script_{vm_name}" {{
  name                 = "CustomScriptExtension"
  virtual_machine_id   = azurerm_linux_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = <<SETTINGS
  {{
      "fileUris": ["{sas_url}"],
      "commandToExecute": "sh {storage_blob_name}"
      
  }}
  SETTINGS
}}
""")
            else:
                if is_windows:
                    tf_file.write(f"""
resource "azurerm_windows_virtual_machine" "{vm_name}" {{
  name                = "{vm_name}"
  resource_group_name = resource.azurerm_resource_group.{vm_name}_rg.name
  location            = "{vm_location}"
  size                = "{vm_size}"
  provider            = azurerm.{provider_aliases[subscription]}

  network_interface_ids = [
    azurerm_network_interface.{vm_name}_nic.id
  ]

  admin_username = "azureadmin"
  admin_password = data.azurerm_key_vault_secret.{vm_name}_admin_password.value
  license_type = "Windows_Server"

  os_disk {{
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }}

  source_image_reference {{
    publisher = "{os_publisher}"
    offer     = "{os_offer}"
    sku       = "{os_sku}"
    version   = "{os_version}"
  }}

  tags = {{
    {tags_str}
  }}
  boot_diagnostics {{
   storage_account_uri = "https://{storage_account}.blob.core.windows.net/"
  }}

  

}}
                # Auto Shutdown for Windows VM

resource "azurerm_dev_test_global_vm_shutdown_schedule" "{vm_name}" {{
  virtual_machine_id = azurerm_windows_virtual_machine.{vm_name}.id
  location           = "{vm_location}"
  provider           = azurerm.{provider_aliases[subscription]}
  enabled            = true

  daily_recurrence_time = "2000"
  timezone              = "Arab Standard Time"

    notification_settings {{
     enabled = false

  }}

}}
                 

""")
              
          # Add additional data disks for Windows VM
                for disk in additional_disks:
                      tf_file.write(f"""
resource "azurerm_managed_disk" "{disk['disk_name']}" {{
  name                 = "{disk['disk_name']}"
  location             = "{vm_location}"
  resource_group_name  = resource.azurerm_resource_group.{vm_name}_rg.name
  provider             = azurerm.{provider_aliases[subscription]}
  storage_account_type = "{disk['storage_type']}"
  disk_size_gb         = {disk['disk_size_gb']}
  create_option        = "Empty" 
}}

resource "azurerm_virtual_machine_data_disk_attachment" "{vm_name}_{disk['disk_name']}_attachment" {{
  managed_disk_id    = azurerm_managed_disk.{disk['disk_name']}.id
  virtual_machine_id = azurerm_windows_virtual_machine.{vm_name}.id
  lun                = {disk['lun']}
  create_option      = "Attach"
  caching            = "ReadWrite"
}}

""")

          # Extensions for Windows VM

                tf_file.write(f"""

                # DependencyAgent

# resource "azurerm_virtual_machine_extension" "DependencyAgentWindows_{vm_name}" {{
#   name                 = "DependencyAgentWindows"
#   virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
#   publisher            = "Microsoft.Azure.Monitoring.DependencyAgent"
#   type                 = "DependencyAgentWindows"
#   type_handler_version = "9.10"
#   auto_upgrade_minor_version = true
#   settings  = <<SETTINGS
#     {{
#         "enableama": ["true"]
#     }}
#   SETTINGS
# }}

                     # AzureMonitorWindowsAgent

# resource "azurerm_virtual_machine_extension" "AzureMonitorWindowsAgent_{vm_name}" {{
#   name                 = "AzureMonitorWindowsAgent"
#   virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
#   publisher            = "Microsoft.Azure.Monitor"
#   type                 = "AzureMonitorWindowsAgent"
#   type_handler_version = "1.30"
#   automatic_upgrade_enabled =  true
# }}

                # Enable VM Insights
resource "azurerm_monitor_data_collection_rule_association" "{vm_name}" {{
  name                    = "{dcr_associate}"
  target_resource_id      = azurerm_windows_virtual_machine.{vm_name}.id
  data_collection_rule_id = data.azurerm_monitor_data_collection_rule.{vm_name}_dcr_associate.id
  provider                = azurerm.{provider_aliases[subscription]}

  }}

                  # Custom Script extension for Windows VM

  resource "azurerm_virtual_machine_extension" "{vm_name}_Custom_Script" {{
  name                 = "{vm_name}-Postconf-script"
  virtual_machine_id   = azurerm_windows_virtual_machine.{vm_name}.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = <<SETTINGS
  {{
      "fileUris": ["{sas_url}"],
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File {storage_blob_name}"
  }}
  SETTINGS

}}

""")


    print("Terraform configuration has been generated in main-v1.tf")
