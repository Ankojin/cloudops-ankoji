#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="azureadmin"

for HOST in $(cat servers.txt); do
    echo "====== $HOST ======"
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no createuser.sh "$USERNAME@$HOST:/tmp/"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$HOST" "sudo bash /tmp/createuser.sh && rm -f /tmp/createuser.sh"
done

