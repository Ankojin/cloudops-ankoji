#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="azureadmin"

for HOST in $(cat server1.txt); do
    echo "====== $HOST ======"
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no createusers-remotely.sh "$USERNAME@$HOST:/tmp/"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$HOST" "sudo bash /tmp/createusers-remotely.sh && rm -f /tmp/createusers-remotely.sh"
done

