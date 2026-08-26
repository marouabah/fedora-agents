#!/usr/bin/env bash
VM="${1:-neutron-template}"
DISK=$(virsh domblklist "$VM" --details 2>/dev/null | awk '/disk/{print $4}' | head -1)
echo "[fix-grub] VM: $VM | Disque: $DISK"

guestfish -a "$DISK" -i \
    sh "echo '=== BLS entries ===' && ls /boot/loader/entries/ 2>/dev/null" : \
    sh "echo '=== Contenu entry ===' && cat /boot/loader/entries/*.conf 2>/dev/null" : \
    sh "sed -i \
        -e 's/ rd\.lvm\.lv=[^ ]*//g' \
        -e 's/ rd\.driver\.blacklist=[^ ]*//g' \
        -e 's/ modprobe\.blacklist=[^ ]*//g' \
        -e 's/ nvidia[^ ]*//g' \
        -e 's/ crashkernel=[^ ]*//g' \
        /boot/loader/entries/*.conf 2>/dev/null || true" : \
    sh "echo '=== Apres patch ===' && grep '^options' /boot/loader/entries/*.conf"

echo "[fix-grub] BLS entries patches"
