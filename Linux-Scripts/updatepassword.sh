#!/bin/bash
USERS=("cortex")                       # List of users
DEFAULT_PASS="Cortexbab@123"          # Default password

for USER in "${USERS[@]}"; do
    if id "$USER" &>/dev/null; then
        echo "User $USER already exists, updating password..."
        echo "$USER:$DEFAULT_PASS" | chpasswd
    else
        echo "Creating user $USER..."
        useradd -m "$USER"
        echo "$USER:$DEFAULT_PASS" | chpasswd
        echo "$USER ALL=(ALL) ALL" > /etc/sudoers.d/$USER
        chmod 0440 /etc/sudoers.d/$USER
        echo "User $USER created and given sudo access."
    fi

    # Set password aging policy regardless of whether user was new or existing
    chage -I -1 -m 0 -M 99999 -E -1 "$USER"
done