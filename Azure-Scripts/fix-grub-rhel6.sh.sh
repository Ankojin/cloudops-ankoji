#!/bin/bash
set -euo pipefail

MNT=/mnt/rescue

echo "[*] Run lsblk first to identify the broken VM disk (usually /dev/sdc)"
read -p "Enter the broken VM root partition (e.g., /dev/sdc1): " ROOT_PART
read -p "If /boot is separate, enter it (or press Enter to skip): " BOOT_PART

echo "[*] Mounting partitions..."
sudo mkdir -p $MNT
sudo mount $ROOT_PART $MNT

if [ -n "$BOOT_PART" ]; then
    sudo mkdir -p $MNT/boot
    sudo mount $BOOT_PART $MNT/boot
fi

echo "[*] Binding system dirs..."
for d in dev proc sys; do
    sudo mount --bind /$d $MNT/$d
done

echo "[*] Entering chroot..."
sudo chroot $MNT /bin/bash -c '
    echo "[*] Inside chroot..."
    if [ ! -x /sbin/grub-install ]; then
        echo "[!] Installing grub..."
        yum -y install grub
    fi

    echo "[*] Reinstalling grub on /dev/sda"
    grub-install /dev/sda

    echo "[*] Rebuilding /boot/grub/grub.conf"
    KERNEL=$(ls /boot/vmlinuz-* | head -n1 | xargs basename)
    INITRD=$(ls /boot/initramfs-*img | head -n1 | xargs basename)

    cat <<EOF > /boot/grub/grub.conf
default=0
timeout=5
hiddenmenu

title RHEL6 (hd0,0)
    root (hd0,0)
    kernel /$KERNEL ro root=/dev/sda1
    initrd /$INITRD
EOF

    ln -sf /boot/grub/grub.conf /boot/grub/menu.lst
    echo "[*] New grub.conf created:"
    cat /boot/grub/grub.conf
'

echo "[*] Cleaning up..."
for d in sys proc dev; do
    sudo umount -lf $MNT/$d || true
done
if [ -n "$BOOT_PART" ]; then
    sudo umount -lf $MNT/boot || true
fi
sudo umount -lf $MNT

echo "[*] Done. Detach disk from Rescue VM and reattach to original VM."