#!/usr/bin/env bash
# Injecte un profil NetworkManager DHCP generique dans la VM (par nom d'interface)
# Usage: sudo ./fix-nm-connection-vm.sh <vm_name>
set -euo pipefail

VM_NAME="${1:-electron-backup-test}"
DISK=$(virsh domblklist "$VM_NAME" --details 2>/dev/null | awk '/disk/{print $4}' | head -1)

[[ -z "$DISK" ]] && { echo "ERREUR: disque introuvable"; exit 1; }
echo "[fix-nm] VM: $VM_NAME | Disque: $DISK"

TMPFILE=$(mktemp /tmp/nm-profile-XXXXXX.nmconnection)
trap "rm -f $TMPFILE" EXIT

cat > "$TMPFILE" << 'NMEOF'
[connection]
id=eth0-dhcp
type=ethernet
autoconnect=true

[ethernet]

[ipv4]
method=auto

[ipv6]
addr-gen-mode=eui64
method=auto

[proxy]
NMEOF

guestfish -a "$DISK" -i \
    mkdir-p /etc/NetworkManager/system-connections : \
    upload "$TMPFILE" /etc/NetworkManager/system-connections/eth0-dhcp.nmconnection : \
    chmod 0600 /etc/NetworkManager/system-connections/eth0-dhcp.nmconnection : \
    sh "for f in /etc/NetworkManager/system-connections/*.nmconnection; do \
          fname=\$(basename \"\$f\"); \
          [ \"\$fname\" = 'eth0-dhcp.nmconnection' ] && continue; \
          sed -i 's/^autoconnect=false/autoconnect=true/' \"\$f\"; \
          sed -i '/^autoconnect-priority=-[0-9]/d' \"\$f\"; \
          sed -i '/^interface-name=/d' \"\$f\"; \
        done" : \
    ls /etc/NetworkManager/system-connections/

echo "[fix-nm] Profil NM injecte + interface-name supprime de tous les profils existants"
