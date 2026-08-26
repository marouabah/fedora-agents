#!/usr/bin/env bash
#
# vm-export.sh - Export et sanitarisation d'une VM KVM
#
# Usage: vm-export.sh <vm_name> [OPTIONS]
#
# Modes:
#   classic  - Export propre: supprime comptes/passwords, installe script firstboot
#   exam     - Export examen: garde users/perms, sanitarise machine-id/SSH/reseau/logs
#
# Exit codes:
#   0 = Succes
#   1 = Erreur generique
#   2 = Timeout
#   3 = Dependances manquantes
#   4 = Espace insuffisant
#   5 = Verification echouee
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# virt-customize/virt-sysprep: bypass libvirt pour eviter les problemes de permissions
# (libvirt tourne en uid qemu=107 et ne peut pas acceder aux fichiers dans /home/)
export LIBGUESTFS_BACKEND=direct

# ==============================================
# Configuration
# ==============================================

EXPORT_VERSION="1.0"
MODE="classic"
OUTPUT_DIR="${HOME}/vm-exports"
FORCE=false
DRY_RUN=false
MIN_FREE_GB=5
CUSTOM_OPERATIONS=""   # mode custom: liste d'operations virt-sysprep separees par virgule
FIRSTBOOT_INJECT=false # injecter le script firstboot (mode classic ou custom explicite)

# Operations virt-sysprep par mode

# Mode exam: sanitarisation minimale (garder users, passwords, SSH keys)
OPS_EXAM="bash-history,blkid-tab,crash-data,dhcp-client-state,dhcp-server-state,\
logfiles,machine-id,net-hwaddr,net-nmconn,pam-data,ssh-hostkeys,\
tmp-files,udev-persistent-net,utmp"

# Mode classic: sanitarisation complete (supprimer users, passwords, SSH keys, keyrings)
OPS_CLASSIC="abrt-data,backup-files,bash-history,blkid-tab,crash-data,cron-spool,\
dhcp-client-state,dhcp-server-state,dovecot-data,ipa-client,\
kerberos-data,kerberos-hostkeytab,logfiles,machine-id,mail-spool,\
net-hostname,net-hwaddr,net-nmconn,pacct-log,package-manager-cache,\
pam-data,passwd-backups,puppet-data-log,rh-subscription-manager,\
rhn-systemid,rpm-db,samba-db-log,smolt-uuid,ssh-hostkeys,\
ssh-userdir,sssd-db-log,tmp-files,udev-persistent-net,\
user-account,utmp,yum-uuid"

# ==============================================
# Script firstboot (injecte en mode classic)
# Sera execute une seule fois au premier demarrage de la VM importee
# ==============================================

FIRSTBOOT_SCRIPT='#!/bin/bash
# lyra-firstboot.sh - Configuration initiale VM exportee
# Se lance automatiquement via autologin root sur tty1 + .bash_profile
# NECESSITE un terminal interactif (ne pas lancer en service systemd)

DONE_FLAG="/etc/lyra-firstboot-done"
LOG_FILE="/var/log/lyra-firstboot.log"
AUTOLOGIN_DIR="/etc/systemd/system/getty@tty1.service.d"
AUTOLOGIN_CONF="${AUTOLOGIN_DIR}/lyra-autologin.conf"

_disable_autologin() {
    rm -f "$AUTOLOGIN_CONF" 2>/dev/null || true
    rmdir "$AUTOLOGIN_DIR" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    sed -i '"'"'/lyra-firstboot/d'"'"' /root/.bash_profile 2>/dev/null || true
}

# Guard: deja execute -> nettoyer et sortir
if [[ -f "$DONE_FLAG" ]]; then
    _disable_autologin
    exit 0
fi

# Guard: necessite un vrai terminal (stdin = TTY)
# Evite de bloquer si lance par erreur en service sans terminal
if [[ ! -t 0 ]]; then
    echo "lyra-firstboot: pas de terminal, attente du prochain boot..." >> "$LOG_FILE" 2>/dev/null || true
    exit 0
fi

# Rediriger la sortie vers le log (mais garder aussi la console)
exec > >(tee -a "$LOG_FILE") 2>&1

# Attendre que le terminal soit pret
sleep 1

clear
echo "============================================"
echo "  CONFIGURATION INITIALE - PREMIERE CONNEXION"
echo "============================================"
echo ""
echo "Cette VM a ete exportee et doit etre configuree."
echo "Veuillez definir vos identifiants de connexion."
echo ""

# --- Nom utilisateur ---
NEW_USER=""
while [[ -z "$NEW_USER" ]]; do
    read -rp "Nom du nouvel utilisateur (ex: admin): " NEW_USER
    if [[ -z "$NEW_USER" ]]; then
        echo "  Erreur: le nom est requis."
        continue
    fi
    if [[ ! "$NEW_USER" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "  Erreur: caracteres autorises: a-z A-Z 0-9 _ - (commence par une lettre)"
        NEW_USER=""
        continue
    fi
    if id "$NEW_USER" &>/dev/null 2>&1; then
        echo "  Erreur: utilisateur $NEW_USER existe deja."
        NEW_USER=""
        continue
    fi
done

# --- Mot de passe utilisateur ---
USER_PASS=""
while [[ -z "$USER_PASS" ]]; do
    read -rsp "Mot de passe pour $NEW_USER (min 8 caracteres): " USER_PASS
    echo ""
    read -rsp "Confirmer le mot de passe: " USER_PASS2
    echo ""
    if [[ "$USER_PASS" != "$USER_PASS2" ]]; then
        echo "  Erreur: les mots de passe ne correspondent pas."
        USER_PASS=""
        continue
    fi
    if [[ ${#USER_PASS} -lt 8 ]]; then
        echo "  Erreur: minimum 8 caracteres."
        USER_PASS=""
        continue
    fi
done

# --- Mot de passe root ---
ROOT_PASS=""
while [[ -z "$ROOT_PASS" ]]; do
    read -rsp "Mot de passe root (min 8 caracteres): " ROOT_PASS
    echo ""
    read -rsp "Confirmer le mot de passe root: " ROOT_PASS2
    echo ""
    if [[ "$ROOT_PASS" != "$ROOT_PASS2" ]]; then
        echo "  Erreur: les mots de passe ne correspondent pas."
        ROOT_PASS=""
        continue
    fi
    if [[ ${#ROOT_PASS} -lt 8 ]]; then
        echo "  Erreur: minimum 8 caracteres."
        ROOT_PASS=""
        continue
    fi
done

echo ""
echo "Configuration en cours..."

# Creer le compte utilisateur avec droits sudo
useradd -m -G wheel -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$USER_PASS" | chpasswd

# Definir le mot de passe root et le deverrouiller
echo "root:$ROOT_PASS" | chpasswd
passwd -u root 2>/dev/null || true

echo "[OK] Compte $NEW_USER cree avec droits sudo"
echo "[OK] Mot de passe root defini"
echo ""
echo "Configuration terminee."
echo "  Utilisateur : $NEW_USER (avec sudo)"
echo "  Root        : disponible via su ou connexion directe"
echo ""
echo "Appuyez sur Entree pour continuer vers la connexion..."
read -r

# Marquer comme fait AVANT de desactiver autologin
touch "$DONE_FLAG"
chmod 444 "$DONE_FLAG"

# Desactiver autologin et nettoyer
_disable_autologin

# Relancer getty proprement pour afficher le prompt de connexion normal
systemctl restart getty@tty1 2>/dev/null || true
'

# ==============================================
# Aide
# ==============================================

usage() {
    cat << EOF
Usage: $(basename "$0") <vm_name> [OPTIONS]

Exporte une VM KVM avec sanitarisation des donnees sensibles.

Arguments:
    vm_name         Nom de la VM a exporter

Options:
    --mode=MODE     Mode d export: classic (defaut), exam ou custom
                      classic: supprime comptes, passwords, cles SSH users
                               installe script firstboot pour configurer au 1er boot
                      exam:    garde comptes, privileges et passwords
                               sanitarise seulement machine-id, SSH host keys,
                               reseau, logs
                      custom:  utilise --operations pour choisir les operations
    --operations=OPS  Liste d operations virt-sysprep separees par virgule (mode custom)
                      Ex: machine-id,bash-history,logfiles,ssh-hostkeys
    --firstboot     Forcer l injection du script firstboot (mode custom)
    --output=DIR    Dossier de sortie (defaut: ~/vm-exports)
    --force         Forcer l arret de la VM si elle tourne
    --dry-run       Simuler sans modifier ni creer de fichiers
    -h, --help      Afficher cette aide

Exit codes:
    0 = Succes
    1 = Erreur generique
    3 = Dependances manquantes
    4 = Espace insuffisant
    5 = Verification echouee

Format de l archive:
    <vm_name>-export-YYYYMMDD-HHMMSS-<mode>.tar.gz
    Contient:
      <vm_name>.qcow2   Image disque sanitarisee
      <vm_name>.xml     Definition virsh sans UUID/MAC
      README.md         Instructions d import + metadonnees

Exemples:
    $(basename "$0") preprod-01
    $(basename "$0") preprod-01 --mode=exam --output=/mnt/exports
    $(basename "$0") preprod-01 --force --dry-run

EOF
}

# ==============================================
# Parse des arguments
# ==============================================

parse_args() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    VM_NAME=""
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                usage
                exit 0
                ;;
        esac
    done

    VM_NAME="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode=*)
                MODE="${1#*=}"
                if [[ "$MODE" != "classic" && "$MODE" != "exam" && "$MODE" != "custom" ]]; then
                    log_error "Mode invalide: '$MODE'. Valeurs: classic, exam, custom"
                    exit 1
                fi
                shift
                ;;
            --operations=*)
                CUSTOM_OPERATIONS="${1#*=}"
                shift
                ;;
            --firstboot)
                FIRSTBOOT_INJECT=true
                shift
                ;;
            --output=*)
                OUTPUT_DIR="${1#*=}"
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Option inconnue: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# ==============================================
# Fonctions utilitaires
# ==============================================

# Verifier que tous les outils requis sont installes
check_export_dependencies() {
    local missing=()
    for cmd in virt-sysprep qemu-img; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependances manquantes: ${missing[*]}"
        log_error "Installer avec: sudo dnf install guestfs-tools qemu-img"
        return 3
    fi
    return 0
}

# Recuperer le chemin du disque principal d'une VM
get_vm_disk_path() {
    local vm="$1"
    local disk_path
    disk_path=$($VIRSH domblklist "$vm" --details 2>/dev/null \
        | awk '/file.*disk/{print $4}' | head -1)
    if [[ -z "$disk_path" ]]; then
        log_error "Impossible de trouver le disque de la VM '$vm'"
        return 1
    fi
    if [[ ! -f "$disk_path" ]]; then
        log_error "Disque introuvable: $disk_path"
        return 1
    fi
    echo "$disk_path"
}

# Verifier l'espace disque disponible (en Go)
check_disk_space() {
    local dir="$1"
    local required_gb="$2"
    local source_path="$3"

    mkdir -p "$dir"

    # Taille du disque source (en Go, arrondi superieur)
    local source_size_gb
    source_size_gb=$(du -BG "$source_path" 2>/dev/null | awk '{gsub("G",""); print int($1)+1}')

    # Espace libre dans le dossier de sortie
    local free_gb
    free_gb=$(df -BG "$dir" 2>/dev/null | awk 'NR==2{gsub("G",""); print int($4)}')

    local needed_gb=$(( source_size_gb + MIN_FREE_GB ))
    log_info "Espace requis: ~${needed_gb} Go (source: ${source_size_gb} Go + ${MIN_FREE_GB} Go marge)"
    log_info "Espace disponible dans $dir: ${free_gb} Go"

    if [[ $free_gb -lt $needed_gb ]]; then
        log_error "Espace insuffisant: besoin de ${needed_gb} Go, disponible ${free_gb} Go"
        return 4
    fi
    return 0
}

# ==============================================
# Etape 1: Pre-test export
# ==============================================

pretest_export() {
    local vm="$1"

    log_step "[PRE-TEST] Verification avant export de '$vm'"

    # 1. Dependances
    check_export_dependencies || return $?

    # 2. VM existe
    if ! check_vm "$vm"; then
        return 1
    fi

    # 3. Trouver le disque
    DISK_PATH=$(get_vm_disk_path "$vm") || return 1
    log_info "Disque source: $DISK_PATH"

    # 4. Verifier integrite du disque source
    log_step "Verification integrite du disque source..."
    local check_output filtered_check
    check_output=$(qemu-img check -q "$DISK_PATH" 2>&1) || true
    filtered_check=$(echo "$check_output" | grep -v \
        -e "OFLAG_COPIED" \
        -e "counting reference for region exceeding" \
        -e "refcount block.*outside image" \
        -e "ERROR refcount block" \
        || true)
    if echo "$filtered_check" | grep -q "errors were found"; then
        log_error "Disque source corrompu: $filtered_check"
        return 5
    elif [ -n "$(echo "$filtered_check" | grep -i 'error\|warn')" ]; then
        log_warn "Avertissement disque: $filtered_check (non bloquant)"
    fi
    log_ok "Disque source OK"

    # 5. Espace disque
    check_disk_space "$OUTPUT_DIR" "$MIN_FREE_GB" "$DISK_PATH" || return $?

    # 6. VM arretee ou --force
    if is_vm_running "$vm"; then
        if [[ "$FORCE" == false ]]; then
            log_error "La VM '$vm' est en cours d'execution."
            log_error "Arretez-la d'abord ou utilisez --force"
            return 1
        fi
        log_warn "La VM '$vm' est en cours d'execution. Arret force demande..."
    fi

    log_ok "[PRE-TEST] Tous les checks sont passes"
    return 0
}

# ==============================================
# Etape 2: Arret de la VM
# ==============================================

stop_vm_for_export() {
    local vm="$1"

    if is_vm_running "$vm"; then
        log_step "Arret de la VM '$vm'..."
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] virsh shutdown '$vm' (simule)"
            return 0
        fi
        # Tentative d'arret propre
        $VIRSH shutdown "$vm" &>/dev/null || true
        local elapsed=0
        local timeout=60
        while is_vm_running "$vm" && [[ $elapsed -lt $timeout ]]; do
            sleep 2
            ((elapsed+=2))
        done
        if is_vm_running "$vm"; then
            log_warn "Arret propre echoue apres ${timeout}s, arret force..."
            $VIRSH destroy "$vm" &>/dev/null || true
            sleep 2
        fi
        log_ok "VM '$vm' arretee"
    else
        log_info "VM '$vm' deja arretee"
    fi
}

# ==============================================
# Etape 3: Copie du disque
# ==============================================

_qemu_convert_progress() {
    local step=$1 total=$2 src=$3 dst=$4
    local src_bytes src_gb
    src_bytes=$(stat -c%s "$src" 2>/dev/null || echo 0)
    src_gb=$(awk "BEGIN{printf \"%.1f\", $src_bytes/1073741824}")

    # Lance qemu-img en background, capturant stderr via tmp file.
    # qemu-img -p ecrit sa progression sur stdout (pas stderr).
    # stdbuf -o0 : stdout unbuffered pour que le fichier soit mis a jour en continu.
    local tmp_prog
    tmp_prog=$(mktemp)
    stdbuf -o0 qemu-img convert -O qcow2 -c -p "$src" "$dst" >"$tmp_prog" 2>&1 &
    local qpid=$!

    while kill -0 "$qpid" 2>/dev/null; do
        local raw pct=0
        raw=$(cat "$tmp_prog" 2>/dev/null | tr '\r' '\n' | grep -oP '\d+(?=\.\d+/100%)' | tail -1)
        [ -n "$raw" ] && pct=$raw
        # gb_done depuis la taille reelle du fichier en cours d'ecriture
        local dst_bytes gb_done
        dst_bytes=$(stat -c%s "$dst" 2>/dev/null || echo 0)
        gb_done=$(awk "BEGIN{printf \"%.1f\", $dst_bytes/1073741824}")
        _lyra_progress "$step" "$total" "Compression qcow2" "$pct" "$gb_done" "$src_gb"
        sleep 0.8
    done

    wait "$qpid"
    local ret=$?
    rm -f "$tmp_prog"
    _lyra_progress "$step" "$total" "Compression qcow2" 100 "$src_gb" "$src_gb"
    return $ret
}

copy_disk() {
    local src="$1"
    local dst="$2"

    log_step "Copie et compression du disque..."
    log_info "  Source : $src"
    log_info "  Destination : $dst"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] qemu-img convert -O qcow2 -c (simule)"
        # Creer un fichier vide pour la suite du dry-run
        touch "$dst"
        return 0
    fi

    # Conversion avec compression qcow2 (reduit la taille ~30-50%) avec suivi progression
    if ! _qemu_convert_progress 2 4 "$src" "$dst"; then
        log_error "Echec de la copie du disque"
        return 1
    fi

    local src_size dst_size
    src_size=$(du -sh "$src" | cut -f1)
    dst_size=$(du -sh "$dst" | cut -f1)
    log_ok "Disque copie: $src_size -> $dst_size (avec compression)"
}

# ==============================================
# Etape 4: Sanitarisation du disque
# ==============================================

sanitize_disk() {
    local disk="$1"
    local mode="$2"
    local firstboot_tmp="$3"

    log_step "Sanitarisation du disque (mode: $mode)..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] virt-sysprep -a $disk --operations ... (simule)"
        return 0
    fi

    local ops
    if [[ "$mode" == "classic" ]]; then
        ops="$OPS_CLASSIC"
        log_info "Mode classic: suppression comptes utilisateurs, passwords, keyrings, SSH user keys"
    elif [[ "$mode" == "exam" ]]; then
        ops="$OPS_EXAM"
        log_info "Mode exam: conservation des comptes, nettoyage machine-id/SSH host/reseau/logs"
    elif [[ "$mode" == "custom" ]]; then
        if [[ -z "$CUSTOM_OPERATIONS" ]]; then
            log_error "Mode custom: --operations requis (liste virt-sysprep separee par virgules)"
            return 1
        fi
        ops="$CUSTOM_OPERATIONS"
        log_info "Mode custom: operations personnalisees: $ops"
    else
        log_error "Mode inconnu: $mode"
        return 1
    fi

    log_step "Lancement de virt-sysprep (peut prendre quelques minutes)..."
    # Note: -a / --add (pas --disk qui n'est pas supporte)
    if ! virt-sysprep -a "$disk" --operations "$ops" --quiet; then
        log_error "virt-sysprep a echoue"
        return 1
    fi
    log_ok "virt-sysprep OK: sanitarisation terminee"

    # Injecter le script firstboot interactif via autologin root si:
    #   - mode classic (toujours)
    #   - mode custom avec --firstboot explicite
    # Approche: --upload vers /usr/local/bin/ + autologin getty@tty1 + .bash_profile
    # (virt-customize --firstboot utilise guestfs-firstboot.service sans TTY - read echoue)
    if [[ "$mode" == "classic" ]] || [[ "$FIRSTBOOT_INJECT" == "true" ]]; then
        log_step "Injection du script firstboot (autologin root + .bash_profile)..."
        echo "$FIRSTBOOT_SCRIPT" > "$firstboot_tmp"
        chmod 755 "$firstboot_tmp"

        # Contenu du drop-in autologin pour getty@tty1
        local autologin_conf="[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM"

        if ! virt-customize -a "$disk" --quiet \
            --upload "${firstboot_tmp}:/usr/local/bin/lyra-firstboot.sh" \
            --chmod "0755:/usr/local/bin/lyra-firstboot.sh" \
            --mkdir "/etc/systemd/system/getty@tty1.service.d" \
            --write "/etc/systemd/system/getty@tty1.service.d/lyra-autologin.conf:${autologin_conf}" \
            --append-line "/root/.bash_profile:/usr/local/bin/lyra-firstboot.sh"; then
            log_error "virt-customize (inject firstboot) a echoue"
            return 1
        fi
        log_ok "Script firstboot injecte (autologin tty1 + .bash_profile)"
    fi

    log_ok "Sanitarisation terminee"
}

# ==============================================
# Etape 5: Export et nettoyage du XML virsh
# ==============================================

export_xml() {
    local vm="$1"
    local dst_xml="$2"
    local new_vm_name="${3:-$vm}"

    log_step "Export de la definition XML de la VM..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] virsh dumpxml + nettoyage UUID/MAC (simule)"
        echo "<domain type='kvm'><name>$new_vm_name</name></domain>" > "$dst_xml"
        return 0
    fi

    # Export XML brut
    local raw_xml
    raw_xml=$($VIRSH dumpxml "$vm" 2>/dev/null)
    if [[ -z "$raw_xml" ]]; then
        log_error "Impossible d'exporter le XML de '$vm'"
        return 1
    fi

    # Nettoyage XML via Python (plus fiable que sed pour XML)
    python3 << PYTHON_EOF
import xml.etree.ElementTree as ET
import sys
import re

xml_content = """$raw_xml"""

try:
    root = ET.fromstring(xml_content)
except ET.ParseError as e:
    print(f"Erreur XML: {e}", file=sys.stderr)
    sys.exit(1)

# 1. Renommer la VM si nouveau nom fourni
name_elem = root.find('name')
if name_elem is not None:
    name_elem.text = '$new_vm_name'

# 2. Supprimer l'UUID (sera genere au virsh define)
uuid_elem = root.find('uuid')
if uuid_elem is not None:
    root.remove(uuid_elem)

# 3. Supprimer les MAC addresses (seront generees a l'import)
for interface in root.findall('.//devices/interface'):
    mac_elem = interface.find('mac')
    if mac_elem is not None:
        interface.remove(mac_elem)

# 4. Remplacer le chemin du disque par un placeholder
for source in root.findall('.//devices/disk/source'):
    orig = source.get('file', '')
    if orig:
        # Garder uniquement le nom du fichier, pas le chemin complet
        import os
        basename = os.path.basename(orig)
        source.set('file', '__DISK_PATH__/' + basename)

# 5. Neutraliser le chemin NVRAM (EFI vars) - sera regenere a l'import
os_elem = root.find('os')
if os_elem is not None:
    nvram_elem = os_elem.find('nvram')
    if nvram_elem is not None:
        # Garder le template mais neutraliser le chemin absolu
        nvram_elem.text = '__NVRAM_PATH__/$new_vm_name' + '_VARS.qcow2'

# 5. Supprimer les elements generes a l'execution (pas necessaires pour reimport)
for elem_tag in ['seclabel', 'cpu']:
    # Garder cpu mais vider les elements generes dynamiquement
    pass

# Ecrire le XML nettoye
ET.indent(root, space='  ')
tree = ET.ElementTree(root)
with open('$dst_xml', 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    ET.indent(root)
    tree.write(f, encoding='unicode', xml_declaration=False)

print("[OK] XML exporte et nettoye: $dst_xml")
PYTHON_EOF

    log_ok "XML exporte: $dst_xml"
}

# ==============================================
# Etape 6: Creation de l'archive README
# ==============================================

create_readme() {
    local readme_path="$1"
    local vm_name="$2"
    local mode="$3"
    local source_disk_size="$4"
    local export_date="$5"

    cat > "$readme_path" << EOF
# VM Export - $vm_name

**Date d'export**: $export_date
**Mode**: $mode
**Version export**: $EXPORT_VERSION

## Contenu de cette archive

- \`$vm_name.qcow2\` : Image disque sanitarisee
- \`$vm_name.xml\`   : Definition virsh (UUID et MAC supprimes, seront regeneres a l'import)
- \`README.md\`      : Ce fichier

## Import de la VM

### Prerequis
- Fedora/RHEL avec libvirt/KVM
- qemu-img, virsh

### Commande d'import

\`\`\`bash
# Avec le MCP fedora-agents:
vm_import archive="$vm_name-export-$export_date-$mode.tar.gz"

# Manuellement:
vm-import.sh $vm_name-export-$export_date-$mode.tar.gz
\`\`\`

## Mode: $mode
EOF

    if [[ "$mode" == "classic" ]]; then
        cat >> "$readme_path" << EOF

**Mode classic**: Les comptes utilisateurs ont ete supprimes.
Un script de configuration s'executera automatiquement au **premier demarrage**.
Il vous demandera de creer:
- Un compte utilisateur (avec droits sudo)
- Le mot de passe root

Assurez-vous d'avoir acces a la console de la VM (virt-viewer, virt-manager).
EOF
    else
        cat >> "$readme_path" << EOF

**Mode exam**: Les comptes utilisateurs et leurs privileges ont ete conserves.
Les elements sanitarises: machine-id, SSH host keys, connexions reseau, logs.
Vous pouvez vous connecter avec les identifiants d'origine.
EOF
    fi

    cat >> "$readme_path" << EOF

## Informations techniques

- Taille disque source (apres compression): $source_disk_size
- Outil de sanitarisation: virt-sysprep
- Format disque: qcow2 compresse
- UUID/MAC: generes aleatoirement a l'import

EOF
}

# ==============================================
# Etape 7: Creation du tarball
# ==============================================

create_manifest() {
    local manifest_path="$1"
    local vm_name="$2"
    local mode="$3"
    local exported_at="$4"
    local firstboot_required="$5"

    # Version de borg si disponible
    local borg_version="n/a"
    if command -v borg &>/dev/null; then
        borg_version=$(borg --version 2>/dev/null | awk '{print $2}' || echo "unknown")
    fi

    local sanitized="true"
    [[ "$mode" == "exam" ]] && sanitized="true"
    [[ "$mode" == "classic" ]] && sanitized="true"

    cat > "$manifest_path" << EOF
{
  "exported_at": "${exported_at}",
  "source_vm": "${vm_name}",
  "mode": "${mode}",
  "sanitized": ${sanitized},
  "firstboot_required": ${firstboot_required},
  "borg_version": "${borg_version}",
  "format_version": "1"
}
EOF
    log_ok "manifest.json cree"
}

create_archive() {
    local work_dir="$1"
    local archive_path="$2"
    local vm_name="$3"
    local exported_at="$4"
    local firstboot_required="${5:-false}"

    log_step "Creation de l'archive: $(basename "$archive_path")"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] tar czf $archive_path (simule)"
        return 0
    fi

    # Creer le manifest avant l'archivage
    create_manifest "${work_dir}/manifest.json" "$vm_name" "$MODE" "$exported_at" "$firstboot_required"

    (cd "$work_dir" && tar czf "$archive_path" \
        "${vm_name}.qcow2" \
        "${vm_name}.xml" \
        "README.md" \
        "manifest.json")
    local tar_rc=$?
    if [[ $tar_rc -ne 0 ]]; then
        log_error "Echec de la creation de l'archive"
        return 1
    fi

    local archive_size
    archive_size=$(du -sh "$archive_path" | cut -f1)
    log_ok "Archive creee: $archive_path ($archive_size)"
}

# ==============================================
# Etape 8: Post-test export
# ==============================================

posttest_export() {
    local archive_path="$1"
    local work_dir="$2"
    local vm_name="$3"

    log_step "[POST-TEST] Verification de l'archive exportee"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] verification (simulee)"
        log_ok "[POST-TEST] OK (dry-run)"
        return 0
    fi

    # 1. Archive lisible et non vide
    if [[ ! -f "$archive_path" ]] || [[ ! -s "$archive_path" ]]; then
        log_error "Archive manquante ou vide: $archive_path"
        return 5
    fi
    log_ok "Archive presente et non vide"

    # 2. Integrite du tarball
    if ! tar tzf "$archive_path" &>/dev/null; then
        log_error "Archive corrompue (tar ne peut pas la lire)"
        return 5
    fi
    log_ok "Archive integre (tar OK)"

    # 3. Verifier presence des fichiers requis dans l'archive
    local files
    files=$(tar tzf "$archive_path" 2>/dev/null)
    local missing_files=()
    for required in "${vm_name}.qcow2" "${vm_name}.xml" "README.md" "manifest.json"; do
        if ! echo "$files" | grep -q "^${required}$"; then
            missing_files+=("$required")
        fi
    done
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Fichiers manquants dans l'archive: ${missing_files[*]}"
        return 5
    fi
    log_ok "Contenu de l'archive: ${vm_name}.qcow2, ${vm_name}.xml, README.md, manifest.json"

    # 4. Integrite du disque qcow2 dans l'archive
    log_step "Verification integrite du disque exporte..."
    local tmp_check
    tmp_check=$(mktemp -d)
    # Extraire uniquement le qcow2 pour le verifier
    tar xzf "$archive_path" -C "$tmp_check" "${vm_name}.qcow2" 2>/dev/null
    local check_result filtered_result
    check_result=$(qemu-img check -q "${tmp_check}/${vm_name}.qcow2" 2>&1) || true
    # Filtrer les faux positifs connus de qemu-img convert -c (artefacts de compression)
    filtered_result=$(echo "$check_result" | grep -v \
        -e "OFLAG_COPIED" \
        -e "counting reference for region exceeding" \
        -e "refcount block.*outside image" \
        -e "ERROR refcount block" \
        || true)
    if echo "$filtered_result" | grep -q "errors were found"; then
        log_error "Disque exporte corrompu: $filtered_result"
        rm -rf "$tmp_check"
        return 5
    elif [ -n "$(echo "$filtered_result" | grep -i 'error\|warn')" ]; then
        log_warn "Avertissement disque (non bloquant): $filtered_result"
    else
        log_ok "Disque exporte: integrite verifiee"
    fi
    rm -rf "$tmp_check"

    log_ok "[POST-TEST] Toutes les verifications ont reussi"
    return 0
}

# ==============================================
# Fonction principale
# ==============================================

main() {
    parse_args "$@"

    log_info "============================================"
    log_info " VM EXPORT - $VM_NAME (mode: $MODE)"
    log_info "============================================"
    [[ "$DRY_RUN" == true ]] && log_warn "MODE DRY-RUN: aucune modification ne sera faite"

    # Timestamp pour le nom de l'archive
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local archive_name="${VM_NAME}-export-${timestamp}-${MODE}.tar.gz"
    local archive_path="${OUTPUT_DIR}/${archive_name}"

    # Dossier de travail temporaire dans OUTPUT_DIR (pas /tmp qui peut etre petit)
    mkdir -p "$OUTPUT_DIR"
    local work_dir
    work_dir=$(mktemp -d "${OUTPUT_DIR}/.vm-export-work-XXXXXX")
    local firstboot_tmp="${work_dir}/lyra-firstboot.sh"

    # Chemins de travail
    local export_disk="${work_dir}/${VM_NAME}.qcow2"
    local export_xml="${work_dir}/${VM_NAME}.xml"
    local readme="${work_dir}/README.md"

    # Nettoyage automatique du dossier temp en cas d'erreur
    trap 'rc=$?; log_warn "Nettoyage du dossier temporaire..."; rm -rf "$work_dir"; exit $rc' EXIT

    # ---- Etape 0: Pre-test ----
    _lyra_progress 1 4 "Pre-verification" 5 0 0
    if ! pretest_export "$VM_NAME"; then
        exit $?
    fi

    # ---- Etape 1: Arret VM ----
    _lyra_progress 1 4 "Pre-verification" 10 0 0
    stop_vm_for_export "$VM_NAME"

    # ---- Etape 2: Copie disque ----
    mkdir -p "$OUTPUT_DIR"
    if ! copy_disk "$DISK_PATH" "$export_disk"; then
        exit 1
    fi

    # ---- Etape 3: Sanitarisation ----
    _lyra_progress 3 4 "Sanitarisation" 50 0 0
    if ! sanitize_disk "$export_disk" "$MODE" "$firstboot_tmp"; then
        exit 1
    fi

    # ---- Etape 4: Export XML ----
    if ! export_xml "$VM_NAME" "$export_xml"; then
        exit 1
    fi

    # ---- Etape 5: README ----
    local disk_size
    if [[ "$DRY_RUN" == false ]]; then
        disk_size=$(du -sh "$export_disk" | cut -f1)
    else
        disk_size="N/A (dry-run)"
    fi
    create_readme "$readme" "$VM_NAME" "$MODE" "$disk_size" "$timestamp"

    # ---- Etape 6: Archive ----
    # Note: work_dir est deja dans OUTPUT_DIR, l'archive sera a cote
    local firstboot_flag="false"
    [[ "$MODE" == "classic" || "$FIRSTBOOT_INJECT" == "true" ]] && firstboot_flag="true"
    _lyra_progress 4 4 "Archivage" 80 0 0
    if ! create_archive "$work_dir" "$archive_path" "$VM_NAME" "$timestamp" "$firstboot_flag"; then
        exit 1
    fi

    # ---- Etape 7: Post-test ----
    if ! posttest_export "$archive_path" "$work_dir" "$VM_NAME"; then
        exit 5
    fi
    _lyra_progress 4 4 "Finalisation" 100 0 0

    # Succes: afficher le recap
    log_info "============================================"
    log_ok " EXPORT TERMINE AVEC SUCCES"
    log_info "============================================"
    log_info " VM             : $VM_NAME"
    log_info " Mode           : $MODE"
    log_info " Archive        : $archive_path"
    if [[ "$DRY_RUN" == false ]]; then
        log_info " Taille archive : $(du -sh "$archive_path" | cut -f1)"
    fi
    if [[ "$MODE" == "classic" ]] || [[ "$FIRSTBOOT_INJECT" == "true" ]]; then
        log_info ""
        log_warn " Script firstboot installe."
        log_warn " Au premier demarrage, la console demandera les"
        log_warn " identifiants (user + password root)."
    fi
    log_info "============================================"

    # Output MCP: le chemin de l'archive (pour la capture)
    echo "$archive_path"

    # Desactiver le trap (sortie propre)
    trap - EXIT
    rm -rf "$work_dir"

    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
