#!/bin/bash

# List of users to create
USERS=("abdanw-b" "mahsha-b" "mohnaz-b")

# Default password for all users (change in production!)
DEFAULT_PASS="ChangeMe123"

# Log file
LOGFILE="/var/log/user_setup.log"

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root." >&2
    exit 1
fi

echo "Starting user creation..." | tee -a "$LOGFILE"

for USER in "${USERS[@]}"; do
    if id "$USER" &>/dev/null; then
        echo "User '$USER' already exists. Skipping..." | tee -a "$LOGFILE"
    else
        useradd -m "$USER"
        echo "$USER:$DEFAULT_PASS" | chpasswd
        # chage -d 0 "$USER"
        # chage -M 90 -m 7 -W 14 "$USER"
        chage -M -1 "$USER"

        echo "$USER ALL=(ALL) ALL" > "/etc/sudoers.d/$USER"
        chmod 0440 "/etc/sudoers.d/$USER"

        echo "User '$USER' created with sudo access (password required)." | tee -a "$LOGFILE"
    fi
done

echo "User setup complete." | tee -a "$LOGFILE"
