#!/bin/bash

# Copy file to multiple RHEL servers using azureadmin
# Flow:
# Local -> /tmp -> sudo move -> /u01/software

# Usage:
# ./copy_file_to_servers.sh servers.txt

SOURCE_FILE="/mnt/c/Users/AnkojiRaoNagisetty/Documents/Downloads/LINUX.X64_193000_client.zip"
TEMP_PATH="/tmp"
DEST_PATH="/u01/software"

USERNAME="azureadmin"
SERVER_LIST="$1"

LOG_FILE="copy_log_$(date +%Y%m%d_%H%M%S).log"

SSH_OPTIONS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

SUCCESS=0
FAILED=0


if [ -z "$SERVER_LIST" ]; then
    echo "Usage: $0 <server_list_file>"
    exit 1
fi


if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: Source file not found: $SOURCE_FILE"
    exit 1
fi


if [ ! -f "$SERVER_LIST" ]; then
    echo "ERROR: Server list not found: $SERVER_LIST"
    exit 1
fi


FILE_NAME=$(basename "$SOURCE_FILE")


while IFS= read -r SERVER
do

    # Skip empty lines/comments
    [[ -z "$SERVER" || "$SERVER" =~ ^# ]] && continue

    echo "----------------------------------------" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') Processing $SERVER" | tee -a "$LOG_FILE"


    # Test SSH connection
    ssh $SSH_OPTIONS "$USERNAME@$SERVER" "echo Connected" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "$(date '+%F %T') FAILED: SSH connection $SERVER" | tee -a "$LOG_FILE"
        ((FAILED++))
        continue
    fi


    # Copy to /tmp
    echo "Copying file to /tmp..." | tee -a "$LOG_FILE"

    scp $SSH_OPTIONS "$SOURCE_FILE" \
        "$USERNAME@$SERVER:$TEMP_PATH/"

    if [ $? -ne 0 ]; then
        echo "$(date '+%F %T') FAILED: SCP $SERVER" | tee -a "$LOG_FILE"
        ((FAILED++))
        continue
    fi


    # Create directory and move file
    echo "Moving file to $DEST_PATH..." | tee -a "$LOG_FILE"


    ssh $SSH_OPTIONS "$USERNAME@$SERVER" "
        sudo mkdir -p $DEST_PATH &&
        sudo mv $TEMP_PATH/$FILE_NAME $DEST_PATH/ &&
        sudo chown oracle:dba $DEST_PATH/$FILE_NAME &&
        sudo chmod 664 $DEST_PATH/$FILE_NAME
    "


    if [ $? -eq 0 ]; then
        echo "$(date '+%F %T') SUCCESS: $SERVER" | tee -a "$LOG_FILE"
        ((SUCCESS++))
    else
        echo "$(date '+%F %T') FAILED: Move/Permission $SERVER" | tee -a "$LOG_FILE"
        ((FAILED++))
    fi


done < "$SERVER_LIST"


echo "========================================"
echo "Completed"
echo "Successful : $SUCCESS"
echo "Failed     : $FAILED"
echo "Log File   : $LOG_FILE"
echo "========================================"