#!/bin/bash
# List of users to create
USERS=("cortex")

# Default password for all users
DEFAULT_PASS="Cortexbab@123"

for USER in "${USERS[@]}"
do
    if id "$USER" &>/dev/null; then
        echo "User $USER already exists, skipping..."
    else
        # Create the user with a home directory
        useradd -m "$USER"

        # Set the default password
        echo "$USER:$DEFAULT_PASS" | chpasswd

        # Disable password expiration
        chage -M -1 "$USER"

        # Add regular sudo access via sudoers.d
        echo "$USER ALL=(ALL) ALL" > /etc/sudoers.d/$USER
        chmod 0440 /etc/sudoers.d/$USER

        echo "User $USER created with non-expiring password and sudo access."
    fi
done