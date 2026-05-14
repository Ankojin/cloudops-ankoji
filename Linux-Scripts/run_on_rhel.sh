#!/bin/bash

read -s -p "Enter SSH password: " PASSWORD
echo

USERNAME="azureadmin"

while IFS=$'\n' read -r HOST || [[ -n "$HOST" ]]; do
    # Trim whitespace and carriage returns
    HOST=$(echo "$HOST" | tr -d '\r' | xargs)
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue  # Skip comments
    echo "====== $HOST ======"
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no createusers-remotely.sh "$USERNAME@$HOST:/tmp/"
    sshpass -p "$PASSWORD" ssh -n -o StrictHostKeyChecking=no "$USERNAME@$HOST" "printf '%s\n' '$PASSWORD' | sudo -S bash /tmp/createusers-remotely.sh && rm -f /tmp/createusers-remotely.sh"
    echo "Completed: $HOST"
    echo
done < server.txt

echo "All servers processed."

