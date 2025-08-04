#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="Azureadmin"

for HOST in $(cat servers.txt); do
    echo "====== $HOST ======"
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no updatepassword.sh "$USERNAME@$HOST:/tmp/"
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$USERNAME@$HOST" "sudo bash /tmp/updatepassword.sh && rm -f /tmp/updatepassword.sh"
done

