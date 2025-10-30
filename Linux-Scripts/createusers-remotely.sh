#!/bin/bash

USERS=("mohnaz-b" "mahsha-b" "abdanw-b")
DEFAULT_PASS="ChangeMe123!"

for USER in "${USERS[@]}"; do
    if id "$USER" &>/dev/null; then
        echo "User $USER already exists, skipping..."
    else
        useradd -m "$USER"
        echo "$USER:$DEFAULT_PASS" | chpasswd
        chage -I -1 -m 0 -M 99999 -E -1 "$USER"
        echo "$USER ALL=(ALL) ALL" > /etc/sudoers.d/$USER
        chmod 0440 /etc/sudoers.d/$USER
        echo "User $USER created with sudo access."
    fi
done