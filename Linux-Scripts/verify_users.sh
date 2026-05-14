#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="azureadmin"
USERS=("mohomr-b" "wilsol-b" "kirkol-b")

for HOST in $(cat server.txt); do
    HOST=$(echo "$HOST" | tr -d '[:space:]')
    [[ -z "$HOST" ]] && continue
    echo "====== Checking $HOST ======"
    for USER in "${USERS[@]}"; do
        sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$HOST" "echo '$PASSWORD' | sudo -S id $USER 2>&1"
    done
    echo
done
