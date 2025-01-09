import csv
import json
import subprocess
from collections import defaultdict
import logging

# Input CSV and output JSON paths
INPUT_CSV = "./R2R_UAEServerList_GenerateList-disk.csv"
OUTPUT_JSON = "./R2R_UAEServerList_GenerateList-disk1.json"

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def get_azure_resource_id(command):
    """Execute an Azure CLI command and return the output."""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        logging.error(f"Error executing command: {e.cmd}")
        logging.error(f"Error message: {e.stderr.strip()}")
        return None

def process_vm_details(vm):
    """Process VM details and retrieve disk IDs."""
    vm_name = vm["vmName"]
    resource_group = vm["resourceGroup"]
    recovery_resource_group_id = vm["recoveryResourceGroupId"]
    recovery_container_id = vm["recoveryContainerId"]
    recovery_azure_network_id = vm["recoveryAzureNetworkId"]
    recovery_subnet_name = vm["recoverySubnetName"]
    static_ip = vm.get("staticIp", None)  # Get static IP from the CSV row

    logging.info(f"Processing VM: {vm_name} in resource group: {resource_group}")

    # Get fabricObjectId (VM resource ID)
    fabric_object_id = get_azure_resource_id(
        f"az vm show --name {vm_name} --resource-group {resource_group} --query id -o tsv"
    )
    if fabric_object_id is None:
        logging.error(f"Failed to retrieve fabricObjectId for VM: {vm_name}")
        return None

    # Get OS disk ID
    os_disk_id = get_azure_resource_id(
        f"az vm show --name {vm_name} --resource-group {resource_group} "
        f"--query 'storageProfile.osDisk.managedDisk.id' -o tsv"
    )
    if os_disk_id is None:
        logging.error(f"Failed to retrieve OS disk ID for VM: {vm_name}")
        return None

    # Get data disk IDs
    data_disk_ids = get_azure_resource_id(
        f"az vm show --name {vm_name} --resource-group {resource_group} "
        f"--query 'storageProfile.dataDisks[].managedDisk.id' -o tsv"
    )
    # Split the returned value into a list of disk IDs (if there are multiple data disks)
    data_disk_ids_list = data_disk_ids.split("\n") if data_disk_ids else []

    if not data_disk_ids:
        logging.warning(f"No data disk IDs found for VM: {vm_name}, continuing...")
        data_disk_ids_list = []
    if not static_ip:
        logging.warning(f"No data disk IDs found for VM: {vm_name}, continuing...")
        static_ip = [] 
    vm_details = {
        "vmName": vm_name,
        "fabricObjectId": fabric_object_id,
        "osDiskId": os_disk_id,
        "recoveryResourceGroupId": recovery_resource_group_id,
        "recoveryContainerId": recovery_container_id,
        "recoveryAzureNetworkId": recovery_azure_network_id,
        "recoverySubnetName": recovery_subnet_name
    }

    if data_disk_ids_list:
        vm_details["dataDiskIds"] = data_disk_ids_list

    if static_ip:
         vm_details["staticIp"] = static_ip

    return vm_details

def set_azure_subscription(subscription):
    """Set the Azure subscription using the az CLI."""
    try:
        subprocess.run(f"az account set --subscription {subscription}", shell=True, check=True)
        logging.info(f"Azure subscription set to: {subscription}")
    except subprocess.CalledProcessError as e:
        logging.error(f"Error setting Azure subscription: {e.cmd}")
        logging.error(f"Error message: {e.stderr.strip()}")

def main():
    # Initialize list to store VM details
    vm_details = []

    # Dictionary to group VMs by subscription
    subscriptions = defaultdict(list)

    # Read the CSV file
    with open(INPUT_CSV, mode="r") as csv_file:
        csv_reader = csv.DictReader(csv_file)
        for row in csv_reader:
            # Skip the row if any required field is missing or null
            if any(not row[key] for key in ["vmName", "resourceGroup", "subscription", 
                                            "recoveryResourceGroupId", "recoveryContainerId", 
                                            "recoveryAzureNetworkId", "recoverySubnetName"]):
                logging.warning(f"Skipping incomplete or null row: {row}")
                continue  # Skip to the next row
            
            subscriptions[row["subscription"]].append(row)

    # Process each subscription
    for subscription in subscriptions:
        logging.info(f"Processing subscription: {subscription}")
        set_azure_subscription(subscription)  # Set the Azure subscription

        processed_vms = []
        for vm in subscriptions[subscription]:
            try:
                processed_vm = process_vm_details(vm)
                if processed_vm:  # Only add if the processing was successful
                    processed_vms.append(processed_vm)
                    logging.info(f"VM {vm['vmName']} processed successfully.")
            except Exception as e:
                logging.error(f"Error processing VM: {e}")
                continue

        vm_details.extend(processed_vms)

    # Write VM details to JSON file
    with open(OUTPUT_JSON, mode="w") as json_file:
        json.dump(vm_details, json_file, indent=4)

    logging.info(f"VM details saved to {OUTPUT_JSON}")

if __name__ == "__main__":
    main()